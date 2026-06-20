defmodule RepoBuilder.Prompts.SlashExpander do
  @moduledoc """
  Server-side slash-command expansion (harness-agnostic, control-owned).

  Some harnesses expand `/slash-command` invocations natively (Claude Code), others
  do not (pi passes the prompt as raw argv). This module moves expansion INTO the
  platform so behavior is uniform across every harness: before a prompt reaches a
  live session, each recognized leading slash-command invocation is replaced by the
  body of the matching `.claude/commands/<name>.md` file (arguments substituted), and
  anything we do not recognize is left byte-for-byte.

  Matching rules:

    * An invocation is recognized ONLY when `/<name>` is the FIRST non-whitespace
      token of a line (Claude semantics) — mid-line `/x`, code-fence content, and bare
      paths like `/usr/bin` are never touched.
    * `<name>` is matched liberally, then confirmed by EXACT membership in the
      discovered command set (`RepoBuilder.Definitions` merges app-root ∪ working-dir,
      the working dir winning). "Not found ⇒ keep the literal line" falls out of this:
      an unknown name is never in the set, so it is passed through unchanged.
    * Built-in / reserved commands (`#{inspect(~w(compact clear resume help model))}`)
      are never expanded even if a same-named file exists — this protects the harness's
      native `/compact` (used internally by `Orchestrator.Tools`).

  Argument handling: the remainder of the invocation line is `$ARGUMENTS`; its
  whitespace-split tokens are `$1`, `$2`, …. A body that templates neither but receives
  a non-empty argument string gets the args appended on a trailing line, so commands
  that don't interpolate still see what the caller passed.

  Pure and fail-silent: it never mutates the filesystem and never raises — a read or
  parse error on a command file degrades to keeping the original line.
  """
  alias RepoBuilder.Definitions
  alias RepoBuilder.Orchestrator.Template

  @typep index :: %{optional(String.t()) => String.t()}

  # Built-in harness commands we must never shadow with a file-based expansion.
  @reserved ~w(compact clear resume help model)

  # Leading `/<name>` (first non-whitespace token on the line) + the rest of the line.
  @leading_re ~r/\A\s*\/([A-Za-z0-9:_\-]+)\s?(.*)\z/

  @doc """
  Expand every recognized leading slash-command invocation in `prompt`, resolving
  command files from `working_dir` (merged over the app root). Unknown, reserved, or
  unreadable invocations — and all ordinary text — are returned unchanged.
  """
  @spec expand(String.t(), working_dir :: String.t() | nil) :: String.t()
  def expand(prompt, working_dir) when is_binary(prompt) do
    case index(working_dir) do
      empty when map_size(empty) == 0 ->
        prompt

      index ->
        prompt
        |> String.split("\n")
        |> Enum.map_join("\n", &expand_line(&1, index))
    end
  end

  def expand(prompt, _working_dir), do: prompt

  # Expand a single line when its leading token is a known, non-reserved command whose
  # file reads cleanly; otherwise return the line verbatim.
  @spec expand_line(String.t(), index()) :: String.t()
  defp expand_line(line, index) do
    with [_full, name, rest] <- Regex.run(@leading_re, line),
         false <- name in @reserved,
         path when is_binary(path) <- Map.get(index, name),
         {:ok, body} <- body(path) do
      substitute(body, String.trim(rest))
    else
      _other -> line
    end
  end

  # Build the `name => path` index for the merged (app ∪ working-dir) command set,
  # reusing the same discovery the file-driven palette uses.
  @spec index(String.t() | nil) :: index()
  defp index(working_dir) do
    :slash_command
    |> Definitions.list(working_dir)
    |> Map.new(fn cmd -> {cmd.name, cmd.path} end)
  end

  # Read a command file's BODY (frontmatter stripped) via the shared template parser.
  @spec body(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp body(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, attrs} <- Template.from_markdown(raw),
         body when is_binary(body) <- attrs["body"] do
      {:ok, body}
    else
      _other -> {:error, :unreadable}
    end
  end

  # Substitute `$ARGUMENTS`/positional `$N` placeholders. With args but no placeholder,
  # append the args so non-templated commands still receive them.
  @spec substitute(String.t(), String.t()) :: String.t()
  defp substitute(body, args) do
    positional = if args == "", do: [], else: String.split(args, ~r/\s+/, trim: true)

    replaced =
      body
      |> String.replace("$ARGUMENTS", args)
      |> replace_positional(positional)

    if args != "" and not placeholder?(body),
      do: replaced <> "\n\n" <> args,
      else: replaced
  end

  @spec replace_positional(String.t(), [String.t()]) :: String.t()
  defp replace_positional(body, positional) do
    Regex.replace(~r/\$(\d+)/, body, fn _whole, num ->
      Enum.at(positional, String.to_integer(num) - 1, "")
    end)
  end

  @spec placeholder?(String.t()) :: boolean()
  defp placeholder?(body) do
    String.contains?(body, "$ARGUMENTS") or Regex.match?(~r/\$\d+/, body)
  end
end
