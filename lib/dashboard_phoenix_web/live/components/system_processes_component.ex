defmodule DashboardPhoenixWeb.Live.Components.SystemProcessesComponent do
  @moduledoc """
  LiveComponent for System Processes panel monitoring and display.
  
  Shows system processes with CPU and memory usage information.
  """
  use DashboardPhoenixWeb, :live_component

  # Required assigns:
  # - recent_processes: list of process information
  # - recent_processes_count: integer count of processes
  # - system_processes_collapsed: boolean for panel collapse state

  def update(assigns, socket) do
    socket = assign(socket,
      recent_processes: assigns.recent_processes,
      recent_processes_count: assigns.recent_processes_count,
      system_processes_collapsed: assigns.system_processes_collapsed
    )
    
    {:ok, socket}
  end

  def handle_event("toggle_panel", _params, socket) do
    send(self(), {:system_processes_component, :toggle_panel})
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="glass-panel rounded-lg overflow-hidden">
      <div 
        class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
        phx-click="toggle_panel"
        phx-target={@myself}
      >
        <div class="flex items-center space-x-2">
          <span class={"text-xs transition-transform duration-200 " <> if(@system_processes_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
          <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">⚙️ System</span>
          <span class="text-[10px] font-mono text-base-content/50"><%= @recent_processes_count %></span>
        </div>
      </div>
      
      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@system_processes_collapsed, do: "max-h-0", else: "max-h-[150px]")}>
        <div class="px-3 pb-3 grid grid-cols-2 gap-1">
          <%= for process <- Enum.take(@recent_processes, 4) do %>
            <div class="px-2 py-1 rounded bg-white/5 text-[10px] font-mono">
              <div class="text-white truncate"><%= process.name %></div>
              <div class="text-base-content/50">
                CPU: <%= format_usage(Map.get(process, :cpu_usage)) %> | 
                MEM: <%= format_usage(Map.get(process, :memory_usage)) %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Format usage values, handling various types
  defp format_usage(nil), do: "?"
  defp format_usage(value) when is_binary(value), do: value
  defp format_usage(value) when is_number(value), do: "#{value}%"
  defp format_usage(_), do: "?"
end