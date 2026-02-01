defmodule DashboardPhoenixWeb.Live.Components.ConfigComponent do
  @moduledoc """
  LiveComponent for managing system configuration and settings.

  Extracted from HomeLive to improve code organization and maintainability.
  Handles coding agent preferences, model selections, and server controls.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator
  alias DashboardPhoenix.Models

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
  def handle_event("set_agent_mode", %{"mode" => mode}, socket) when mode in ["single", "round_robin"] do
    send(self(), {:config_component, :set_agent_mode, mode})
    {:noreply, socket}
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
    <div class="panel-status overflow-hidden" role="region" aria-label="Configuration settings">
      <div 
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@config_collapsed, do: "false", else: "true")}
        aria-controls="config-panel-content"
        aria-label="Toggle Configuration panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@config_collapsed, do: "collapsed", else: "")} aria-hidden="true">▼</span>
          <span class="panel-icon opacity-60" aria-hidden="true">⚙️</span>
          <span class="text-panel-label text-base-content/60">Config</span>
        </div>
        <div class="flex items-center space-x-2 text-xs font-mono text-base-content/40" aria-live="polite">
          <%= if @agent_mode == "round_robin" do %>
            <span class="text-warning">🔄 Round Robin</span>
            <span class="text-base-content/30" aria-hidden="true">|</span>
            <span>Next: <%= if @last_agent == "claude", do: "OpenCode", else: "Claude" %></span>
          <% else %>
            <span><%= if @coding_agent_pref == :opencode, do: "OpenCode + #{@opencode_model}", else: "Claude + #{String.replace(@claude_model, "anthropic/claude-", "")}" %></span>
          <% end %>
        </div>
      </div>
      
      <div id="config-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@config_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-4 py-3 border-t border-white/5">
          <div class="grid grid-cols-1 md:grid-cols-5 gap-4">
            <!-- Agent Distribution Mode -->
            <fieldset>
              <legend class="text-xs font-mono text-base-content/50 mb-2">Distribution</legend>
              <div class="flex overflow-hidden border border-white/10" role="group" aria-label="Agent distribution mode">
                <button 
                  phx-click="set_agent_mode"
                  phx-value-mode="single"
                  phx-target={@myself}
                  aria-pressed={if(@agent_mode == "single", do: "true", else: "false")}
                  aria-label="Single agent mode - use one agent consistently"
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                    if(@agent_mode == "single", 
                      do: "bg-accent/30 text-accent",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span aria-hidden="true">🎯</span>
                  <span class="hidden sm:inline">Single</span>
                </button>
                <button 
                  phx-click="set_agent_mode"
                  phx-value-mode="round_robin"
                  phx-target={@myself}
                  aria-pressed={if(@agent_mode == "round_robin", do: "true", else: "false")}
                  aria-label="Round robin mode - alternate between agents"
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all border-l border-white/10 " <> 
                    if(@agent_mode == "round_robin", 
                      do: "bg-warning/30 text-warning",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span aria-hidden="true">🔄</span>
                  <span class="hidden sm:inline">Round Robin</span>
                </button>
              </div>
              <%= if @agent_mode == "round_robin" do %>
                <div class="text-xs font-mono text-warning/70 mt-1" aria-live="polite">
                  Next: <%= if @last_agent == "claude", do: "OpenCode", else: "Claude" %>
                </div>
              <% end %>
            </fieldset>
            
            <!-- Coding Agent Toggle (3-way) - disabled in round_robin mode -->
            <fieldset class={if @agent_mode == "round_robin", do: "opacity-50", else: ""} disabled={@agent_mode == "round_robin"}>
              <legend class="text-xs font-mono text-base-content/50 mb-2">Coding Agent</legend>
              <div class="flex overflow-hidden border border-white/10" role="group" aria-label="Select coding agent">
                <button 
                  phx-click="set_coding_agent"
                  phx-value-agent="opencode"
                  phx-target={@myself}
                  disabled={@agent_mode == "round_robin"}
                  aria-pressed={if(@coding_agent_pref == :opencode, do: "true", else: "false")}
                  aria-label="Use OpenCode as coding agent"
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                    if(@coding_agent_pref == :opencode, 
                      do: "bg-blue-500/30 text-blue-400",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span aria-hidden="true">💻</span>
                  <span class="hidden sm:inline">OpenCode</span>
                </button>
                <button 
                  phx-click="set_coding_agent"
                  phx-value-agent="claude"
                  phx-target={@myself}
                  disabled={@agent_mode == "round_robin"}
                  aria-pressed={if(@coding_agent_pref == :claude, do: "true", else: "false")}
                  aria-label="Use Claude as coding agent"
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all border-x border-white/10 " <> 
                    if(@coding_agent_pref == :claude, 
                      do: "bg-purple-500/30 text-purple-400",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span aria-hidden="true">🤖</span>
                  <span class="hidden sm:inline">Claude</span>
                </button>
                <button 
                  phx-click="set_coding_agent"
                  phx-value-agent="gemini"
                  phx-target={@myself}
                  disabled={@agent_mode == "round_robin"}
                  aria-pressed={if(@coding_agent_pref == :gemini, do: "true", else: "false")}
                  aria-label="Use Gemini as coding agent"
                  class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                    if(@coding_agent_pref == :gemini, 
                      do: "bg-green-500/30 text-green-400",
                      else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                    )}
                >
                  <span aria-hidden="true">✨</span>
                  <span class="hidden sm:inline">Gemini</span>
                </button>
              </div>
            </fieldset>
            
            <!-- Claude Model -->
            <div>
              <label for="claude-model-select" class="text-xs font-mono text-base-content/50 mb-2 block">Claude Model</label>
              <select 
                id="claude-model-select"
                phx-change="select_claude_model"
                phx-target={@myself}
                name="model"
                aria-label="Select Claude model"
                class="w-full text-sm font-mono bg-purple-500/10 border border-purple-500/30 px-3 py-2 text-purple-400"
              >
                <option value={Models.claude_opus()} selected={@claude_model == Models.claude_opus()}>Opus</option>
                <option value={Models.claude_sonnet()} selected={@claude_model == Models.claude_sonnet()}>Sonnet</option>
              </select>
            </div>
            
            <!-- OpenCode Model -->
            <div>
              <label for="opencode-model-select" class="text-xs font-mono text-base-content/50 mb-2 block">OpenCode Model</label>
              <select 
                id="opencode-model-select"
                phx-change="select_opencode_model"
                phx-target={@myself}
                name="model"
                aria-label="Select OpenCode model"
                class="w-full text-sm font-mono bg-blue-500/10 border border-blue-500/30 px-3 py-2 text-blue-400"
              >
                <option value={Models.gemini_3_pro()} selected={@opencode_model == Models.gemini_3_pro()}>Gemini 3 Pro</option>
                <option value={Models.gemini_3_flash()} selected={@opencode_model == Models.gemini_3_flash()}>Gemini 3 Flash</option>
                <option value={Models.gemini_2_5_pro()} selected={@opencode_model == Models.gemini_2_5_pro()}>Gemini 2.5 Pro</option>
              </select>
            </div>
          </div>
          
          <!-- Server Controls based on selected agent -->
          <div class="mt-3 pt-3 border-t border-white/5" role="region" aria-label="Server controls">
            <%= cond do %>
              <% @coding_agent_pref == :opencode -> %>
                <!-- OpenCode Server Controls -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center space-x-2 text-xs font-mono" aria-live="polite">
                    <span class="text-base-content/50">ACP Server:</span>
                    <%= if @opencode_server_status.running do %>
                      <span class="text-success" role="status">Running on :<%= @opencode_server_status.port %></span>
                    <% else %>
                      <span class="text-base-content/40" role="status">Stopped</span>
                    <% end %>
                  </div>
                  <%= if @opencode_server_status.running do %>
                    <button phx-click="stop_opencode_server" phx-target={@myself} class="text-xs px-2 py-1bg-error/20 text-error hover:bg-error/40" aria-label="Stop OpenCode ACP server">Stop</button>
                  <% else %>
                    <button phx-click="start_opencode_server" phx-target={@myself} class="text-xs px-2 py-1bg-success/20 text-success hover:bg-success/40" aria-label="Start OpenCode ACP server">Start</button>
                  <% end %>
                </div>
              <% @coding_agent_pref == :gemini -> %>
                <!-- Gemini CLI Controls -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center space-x-2 text-xs font-mono" aria-live="polite">
                    <span class="text-base-content/50">Gemini CLI:</span>
                    <%= if @gemini_server_status.running do %>
                      <%= if @gemini_server_status[:busy] do %>
                        <span class="text-warning" role="status">Running prompt...</span>
                      <% else %>
                        <span class="text-success" role="status">Ready</span>
                      <% end %>
                    <% else %>
                      <span class="text-base-content/40" role="status">Stopped</span>
                    <% end %>
                  </div>
                  <%= if @gemini_server_status.running do %>
                    <button phx-click="stop_gemini_server" phx-target={@myself} class="text-xs px-2 py-1bg-error/20 text-error hover:bg-error/40" aria-label="Stop Gemini CLI server">Stop</button>
                  <% else %>
                    <button phx-click="start_gemini_server" phx-target={@myself} class="text-xs px-2 py-1bg-success/20 text-success hover:bg-success/40" aria-label="Start Gemini CLI server">Start</button>
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