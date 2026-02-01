defmodule DashboardPhoenixWeb.Live.Components.DaveComponent do
  @moduledoc """
  LiveComponent for Dave Panel (Main Agent) monitoring and display.
  
  Shows the main agent session status, current activity, recent actions, and stats.
  """
  use DashboardPhoenixWeb, :live_component

  # Required assigns:
  # - agent_sessions: list of agent sessions
  # - dave_collapsed: boolean for panel collapse state

  def update(assigns, socket) do
    main_agent_session = find_main_agent_session(assigns.agent_sessions)
    
    # Pre-calculate recent actions to avoid template computation
    recent_actions = case main_agent_session do
      nil -> []
      session -> 
        session
        |> Map.get(:recent_actions, [])
        |> Enum.take(-5)
    end
    
    socket = assign(socket,
      main_agent_session: main_agent_session,
      recent_actions: recent_actions,
      dave_collapsed: assigns.dave_collapsed
    )
    
    {:ok, socket}
  end

  def handle_event("toggle_panel", _params, socket) do
    send(self(), {:dave_component, :toggle_panel})
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="panel-content-standard" id="dave">
      <%= if @main_agent_session do %>
        <div 
          class="panel-header-standard panel-header-interactive flex items-center justify-between select-none"
          phx-click="toggle_panel"
          phx-target={@myself}
        >
          <div class="flex items-center space-x-2">
            <span class={"panel-chevron " <> if(@dave_collapsed, do: "collapsed", else: "")}>▼</span>
            <span class="panel-icon">🐙</span>
            <span class="text-panel-label text-purple-400">Dave</span>
            <%= if @main_agent_session.status == "running" do %>
              <span class="status-beacon text-warning"></span>
            <% else %>
              <span class={"px-1.5 py-0.5 rounded text-xs " <> status_badge(@main_agent_session.status)}>
                <%= @main_agent_session.status %>
              </span>
            <% end %>
          </div>
          <div class="flex items-center space-x-2">
            <% {_type, model_name, model_icon} = agent_type_from_model(Map.get(@main_agent_session, :model)) %>
            <span class="px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 text-xs" title={Map.get(@main_agent_session, :model)}>
              <%= model_icon %> <%= model_name %>
            </span>
          </div>
        </div>
        
        <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@dave_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
          <div class="px-3 pb-3">
            <% current_action = Map.get(@main_agent_session, :current_action) %>
            
            <!-- Current Activity -->
            <div class="py-2">
              <%= if @main_agent_session.status == "running" do %>
                <%= if current_action do %>
                  <div class="flex items-center space-x-2 mb-2">
                    <span class="status-activity-ring text-purple-400"></span>
                    <span class="text-xs text-purple-400/70">Current:</span>
                    <span class="text-purple-300 text-xs font-mono truncate" title={current_action}>
                      <%= current_action %>
                    </span>
                  </div>
                <% else %>
                  <div class="flex items-center space-x-2 mb-2">
                    <span class="status-activity-ring text-purple-400"></span>
                    <span class="text-xs text-purple-400/60 italic">Working...</span>
                  </div>
                <% end %>
              <% else %>
                <div class="flex items-center space-x-2 mb-2">
                  <span class="status-marker-idle w-2 h-2 rounded-full bg-purple-400"></span>
                  <span class="text-xs text-purple-400/60">Idle</span>
                </div>
              <% end %>
              
              <!-- Recent Actions -->
              <%= if @recent_actions != [] do %>
                <div class="text-xs text-base-content/40 space-y-0.5 max-h-[100px] overflow-y-auto">
                  <%= for action <- @recent_actions do %>
                    <div class="truncate" title={action}>✓ <%= action %></div>
                  <% end %>
                </div>
              <% end %>
            </div>
            
            <!-- Stats Footer -->
            <div class="pt-2 border-t border-purple-500/20 flex items-center justify-between text-xs font-mono">
              <div class="flex items-center space-x-3 text-base-content/50">
                <span>↓ <%= format_tokens(Map.get(@main_agent_session, :tokens_in, 0)) %></span>
                <span>↑ <%= format_tokens(Map.get(@main_agent_session, :tokens_out, 0)) %></span>
              </div>
              <%= if Map.get(@main_agent_session, :cost, 0) > 0 do %>
                <span class="text-success/60">$<%= Float.round(@main_agent_session.cost, 4) %></span>
              <% end %>
              <%= if Map.get(@main_agent_session, :runtime) do %>
                <span class="text-purple-400/60"><%= @main_agent_session.runtime %></span>
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <div class="flex items-center justify-between px-3 py-2 bg-base-content/5">
          <div class="flex items-center space-x-2">
            <span class="text-xs">▼</span>
            <span class="text-panel-label text-base-content/60">🐙 Dave</span>
            <span class="px-1.5 py-0.5 rounded text-xs bg-base-content/20 text-base-content/60">
              offline
            </span>
          </div>
        </div>
        <div class="px-3 py-2">
          <div class="text-xs text-base-content/50 italic">No main agent session found</div>
        </div>
      <% end %>
    </div>
    """
  end

  # Find the main agent session from the sessions list
  defp find_main_agent_session(agent_sessions) do
    Enum.find(agent_sessions, fn s -> 
      Map.get(s, :session_key) == "agent:main:main" 
    end)
  end

  # Status badge styles
  defp status_badge("running"), do: "bg-warning/20 text-warning animate-pulse"
  defp status_badge("idle"), do: "bg-info/20 text-info"
  defp status_badge("completed"), do: "bg-success/20 text-success"
  defp status_badge("failed"), do: "bg-error/20 text-error"
  defp status_badge("stopped"), do: "bg-base-content/20 text-base-content/60"
  defp status_badge(_), do: "bg-base-content/10 text-base-content/60"

  # Token formatting
  defp format_tokens(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n) when is_integer(n), do: to_string(n)
  defp format_tokens(_), do: "0"

  # Agent type helpers
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
end