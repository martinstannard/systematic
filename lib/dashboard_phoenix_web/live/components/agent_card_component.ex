defmodule DashboardPhoenixWeb.Live.Components.AgentCardComponent do
  @moduledoc """
  Unified card component for displaying all agent types in the Work Panel.
  
  Supports:
  - Claude sub-agents (🟣)
  - OpenCode sessions (🔷)
  - Any agent type with consistent styling
  
  Features:
  - Agent icon based on type
  - Task/session name
  - Real-time duration updates (via LiveDuration hook)
  - Color-coded state indicators:
    - Running: green
    - Completed: blue
    - Failed: red
    - Idle: gray
  """
  use DashboardPhoenixWeb, :live_component

  @type agent_type :: :claude | :opencode | :gemini | :openai | :subagent | :unknown
  @type state :: :running | :completed | :failed | :idle

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
  def normalize_state("running"), do: :running
  def normalize_state("active"), do: :running
  def normalize_state("completed"), do: :completed
  def normalize_state("done"), do: :completed
  def normalize_state("failed"), do: :failed
  def normalize_state("error"), do: :failed
  def normalize_state("idle"), do: :idle
  def normalize_state("ready"), do: :idle
  def normalize_state("stopped"), do: :idle
  def normalize_state(_), do: :idle

  @impl true
  def update(assigns, socket) do
    # Extract and normalize agent info (handle nil gracefully)
    agent = Map.get(assigns, :agent) || %{}
    agent_type_key = Map.get(assigns, :type) || Map.get(agent, :type, nil) || Map.get(agent, :model, nil)
    {type_atom, type_name, icon} = agent_type_info(agent_type_key)
    
    # Determine state
    status = Map.get(agent, :status) || Map.get(agent, :state) || "idle"
    state = normalize_state(status)
    
    # Get display name
    name = Map.get(agent, :name) || 
           Map.get(agent, :label) || 
           Map.get(agent, :slug) || 
           Map.get(agent, :title) ||
           Map.get(agent, :id) ||
           "Unknown"
    
    # Get task description
    task = Map.get(agent, :task) ||
           Map.get(agent, :task_summary) ||
           Map.get(agent, :description) ||
           Map.get(agent, :title)
    
    # Duration handling
    start_time = compute_start_time(agent)
    runtime = Map.get(agent, :runtime)
    
    socket = socket
    |> assign(assigns)
    |> assign(:type_atom, type_atom)
    |> assign(:type_name, type_name)
    |> assign(:icon, icon)
    |> assign(:state, state)
    |> assign(:name, name)
    |> assign(:task, task)
    |> assign(:start_time, start_time)
    |> assign(:runtime, runtime)
    |> assign(:agent_id, Map.get(agent, :id, "unknown"))
    
    {:ok, socket}
  end

  # Compute start time for live duration updates
  defp compute_start_time(%{created_at: created_at}) when is_integer(created_at), do: created_at
  defp compute_start_time(%{updated_at: updated_at, runtime: runtime}) when is_binary(runtime) do
    seconds = parse_runtime_to_seconds(runtime)
    updated_at - (seconds * 1000)
  end
  defp compute_start_time(%{updated_at: updated_at}) when is_integer(updated_at) do
    updated_at - 60_000  # Default to 1 min ago
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
        true -> acc
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
  defp state_text(:running), do: "running"
  defp state_text(:completed), do: "completed"
  defp state_text(:failed), do: "failed"
  defp state_text(:idle), do: "idle"
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

  @impl true
  def render(assigns) do
    ~H"""
    <div 
      class={"agent-card panel-status border p-2 transition-all " <> card_border_class(@state)}
      id={"agent-card-#{@agent_id}"}
      data-agent-type={@type_atom}
      data-state={@state}
    >
      <div class="flex items-center justify-between gap-2">
        <!-- Left: Icon, State Indicator, Name -->
        <div class="flex items-center space-x-2 min-w-0 flex-1">
          <!-- State Indicator Dot -->
          <span 
            class={"w-2 h-2 rounded-full flex-shrink-0 " <> state_indicator_class(@state) <> if(@state == :running, do: " animate-pulse", else: "")}
            aria-hidden="true"
            title={state_text(@state)}
          ></span>
          
          <!-- Agent Icon -->
          <span class="text-sm flex-shrink-0" aria-hidden="true"><%= @icon %></span>
          
          <!-- Agent Name -->
          <span class="text-xs font-medium text-white truncate" title={@name}>
            <%= @name %>
          </span>
        </div>
        
        <!-- Right: Duration, State Badge -->
        <div class="flex items-center space-x-2 flex-shrink-0">
          <!-- Duration -->
          <%= if @state == :running do %>
            <span 
              class={"px-1.5 py-0.5 text-xs tabular-nums " <> duration_badge_class(@state)}
              id={"duration-#{@agent_id}"}
              phx-hook="LiveDuration"
              data-start-time={@start_time}
            >
              <%= @runtime || "0s" %>
            </span>
          <% else %>
            <%= if @runtime do %>
              <span class={"px-1.5 py-0.5 text-xs tabular-nums " <> duration_badge_class(@state)}>
                <%= @runtime %>
              </span>
            <% end %>
          <% end %>
          
          <!-- State Badge -->
          <span class={"px-1.5 py-0.5 text-xs " <> state_badge_class(@state)}>
            <%= state_text(@state) %>
          </span>
        </div>
      </div>
      
      <!-- Task Description (if present) -->
      <%= if @task do %>
        <div class="mt-1.5 text-xs text-base-content/60 truncate" title={@task}>
          <%= @task %>
        </div>
      <% end %>
    </div>
    """
  end
end
