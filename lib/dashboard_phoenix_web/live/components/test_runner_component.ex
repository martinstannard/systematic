defmodule DashboardPhoenixWeb.Live.Components.TestRunnerComponent do
  @moduledoc """
  LiveComponent for running tests and viewing results.
  
  Provides:
  - Run all tests button
  - Run specific test pattern
  - Test status display (passed/failed/running)
  - Recent test results from ActivityLog
  """
  use DashboardPhoenixWeb, :live_component
  
  alias DashboardPhoenix.ActivityLog

  def update(assigns, socket) do
    # Get recent test events from ActivityLog
    recent_test_events = get_recent_test_events()
    
    socket = assign(socket,
      test_runner_collapsed: assigns.test_runner_collapsed,
      test_running: assigns[:test_running] || false,
      recent_test_events: recent_test_events
    )
    
    {:ok, socket}
  end

  def handle_event("toggle_test_runner_panel", _params, socket) do
    send(self(), {:test_runner_component, :toggle_panel, "test_runner"})
    {:noreply, socket}
  end

  def handle_event("run_all_tests", _params, socket) do
    if socket.assigns.test_running do
      {:noreply, socket}
    else
      send(self(), {:test_runner_component, :run_tests, []})
      socket = assign(socket, test_running: true)
      {:noreply, socket}
    end
  end

  def handle_event("run_test_pattern", %{"pattern" => pattern}, socket) do
    if socket.assigns.test_running do
      {:noreply, socket}
    else
      send(self(), {:test_runner_component, :run_test_pattern, pattern})
      socket = assign(socket, test_running: true)
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <button 
        phx-click="toggle_test_runner_panel"
        phx-target={@myself}
        class="panel-header-button w-full"
        type="button"
      >
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-blue-500"></div>
            <span class="text-panel-header font-medium">Test Runner</span>
            <span class="text-ui-caption">
              <%= if @test_running, do: "Running...", else: get_test_status(@recent_test_events) %>
            </span>
          </div>
          <div class="text-ui-secondary">
            <%= if @test_runner_collapsed, do: "▼", else: "▲" %>
          </div>
        </div>
      </button>

      <div class={["space-y-4 px-4 pb-4", @test_runner_collapsed && "hidden"]}>
        <!-- Test Controls -->
        <div class="flex gap-2 flex-wrap">
          <button 
            phx-click="run_all_tests"
            phx-target={@myself}
            disabled={@test_running}
            class={[
              "btn-primary px-3 py-1 text-sm",
              @test_running && "opacity-50 cursor-not-allowed"
            ]}
            type="button"
          >
            <%= if @test_running, do: "Running...", else: "Run All Tests" %>
          </button>
          
          <div class="flex gap-1">
            <input 
              type="text" 
              placeholder="Test pattern..."
              class="input-field px-2 py-1 text-sm w-32"
              id="test-pattern-input"
              phx-keydown="run_test_pattern"
              phx-key="Enter"
              phx-target={@myself}
              phx-value-pattern=""
              disabled={@test_running}
            />
            <button 
              phx-click="run_test_pattern"
              phx-target={@myself}
              phx-value-pattern=""
              class="btn-secondary px-2 py-1 text-sm"
              onclick="this.setAttribute('phx-value-pattern', document.getElementById('test-pattern-input').value)"
              disabled={@test_running}
              type="button"
            >
              Run
            </button>
          </div>
        </div>

        <!-- Recent Test Results -->
        <%= if length(@recent_test_events) > 0 do %>
          <div class="space-y-2">
            <h4 class="text-ui-secondary text-sm">Recent Test Results</h4>
            <div class="space-y-1 max-h-32 overflow-y-auto">
              <%= for event <- @recent_test_events do %>
                <div class={[
                  "flex items-start gap-2 text-xs p-2 rounded",
                  event.type == :test_passed && "bg-green-50 text-green-800",
                  event.type == :test_failed && "bg-red-50 text-red-800"
                ]}>
                  <div class="flex-shrink-0 mt-0.5">
                    <%= if event.type == :test_passed do %>
                      <div class="w-2 h-2 rounded-full bg-green-500"></div>
                    <% else %>
                      <div class="w-2 h-2 rounded-full bg-red-500"></div>
                    <% end %>
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="font-medium truncate"><%= event.message %></div>
                    <div class="text-ui-caption">
                      <%= Calendar.strftime(event.timestamp, "%H:%M:%S") %>
                      <%= if event.details[:total] do %>
                        • <%= event.details.passed %>/<%=event.details.total%> passed
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="text-ui-secondary text-sm">No recent test runs</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp get_recent_test_events do
    ActivityLog.get_events(50)
    |> Enum.filter(fn event -> event.type in [:test_passed, :test_failed] end)
    |> Enum.take(5)
  end

  defp get_test_status([]), do: "No recent runs"
  
  defp get_test_status([latest | _]) do
    case latest.type do
      :test_passed -> "✓ Last run passed"
      :test_failed -> "✗ Last run failed"
    end
  end
end