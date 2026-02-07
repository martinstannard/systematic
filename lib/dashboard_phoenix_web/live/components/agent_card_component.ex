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

    agent_type_key =
      Map.get(assigns, :type) || Map.get(agent, :type, nil) || Map.get(agent, :model, nil)

    {type_atom, type_name, icon} = agent_type_info(agent_type_key)

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

    # Token usage and cost
    tokens_in = Map.get(agent, :tokens_in, 0)
    tokens_out = Map.get(agent, :tokens_out, 0)
    cost = Map.get(agent, :cost, 0)

    # Recent actions for expanded view
    recent_actions = Map.get(agent, :recent_actions, []) |> Enum.take(-5)
    current_action = Map.get(agent, :current_action)
    result_snippet = Map.get(agent, :result_snippet)

    # Expanded state - preserve if already set, otherwise default to false
    expanded = Map.get(socket.assigns, :expanded, false)

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
      |> assign(:cost, cost)
      |> assign(:recent_actions, recent_actions)
      |> assign(:current_action, current_action)
      |> assign(:result_snippet, result_snippet)
      |> assign(:expanded, expanded)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_expand", _, socket) do
    {:noreply, assign(socket, :expanded, !socket.assigns.expanded)}
  end

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

  # State badge styling
  defp state_badge_class(:running), do: "bg-green-500/20 text-green-400"
  defp state_badge_class(:completed), do: "bg-blue-500/20 text-blue-400"
  defp state_badge_class(:failed), do: "bg-red-500/20 text-red-400"
  defp state_badge_class(:idle), do: "bg-gray-500/20 text-gray-400"
  defp state_badge_class(_), do: "bg-gray-500/20 text-gray-400"

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

  # Card border styling based on state
  defp card_border_class(:running), do: "border-green-500/40"
  defp card_border_class(:completed), do: "border-blue-500/30"
  defp card_border_class(:failed), do: "border-red-500/30"
  defp card_border_class(:idle), do: "border-accent/20"
  defp card_border_class(_), do: "border-accent/20"

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

  # Check if we have expandable details
  defp has_details?(assigns) do
    assigns.tokens_in > 0 or assigns.tokens_out > 0 or
      assigns.cost > 0 or
      assigns.current_action != nil or
      assigns.recent_actions != [] or
      assigns.result_snippet != nil or
      assigns.model != nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class={"agent-card panel-status border transition-all cursor-pointer " <> card_border_class(@state)}
      id={"agent-card-#{@agent_id}"}
      data-agent-type={@type_atom}
      data-state={@state}
      data-expanded={@expanded}
      phx-click="toggle_expand"
      phx-target={@myself}
      role="button"
      tabindex="0"
      aria-expanded={to_string(@expanded)}
      aria-label={"Agent card: #{@name}. Click to #{if @expanded, do: "collapse", else: "expand"} details."}
      onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
    >
      <!-- Card Header: Stacked layout - Name on top, details below -->
      <div class="agent-card-header flex-col items-start gap-1.5">
        <!-- Line 1: Icon + Name (full width) -->
        <div class="flex items-center gap-2 w-full min-w-0">
          <!-- State Indicator Dot -->
          <span
            class={"w-2.5 h-2.5 rounded-full flex-shrink-0 " <> state_indicator_class(@state) <> if(@state == :running, do: " animate-pulse", else: "")}
            aria-hidden="true"
            title={state_text(@state)}
          >
          </span>
          
    <!-- Agent Icon -->
          <span class="agent-card-icon" aria-hidden="true">{@icon}</span>
          
    <!-- Agent Name - now gets full width -->
          <span class="agent-card-name flex-1" title={@name}>
            {@name}
          </span>
          
    <!-- Expand chevron indicator -->
          <%= if has_details?(assigns) do %>
            <span
              class={"text-xs text-base-content/60 transition-transform duration-200 flex-shrink-0 " <> if(@expanded, do: "rotate-180", else: "")}
              aria-hidden="true"
            >
              ▼
            </span>
          <% end %>
        </div>
        
    <!-- Line 2: Model, Duration, State badges -->
        <div class="agent-card-badges w-full justify-start">
          <%= if @state == :running do %>
            <span
              class={"px-2 py-1 text-xs font-mono tabular-nums rounded " <> duration_badge_class(@state)}
              id={"card-duration-#{@agent_id}"}
              phx-hook="LiveDuration"
              data-start-time={@start_time}
              data-model={@model_short}
            >
              <%= if @model_short do %>
                {@model_short} •
              <% end %>
              {@runtime || "0s"}
            </span>
          <% else %>
            <%= if @runtime || @model_short do %>
              <span class={"px-2 py-1 text-xs font-mono tabular-nums rounded " <> duration_badge_class(@state)}>
                <%= if @model_short && @runtime do %>
                  {@model_short} • {@runtime}
                <% else %>
                  {@model_short || @runtime}
                <% end %>
              </span>
            <% end %>
          <% end %>

          <span class={"px-2 py-1 text-xs font-semibold uppercase tracking-wide rounded " <> state_badge_class(@state)}>
            {state_text(@state)}
          </span>
        </div>
      </div>
      
    <!-- Task Description (always visible) -->
      <%= if @task do %>
        <div class="agent-card-task" title={@task}>
          {@task}
        </div>
      <% else %>
        <div class="agent-card-task text-base-content/40 italic">
          No active task
        </div>
      <% end %>
      
    <!-- Expandable Details Section -->
      <div
        class={"agent-card-details overflow-hidden transition-all duration-300 ease-in-out " <> 
          if(@expanded, do: "max-h-[400px] opacity-100 mt-3", else: "max-h-0 opacity-0")}
        aria-hidden={not @expanded}
      >
        <div class="pt-3 border-t border-base-content/10 space-y-3">
          <!-- Current Action (for running agents) -->
          <%= if @state == :running && @current_action do %>
            <div class="text-sm">
              <div class="text-xs text-green-400/70 mb-1 font-medium">▶ Current Action</div>
              <div
                class="text-green-400 font-mono text-xs truncate bg-green-500/10 px-2 py-1 rounded"
                title={@current_action}
              >
                {@current_action}
              </div>
            </div>
          <% end %>
          
    <!-- Recent Actions -->
          <%= if @recent_actions != [] do %>
            <div class="text-sm">
              <div class="text-xs text-base-content/50 mb-1 font-medium">Recent Activity</div>
              <div class="space-y-1 max-h-[100px] overflow-y-auto">
                <%= for action <- @recent_actions do %>
                  <div
                    class="text-xs text-base-content/60 font-mono truncate flex items-center gap-1"
                    title={action}
                  >
                    <span class="text-success/50">✓</span>
                    {action}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
          
    <!-- Result Snippet (for completed agents) -->
          <%= if @state == :completed && @result_snippet do %>
            <div class="text-sm">
              <div class="text-xs text-blue-400/70 mb-1 font-medium">Result</div>
              <div
                class="text-base-content/70 text-xs bg-blue-500/10 px-2 py-1 rounded line-clamp-3"
                title={@result_snippet}
              >
                {@result_snippet}
              </div>
            </div>
          <% end %>
          
    <!-- Token Usage & Cost Stats -->
          <%= if @tokens_in > 0 || @tokens_out > 0 || @cost > 0 do %>
            <div
              class="flex items-center justify-between text-xs bg-base-content/5 px-2 py-1.5 rounded"
              role="group"
              aria-label="Token usage and cost"
            >
              <div class="flex items-center gap-3">
                <%= if @tokens_in > 0 do %>
                  <div class="flex items-center gap-1">
                    <span class="w-1.5 h-1.5 rounded-full bg-info/60" aria-hidden="true"></span>
                    <span
                      class="text-base-content/60 font-mono tabular-nums"
                      aria-label={"Input tokens: " <> format_tokens(@tokens_in)}
                    >
                      <span aria-hidden="true">↓</span> {format_tokens(@tokens_in)}
                    </span>
                  </div>
                <% end %>
                <%= if @tokens_out > 0 do %>
                  <div class="flex items-center gap-1">
                    <span class="w-1.5 h-1.5 rounded-full bg-secondary/60" aria-hidden="true"></span>
                    <span
                      class="text-base-content/60 font-mono tabular-nums"
                      aria-label={"Output tokens: " <> format_tokens(@tokens_out)}
                    >
                      <span aria-hidden="true">↑</span> {format_tokens(@tokens_out)}
                    </span>
                  </div>
                <% end %>
              </div>
              <%= if @cost > 0 do %>
                <div class="flex items-center gap-1">
                  <span class="w-1.5 h-1.5 rounded-full bg-success" aria-hidden="true"></span>
                  <span
                    class="text-success font-mono tabular-nums"
                    aria-label={"Cost: $" <> to_string(Float.round(@cost, 4))}
                  >
                    ${Float.round(@cost, 4)}
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>
          
    <!-- Model Info (if not already shown in header) -->
          <%= if @model && !@model_short do %>
            <div class="text-xs text-base-content/50">
              <span class="font-medium">Model:</span>
              <span class="font-mono ml-1">{@model}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
