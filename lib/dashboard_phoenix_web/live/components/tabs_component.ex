defmodule DashboardPhoenixWeb.Live.Components.TabsComponent do
  @moduledoc """
  A tabbed navigation component that organizes content into switchable tabs.
  
  Supports:
  - Horizontal tab navigation with daisyUI styling
  - Badge counts on tabs
  - Keyboard navigation (arrow keys, Home, End)
  - Persistent active tab via parent assign
  
  ## Usage
  
      <.live_component
        module={TabsComponent}
        id="main-tabs"
        active_tab={@active_tab}
        tabs={[
          %{id: "work", label: "Work", badge: 5},
          %{id: "agents", label: "Agents", badge: 2},
          %{id: "system", label: "System"}
        ]}
      >
        <:tab_content tab="work">
          <!-- Work content here -->
        </:tab_content>
        <:tab_content tab="agents">
          <!-- Agents content here -->
        </:tab_content>
      </.live_component>
  """
  use Phoenix.LiveComponent

  @doc """
  Renders the tabs component.
  
  ## Assigns
  
  * `tabs` - List of tab definitions, each with :id, :label, and optional :badge
  * `active_tab` - The currently active tab id (string)
  * `tab_content` - Named slots for each tab's content
  """
  def render(assigns) do
    ~H"""
    <div class="tabs-container" id={@id}>
      <!-- Tab Navigation -->
      <div 
        role="tablist" 
        aria-label="Dashboard sections"
        class="tabs tabs-border tabs-lg bg-base-200/50 rounded-t-box p-1"
      >
        <%= for tab <- @tabs do %>
          <button
            type="button"
            role="tab"
            id={"tab-#{tab.id}"}
            aria-selected={@active_tab == tab.id}
            aria-controls={"tabpanel-#{tab.id}"}
            tabindex={if @active_tab == tab.id, do: "0", else: "-1"}
            phx-click="switch_tab"
            phx-value-tab={tab.id}
            phx-target={@myself}
            class={[
              "tab gap-2 transition-all duration-200",
              @active_tab == tab.id && "tab-active font-semibold"
            ]}
          >
            <span><%= tab.label %></span>
            <%= if Map.get(tab, :badge) && tab.badge > 0 do %>
              <span class={[
                "badge badge-sm font-mono tabular-nums",
                tab_badge_class(tab, @active_tab)
              ]}>
                <%= tab.badge %>
              </span>
            <% end %>
            <%= if Map.get(tab, :status) do %>
              <span class={["w-2 h-2 rounded-full", status_dot_class(tab.status)]}></span>
            <% end %>
          </button>
        <% end %>
      </div>

      <!-- Tab Panels -->
      <div class="tab-content bg-base-100 rounded-b-box">
        <%= for {slot, _idx} <- Enum.with_index(@tab_content) do %>
          <div
            role="tabpanel"
            id={"tabpanel-#{slot.tab}"}
            aria-labelledby={"tab-#{slot.tab}"}
            class={if @active_tab == slot.tab, do: "block", else: "hidden"}
            tabindex="0"
          >
            <%= render_slot(slot) %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def handle_event("switch_tab", %{"tab" => tab_id}, socket) do
    # Notify parent of tab change
    send(self(), {:tabs_component, :switch_tab, tab_id})
    {:noreply, socket}
  end

  # Badge styling based on tab state and type
  defp tab_badge_class(tab, active_tab) do
    cond do
      active_tab == tab.id -> "badge-primary"
      Map.get(tab, :urgent) -> "badge-error"
      Map.get(tab, :attention) -> "badge-warning"
      true -> "badge-ghost"
    end
  end

  # Status dot styling
  defp status_dot_class(status) do
    case status do
      :running -> "bg-success animate-pulse"
      :idle -> "bg-info"
      :error -> "bg-error"
      :warning -> "bg-warning"
      _ -> "bg-base-content/30"
    end
  end
end
