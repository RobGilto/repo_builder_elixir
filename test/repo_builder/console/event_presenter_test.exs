defmodule RepoBuilder.Console.EventPresenterTest do
  @moduledoc """
  Unit tests for the console event presenter (issue polished-event-stream-cards): one
  per `Event` variant via `from_event/1`, the matching `from_payload/2` backfill, and the
  content-flattening / file-extraction / search-text edge cases. Live and backfill must
  agree where the persisted shape allows (regression guard against drift).
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Console.EventPresenter, as: P
  alias RepoBuilder.Harness.Event

  describe "from_event/1 — ToolCall" do
    test "summary names the tool, preview is a compact input, pill is set" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Bash",
          input: %{"command" => "echo hi"}
        })

      assert m.summary == "Using tool: Bash"
      assert m.tool_name == "Bash"
      assert m.preview == "command: echo hi"
      refute m.error?
      assert m.files == []
    end

    test "empty input yields no preview but keeps the summary" do
      m = P.from_event(%Event.ToolCall{harness: :fake, name: "Now", input: %{}})
      assert m.summary == "Using tool: Now"
      assert m.preview == nil
    end
  end

  describe "from_event/1 — ToolResult" do
    test "flattens the Claude block-list content and marks success" do
      content = [%{"type" => "text", "text" => "file contents here"}]
      m = P.from_event(%Event.ToolResult{harness: :claude, is_error: false, content: content})

      assert m.summary == "Tool result"
      assert m.preview == "file contents here"
      refute m.error?
    end

    test "error result sets error?" do
      m = P.from_event(%Event.ToolResult{harness: :fake, is_error: true, content: "boom"})
      assert m.error?
      assert m.preview == "boom"
    end

    test "non-binary / nested content degrades preview to nil without raising" do
      assert P.from_event(%Event.ToolResult{harness: :fake, is_error: false, content: nil}).preview ==
               nil

      assert P.from_event(%Event.ToolResult{harness: :fake, is_error: false, content: 42}).preview ==
               nil

      nested = %{"meta" => %{"deep" => %{"x" => 1}}}

      assert P.from_event(%Event.ToolResult{harness: :fake, is_error: false, content: nested}).preview ==
               nil
    end

    test "extracts file activity from a files list" do
      content = %{
        "content" => [%{"text" => "done"}],
        "files" => [
          %{"path" => "/a.ex", "action" => "read", "bytes" => 120},
          %{"path" => "/b.ex", "action" => "write", "size" => 88},
          %{"path" => "/c.ex"}
        ]
      }

      m = P.from_event(%Event.ToolResult{harness: :fake, is_error: false, content: content})

      assert m.files == [
               %{path: "/a.ex", action: :read, bytes: 120},
               %{path: "/b.ex", action: :write, bytes: 88},
               %{path: "/c.ex", action: :read, bytes: nil}
             ]

      assert m.preview == "done"
    end
  end

  describe "from_event/1 — TextDelta / Usage / Status / Done / Error" do
    test "TextDelta summary is the first line; long text goes to detail" do
      m = P.from_event(%Event.TextDelta{harness: :fake, text: "hello\nworld\nmore"})
      assert m.summary == "hello"
      assert m.detail == "hello\nworld\nmore"
    end

    test "TextDelta single short line has no extra detail" do
      m = P.from_event(%Event.TextDelta{harness: :fake, text: "ok"})
      assert m.summary == "ok"
      assert m.detail == nil
    end

    test "TextDelta surfaces response file activity from raw" do
      raw = %{"files" => [%{"path" => "/x.ex", "action" => "read", "bytes" => 10}]}
      m = P.from_event(%Event.TextDelta{harness: :fake, text: "consumed", raw: raw})
      assert m.files == [%{path: "/x.ex", action: :read, bytes: 10}]
    end

    test "Usage summarizes tokens, no preview" do
      m = P.from_event(%Event.Usage{harness: :fake, input_tokens: 12, output_tokens: 34})
      assert m.summary == "in=12 out=34"
      assert m.preview == nil
    end

    test "Status summary is the kind" do
      m = P.from_event(%Event.Status{harness: :fake, kind: :retry, detail: %{"attempt" => 2}})
      assert m.summary == "retry"
      assert m.preview == "attempt: 2"
    end

    test "Done reports the reason" do
      m = P.from_event(%Event.Done{harness: :fake, ok: true, reason: :success})
      assert m.summary == "reason=success"
      refute m.error?
    end

    test "Error reports reason + message and sets error?" do
      m = P.from_event(%Event.Error{harness: :fake, reason: :provider_error, message: "429"})
      assert m.summary == "provider_error: 429"
      assert m.error?
    end
  end

  describe "from_payload/2 parity + degradation" do
    test "text_delta payload renders like the live event" do
      live = P.from_event(%Event.TextDelta{harness: :fake, text: "hello\nworld"})
      back = P.from_payload(:text_delta, %{"text" => "hello\nworld", "thinking" => false})
      assert live.summary == back.summary
      assert live.detail == back.detail
    end

    test "error payload (clean persisted shape) matches the live model" do
      live = P.from_event(%Event.Error{harness: :fake, reason: :idle_timeout, message: "stalled"})
      back = P.from_payload(:error, %{"reason" => "idle_timeout", "message" => "stalled"})
      assert live.summary == back.summary
      assert back.error?
    end

    test "tool_call payload with name/input renders the polished summary" do
      back = P.from_payload(:tool_call, %{"name" => "Bash", "input" => %{"command" => "ls"}})
      assert back.summary == "Using tool: Bash"
      assert back.preview == "command: ls"
    end

    test "tool_result payload flattens content and reads isError" do
      back =
        P.from_payload(:tool_result, %{"content" => [%{"text" => "out"}], "isError" => true})

      assert back.summary == "Tool result"
      assert back.preview == "out"
      assert back.error?
    end

    test "degraded tool_call payload (raw frame) never dumps a raw map" do
      back = P.from_payload(:tool_call, %{"type" => "assistant", "message" => %{"x" => 1}})
      assert back.summary == "Using tool"
      assert back.tool_name == nil
      # No input map ⇒ no preview block, and certainly no raw `%{…}` dump.
      assert back.preview == nil
    end

    test "an unknown event type degrades to an empty summary" do
      assert P.from_payload(:mystery, %{}) == %{
               summary: "",
               preview: nil,
               detail: nil,
               tool_name: nil,
               error?: false,
               files: [],
               file_change: nil
             }
    end
  end

  describe "flatten_content/1" do
    test "handles claude list, nested envelope, bare string, and non-string terms" do
      assert P.flatten_content([%{"type" => "text", "text" => "a"}, %{"text" => "b"}]) == "a\nb"
      assert P.flatten_content(%{"content" => [%{"text" => "x"}]}) == "x"
      assert P.flatten_content(%{"text" => "y"}) == "y"
      assert P.flatten_content("plain") == "plain"
      assert P.flatten_content("") == nil
      assert P.flatten_content(nil) == nil
      assert P.flatten_content(99) == nil
      assert P.flatten_content(%{"other" => 1}) == nil
    end
  end

  describe "extract_files/1" do
    test "returns [] when there is no file activity" do
      assert P.extract_files(%{"content" => "nope"}) == []
      assert P.extract_files("string") == []
      assert P.extract_files(nil) == []
    end

    test "skips malformed entries" do
      files = %{"files" => [%{"no_path" => 1}, %{"path" => "/ok.ex"}]}
      assert P.extract_files(files) == [%{path: "/ok.ex", action: :read, bytes: nil}]
    end
  end

  describe "file_change — Write (live path)" do
    test "Write tool sets file_change.status = :created, added > 0, removed = 0" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Write",
          input: %{"file_path" => "/app/new.ex", "content" => "defmodule A, do: :ok\n"}
        })

      assert %{
               path: "/app/new.ex",
               status: :created,
               added: added,
               removed: 0,
               absolute?: true
             } = m.file_change

      assert added > 0
    end

    test "lowercase write (pi) is also recognized as :created" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "write",
          input: %{"file_path" => "/tmp/file.ex", "content" => "hello\nworld"}
        })

      assert m.file_change.status == :created
      assert m.file_change.added == 2
    end

    test "Write with empty content yields added = 0" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Write",
          input: %{"file_path" => "/x.ex", "content" => ""}
        })

      assert m.file_change.added == 0
      assert m.file_change.removed == 0
    end

    test "relative file_path sets absolute? = false" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Write",
          input: %{"file_path" => "relative/path.ex", "content" => "x"}
        })

      refute m.file_change.absolute?
    end
  end

  describe "file_change — Edit (live path)" do
    test "Edit tool sets file_change.status = :modified with correct added/removed" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Edit",
          input: %{
            "file_path" => "/app/foo.ex",
            "old_string" => "old line\nshared",
            "new_string" => "new line\nshared"
          }
        })

      assert m.file_change.status == :modified
      assert m.file_change.path == "/app/foo.ex"
      assert m.file_change.added >= 1
      assert m.file_change.removed >= 1
    end

    test "Edit with old_string == new_string gives 0/0 stats (no-op)" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Edit",
          input: %{
            "file_path" => "/app/foo.ex",
            "old_string" => "unchanged",
            "new_string" => "unchanged"
          }
        })

      assert m.file_change.added == 0
      assert m.file_change.removed == 0
    end

    test "Edit that only deletes lines has added = 0 and removed > 0" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Edit",
          input: %{
            "file_path" => "/app/foo.ex",
            "old_string" => "gone1\ngone2",
            "new_string" => ""
          }
        })

      assert m.file_change.added == 0
      assert m.file_change.removed >= 1
    end
  end

  describe "file_change — MultiEdit (live path)" do
    test "MultiEdit folds edits into a combined diff" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "MultiEdit",
          input: %{
            "file_path" => "/app/bar.ex",
            "edits" => [
              %{"old_string" => "alpha", "new_string" => "ALPHA"},
              %{"old_string" => "beta", "new_string" => "BETA"}
            ]
          }
        })

      assert m.file_change.status == :modified
      assert m.file_change.added >= 1
      assert m.file_change.removed >= 1
    end
  end

  describe "file_change — non-file tools" do
    test "Bash tool yields file_change = nil" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Bash",
          input: %{"command" => "ls"}
        })

      assert m.file_change == nil
    end

    test "unknown tool name yields file_change = nil" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Read",
          input: %{"file_path" => "/tmp/x.ex"}
        })

      assert m.file_change == nil
    end

    test "ToolResult always yields file_change = nil" do
      m = P.from_event(%Event.ToolResult{harness: :fake, is_error: false, content: "ok"})
      assert m.file_change == nil
    end
  end

  describe "file_change — backfill parity (from_payload)" do
    test "clean top-level payload (already-normalized) extracts file_change for Write" do
      back =
        P.from_payload(:tool_call, %{
          "name" => "Write",
          "input" => %{"file_path" => "/app/a.ex", "content" => "hello\nworld"}
        })

      assert %{status: :created, added: 2, removed: 0} = back.file_change
    end

    test "Claude raw frame (name/input nested under message.content tool_use block) works" do
      raw_frame = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "tu_123",
              "name" => "Edit",
              "input" => %{
                "file_path" => "/app/b.ex",
                "old_string" => "old line",
                "new_string" => "new line"
              }
            }
          ]
        }
      }

      back = P.from_payload(:tool_call, raw_frame)

      assert back.tool_name == "Edit"
      assert %{status: :modified, path: "/app/b.ex"} = back.file_change
      assert back.file_change.added >= 1
      assert back.file_change.removed >= 1
    end

    test "Claude raw frame for Write matches the live from_event render" do
      live =
        P.from_event(%Event.ToolCall{
          harness: :claude,
          name: "Write",
          input: %{"file_path" => "/app/c.ex", "content" => "line1\nline2"}
        })

      raw_frame = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "name" => "Write",
              "input" => %{"file_path" => "/app/c.ex", "content" => "line1\nline2"}
            }
          ]
        }
      }

      back = P.from_payload(:tool_call, raw_frame)

      assert live.file_change.status == back.file_change.status
      assert live.file_change.added == back.file_change.added
      assert live.file_change.removed == back.file_change.removed
      assert live.tool_name == back.tool_name
    end

    test "degraded raw frame (missing tool_use block) still degrades cleanly with nil file_change" do
      back = P.from_payload(:tool_call, %{"type" => "assistant", "message" => %{"x" => 1}})
      assert back.file_change == nil
      assert back.tool_name == nil
    end
  end

  describe "search_text/1" do
    test "drops substring duplicates so a response body is not repeated" do
      m = P.from_event(%Event.TextDelta{harness: :fake, text: "first line\nrest of body"})
      assert P.search_text(m) == "first line\nrest of body"
    end

    test "joins distinct summary + detail for a tool call" do
      m =
        P.from_event(%Event.ToolCall{
          harness: :fake,
          name: "Bash",
          input: %{"command" => "echo hi"}
        })

      text = P.search_text(m)
      assert text =~ "Using tool: Bash"
      assert text =~ "command: echo hi"
    end
  end
end
