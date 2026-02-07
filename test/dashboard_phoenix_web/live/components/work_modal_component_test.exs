defmodule DashboardPhoenixWeb.Live.Components.WorkModalComponentTest do
  @moduledoc """
  Tests for the WorkModalComponent LiveComponent.
  """
  use DashboardPhoenixWeb.ConnCase, async: true

  alias DashboardPhoenixWeb.Live.Components.WorkModalComponent

  describe "render/1 agent mode display" do
    test "shows single mode agent when agent_mode is single" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        show_work_modal: true,
        work_ticket_id: "TEST-123",
        work_ticket_details: "Test details",
        work_ticket_loading: false,
        work_in_progress: false,
        work_sent: false,
        work_error: nil,
        coding_agent_pref: :opencode,
        agent_mode: "single",
        last_agent: "claude",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        tickets_in_progress: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(WorkModalComponent.render(assigns))

      # Should show the coding agent preference
      assert html =~ "Using: 💻 OpenCode"
      # Should NOT show round robin indicator
      refute html =~ "Round Robin"
    end

    test "shows round robin mode when agent_mode is round_robin with last_agent claude" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        show_work_modal: true,
        work_ticket_id: "TEST-123",
        work_ticket_details: "Test details",
        work_ticket_loading: false,
        work_in_progress: false,
        work_sent: false,
        work_error: nil,
        coding_agent_pref: :opencode,
        agent_mode: "round_robin",
        last_agent: "claude",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        tickets_in_progress: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(WorkModalComponent.render(assigns))

      # Should show round robin indicator
      assert html =~ "Round Robin"
      # Should show next agent as OpenCode (since last was claude)
      assert html =~ "Next: OpenCode"
      # Should have warning styling for round robin
      assert html =~ "bg-warning/20"
    end

    test "shows round robin mode when agent_mode is round_robin with last_agent opencode" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        show_work_modal: true,
        work_ticket_id: "TEST-123",
        work_ticket_details: "Test details",
        work_ticket_loading: false,
        work_in_progress: false,
        work_sent: false,
        work_error: nil,
        coding_agent_pref: :claude,
        agent_mode: "round_robin",
        last_agent: "opencode",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        tickets_in_progress: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(WorkModalComponent.render(assigns))

      # Should show round robin indicator
      assert html =~ "Round Robin"
      # Should show next agent as Claude (since last was opencode)
      assert html =~ "Next: Claude"
    end

    test "shows claude agent in single mode" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        show_work_modal: true,
        work_ticket_id: "TEST-123",
        work_ticket_details: "Test details",
        work_ticket_loading: false,
        work_in_progress: false,
        work_sent: false,
        work_error: nil,
        coding_agent_pref: :claude,
        agent_mode: "single",
        last_agent: "opencode",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        tickets_in_progress: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(WorkModalComponent.render(assigns))

      # Should show claude agent
      assert html =~ "Using: 🤖 Claude"
      refute html =~ "Round Robin"
    end

    test "shows gemini agent in single mode" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        show_work_modal: true,
        work_ticket_id: "TEST-123",
        work_ticket_details: "Test details",
        work_ticket_loading: false,
        work_in_progress: false,
        work_sent: false,
        work_error: nil,
        coding_agent_pref: :gemini,
        agent_mode: "single",
        last_agent: "claude",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        tickets_in_progress: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(WorkModalComponent.render(assigns))

      # Should show gemini agent
      assert html =~ "Using: ✨ Gemini"
      refute html =~ "Round Robin"
    end
  end
end
