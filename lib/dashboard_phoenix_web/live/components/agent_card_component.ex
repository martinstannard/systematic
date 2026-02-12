defmodule DashboardPhoenixWeb.Live.Components.AgentCardComponent do
  @moduledoc """
  Unified card component for displaying all agent types in the Work Panel.

  Supports:
  - Claude sub-agents (🟣)
  - OpenCode sessions (🔷)
  - Gemini CLI (✨)
  - Any other agent type with consistent styling

  Features:
  - Agent icon based on type
  - Task/session name
  - Real-time duration updates (via LiveDuration hook)
  - Color-coded state indicators (running/completed/failed/idle)
  - **Expandable details** with smooth animation showing:
    - Recent messages/actions
    - Token usage (input/output)
    - Cost information
    - Model details
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.Status

  @type agent_type :: :claude | :opencode | :gemini | :openai | :subagent | :unknown
  @type state :: :running | :completed | :failed | :idle

  @doc """
  Extracts a short model name for display (e.g., "opus", "sonnet", "gemini").
  """
  def short_model_name(nil), do: nil

  def short_model_name(model) when is_binary(model) do
    model_lower = String.downcase(model)

    cond do
      String.contains?(model_lower, "opus") -> "opus"
      String.contains?(model_lower, "sonnet") -> "sonnet"
      String.contains?(model_lower, "haiku") -> "haiku"
      String.contains?(model_lower, "gemini") -> "gemini"
      String.contains?(model_lower, "gpt-4o") -> "gpt-4o"
      String.contains?(model_lower, "gpt-4") -> "gpt-4"
      String.contains?(model_lower, "gpt-3") -> "gpt-3"
      String.contains?(model_lower, "o1") -> "o1"
      String.contains?(model_lower, "o3") -> "o3"
      true -> nil
    end
  end

  def short_model_name(_), do: nil

  @doc """
  Determines the agent type info (atom, display name, icon) from the type string or model.
  """
  def agent_type_info("claude"), do: {:claude, "Claude", "🟣"}
  def agent_type_info("opencode"), do: {:opencode, "OpenCode", "🔷"}
  def agent_type_info("subagent"), do: {:subagent, "Sub-agent", "🤖"}
  def agent_type_info("gemini"), do: {:gemini, "Gemini", "✨"}
  def agent_type_info("openai"), do: {:openai, "OpenAI", "🔥"}
  def agent_type_info("anthropic/" <> _), do: {:claude, "Claude", "🟣"}
  def agent_type_info("google/" <> _), do: {:gemini, "Gemini", "✨"}
  def agent_type_info("openai/" <> _), do: {:openai, "OpenAI", "🔥"}

  def agent_type_info(model) when is_binary(model) do
    cond do
      String.contains?(model, "claude") -> {:claude, "Claude", "🟣"}
      String.contains?(model, "gemini") -> {:gemini, "Gemini", "✨"}
      String.contains?(model, "gpt") -> {:openai, "OpenAI", "🔥"}
      String.contains?(model, "opencode") -> {:opencode, "OpenCode", "🔷"}
      true -> {:unknown, "Agent", "⚡"}
    end
  end

  def agent_type_info(_), do: {:unknown, "Agent", "⚡"}

  @doc """
  Normalizes a status string to a state atom.
  """
  def normalize_state(status) do
    cond do
      status == Status.running() -> :running
      status == Status.active() -> :running
      status == Status.completed() -> :completed
      status == Status.done() -> :completed
      status == Status.failed() -> :failed
      status == Status.error() -> :failed
      status == Status.idle() -> :idle
      status == "ready" -> :idle
      status == Status.stopped() -> :idle
      true -> :idle
    end
  end

  @impl true
  def update(assigns, socket) do
    # Extract and normalize agent info (handle nil gracefully)
    agent = Map.get(assigns, :agent) || %{}

    # For icon/provider determination, prefer model over type
    icon_key =
      Map.get(agent, :model, nil) || Map.get(assigns, :type) || Map.get(agent, :type, nil)

    {type_atom, type_name, icon} = agent_type_info(icon_key)

    # Determine state
    status = Map.get(agent, :status) || Map.get(agent, :state) || Status.idle()
    state = normalize_state(status)

    # Get display name
    name =
      Map.get(agent, :name) ||
        Map.get(agent, :label) ||
        Map.get(agent, :slug) ||
        Map.get(agent, :title) ||
        Map.get(agent, :id) ||
        "Unknown"

    # Get task description
    task =
      Map.get(agent, :task) ||
        Map.get(agent, :task_summary) ||
        Map.get(agent, :description) ||
        Map.get(agent, :title)

    # Duration handling
    start_time = compute_start_time(agent)
    runtime = Map.get(agent, :runtime)

    # Model name for display
    model = Map.get(agent, :model)
    model_short = short_model_name(model)

    # Token usage, request count, and cost (#134)
    tokens_in = Map.get(agent, :tokens_in, 0)
    tokens_out = Map.get(agent, :tokens_out, 0)
    request_count = Map.get(agent, :request_count, 0)
    cost = Map.get(agent, :cost, 0)

    # Recent actions for expanded view
    recent_actions = Map.get(agent, :recent_actions, []) |> Enum.take(-5)
    current_action = Map.get(agent, :current_action)
    result_snippet = Map.get(agent, :result_snippet)

    # Event stream for live feed view
    event_stream = Map.get(agent, :event_stream, [])

    # Compute last action summary for compact view
    last_action = compute_last_action(state, current_action, recent_actions, event_stream)

    # View mode from parent: "overview" (compact default) or "live_feed" (expanded default)
    view_mode = Map.get(assigns, :view_mode, "overview")

    socket =
      socket
      |> assign(assigns)
      |> assign(:type_atom, type_atom)
      |> assign(:type_name, type_name)
      |> assign(:icon, icon)
      |> assign(:state, state)
      |> assign(:name, name)
      |> assign(:task, task)
      |> assign(:start_time, start_time)
      |> assign(:runtime, runtime)
      |> assign(:model, model)
      |> assign(:model_short, model_short)
      |> assign(:agent_id, Map.get(agent, :id, "unknown"))
      |> assign(:tokens_in, tokens_in)
      |> assign(:tokens_out, tokens_out)
      |> assign(:request_count, request_count)
      |> assign(:cost, cost)
      |> assign(:recent_actions, recent_actions)
      |> assign(:current_action, current_action)
      |> assign(:result_snippet, result_snippet)
      |> assign(:event_stream, event_stream)
      |> assign(:last_action, last_action)
      |> assign(:view_mode, view_mode)
      |> assign(:expanded, true)

    {:ok, socket}
  end

  # toggle_expand removed - cards are always expanded (#138)

  # Compute start time for live duration updates
  defp compute_start_time(%{created_at: created_at}) when is_integer(created_at), do: created_at

  defp compute_start_time(%{updated_at: updated_at, runtime: runtime})
       when is_integer(updated_at) and is_binary(runtime) do
    seconds = parse_runtime_to_seconds(runtime)
    updated_at - seconds * 1000
  end

  defp compute_start_time(%{updated_at: updated_at}) when is_integer(updated_at) do
    # Default to 1 min ago
    updated_at - 60_000
  end

  defp compute_start_time(%{start_time: start_time}) when is_integer(start_time), do: start_time
  defp compute_start_time(_), do: System.system_time(:millisecond)

  # Parse runtime strings like "2m 34s" into total seconds
  defp parse_runtime_to_seconds(runtime) when is_binary(runtime) do
    runtime
    |> String.split()
    |> Enum.reduce(0, fn part, acc ->
      cond do
        String.ends_with?(part, "h") ->
          acc + (String.trim_trailing(part, "h") |> String.to_integer() |> Kernel.*(3600))

        String.ends_with?(part, "m") ->
          acc + (String.trim_trailing(part, "m") |> String.to_integer() |> Kernel.*(60))

        String.ends_with?(part, "s") ->
          acc + (String.trim_trailing(part, "s") |> String.to_integer())

        true ->
          acc
      end
    end)
  rescue
    _ -> 60
  end

  # State indicator styling
  defp state_indicator_class(:running), do: "bg-green-500"
  defp state_indicator_class(:completed), do: "bg-blue-500"
  defp state_indicator_class(:failed), do: "bg-red-500"
  defp state_indicator_class(:idle), do: "bg-gray-500"
  defp state_indicator_class(_), do: "bg-gray-500"

  # State text
  defp state_text(:running), do: Status.running()
  defp state_text(:completed), do: Status.completed()
  defp state_text(:failed), do: Status.failed()
  defp state_text(:idle), do: Status.idle()
  defp state_text(_), do: "unknown"

  # Duration badge styling based on state
  defp duration_badge_class(:running), do: "bg-green-500/20 text-green-400"
  defp duration_badge_class(:completed), do: "bg-blue-500/20 text-blue-400"
  defp duration_badge_class(:failed), do: "bg-red-500/20 text-red-400"
  defp duration_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  # Format token counts
  defp format_tokens(n) when is_integer(n) and n >= 1_000_000 do
    formatted = Float.round(n / 1_000_000, 1)
    if formatted == Float.round(formatted), do: "#{round(formatted)}M", else: "#{formatted}M"
  end

  defp format_tokens(n) when is_integer(n) and n >= 1_000 do
    formatted = Float.round(n / 1_000, 1)
    if formatted == Float.round(formatted), do: "#{round(formatted)}K", else: "#{formatted}K"
  end

  defp format_tokens(n) when is_integer(n), do: "#{n}"
  defp format_tokens(_), do: "0"

  # Compute a one-line last action summary for compact view
  defp compute_last_action(state, current_action, recent_actions, event_stream) do
    cond do
      state == :completed ->
        "Completed"

      state == :failed ->
        "Failed"

      current_action != nil ->
        "▶ #{current_action}"

      event_stream != [] ->
        last = List.last(event_stream)

        case last.type do
          :tool_call -> "Called #{last.name}"
          :thinking -> "Thinking..."
          :response -> "Responded"
          _ -> nil
        end

      recent_actions != [] ->
        List.last(recent_actions)

      state == :running ->
        "Working..."

      true ->
        nil
    end
  end

  # has_details? removed - cards are always expanded (#138)

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="agent-card"
      id={"agent-card-#{@agent_id}"}
      data-agent-type={@type_atom}
      data-state={@state}
    >
      <%!-- Row 1: Status dot + Icon + Name + Model/Duration badge --%>
      <div class="flex items-center gap-2 min-w-0">
        <span
          class={"w-2 h-2 rounded-full flex-shrink-0 " <> state_indicator_class(@state) <> if(@state == :running, do: " animate-pulse", else: "")}
          title={state_text(@state)}
        />
        <span class="agent-card-icon" aria-hidden="true">{@icon}</span>
        <span class="agent-card-name flex-1 min-w-0" title={@name}>{@name}</span>

        <%!-- Model + Duration pill --%>
        <%= if @state == :running do %>
          <span
            class="inline-flex items-center gap-1 px-2 py-0.5 text-[11px] font-mono tabular-nums rounded-full bg-green-500/15 text-green-400 flex-shrink-0"
            id={"card-duration-#{@agent_id}"}
            phx-hook="LiveDuration"
            data-start-time={@start_time}
            data-model={@model_short}
          >
            <%= if @model_short do %><span class="opacity-70">{@model_short}</span><span class="opacity-40">·</span><% end %>
            {@runtime || "0s"}
          </span>
        <% else %>
          <%= if @runtime || @model_short do %>
            <span class={"inline-flex items-center gap-1 px-2 py-0.5 text-[11px] font-mono tabular-nums rounded-full flex-shrink-0 " <> duration_badge_class(@state)}>
              <%= if @model_short && @runtime do %>
                <span class="opacity-70">{@model_short}</span><span class="opacity-40">·</span>{@runtime}
              <% else %>
                {@model_short || @runtime}
              <% end %>
            </span>
          <% end %>
        <% end %>
      </div>

      <%!-- Row 2: Current action or task --%>
      <%= if @state == :running && @current_action do %>
        <div class="mt-1.5 flex items-center gap-1.5 min-w-0">
          <span class="text-green-400 text-[11px]">▶</span>
          <span class="text-[12px] font-mono text-green-400/90 truncate" title={@current_action}>{@current_action}</span>
        </div>
      <% end %>

      <%= if @task do %>
        <div class="agent-card-task" title={@task}>{@task}</div>
      <% end %>

      <%!-- Event stream --%>
      <%= if @event_stream != [] do %>
        <div class="mt-2 pt-2 border-t border-base-content/5 space-y-0.5 max-h-[160px] overflow-y-auto">
          <%= for event <- @event_stream do %>
            <div class="text-[11px] font-mono flex items-center gap-1.5 py-px leading-tight">
              <span class="text-base-content/25 w-10 text-right flex-shrink-0 tabular-nums">{event.elapsed || "—"}</span>
              <span class="flex-shrink-0">
                <%= case event.type do %>
                  <% :tool_call -> %>
                    <span class={if(event.status == :error, do: "text-red-400", else: if(event.status == :running, do: "text-yellow-400", else: "text-green-400/70"))}>
                      {if(event.status == :error, do: "✗", else: if(event.status == :running, do: "⏳", else: "✓"))}
                    </span>
                  <% :thinking -> %><span class="text-purple-400/70">◆</span>
                  <% :response -> %><span class="text-blue-400/70">●</span>
                  <% _ -> %><span class="text-base-content/30">·</span>
                <% end %>
              </span>
              <span class={"truncate " <> if(event.status == :error, do: "text-red-400", else: "text-base-content/55")}>
                {event.name}<%= if event.target != "" do %>: {event.target}<% end %>
              </span>
              <%= if event.duration_ms do %>
                <span class="text-base-content/25 flex-shrink-0 tabular-nums ml-auto">{event.duration_ms}ms</span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Recent actions (when no event stream) --%>
      <%= if @event_stream == [] && @recent_actions != [] do %>
        <div class="mt-2 pt-2 border-t border-base-content/5 space-y-0.5 max-h-[80px] overflow-y-auto">
          <%= for action <- @recent_actions do %>
            <div class="text-[11px] font-mono text-base-content/45 truncate flex items-center gap-1" title={action}>
              <span class="text-success/40">✓</span>{action}
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Result snippet for completed --%>
      <%= if @state == :completed && @result_snippet do %>
        <div class="mt-2 text-[11px] text-base-content/50 bg-blue-500/8 px-2 py-1 rounded line-clamp-2" title={@result_snippet}>
          {@result_snippet}
        </div>
      <% end %>

      <%!-- Stats bar: tokens, requests, cost --%>
      <%= if @tokens_in > 0 || @tokens_out > 0 || @request_count > 0 || @cost > 0 do %>
        <div class="mt-2 pt-2 border-t border-base-content/5 flex items-center gap-3 text-[11px] font-mono tabular-nums text-base-content/40">
          <%= if @tokens_in > 0 do %>
            <span title="Input tokens">↓{format_tokens(@tokens_in)}</span>
          <% end %>
          <%= if @tokens_out > 0 do %>
            <span title="Output tokens">↑{format_tokens(@tokens_out)}</span>
          <% end %>
          <%= if @request_count > 0 do %>
            <span title="API requests">{@request_count}req</span>
          <% end %>
          <%= if @cost > 0 do %>
            <span class="ml-auto text-success/70" title="Cost">${Float.round(@cost, 4)}</span>
          <% end %>
        </div>
      <% end %>

      <%!-- Model info fallback --%>
      <%= if @model && !@model_short do %>
        <div class="mt-1 text-[11px] text-base-content/35 font-mono">{@model}</div>
      <% end %>
    </div>
    """
  end
end
