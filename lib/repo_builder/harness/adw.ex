defmodule RepoBuilder.Harness.Adw do
  @moduledoc """
  ADW harness adapter (BUILD_PROMPT.md §4/§10, issue-the-adw-gap).

  Treats a portable Python AI Developer Workflow as "just another harness". The
  ADWs stay standalone scripts (reusable by any product, Elixir or not); this
  adapter shells out to one and maps its neutral stdout-JSON event stream onto the
  canonical `RepoBuilder.Harness.Event` set, so the generic §6 session runtime owns
  spawn/stream/interrupt/terminate exactly as it does for Claude/pi/cursor.

  ## `command/1`

  Builds the argv to run the discovered workflow script in `--emit json` mode:

      uv run <script.py> --prompt <input> --working-dir <cwd> --adw-id <id> [--model <m>] --emit json

  The script path, ADW slug, and run id are resolved at launch time by
  `Orchestrator.Tools.start_adw/2` (from `RepoBuilder.Definitions.Adw` discovery)
  and threaded in via `opts.config`:

    * `config["adw_script"]` — absolute path to the workflow `.py` (falls back to
      `adws/adw_workflows/adw_<type>.py` under the cwd);
    * `config["adw_type"]`   — the workflow slug (for the `session_ctx` + default path);
    * `config["adw_id"]`     — the run/correlation id;
    * `config["adw_runner"]` — interpreter override (default `uv run`). A test fixture
      sets this to e.g. `"bash"` so a canned-event script replays through the real
      spawn path without `uv`/Python.

  ## `normalize/2`

  Delegates each decoded stdout frame to `RepoBuilder.Harness.Adw.EventSchema.decode/2`
  (a tight, versioned decoder). Never raises; unknown/older/malformed frames `:skip`.

  ## Lifecycle (single system of record)

  The spawned `uv`/Python parent is recorded in `OsPidLedger` and reaped by
  `OrphanReaper` like any session child; the §6 runtime spawns it in its own process
  group (`{:group, 0}`, `:kill_group`), so an interrupt reaps the Python→Claude child
  tree. In `--emit json` mode the Python ADW emits ONLY to stdout (its websocket/DB
  emitters stay off), so the Elixir `agent_logs` are the single record.
  """
  @behaviour RepoBuilder.Harness

  alias RepoBuilder.Harness.Adw.EventSchema

  @harness :adw
  @default_runner_exe "uv"
  @default_runner_pre ["run"]

  @impl true
  def command(opts) do
    config = Map.get(opts, :config, %{})
    type = string(config["adw_type"]) || "plan_build"
    adw_id = string(config["adw_id"]) || ""
    model = opts[:model]
    cwd = to_string(opts.cwd)
    script = string(config["adw_script"]) || default_script(cwd, type)

    {exe, pre_args} = runner(config["adw_runner"])

    args =
      pre_args ++
        [script] ++
        ["--prompt", opts.prompt, "--working-dir", cwd, "--adw-id", adw_id] ++
        model_args(model) ++
        ["--emit", "json"]

    ctx = %{
      harness: @harness,
      model: model,
      adw_id: adw_id,
      adw_type: type,
      price_table: Map.get(opts, :price_table, %{})
    }

    {exe, args, env(opts), ctx}
  end

  @impl true
  def normalize(raw, ctx) when is_map(raw), do: EventSchema.decode(raw, ctx)
  def normalize(_raw, _ctx), do: :skip

  # --- argv construction ---

  @spec runner(term()) :: {String.t(), [String.t()]}
  defp runner(custom) when is_binary(custom) and custom != "", do: {custom, []}
  defp runner(_custom), do: {@default_runner_exe, @default_runner_pre}

  # The conventional location for a portable workflow script of `type` under the cwd.
  @spec default_script(String.t(), String.t()) :: String.t()
  defp default_script(cwd, type), do: Path.join([cwd, "adws", "adw_workflows", "adw_#{type}.py"])

  @spec model_args(String.t() | nil) :: [String.t()]
  defp model_args(model) when is_binary(model) and model != "", do: ["--model", model]
  defp model_args(_model), do: []

  # Secrets stay in env (never argv, never logged). `ADW_EMIT=json` mirrors the `--emit
  # json` flag for scripts that prefer the env toggle; both select the neutral mode.
  @spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
  defp env(opts) do
    secret_env =
      opts
      |> Map.get(:secrets, %{})
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    [{"ADW_EMIT", "json"} | secret_env]
  end

  @spec string(term()) :: String.t() | nil
  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
