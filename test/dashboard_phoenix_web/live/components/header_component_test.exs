defmodule DashboardPhoenixWeb.Live.Components.HeaderComponentTest do
  @moduledoc """
  Tests for the HeaderComponent LiveComponent.

  Tests rendering, CSS class presence, and accessibility attributes.
  """
  use DashboardPhoenixWeb.ConnCase, async: true

  alias DashboardPhoenixWeb.Live.Components.HeaderComponent

  # Default assigns for testing - just the data the component needs
  defp default_assigns do
    %{
      id: "header",
      agent_sessions_count: 3,
      agent_progress_count: 42,
      coding_agent_pref: :opencode,
      opencode_server_status: %{running: true},
      health_status: :healthy,
      health_last_check: DateTime.utc_now()
    }
  end

  # Helper to render the component directly
  defp render_component(assigns) do
    Phoenix.LiveViewTest.rendered_to_string(HeaderComponent.render(assigns))
  end

  describe "render/1" do
    test "renders header with container class" do
      html = render_component(default_assigns())

      # Main container classes
      assert html =~ "header-container"
      assert html =~ "header-inner"
      assert html =~ ~s(role="banner")
    end

    test "renders SYSTEMATIC logo" do
      html = render_component(default_assigns())

      assert html =~ "SYSTEMATIC"
      assert html =~ "header-logo"
      assert html =~ "header-logo-link"
    end

    test "renders stats bar with agent counts" do
      assigns =
        Map.merge(default_assigns(), %{
          agent_sessions_count: 5,
          agent_progress_count: 100
        })

      html = render_component(assigns)

      assert html =~ "header-stats"
      # agent sessions count
      assert html =~ "5"
      # agent progress count
      assert html =~ "100"
      assert html =~ "stat-value-success"
      assert html =~ "stat-value-primary"
    end

    test "renders theme toggle button" do
      html = render_component(default_assigns())

      assert html =~ "theme-toggle"
      assert html =~ "header-theme-toggle"
      # phx-hook
      assert html =~ "ThemeToggle"
    end

    test "renders breadcrumb navigation" do
      html = render_component(default_assigns())

      assert html =~ "header-breadcrumb"
      assert html =~ "breadcrumb-current"
      assert html =~ "Dashboard"
    end
  end

  describe "health indicator" do
    test "renders healthy status indicator" do
      assigns = Map.merge(default_assigns(), %{health_status: :healthy})
      html = render_component(assigns)

      assert html =~ "health-indicator"
      assert html =~ "health-indicator-healthy"
    end

    test "renders unhealthy status indicator" do
      assigns = Map.merge(default_assigns(), %{health_status: :unhealthy})
      html = render_component(assigns)

      assert html =~ "health-indicator-unhealthy"
    end

    test "renders checking status indicator" do
      assigns = Map.merge(default_assigns(), %{health_status: :checking})
      html = render_component(assigns)

      assert html =~ "health-indicator-checking"
    end

    test "renders unknown status indicator for nil" do
      assigns = Map.merge(default_assigns(), %{health_status: nil})
      html = render_component(assigns)

      assert html =~ "health-indicator-unknown"
    end
  end

  describe "coding agent badge" do
    test "renders opencode badge" do
      assigns = Map.merge(default_assigns(), %{coding_agent_pref: :opencode})
      html = render_component(assigns)

      assert html =~ "agent-badge"
      assert html =~ "agent-badge-opencode"
      assert html =~ "OpenCode"
      assert html =~ "💻"
    end

    test "renders claude badge" do
      assigns = Map.merge(default_assigns(), %{coding_agent_pref: :claude})
      html = render_component(assigns)

      assert html =~ "agent-badge-claude"
      assert html =~ "Claude"
      assert html =~ "🤖"
    end

    test "renders gemini badge" do
      assigns = Map.merge(default_assigns(), %{coding_agent_pref: :gemini})
      html = render_component(assigns)

      assert html =~ "agent-badge-gemini"
      assert html =~ "Gemini"
      assert html =~ "✨"
    end

    test "renders unknown badge for unrecognized agent" do
      assigns = Map.merge(default_assigns(), %{coding_agent_pref: :other})
      html = render_component(assigns)

      assert html =~ "agent-badge-unknown"
      assert html =~ "Unknown"
      assert html =~ "❓"
    end
  end

  describe "opencode server status" do
    test "shows online indicator when server is running" do
      assigns =
        Map.merge(default_assigns(), %{
          coding_agent_pref: :opencode,
          opencode_server_status: %{running: true}
        })

      html = render_component(assigns)

      assert html =~ "stat-status-online"
      assert html =~ "●"
    end

    test "shows offline indicator when server is not running" do
      assigns =
        Map.merge(default_assigns(), %{
          coding_agent_pref: :opencode,
          opencode_server_status: %{running: false}
        })

      html = render_component(assigns)

      assert html =~ "stat-status-offline"
      assert html =~ "○"
    end

    test "hides server status when not using opencode" do
      assigns =
        Map.merge(default_assigns(), %{
          coding_agent_pref: :claude,
          opencode_server_status: %{running: true}
        })

      html = render_component(assigns)

      # Server label should not appear when not using opencode
      refute html =~ ~r/>Server</
    end
  end

  describe "accessibility" do
    test "includes proper ARIA attributes" do
      html = render_component(default_assigns())

      # Banner role
      assert html =~ ~s(role="banner")

      # Breadcrumb navigation
      assert html =~ ~s(aria-label="Breadcrumb")

      # Stats live region
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-label="Dashboard statistics")

      # Theme toggle
      assert html =~ ~s(aria-label="Toggle between light and dark theme")
      assert html =~ ~s(aria-pressed="false")

      # Logo link
      assert html =~ ~s(aria-label="SYSTEMATIC Dashboard Home")
    end

    test "health indicator has accessible description" do
      assigns = Map.merge(default_assigns(), %{health_status: :healthy})
      html = render_component(assigns)

      assert html =~ ~s(aria-label="System status: healthy")
    end

    test "coding agent badge has accessible description" do
      assigns = Map.merge(default_assigns(), %{coding_agent_pref: :opencode})
      html = render_component(assigns)

      assert html =~ ~s(aria-label="Active coding agent: OpenCode")
    end
  end

  describe "update/2" do
    test "assigns all passed values to socket" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{}
        }
      }

      new_assigns = %{
        id: "header",
        agent_sessions_count: 10,
        agent_progress_count: 200,
        coding_agent_pref: :claude,
        opencode_server_status: %{running: false},
        health_status: :unhealthy,
        health_last_check: nil
      }

      {:ok, updated_socket} = HeaderComponent.update(new_assigns, socket)

      assert updated_socket.assigns.agent_sessions_count == 10
      assert updated_socket.assigns.agent_progress_count == 200
      assert updated_socket.assigns.coding_agent_pref == :claude
      assert updated_socket.assigns.health_status == :unhealthy
    end
  end
end
