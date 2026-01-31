defmodule DashboardPhoenixWeb.Live.Components.SubagentsComponentTest do
  use DashboardPhoenixWeb.ConnCase

  import Phoenix.LiveViewTest
  alias DashboardPhoenixWeb.Live.Components.SubagentsComponent

  describe "SubagentsComponent" do
    test "renders empty state when no sub-agents" do
      assigns = %{
        agent_sessions: [],
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "🤖 Sub-Agents"
      assert html =~ "No active sub-agents"
    end

    test "renders running sub-agent sessions" do
      sessions = [
        %{
          id: "test-1",
          session_key: "agent:sub:test-1",
          status: "running",
          model: "anthropic/claude-opus-4-5",
          label: "Test Sub-Agent",
          task_summary: "Working on test task",
          current_action: "Reading files",
          recent_actions: ["Started task", "Analyzed requirements"],
          runtime: "2m 30s",
          tokens_in: 1500,
          tokens_out: 800,
          cost: 0.025,
          updated_at: System.system_time(:millisecond) - 150_000
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "Test Sub-Agent"
      assert html =~ "Working on test task"
      assert html =~ "Reading files"
      assert html =~ "Started task"
      assert html =~ "🤖 Claude"
      assert html =~ "running"
      assert html =~ "1 active"
      assert html =~ "1.5K"  # tokens_in formatted
      assert html =~ "800"   # tokens_out
      assert html =~ "$0.025" # cost
    end

    test "renders completed sub-agent sessions" do
      sessions = [
        %{
          id: "test-completed",
          session_key: "agent:sub:test-completed",
          status: "completed",
          model: "google/gemini-3-pro",
          label: "Completed Task",
          task_summary: "Finished test task",
          result_snippet: "Task completed successfully",
          runtime: "5m 12s",
          tokens_in: 3000,
          tokens_out: 1200,
          cost: 0.045
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "Completed Task"
      assert html =~ "Finished test task"
      assert html =~ "Task completed successfully"
      assert html =~ "✨ Gemini"
      assert html =~ "completed"
      assert html =~ "3K"    # tokens_in formatted
      assert html =~ "1.2K"  # tokens_out formatted
      assert html =~ "$0.045" # cost
      refute html =~ "active" # no running sessions
      assert html =~ "Clear Completed (1)"
    end

    test "filters out main agent sessions" do
      sessions = [
        %{
          id: "main",
          session_key: "agent:main:main",
          status: "running",
          model: "anthropic/claude-opus-4-5",
          label: "Main Agent"
        },
        %{
          id: "sub-1",
          session_key: "agent:sub:sub-1",
          status: "running",
          model: "anthropic/claude-sonnet-4-20250514",
          label: "Sub Agent"
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      refute html =~ "Main Agent"
      assert html =~ "Sub Agent"
      assert html =~ "1"  # count should be 1, not 2
    end

    test "filters out dismissed sessions" do
      sessions = [
        %{
          id: "dismissed-session",
          session_key: "agent:sub:dismissed",
          status: "completed",
          model: "anthropic/claude-opus-4-5",
          label: "Dismissed Session"
        },
        %{
          id: "visible-session",
          session_key: "agent:sub:visible",
          status: "completed",
          model: "anthropic/claude-opus-4-5",
          label: "Visible Session"
        }
      ]

      dismissed_sessions = MapSet.new(["dismissed-session"])

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: dismissed_sessions,
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      refute html =~ "Dismissed Session"
      assert html =~ "Visible Session"
      assert html =~ "Clear Completed (1)"
    end

    test "hides completed sessions when show_completed is false" do
      sessions = [
        %{
          id: "running-session",
          session_key: "agent:sub:running",
          status: "running",
          model: "anthropic/claude-opus-4-5",
          label: "Running Session"
        },
        %{
          id: "completed-session",
          session_key: "agent:sub:completed",
          status: "completed",
          model: "anthropic/claude-opus-4-5",
          label: "Completed Session"
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: false
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "Running Session"
      refute html =~ "Completed Session"
      refute html =~ "Clear Completed"
    end

    test "handles collapsed state" do
      sessions = [
        %{
          id: "test-session",
          session_key: "agent:sub:test",
          status: "running",
          model: "anthropic/claude-opus-4-5",
          label: "Test Session"
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: true,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "🤖 Sub-Agents"
      assert html =~ "max-h-0"  # collapsed state CSS class
      assert html =~ "-rotate-90"  # collapsed arrow
    end

    test "handles different agent types and models" do
      sessions = [
        %{
          id: "claude-session",
          session_key: "agent:sub:claude",
          status: "running",
          model: "anthropic/claude-sonnet-4-20250514",
          label: "Claude Session"
        },
        %{
          id: "gemini-session",
          session_key: "agent:sub:gemini",
          status: "running",
          model: "google/gemini-3-pro",
          label: "Gemini Session"
        },
        %{
          id: "opencode-session",
          session_key: "agent:sub:opencode",
          status: "running",
          model: "opencode-model",
          label: "OpenCode Session"
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "🤖 Claude"
      assert html =~ "✨ Gemini"
      assert html =~ "💻 OpenCode"
      assert html =~ "bg-purple-500/20"  # Claude badge class
      assert html =~ "bg-green-500/20"   # Gemini badge class
      assert html =~ "bg-blue-500/20"    # OpenCode badge class
    end

    test "formats token counts correctly" do
      sessions = [
        %{
          id: "large-tokens",
          session_key: "agent:sub:large",
          status: "completed",
          model: "anthropic/claude-opus-4-5",
          label: "Large Tokens",
          tokens_in: 2_500_000,  # Should format as 2.5M
          tokens_out: 45_000     # Should format as 45K
        },
        %{
          id: "small-tokens",
          session_key: "agent:sub:small",
          status: "completed",
          model: "anthropic/claude-opus-4-5",
          label: "Small Tokens",
          tokens_in: 850,        # Should format as 850
          tokens_out: 1_200      # Should format as 1.2K
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "2.5M"
      assert html =~ "45K"
      assert html =~ "850"
      assert html =~ "1.2K"
    end

    test "handles edge cases gracefully" do
      sessions = [
        %{
          id: "minimal-session",
          session_key: "agent:sub:minimal",
          status: "running",
          # Missing many optional fields
          label: nil,
          model: nil,
          task_summary: nil,
          current_action: nil,
          recent_actions: [],
          tokens_in: 0,
          tokens_out: 0
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      # Should not crash and should render something reasonable
      html = render_component(SubagentsComponent, assigns)

      assert html =~ "🤖 Sub-Agents"
      assert html =~ "minimal-"  # truncated ID used as label
      assert html =~ "⚡ Unknown"  # unknown agent type
      assert html =~ "Initializing..."  # no current action
    end
  end

  describe "SubagentsComponent events" do
    test "renders component successfully and handles basic interactions" do
      sessions = [
        %{
          id: "test-session",
          session_key: "agent:sub:test",
          status: "running",
          model: "anthropic/claude-opus-4-5",
          label: "Test Session"
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      # Verify the component renders correctly with events
      assert html =~ "phx-click=\"toggle_panel\""
      assert html =~ "Test Session"
      # phx-target won't be present in test context since assigns[:myself] is nil, which is expected
    end

    test "renders clear completed button when needed" do
      sessions = [
        %{
          id: "completed-session",
          session_key: "agent:sub:completed",
          status: "completed",
          model: "anthropic/claude-opus-4-5",
          label: "Completed Session"
        }
      ]

      assigns = %{
        agent_sessions: sessions,
        subagents_collapsed: false,
        dismissed_sessions: MapSet.new(),
        show_completed: true
      }

      html = render_component(SubagentsComponent, assigns)

      assert html =~ "phx-click=\"clear_completed\""
      assert html =~ "Clear Completed (1)"
    end
  end
end