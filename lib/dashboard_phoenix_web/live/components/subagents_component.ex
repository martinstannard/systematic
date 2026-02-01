defmodule DashboardPhoenixWeb.Live.Components.SubagentsComponent do
  @moduledoc """
  LiveComponent for displaying and managing sub-agent sessions.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows running and completed sub-agents with their status, tasks, and progress.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    # Pre-calculate filtered sessions and counts to improve template performance
    sub_agent_sessions = Enum.reject(assigns.agent_sessions, fn s -> 
      Map.get(s, :session_key) == "agent:main:main" 
    end)

    visible_sessions = sub_agent_sessions
    |> Enum.reject(fn s -> MapSet.member?(assigns.dismissed_sessions, s.id) end)
    |> Enum.reject(fn s -> !assigns.show_completed && s.status == "completed" end)
    |> Enum.map(fn session ->
      # Pre-calculate recent actions to avoid template computation
      recent_actions = session
      |> Map.get(:recent_actions, [])
      |> Enum.take(-3)
      
      Map.put(session, :limited_recent_actions, recent_actions)
    end)

    # Count both "running" (< 1 min) and "idle" (1-5 mins) as active
    # since "idle" just means a brief pause, not that the agent completed
    running_count = Enum.count(sub_agent_sessions, fn s -> s.status in ["running", "idle"] end)
    completed_count = Enum.count(visible_sessions, fn s -> s.status == "completed" end)
    sub_agent_sessions_count = length(sub_agent_sessions)

    updated_assigns = assigns
    |> Map.put(:sub_agent_sessions, sub_agent_sessions)
    |> Map.put(:visible_sessions, visible_sessions)
    |> Map.put(:running_count, running_count)
    |> Map.put(:completed_count, completed_count)
    |> Map.put(:sub_agent_sessions_count, sub_agent_sessions_count)

    {:ok, assign(socket, updated_assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:subagents_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_completed", _, socket) do
    send(self(), {:subagents_component, :clear_completed})
    {:noreply, socket}
  end

  # Helper functions

  # Session status badges
  defp status_badge("running"), do: "bg-warning/20 text-warning animate-pulse"
  defp status_badge("idle"), do: "bg-info/20 text-info"
  defp status_badge("completed"), do: "bg-success/20 text-success/60"
  defp status_badge("done"), do: "bg-success/20 text-success"
  defp status_badge("error"), do: "bg-error/20 text-error"
  defp status_badge(_), do: "bg-base-content/10 text-base-content/60"

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

  # Agent type detection from model string
  defp agent_type_from_model("anthropic/" <> _), do: {:claude, "Claude", "🤖"}
  defp agent_type_from_model("google/" <> _), do: {:gemini, "Gemini", "✨"}
  defp agent_type_from_model("openai/" <> _), do: {:openai, "OpenAI", "🔥"}
  defp agent_type_from_model(model) when is_binary(model) do
    cond do
      String.contains?(model, "claude") -> {:claude, "Claude", "🤖"}
      String.contains?(model, "gemini") -> {:gemini, "Gemini", "✨"}
      String.contains?(model, "gpt") -> {:openai, "OpenAI", "🔥"}
      String.contains?(model, "opencode") -> {:opencode, "OpenCode", "💻"}
      true -> {:unknown, "Unknown", "⚡"}
    end
  end
  defp agent_type_from_model(_), do: {:unknown, "Unknown", "⚡"}

  defp agent_type_badge_class(:claude), do: "bg-purple-500/20 text-purple-400"
  defp agent_type_badge_class(:gemini), do: "bg-green-500/20 text-green-400"
  defp agent_type_badge_class(:opencode), do: "bg-blue-500/20 text-blue-400"
  defp agent_type_badge_class(:openai), do: "bg-emerald-500/20 text-emerald-400"
  defp agent_type_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  # Extract session start timestamp for live duration display
  defp session_start_timestamp(%{updated_at: updated_at, runtime: runtime}) when is_binary(runtime) do
    # Parse runtime like "2m 34s" to seconds
    seconds = parse_runtime_to_seconds(runtime)
    updated_at - (seconds * 1000)  # Convert to milliseconds and subtract
  end
  defp session_start_timestamp(%{created_at: created_at}), do: created_at
  defp session_start_timestamp(%{updated_at: updated_at}), do: updated_at - 60_000  # Default to 1 min ago
  defp session_start_timestamp(_), do: System.system_time(:millisecond)

  # Parse runtime strings like "2m 34s" into total seconds
  defp parse_runtime_to_seconds(runtime) when is_binary(runtime) do
    # Handle formats like "2m 34s", "1h 23m", "45s"
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
    _ -> 60  # Default to 60 seconds if parsing fails
  end

  @impl true
  def render(assigns) do
    # Pre-calculated values are already available in assigns from update/2

    ~H"""
    <div class="panel-work overflow-hidden" id="subagents">
      <div 
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        {if assigns[:myself], do: [{"phx-target", assigns[:myself]}], else: []}
        role="button"
        tabindex="0"
        aria-expanded={if(@subagents_collapsed, do: "false", else: "true")}
        aria-controls="subagents-panel-content"
        aria-label="Toggle Sub-Agents panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@subagents_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">🤖</span>
          <span class="text-panel-label text-accent">Sub-Agents</span>
          <span class="text-xs font-mono text-base-content/50"><%= @sub_agent_sessions_count %></span>
          <%= if @running_count > 0 do %>
            <span class="status-beacon text-warning" aria-hidden="true"></span>
            <span class="px-1.5 py-0.5bg-warning/20 text-warning text-xs" role="status">
              <%= @running_count %> active
            </span>
          <% end %>
        </div>
        <%= if @completed_count > 0 do %>
          <button 
            phx-click="clear_completed" 
            {if assigns[:myself], do: [{"phx-target", assigns[:myself]}], else: []}
            class="text-xs px-2 py-0.5bg-base-content/10 text-base-content/50 hover:bg-accent/20 hover:text-accent transition-colors uppercase tracking-wider" 
            onclick="event.stopPropagation()"
            aria-label={"Clear " <> to_string(@completed_count) <> " completed sub-agent sessions"}
          >
            Clear Completed (<%= @completed_count %>)
          </button>
        <% end %>
      </div>
      
      <div id="subagents-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@subagents_collapsed, do: "max-h-0", else: "max-h-[500px]")}>
        <div class="px-3 pb-3 space-y-2 max-h-[450px] overflow-y-auto" role="region" aria-live="polite" aria-label="Sub-agent sessions list">
          <%= if @visible_sessions == [] do %>
            <div class="text-xs text-base-content/40 py-4 text-center font-mono">No active sub-agents</div>
          <% end %>
          <%= for session <- @visible_sessions do %>
            <% status = Map.get(session, :status, "unknown") %>
            <% {agent_type, agent_name, agent_icon} = agent_type_from_model(Map.get(session, :model)) %>
            <% task = Map.get(session, :task_summary) %>
            <% current_action = Map.get(session, :current_action) %>
            <% recent_actions = Map.get(session, :recent_actions, []) %>
            <% limited_recent_actions = Map.get(session, :limited_recent_actions, []) %>
            <% start_time = session_start_timestamp(session) %>
            
            <div class={"border text-xs font-mono transition-all " <> 
              if(status == "running", 
                do: "panel-work bg-warning/10 border-warning/40 shadow-lg", 
                else: if(status == "completed", do: "panel-status bg-success/10 border-success/30", else: "panel-status"))}>
              
              <!-- Header Row: Status, Label, Agent Type, Duration -->
              <div class="flex flex-wrap items-start justify-between gap-2 px-3 py-2 border-b border-accent/20">
                <div class="flex items-start space-x-2 min-w-0 flex-1">
                  <%= if status == "running" do %>
                    <span class="throbber-small flex-shrink-0 mt-0.5"></span>
                  <% else %>
                    <span class={"flex-shrink-0 mt-0.5 " <> if(status == "completed", do: "text-success", else: "text-info")}>
                      <%= if status == "completed", do: "✓", else: "○" %>
                    </span>
                  <% end %>
                  <span class="text-white font-medium break-words" title={Map.get(session, :label) || Map.get(session, :id)}>
                    <%= Map.get(session, :label) || String.slice(Map.get(session, :id, ""), 0, 8) %>
                  </span>
                </div>
                
                <div class="flex items-center space-x-2 flex-shrink-0">
                  <!-- Agent Type Badge -->
                  <span class={"px-1.5 py-0.5text-xs " <> agent_type_badge_class(agent_type)} title={Map.get(session, :model)}>
                    <%= agent_icon %> <%= agent_name %>
                  </span>
                  
                  <!-- Live Duration (for running) or Static (for completed) -->
                  <%= if status == "running" do %>
                    <span 
                      class="px-1.5 py-0.5bg-warning/20 text-warning text-xs tabular-nums"
                      id={"duration-#{session.id}"}
                      phx-hook="LiveDuration"
                      data-start-time={start_time}
                    >
                      <%= Map.get(session, :runtime) || "..." %>
                    </span>
                  <% else %>
                    <%= if Map.get(session, :runtime) do %>
                      <span class="px-1.5 py-0.5bg-base-content/10 text-base-content/60 text-xs tabular-nums">
                        <%= session.runtime %>
                      </span>
                    <% end %>
                  <% end %>
                  
                  <!-- Status Badge -->
                  <span class={status_badge(status)}><%= status %></span>
                </div>
              </div>
              
              <!-- Task Description -->
              <%= if task do %>
                <div class="px-3 py-2 border-b border-accent/10">
                  <div class="text-ui-caption text-base-content/60 mb-0.5">Task</div>
                  <div class="text-ui-body text-base-content/90 leading-relaxed" title={task}>
                    <%= task %>
                  </div>
                </div>
              <% end %>
              
              <!-- Live Work Status (for running agents) -->
              <%= if status == "running" do %>
                <div class="px-3 py-2">
                  <%= if current_action do %>
                    <div class="flex items-center space-x-2 mb-1">
                      <span class="text-xs text-warning/70">▶ Now:</span>
                      <span class="text-warning text-xs truncate animate-pulse" title={current_action}>
                        <%= current_action %>
                      </span>
                    </div>
                  <% end %>
                  
                  <%= if limited_recent_actions != [] do %>
                    <div class="text-xs text-base-content/40 space-y-0.5">
                      <%= for action <- limited_recent_actions do %>
                        <div class="truncate" title={action}>✓ <%= action %></div>
                      <% end %>
                    </div>
                  <% end %>
                  
                  <%= if current_action == nil && recent_actions == [] do %>
                    <div class="text-xs text-base-content/40 italic">Initializing...</div>
                  <% end %>
                </div>
              <% end %>
              
              <!-- Result snippet for completed agents -->
              <%= if status == "completed" && Map.get(session, :result_snippet) do %>
                <div class="px-3 py-2">
                  <div class="text-xs text-success/70 mb-0.5">Result</div>
                  <div class="text-base-content/70 text-xs truncate" title={session.result_snippet}>
                    <%= session.result_snippet %>
                  </div>
                </div>
              <% end %>
              
              <!-- Footer: Tokens & Cost (if available) -->
              <%= if (Map.get(session, :tokens_in, 0) > 0 || Map.get(session, :tokens_out, 0) > 0) do %>
                <div class="px-3 py-1.5 panel-data border-t border-accent/10 flex items-center justify-between">
                  <div class="flex items-center space-x-3 text-ui-micro text-base-content/60">
                    <div class="flex items-center space-x-1">
                      <span class="status-marker text-info opacity-60" aria-hidden="true"></span>
                      <span class="text-tabular"><span class="sr-only">Input tokens: </span>↓ <%= format_tokens(session.tokens_in) %></span>
                    </div>
                    <div class="flex items-center space-x-1">
                      <span class="status-marker text-secondary opacity-60" aria-hidden="true"></span>
                      <span class="text-tabular"><span class="sr-only">Output tokens: </span>↑ <%= format_tokens(session.tokens_out) %></span>
                    </div>
                  </div>
                  <%= if Map.get(session, :cost, 0) > 0 do %>
                    <div class="flex items-center space-x-1">
                      <span class="status-marker text-success" aria-hidden="true"></span>
                      <span class="text-ui-value text-success"><span class="sr-only">Cost: </span>$<%= Float.round(session.cost, 4) %></span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end