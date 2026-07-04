defmodule RepoBuilderWeb.Console.ChatComponents do
  @moduledoc """
  Orchestrator chat components: chat/thinking/streaming bubbles, the tool-use
  card, the right chat/command panel, and the queued-messages strip.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.DashboardComponents, only: [cost_badge: 1]

  import RepoBuilderWeb.Console.SharedComponents,
    only: [activity_orb: 1, typing_indicator: 1]

  alias RepoBuilder.Orchestrator.ContextWindow

  # --- chat -----------------------------------------------------------------

  attr :role, :atom, required: true, values: [:user, :orchestrator]
  attr :label, :string, required: true
  attr :content, :string, required: true
  attr :time, :string, default: ""

  @doc "A chat bubble: user (right) or orchestrator (left)."
  @spec chat_message(map()) :: Phoenix.LiveView.Rendered.t()
  def chat_message(assigns) do
    ~H"""
    <div class={["flex flex-col gap-0.5", @role == :user && "items-end"]}>
      <div class="cns-bubble__label" style="color: var(--cns-text-2)">
        {@label} · {@time}
      </div>
      <div class={["cns-bubble", (@role == :user && "cns-bubble--user") || "cns-bubble--orch"]}>
        {@content}
      </div>
    </div>
    """
  end

  attr :content, :string, required: true
  attr :time, :string, default: ""

  @doc "Orchestrator THINKING bubble (purple, italic mono)."
  @spec thinking_bubble(map()) :: Phoenix.LiveView.Rendered.t()
  def thinking_bubble(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <div class="cns-bubble__label" style="color: var(--cns-thinking)">
        🤔 ORCHESTRATOR THINKING · {@time}
      </div>
      <div class="cns-bubble cns-bubble--thinking">{@content}</div>
    </div>
    """
  end

  attr :content, :string, required: true
  attr :thinking?, :boolean, default: false
  attr :label, :string, default: "ORCHESTRATOR"
  attr :time, :string, default: ""
  attr :id, :string, default: nil

  @doc """
  In-progress streaming bubble: the live token-by-token buffer for one harness
  turn, with a blinking caret. `thinking?: true` renders the reasoning variant.
  Coalesces partials in place; replaced by a finalized `chat_message`/`thinking_bubble`.
  """
  @spec streaming_bubble(map()) :: Phoenix.LiveView.Rendered.t()
  def streaming_bubble(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-0.5">
      <div
        class="cns-bubble__label"
        style={"color: var(#{(@thinking? && "--cns-thinking") || "--cns-text-2"})"}
      >
        {(@thinking? && "🤔 ORCHESTRATOR THINKING") || @label} · {@time}
      </div>
      <div class={[
        "cns-bubble cns-bubble--streaming",
        (@thinking? && "cns-bubble--thinking") || "cns-bubble--orch"
      ]}>
        {@content}<span class="cns-caret">▋</span>
      </div>
    </div>
    """
  end

  attr :tool_name, :string, required: true
  attr :params_json, :string, required: true, doc: "pretty-printed JSON params"
  attr :time, :string, default: ""

  @doc "Orchestrator ACTION (tool-use) card (amber, tool name + pretty JSON params)."
  @spec tool_use_card(map()) :: Phoenix.LiveView.Rendered.t()
  def tool_use_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <div class="cns-bubble__label" style="color: var(--cns-warning)">
        🔧 ORCHESTRATOR ACTION · {@time}
      </div>
      <div class="cns-bubble cns-bubble--tool">
        <div class="font-bold">{@tool_name}</div>
        <pre
          class="mt-1 overflow-x-auto whitespace-pre-wrap break-all text-[0.6875rem]"
          phx-no-curly-interpolation
        ><%= @params_json %></pre>
      </div>
    </div>
    """
  end

  # --- command panel (restyled launch/interrupt/ADW controls) ---------------

  attr :chat_width, :atom, default: :sm, values: [:sm, :md, :lg]
  attr :cost, :any, default: nil
  attr :estimate, :any, default: nil, doc: "token-derived live cost estimate (display-only)"

  attr :context_tokens, :integer,
    default: 0,
    doc: "the orchestrator's own context-window occupancy"

  attr :harness, :string, default: nil, doc: "the orchestrator's harness (drives window sizing)"
  attr :model, :string, default: nil, doc: "the orchestrator's model (drives window sizing)"

  attr :typing?, :boolean, default: false
  attr :auto_follow?, :boolean, default: true
  slot :messages, doc: "rendered chat bubbles"

  @doc "Right chat/command panel: chat header (context bar + clear + width toggle + cost) + the orchestrator text stream. Input is the ⌘K command modal."
  @spec command_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def command_panel(assigns) do
    window = ContextWindow.size(assigns.harness || "", assigns.model)

    assigns =
      assigns
      |> assign(:window, window)
      |> assign(:ctx_pct, context_pct(assigns.context_tokens, window))

    ~H"""
    <div id="command-panel" class="flex h-full flex-col gap-3">
      <div class="flex flex-col gap-2 border-b pb-2" style="border-color: var(--cns-border)">
        <div class="flex items-center justify-between">
          <span
            class="flex items-center gap-1.5 text-xs font-semibold"
            style="color: var(--cns-cyan)"
          >
            ORCHESTRATOR <.activity_orb variant={:orchestrator} active?={@typing?} />
          </span>
          <div class="flex items-center gap-2">
            <.cost_badge cost={@cost} estimated={@estimate} />
            <div class="cns-toggle">
              <button
                type="button"
                id="chat-width"
                phx-click="cycle_chat_width"
                class="cns-toggle__seg cns-toggle__seg--active"
                title="Chat width — click to cycle SM / MD / LG"
              >
                {@chat_width |> Atom.to_string() |> String.upcase()}
              </button>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <div class="min-w-0 flex-1">
            <div
              class="flex items-center justify-between text-[0.5625rem]"
              style="color: var(--cns-text-2)"
            >
              <span>CONTEXT WINDOW</span>
              <span>{ktok(@context_tokens)} / {ktok(@window)}</span>
            </div>
            <div class="cns-ctx-bar mt-1">
              <div class="cns-ctx-bar__fill" style={"width: #{@ctx_pct}%"} />
            </div>
          </div>
          <button
            type="button"
            id="clear-orchestrator-context"
            phx-click="clear_orchestrator_context"
            class="cns-chip shrink-0"
            title="Clear the orchestrator's conversation context — the next turn starts fresh"
          >
            Clear
          </button>
        </div>
      </div>

      <div
        id="chat-log"
        phx-hook="AutoScroll"
        data-auto-follow={to_string(@auto_follow?)}
        tabindex="0"
        role="log"
        aria-label="Chat log"
        class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto pr-1"
      >
        {render_slot(@messages)}
        <.typing_indicator :if={@typing?} />
      </div>
    </div>
    """
  end

  # --- orchestrator message queue strip -------------------------------------

  attr :busy?, :boolean, default: false, doc: "a turn is currently in flight"
  attr :depth, :integer, default: 0, doc: "number of queued operator/auto-resume turns"

  attr :queued, :list,
    default: [],
    doc: "pending items: %{id, preview, kind} maps, in FIFO order"

  @doc """
  The pending-message strip (issue message-queue): a busy/queued badge plus one chip
  per queued turn with a cancel button. Hidden entirely when the orchestrator is idle
  with an empty queue, so it never takes vertical space in the common case.
  """
  @spec queued_messages(map()) :: Phoenix.LiveView.Rendered.t()
  def queued_messages(assigns) do
    ~H"""
    <div
      :if={@busy? or @depth > 0}
      id="orchestrator-queue"
      class="flex flex-wrap items-center gap-1.5 border-t px-3 py-1.5"
      style="border-color: var(--cns-border)"
    >
      <span
        id="queue-badge"
        class="text-[0.625rem] font-semibold uppercase"
        style="color: var(--cns-text-2)"
      >
        {if @busy?, do: "Busy", else: "Idle"} · {@depth} queued
      </span>
      <span
        :for={item <- @queued}
        id={"queued-#{item.id}"}
        class="cns-chip flex items-center gap-1"
        title={item.preview}
      >
        <span :if={item.kind == :auto_resume} class="text-[0.625rem]" style="color: var(--cns-text-3)">
          auto
        </span>
        <span class="max-w-[14rem] truncate">{item.preview}</span>
        <button
          type="button"
          id={"cancel-queued-#{item.id}"}
          phx-click="cancel_queued"
          phx-value-id={item.id}
          class="font-bold"
          title="Cancel"
          aria-label="Cancel queued message"
        >
          ×
        </button>
      </span>
    </div>
    """
  end

  # Duplicated from Console.SharedComponents (private there; also used by its
  # agent_card): context-window occupancy % and k-token label.
  @spec context_pct(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp context_pct(tokens, window), do: min(100, div(tokens * 100, max(window, 1)))

  @spec ktok(non_neg_integer()) :: String.t()
  defp ktok(tokens), do: "#{div(tokens, 1000)}k"
end
