defmodule DashboardPhoenixWeb.HomeLive do
  use DashboardPhoenixWeb, :live_view
  
  alias DashboardPhoenix.ProcessMonitor
  alias DashboardPhoenix.AgentMonitor

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :update_data, 100)
      :timer.send_interval(3_000, :update_data) # Update every 3 seconds for agent activity
    end

    processes = ProcessMonitor.list_processes()
    agents = fetch_agents()
    
    socket = assign(socket,
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes,
      agent_sessions: agents,
      agent_stats: compute_agent_stats(agents)
    )

    {:ok, socket}
  end

  def handle_info(:update_data, socket) do
    processes = ProcessMonitor.list_processes()
    agents = fetch_agents()
    
    socket = assign(socket,
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes,
      agent_sessions: agents,
      agent_stats: compute_agent_stats(agents)
    )
    {:noreply, socket}
  end
  
  defp fetch_agents do
    case AgentMonitor.list_active_agents() do
      agents when is_list(agents) -> agents
      {:error, _} -> []
    end
  end
  
  defp compute_agent_stats(agents) do
    %{
      running: Enum.count(agents, &(&1.status == "running")),
      completed: Enum.count(agents, &(&1.status == "completed")),
      total: length(agents)
    }
  end

  def handle_event("kill_process", %{"name" => _name, "pid" => pid}, socket) do
    case System.cmd("kill", [pid]) do
      {_, 0} -> socket |> put_flash(:info, "Process #{pid} killed")
      {_, _} -> socket |> put_flash(:error, "Failed to kill process #{pid}")
    end
    |> then(&{:noreply, &1})
  end
  
  def handle_event("kill_process", %{"name" => name}, socket) do
    socket = put_flash(socket, :info, "Kill requires PID - #{name}")
    {:noreply, socket}
  end

  def handle_event("view_logs", %{"name" => process_name}, socket) do
    socket = put_flash(socket, :info, "Logs for #{process_name} - check terminal")
    {:noreply, socket}
  end

  def handle_event("restart_process", %{"name" => process_name}, socket) do
    socket = put_flash(socket, :info, "Restart not available for #{process_name}")
    {:noreply, socket}
  end

  def handle_event("kill_agent", %{"id" => session_id}, socket) do
    case System.cmd("openclaw", ["process", "kill", session_id]) do
      {_, 0} -> socket |> put_flash(:info, "Agent #{session_id} killed")
      {_, _} -> socket |> put_flash(:error, "Failed to kill agent #{session_id}")
    end
    |> then(&{:noreply, &1})
  end

  def handle_event("view_agent_logs", %{"id" => session_id}, socket) do
    # Could expand to show a modal with full logs
    socket = put_flash(socket, :info, "Logs for #{session_id} - use `openclaw process log #{session_id}`")
    {:noreply, socket}
  end

  # Helper function to format numbers with commas
  defp format_number(number) when is_integer(number) and number >= 1000 do
    # Simple comma formatting for readability
    cond do
      number >= 1_000_000 -> "#{Float.round(number / 1_000_000, 1)}M"
      number >= 1_000 -> "#{Float.round(number / 1_000, 1)}K"
      true -> Integer.to_string(number)
    end
  end
  
  defp format_number(number) when is_integer(number), do: Integer.to_string(number)
  defp format_number(number), do: to_string(number)

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- Header Bar -->
      <div class="glass-panel rounded-lg px-4 py-2 flex items-center justify-between">
        <div class="flex items-center space-x-4">
          <h1 class="text-sm font-bold tracking-widest text-white">SYSTEMATIC</h1>
          <span class="text-[10px] text-base-content/60 font-mono">PROCESS CONTROL</span>
        </div>
        <div class="flex items-center space-x-4 text-xs font-mono">
          <span class={"font-bold " <> if(Map.get(@process_stats, :busy, 0) > 0, do: "text-warning", else: "text-base-content/60")}><%= Map.get(@process_stats, :busy, 0) %> <span class="text-base-content/60">BUSY</span></span>
          <span class={"font-bold " <> if(Map.get(@process_stats, :idle, 0) > 0, do: "text-success", else: "text-base-content/60")}><%= Map.get(@process_stats, :idle, 0) %> <span class="text-base-content/60">IDLE</span></span>
          <span class={"font-bold " <> if(@process_stats.failed > 0, do: "text-error", else: "text-base-content/60")}><%= @process_stats.failed %> <span class="text-base-content/60">STOP</span></span>
          <span class={"font-bold " <> if(@process_stats.failed < 1, do: "text-success", else: "text-error")}><%= if @process_stats.failed < 1, do: "●", else: "⚠" %></span>
        </div>
      </div>

      <!-- Agent Sessions (Coding Agents) -->
      <%= if @agent_sessions != [] do %>
        <div class="space-y-3">
          <div class="flex items-center justify-between px-1">
            <div class="flex items-center space-x-2">
              <span class="text-xs font-mono text-accent uppercase tracking-wider">🤖 Coding Agents</span>
              <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> if(@agent_stats.running > 0, do: "bg-warning/20 text-warning animate-pulse", else: "bg-base-content/10 text-base-content/60")}>
                <%= @agent_stats.running %> ACTIVE
              </span>
            </div>
          </div>
          
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
            <%= for agent <- @agent_sessions do %>
              <div class={"glass-panel rounded-lg p-4 border-l-4 hover:bg-white/5 transition-all duration-300 " <> case agent.status do
                "running" -> "border-l-warning shadow-warning/20"
                "completed" -> "border-l-success shadow-success/10"
                _ -> "border-l-base-content/20"
              end}>
                
                <!-- Agent Header -->
                <div class="flex items-center justify-between mb-3">
                  <div class="flex items-center space-x-2">
                    <span class={"w-2 h-2 rounded-full " <> if(agent.status == "running", do: "bg-warning animate-pulse", else: "bg-success")}></span>
                    <span class="text-sm font-mono text-white font-bold"><%= agent.name %></span>
                    <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> case agent.agent_type do
                      "opencode" -> "bg-purple-500/20 text-purple-400"
                      "codex" -> "bg-green-500/20 text-green-400"
                      "claude" -> "bg-orange-500/20 text-orange-400"
                      _ -> "bg-base-content/10 text-base-content/60"
                    end}>
                      <%= String.upcase(agent.agent_type) %>
                    </span>
                  </div>
                  <div class="flex items-center space-x-2">
                    <span class="text-xs font-mono text-base-content/60"><%= agent.duration %></span>
                    <%= if agent.status == "running" do %>
                      <button phx-click="kill_agent" phx-value-id={agent.id}
                        class="text-[10px] font-mono px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/30 border border-error/30">KILL</button>
                    <% end %>
                  </div>
                </div>
                
                <!-- Command -->
                <div class="mb-3">
                  <div class="text-xs font-mono text-white bg-black/30 rounded px-2 py-1 border border-white/10 truncate" title={agent.command}>
                    <span class="text-accent">$</span> <%= agent.command %>
                  </div>
                </div>
                
                <!-- Current Action (the good stuff!) -->
                <%= if agent.current_action do %>
                  <div class="mb-2 p-2 bg-warning/10 rounded border border-warning/20">
                    <div class="text-[10px] text-warning/80 font-mono uppercase tracking-wide mb-1">Current Action</div>
                    <div class="flex items-center space-x-2">
                      <span class="text-xs font-bold text-warning"><%= agent.current_action.action %></span>
                      <span class="text-xs font-mono text-base-content/70 truncate"><%= agent.current_action.target %></span>
                    </div>
                  </div>
                <% end %>
                
                <!-- Last Output -->
                <%= if agent.last_output do %>
                  <div class="text-[10px] font-mono text-base-content/60 bg-black/20 rounded px-2 py-1 border border-white/5 truncate">
                    <%= agent.last_output %>
                  </div>
                <% end %>
                
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Process Panels -->
      <div class="space-y-3">
        <div class="flex items-center px-1">
          <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">System Processes</span>
        </div>
        
        <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-3">
          <%= for process <- @recent_processes do %>
            <div class={"glass-panel rounded-lg p-3 border-l-4 hover:bg-white/5 transition-all duration-300 " <> case process.status do
              "busy" -> "border-l-warning shadow-warning/10"
              "idle" -> "border-l-success shadow-success/10"
              "running" -> "border-l-success shadow-success/10"
              "stopped" -> "border-l-base-content/40 shadow-none"
              "zombie" -> "border-l-error shadow-error/10"
              "dead" -> "border-l-error shadow-error/10"
              _ -> "border-l-base-content/20"
            end}>
              
              <!-- Process Header - Command as Title -->
              <div class="mb-2">
                <div class="text-xs font-mono text-white bg-black/30 rounded px-2 py-1 border border-white/10 mb-1.5 truncate" title={process.command}>
                  <span class="text-accent">$</span> <%= process.command %>
                </div>
                <div class="flex items-center justify-between">
                  <div class="flex items-center space-x-2">
                    <span class={"w-1.5 h-1.5 rounded-full " <> case process.status do
                      "busy" -> "bg-warning animate-pulse"
                      "idle" -> "bg-success"
                      "running" -> "bg-success animate-pulse"
                      "stopped" -> "bg-base-content/40"
                      "zombie" -> "bg-error animate-pulse"
                      "dead" -> "bg-error"
                      _ -> "bg-base-content/30"
                    end}></span>
                    <span class="text-xs font-mono text-base-content/80"><%= process.name %></span>
                    <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> case process.status do
                      "busy" -> "bg-warning/20 text-warning"
                      "idle" -> "bg-success/20 text-success"
                      "running" -> "bg-success/20 text-success"
                      "stopped" -> "bg-base-content/10 text-base-content/60"
                      "zombie" -> "bg-error/20 text-error"
                      "dead" -> "bg-error/20 text-error"
                      _ -> "bg-base-content/10 text-base-content/60"
                    end}>
                      <%= String.upcase(process.status) %>
                    </span>
                    <span class="text-xs font-mono text-base-content/60"><%= process.time %></span>
                  </div>
                
                <!-- Action Buttons at Top -->
                <div class="flex items-center space-x-1">
                  <%= if process.status in ["busy", "idle", "running"] && Map.get(process, :pid) do %>
                    <button phx-click="kill_process" phx-value-name={process.name} phx-value-pid={process.pid}
                      class="text-[10px] font-mono px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/30 border border-error/30">KILL</button>
                  <% end %>
                  <span class="text-[10px] font-mono text-base-content/40">PID:<%= Map.get(process, :pid, "?") %></span>
                </div>
              </div>
              </div>
              
              <!-- Directory -->
              <div class="mb-2">
                <div class="text-[10px] text-base-content/60 font-mono uppercase tracking-wide">Directory</div>
                <div class="text-xs font-mono text-accent truncate"><%= Map.get(process, :directory, "N/A") %></div>
              </div>
              
              <!-- Resource Usage Grid -->
              <div class="grid grid-cols-2 gap-2 mb-2">
                <!-- Performance Metrics -->
                <div class="bg-black/10 rounded p-2 border border-white/5">
                  <div class="text-[10px] text-base-content/60 font-mono uppercase tracking-wide mb-1">Performance</div>
                  <div class="space-y-0.5 text-xs font-mono">
                    <div class="flex justify-between">
                      <span class="text-base-content/70">Runtime:</span>
                      <span class="text-white font-bold"><%= Map.get(process, :runtime, "N/A") %></span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/70">CPU:</span>
                      <span class={"font-bold " <> if(String.contains?(Map.get(process, :cpu_usage, "0"), ["8", "9"]) || String.starts_with?(Map.get(process, :cpu_usage, ""), ["1", "2", "3", "4", "5", "6", "7"]), do: "text-success", else: "text-warning")}>
                        <%= Map.get(process, :cpu_usage, "N/A") %>
                      </span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/70">Memory:</span>
                      <span class={"font-bold " <> if(String.contains?(Map.get(process, :memory_usage, ""), "MB"), do: "text-success", else: "text-warning")}>
                        <%= Map.get(process, :memory_usage, "N/A") %>
                      </span>
                    </div>
                  </div>
                </div>

                <!-- AI Model & Tokens -->
                <div class="bg-black/10 rounded p-2 border border-white/5">
                  <div class="text-[10px] text-base-content/60 font-mono uppercase tracking-wide mb-1">AI Resources</div>
                  <div class="space-y-0.5 text-xs font-mono">
                    <div class="flex justify-between">
                      <span class="text-base-content/70">Model:</span>
                      <span class="text-accent font-bold text-xs">
                        <%= String.replace(Map.get(process, :model, "N/A"), "claude-sonnet-4-20250514", "sonnet-4") %>
                      </span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/70">Tokens:</span>
                      <span class="text-primary font-bold">
                        <%= if Map.get(process, :tokens) && Map.get(process, :tokens).total > 0 do %>
                          <%= format_number(Map.get(process, :tokens).total) %>
                        <% else %>
                          0
                        <% end %>
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Token Breakdown (for AI processes) -->
              <%= if Map.get(process, :tokens) && Map.get(process, :tokens).total > 0 do %>
                <div class="mb-2">
                  <div class="text-[10px] text-base-content/60 font-mono uppercase tracking-wide mb-1">Token Usage</div>
                  <div class="flex gap-1 text-[10px] font-mono">
                    <div class="flex-1 bg-primary/20 rounded px-1.5 py-1 text-center">
                      <div class="text-primary font-bold"><%= format_number(Map.get(process, :tokens).input) %></div>
                      <div class="text-base-content/60">In</div>
                    </div>
                    <div class="flex-1 bg-secondary/20 rounded px-1.5 py-1 text-center">
                      <div class="text-secondary font-bold"><%= format_number(Map.get(process, :tokens).output) %></div>
                      <div class="text-base-content/60">Out</div>
                    </div>
                  </div>
                </div>
              <% end %>

              <!-- Details -->
              <div class="mb-2">
                <div class="text-[10px] text-base-content/60 font-mono uppercase tracking-wide">Details</div>
                <div class="text-xs text-base-content/80 line-clamp-2"><%= Map.get(process, :details, "No additional details available") %></div>
              </div>
              
              <!-- Last Output -->
              <%= if Map.get(process, :last_output) do %>
                <div class="mb-2">
                  <div class="text-[10px] text-base-content/60 font-mono uppercase tracking-wide">Last Output</div>
                  <div class="text-[10px] font-mono text-base-content/70 bg-black/10 rounded px-1.5 py-1 border border-white/5 line-clamp-2">
                    <%= Map.get(process, :last_output) %>
                  </div>
                </div>
              <% end %>
              
              <!-- Exit Code Status -->
              <%= if Map.get(process, :exit_code) do %>
                <div class="pt-2 border-t border-white/5">
                  <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> if(Map.get(process, :exit_code) == 0, do: "bg-success/20 text-success", else: "bg-error/20 text-error")}>
                    EXIT: <%= Map.get(process, :exit_code) %>
                  </span>
                </div>
              <% end %>
              
            </div>
          <% end %>
          
          <%= if @recent_processes == [] do %>
            <div class="lg:col-span-2 xl:col-span-3 glass-panel rounded-lg p-6 text-center">
              <div class="text-base-content/40 font-mono text-xs mb-2">[NO ACTIVE OPERATIONS]</div>
              <div class="text-base-content/60 text-xs">All systems idle • Ready for new missions</div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
