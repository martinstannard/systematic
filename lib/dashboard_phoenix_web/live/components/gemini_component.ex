defmodule DashboardPhoenixWeb.Live.Components.GeminiComponent do
  @moduledoc """
  LiveComponent for displaying and managing Gemini CLI server.

  Extracted from HomeLive to improve code organization and maintainability.
  Handles Gemini server status, output display, prompt input, and server controls.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:gemini_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_server", _, socket) do
    send(self(), {:gemini_component, :start_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_server", _, socket) do
    send(self(), {:gemini_component, :stop_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt}, socket) when prompt != "" do
    case InputValidator.validate_prompt(prompt) do
      {:ok, validated_prompt} ->
        send(self(), {:gemini_component, :send_prompt, validated_prompt})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid prompt: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_prompt", _, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_output", _, socket) do
    send(self(), {:gemini_component, :clear_output})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-work overflow-hidden">
      <div 
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@gemini_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">✨</span>
          <span class="text-panel-label text-accent">Gemini CLI</span>
          <%= if @gemini_server_status.running do %>
            <span class="status-beacon text-success" aria-hidden="true"></span>
            <span class="sr-only">Server running</span>
          <% end %>
        </div>
        <%= if @gemini_server_status.running do %>
          <button phx-click="clear_output" phx-target={@myself} class="text-xs text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">Clear</button>
        <% end %>
      </div>
      
      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@gemini_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-3 pb-3">
          <%= if not @gemini_server_status.running do %>
            <div class="text-center py-4">
              <div class="text-xs text-base-content/40 mb-2">Gemini CLI not running</div>
              <button phx-click="start_server" phx-target={@myself} class="text-xs px-3 py-1.5bg-green-500/20 text-green-400 hover:bg-green-500/40">
                ✨ Start Gemini
              </button>
            </div>
          <% else %>
            <!-- Status -->
            <div class="flex items-center justify-between mb-2 text-xs font-mono">
              <div class="flex items-center space-x-2">
                <span class="text-base-content/50">Status:</span>
                <%= if @gemini_server_status[:busy] do %>
                  <span class="text-warning">Running...</span>
                <% else %>
                  <span class="text-green-400">Ready</span>
                <% end %>
                <span class="text-base-content/30">|</span>
                <span class="text-base-content/50">Dir:</span>
                <span class="text-blue-400 truncate max-w-[150px]" title={@gemini_server_status.cwd}><%= @gemini_server_status.cwd %></span>
              </div>
              <button phx-click="stop_server" phx-target={@myself} class="px-2 py-0.5bg-error/20 text-error hover:bg-error/40 text-xs">
                Stop
              </button>
            </div>
            
            <!-- Output - using data panel for terminal display -->
            <div class="panel-data p-3 mb-2 max-h-[200px] overflow-y-auto" id="gemini-output" phx-hook="ScrollBottom">
              <%= if @gemini_output == "" do %>
                <div class="flex items-center space-x-2 text-base-content/50" role="status">
                  <span class="status-marker text-info opacity-50" aria-hidden="true"></span>
                  <span class="text-ui-caption italic">Waiting for output...</span>
                </div>
              <% else %>
                <pre class="text-ui-value text-base-content/90 whitespace-pre-wrap font-mono"><%= @gemini_output %></pre>
              <% end %>
            </div>
            
            <!-- Prompt Input - using status panel styling -->
            <form phx-submit="send_prompt" phx-target={@myself} class="flex items-center space-x-2">
              <div class="flex-1 panel-statusborder border-accent/30 focus-within:border-accent/60 transition-colors">
                <input
                  type="text"
                  name="prompt"
                  placeholder="Send a prompt to Gemini..."
                  class="w-full bg-transparent px-3 py-1.5 text-ui-body font-mono text-base-content placeholder-base-content/50 focus:outline-none"
                  autocomplete="off"
                />
              </div>
              <button
                type="submit"
                class="panel-work px-3 py-1.5border border-success/40 text-success hover:border-success/60 hover:bg-success/10 text-ui-label font-mono transition-all"
                aria-label="Send prompt to Gemini"
              >
                <span class="status-hex text-current scale-75 inline-block"></span>
                <span class="ml-1">Send</span>
              </button>
            </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end