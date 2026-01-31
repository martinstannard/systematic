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
    <div class="glass-panel rounded-lg overflow-hidden">
      <div 
        class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
        phx-click="toggle_panel"
        phx-target={@myself}
      >
        <div class="flex items-center space-x-2">
          <span class={"text-xs transition-transform duration-200 " <> if(@gemini_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
          <span class="text-xs font-mono text-accent uppercase tracking-wider">✨ Gemini CLI</span>
          <%= if @gemini_server_status.running do %>
            <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
          <% end %>
        </div>
        <%= if @gemini_server_status.running do %>
          <button phx-click="clear_output" phx-target={@myself} class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">Clear</button>
        <% end %>
      </div>
      
      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@gemini_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-3 pb-3">
          <%= if not @gemini_server_status.running do %>
            <div class="text-center py-4">
              <div class="text-[10px] text-base-content/40 mb-2">Gemini CLI not running</div>
              <button phx-click="start_server" phx-target={@myself} class="text-xs px-3 py-1.5 rounded bg-green-500/20 text-green-400 hover:bg-green-500/40">
                ✨ Start Gemini
              </button>
            </div>
          <% else %>
            <!-- Status -->
            <div class="flex items-center justify-between mb-2 text-[10px] font-mono">
              <div class="flex items-center space-x-2">
                <span class="text-base-content/50">Status:</span>
                <%= if @gemini_server_status[:busy] do %>
                  <span class="text-warning animate-pulse">Running...</span>
                <% else %>
                  <span class="text-green-400">Ready</span>
                <% end %>
                <span class="text-base-content/30">|</span>
                <span class="text-base-content/50">Dir:</span>
                <span class="text-blue-400 truncate max-w-[150px]" title={@gemini_server_status.cwd}><%= @gemini_server_status.cwd %></span>
              </div>
              <button phx-click="stop_server" phx-target={@myself} class="px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/40 text-[10px]">
                Stop
              </button>
            </div>
            
            <!-- Output -->
            <div class="bg-black/40 rounded-lg p-2 mb-2 max-h-[200px] overflow-y-auto font-mono text-[10px] text-base-content/70" id="gemini-output" phx-hook="ScrollBottom">
              <%= if @gemini_output == "" do %>
                <span class="text-base-content/40 italic">Waiting for output...</span>
              <% else %>
                <pre class="whitespace-pre-wrap"><%= @gemini_output %></pre>
              <% end %>
            </div>
            
            <!-- Prompt Input -->
            <form phx-submit="send_prompt" phx-target={@myself} class="flex items-center space-x-2">
              <input
                type="text"
                name="prompt"
                placeholder="Send a prompt to Gemini..."
                class="flex-1 bg-black/30 border border-white/10 rounded px-3 py-1.5 text-xs font-mono text-white placeholder-base-content/40 focus:outline-none focus:border-green-500/50"
                autocomplete="off"
              />
              <button
                type="submit"
                class="px-3 py-1.5 rounded bg-green-500/20 text-green-400 hover:bg-green-500/40 text-xs font-mono"
              >
                Send
              </button>
            </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end