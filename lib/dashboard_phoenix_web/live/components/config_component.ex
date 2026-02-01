defmodule DashboardPhoenixWeb.Live.Components.ConfigComponent do
  @moduledoc """
  LiveComponent for managing system configuration and settings.

  Extracted from HomeLive to improve code organization and maintainability.
  Handles coding agent preferences, model selections, and server controls.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:config_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_coding_agent", %{"agent" => agent}, socket) do
    case InputValidator.validate_agent_name(agent) do
      {:ok, validated_agent} ->
        send(self(), {:config_component, :set_coding_agent, validated_agent})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid agent name: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_claude_model", %{"model" => model}, socket) do
    case InputValidator.validate_model_name(model) do
      {:ok, validated_model} ->
        send(self(), {:config_component, :select_claude_model, validated_model})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid Claude model: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_opencode_model", %{"model" => model}, socket) do
    case InputValidator.validate_model_name(model) do
      {:ok, validated_model} ->
        send(self(), {:config_component, :select_opencode_model, validated_model})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid OpenCode model: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_opencode_server", _, socket) do
    send(self(), {:config_component, :start_opencode_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_opencode_server", _, socket) do
    send(self(), {:config_component, :stop_opencode_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_gemini_server", _, socket) do
    send(self(), {:config_component, :start_gemini_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_gemini_server", _, socket) do
    send(self(), {:config_component, :stop_gemini_server})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-status rounded-lg overflow-hidden">
      <div 
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@config_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon opacity-60">⚙️</span>
          <span class="text-panel-label text-base-content/60">Config</span>
        </div>
        <div class="flex items-center space-x-2 text-[10px] font-mono text-base-content/40">
          <span><%= if @coding_agent_pref == :opencode, do: "OpenCode + #{@opencode_model}", else: "Claude + #{String.replace(@claude_model, "anthropic/claude-", "")}" %></span>
        </div>
      </div>
      
      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@config_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-4 py-3 border-t border-white/5">
          <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <!-- Coding Agent Toggle (3-way) -->
            <div>
              <div class="text-[10px] font-mono text-base-content/50 mb-2">Coding Agent</div>
              <div class="flex rounded-lg overflow-hidden border border-white/10">
                <button 
                  phx-click="set_coding_agent"
                  phx-value-agent="opencode"
                  phx-target={@myself}
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                    if(@coding_agent_pref == :opencode, 
                      do: "bg-blue-500/30 text-blue-400",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span>💻</span>
                  <span class="hidden sm:inline">OpenCode</span>
                </button>
                <button 
                  phx-click="set_coding_agent"
                  phx-value-agent="claude"
                  phx-target={@myself}
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all border-x border-white/10 " <> 
                    if(@coding_agent_pref == :claude, 
                      do: "bg-purple-500/30 text-purple-400",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span>🤖</span>
                  <span class="hidden sm:inline">Claude</span>
                </button>
                <button 
                  phx-click="set_coding_agent"
                  phx-value-agent="gemini"
                  phx-target={@myself}
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                    if(@coding_agent_pref == :gemini, 
                      do: "bg-green-500/30 text-green-400",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span>✨</span>
                  <span class="hidden sm:inline">Gemini</span>
                </button>
              </div>
            </div>
            
            <!-- Claude Model -->
            <div>
              <div class="text-[10px] font-mono text-base-content/50 mb-2">Claude Model</div>
              <select 
                phx-change="select_claude_model"
                phx-target={@myself}
                name="model"
                class="w-full text-sm font-mono bg-purple-500/10 border border-purple-500/30 rounded-lg px-3 py-2 text-purple-400"
              >
                <option value="anthropic/claude-opus-4-5" selected={@claude_model == "anthropic/claude-opus-4-5"}>Opus</option>
                <option value="anthropic/claude-sonnet-4-20250514" selected={@claude_model == "anthropic/claude-sonnet-4-20250514"}>Sonnet</option>
              </select>
            </div>
            
            <!-- OpenCode Model -->
            <div>
              <div class="text-[10px] font-mono text-base-content/50 mb-2">OpenCode Model</div>
              <select 
                phx-change="select_opencode_model"
                phx-target={@myself}
                name="model"
                class="w-full text-sm font-mono bg-blue-500/10 border border-blue-500/30 rounded-lg px-3 py-2 text-blue-400"
              >
                <option value="gemini-3-pro" selected={@opencode_model == "gemini-3-pro"}>Gemini 3 Pro</option>
                <option value="gemini-3-flash" selected={@opencode_model == "gemini-3-flash"}>Gemini 3 Flash</option>
                <option value="gemini-2.5-pro" selected={@opencode_model == "gemini-2.5-pro"}>Gemini 2.5 Pro</option>
              </select>
            </div>
          </div>
          
          <!-- Server Controls based on selected agent -->
          <div class="mt-3 pt-3 border-t border-white/5">
            <%= cond do %>
              <% @coding_agent_pref == :opencode -> %>
                <!-- OpenCode Server Controls -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center space-x-2 text-xs font-mono">
                    <span class="text-base-content/50">ACP Server:</span>
                    <%= if @opencode_server_status.running do %>
                      <span class="text-success">Running on :<%= @opencode_server_status.port %></span>
                    <% else %>
                      <span class="text-base-content/40">Stopped</span>
                    <% end %>
                  </div>
                  <%= if @opencode_server_status.running do %>
                    <button phx-click="stop_opencode_server" phx-target={@myself} class="text-xs px-2 py-1 rounded bg-error/20 text-error hover:bg-error/40">Stop</button>
                  <% else %>
                    <button phx-click="start_opencode_server" phx-target={@myself} class="text-xs px-2 py-1 rounded bg-success/20 text-success hover:bg-success/40">Start</button>
                  <% end %>
                </div>
              <% @coding_agent_pref == :gemini -> %>
                <!-- Gemini CLI Controls -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center space-x-2 text-xs font-mono">
                    <span class="text-base-content/50">Gemini CLI:</span>
                    <%= if @gemini_server_status.running do %>
                      <%= if @gemini_server_status[:busy] do %>
                        <span class="text-warning animate-pulse">Running prompt...</span>
                      <% else %>
                        <span class="text-success">Ready</span>
                      <% end %>
                    <% else %>
                      <span class="text-base-content/40">Stopped</span>
                    <% end %>
                  </div>
                  <%= if @gemini_server_status.running do %>
                    <button phx-click="stop_gemini_server" phx-target={@myself} class="text-xs px-2 py-1 rounded bg-error/20 text-error hover:bg-error/40">Stop</button>
                  <% else %>
                    <button phx-click="start_gemini_server" phx-target={@myself} class="text-xs px-2 py-1 rounded bg-success/20 text-success hover:bg-success/40">Start</button>
                  <% end %>
                </div>
              <% true -> %>
                <!-- Claude sub-agents don't need server controls -->
                <div class="text-xs font-mono text-base-content/40">
                  Claude uses OpenClaw sub-agents (no server needed)
                </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end