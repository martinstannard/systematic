defmodule DashboardPhoenixWeb.Live.Components.SystemProcessesComponent do
  @moduledoc """
  LiveComponent for System Processes monitoring and management.
  
  Manages:
  - Coding Agents panel (monitoring and killing processes)
  - System Processes panel (recent process display)
  - Process Relationships panel (graph visualization)
  
  Required assigns:
  - coding_agents: list of coding agent processes
  - coding_agents_count: integer count of coding agents
  - coding_agents_collapsed: boolean for coding agents panel collapse state
  - recent_processes: list of recent system processes
  - recent_processes_count: integer count of recent processes
  - system_processes_collapsed: boolean for system processes panel collapse state
  - process_relationships_collapsed: boolean for relationships panel collapse state
  - graph_data: data for process relationships graph
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  def update(assigns, socket) do
    # Pre-calculate limited recent processes to avoid template computation
    limited_recent_processes = Enum.take(assigns.recent_processes, 4)
    
    socket = assign(socket,
      coding_agents: assigns.coding_agents,
      coding_agents_count: assigns.coding_agents_count,
      coding_agents_collapsed: assigns.coding_agents_collapsed,
      recent_processes: assigns.recent_processes,
      limited_recent_processes: limited_recent_processes,
      recent_processes_count: assigns.recent_processes_count,
      system_processes_collapsed: assigns.system_processes_collapsed,
      process_relationships_collapsed: assigns.process_relationships_collapsed,
      graph_data: assigns.graph_data
    )
    
    {:ok, socket}
  end

  def handle_event("toggle_coding_agents_panel", _params, socket) do
    send(self(), {:system_processes_component, :toggle_panel, "coding_agents"})
    {:noreply, socket}
  end

  def handle_event("toggle_system_processes_panel", _params, socket) do
    send(self(), {:system_processes_component, :toggle_panel, "system_processes"})
    {:noreply, socket}
  end

  def handle_event("toggle_process_relationships_panel", _params, socket) do
    send(self(), {:system_processes_component, :toggle_panel, "process_relationships"})
    {:noreply, socket}
  end

  def handle_event("kill_process", %{"pid" => pid}, socket) do
    case DashboardPhoenix.InputValidator.validate_pid(pid) do
      {:ok, validated_pid} ->
        send(self(), {:system_processes_component, :kill_process, validated_pid})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid PID: #{reason}")
        {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="panel-content-standard">
      <!-- Coding Agents Panel -->
      <%= if @coding_agents != [] do %>
        <div class="mb-4">
          <div 
            class="panel-header-standard panel-header-interactive flex items-center justify-between select-none"
            phx-click="toggle_coding_agents_panel"
            phx-target={@myself}
          >
            <div class="flex items-center space-x-2">
              <span class={"panel-chevron " <> if(@coding_agents_collapsed, do: "collapsed", else: "")}>▼</span>
              <span class="panel-icon opacity-60">💻</span>
              <span class="text-panel-label text-base-content/60">Coding Agents</span>
              <span class="text-xs font-mono text-base-content/50"><%= @coding_agents_count %></span>
            </div>
          </div>
          
          <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@coding_agents_collapsed, do: "max-h-0", else: "max-h-[200px]")}>
            <div class="px-3 pb-3">
              <div class="grid grid-cols-2 lg:grid-cols-4 gap-2">
                <%= for agent <- @coding_agents do %>
                  <div class={"px-2 py-1.5 rounded text-xs font-mono " <> if(agent.status == "running", do: "bg-warning/10", else: "bg-white/5")}>
                    <div class="flex items-center justify-between">
                      <span class="text-white font-bold"><%= agent.type %></span>
                      <button phx-click="kill_process" phx-value-pid={agent.pid} phx-target={@myself} class="text-error/50 hover:text-error">✕</button>
                    </div>
                    <div class="text-xs text-base-content/50 mt-1">
                      CPU: <%= agent.cpu %>% | MEM: <%= agent.memory %>%
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <!-- System & Relationships Row -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <!-- System Processes -->
        <div>
          <div 
            class="panel-header-standard panel-header-interactive flex items-center justify-between select-none mb-3"
            phx-click="toggle_system_processes_panel"
            phx-target={@myself}
          >
            <div class="flex items-center space-x-2">
              <span class={"panel-chevron " <> if(@system_processes_collapsed, do: "collapsed", else: "")}>▼</span>
              <span class="panel-icon opacity-60">⚙️</span>
              <span class="text-panel-label text-base-content/60">System</span>
              <span class="text-xs font-mono text-base-content/50"><%= @recent_processes_count %></span>
            </div>
          </div>
          
          <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@system_processes_collapsed, do: "max-h-0", else: "max-h-[150px]")}>
            <div class="px-3 pb-3 grid grid-cols-2 gap-1">
              <%= for process <- @limited_recent_processes do %>
                <div class="px-2 py-1 rounded bg-white/5 text-xs font-mono">
                  <div class="text-white truncate"><%= process.name %></div>
                  <div class="text-base-content/50">CPU: <%= Map.get(process, :cpu_usage, "?") %> | MEM: <%= Map.get(process, :memory_usage, "?") %></div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Process Relationships -->
        <div>
          <div 
            class="panel-header-standard panel-header-interactive flex items-center justify-between select-none mb-3"
            phx-click="toggle_process_relationships_panel"
            phx-target={@myself}
          >
            <div class="flex items-center space-x-2">
              <span class={"panel-chevron " <> if(@process_relationships_collapsed, do: "collapsed", else: "")}>▼</span>
              <span class="panel-icon opacity-60">🔗</span>
              <span class="text-panel-label text-base-content/60">Relationships</span>
            </div>
          </div>
          
          <div class={"transition-all duration-300 ease-in-out " <> if(@process_relationships_collapsed, do: "max-h-0 overflow-hidden", else: "")}>
            <div class="p-2">
              <div id="relationship-graph" phx-hook="RelationshipGraph" phx-update="ignore" class="w-full h-[180px]"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end