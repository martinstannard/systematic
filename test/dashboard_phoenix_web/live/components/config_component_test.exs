defmodule DashboardPhoenixWeb.Live.Components.ConfigComponentTest do
  @moduledoc """
  Tests for the ConfigComponent LiveComponent.
  """
  use DashboardPhoenixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  
  alias DashboardPhoenixWeb.Live.Components.ConfigComponent

  describe "handle_event/3 set_agent_mode" do
    test "set_agent_mode sends message to parent with mode" do
      # Create a minimal socket with required assigns
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          myself: %Phoenix.LiveComponent.CID{cid: 1},
          config_collapsed: false,
          coding_agent_pref: :opencode,
          agent_mode: "single",
          last_agent: "claude",
          claude_model: "anthropic/claude-opus-4-5",
          opencode_model: "gemini-3-pro",
          opencode_server_status: %{running: false},
          gemini_server_status: %{running: false}
        }
      }
      
      # Call handle_event with round_robin mode
      {:noreply, _socket} = ConfigComponent.handle_event("set_agent_mode", %{"mode" => "round_robin"}, socket)
      
      # The component sends a message to self(), which in a LiveComponent is the parent
      # We can verify the message was sent by checking the mailbox
      assert_received {:config_component, :set_agent_mode, "round_robin"}
    end
    
    test "set_agent_mode handles single mode" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          myself: %Phoenix.LiveComponent.CID{cid: 1},
          config_collapsed: false,
          coding_agent_pref: :opencode,
          agent_mode: "round_robin",
          last_agent: "claude",
          claude_model: "anthropic/claude-opus-4-5",
          opencode_model: "gemini-3-pro",
          opencode_server_status: %{running: false},
          gemini_server_status: %{running: false}
        }
      }
      
      {:noreply, _socket} = ConfigComponent.handle_event("set_agent_mode", %{"mode" => "single"}, socket)
      
      assert_received {:config_component, :set_agent_mode, "single"}
    end
    
    test "set_agent_mode rejects invalid modes" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          myself: %Phoenix.LiveComponent.CID{cid: 1},
          config_collapsed: false,
          coding_agent_pref: :opencode,
          agent_mode: "single",
          last_agent: "claude",
          claude_model: "anthropic/claude-opus-4-5",
          opencode_model: "gemini-3-pro",
          opencode_server_status: %{running: false},
          gemini_server_status: %{running: false}
        }
      }
      
      # Invalid mode should not match the guard clause and raise FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        ConfigComponent.handle_event("set_agent_mode", %{"mode" => "invalid"}, socket)
      end
    end
  end
  
  describe "render/1 agent mode display" do
    test "shows Single button as active when agent_mode is single" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        config_collapsed: false,
        coding_agent_pref: :opencode,
        agent_mode: "single",
        last_agent: "claude",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        opencode_server_status: %{running: false},
        gemini_server_status: %{running: false}
      }
      
      html = Phoenix.LiveViewTest.rendered_to_string(ConfigComponent.render(assigns))
      
      # Single button should have active styling
      assert html =~ "bg-accent/30"
      # The collapsed header should NOT show Round Robin indicator
      refute html =~ "🔄 Round Robin"
    end
    
    test "shows Round Robin button as active when agent_mode is round_robin" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        config_collapsed: false,
        coding_agent_pref: :opencode,
        agent_mode: "round_robin",
        last_agent: "claude",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        opencode_server_status: %{running: false},
        gemini_server_status: %{running: false}
      }
      
      html = Phoenix.LiveViewTest.rendered_to_string(ConfigComponent.render(assigns))
      
      # Round Robin button should have warning styling
      assert html =~ "bg-warning/30"
      # Should show Round Robin indicator in header
      assert html =~ "🔄 Round Robin"
      # Should show Next agent indicator
      assert html =~ "Next: OpenCode"  # When last_agent is claude, next is opencode
    end
    
    test "shows correct next agent when last_agent is opencode" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        config_collapsed: false,
        coding_agent_pref: :opencode,
        agent_mode: "round_robin",
        last_agent: "opencode",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        opencode_server_status: %{running: false},
        gemini_server_status: %{running: false}
      }
      
      html = Phoenix.LiveViewTest.rendered_to_string(ConfigComponent.render(assigns))
      
      # When last_agent is opencode, next should be Claude
      assert html =~ "Next: Claude"
    end
    
    test "disables coding agent toggle buttons in round_robin mode" do
      assigns = %{
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        config_collapsed: false,
        coding_agent_pref: :opencode,
        agent_mode: "round_robin",
        last_agent: "claude",
        claude_model: "anthropic/claude-opus-4-5",
        opencode_model: "gemini-3-pro",
        opencode_server_status: %{running: false},
        gemini_server_status: %{running: false}
      }
      
      html = Phoenix.LiveViewTest.rendered_to_string(ConfigComponent.render(assigns))
      
      # The coding agent section should have opacity-50 class
      assert html =~ "opacity-50"
      # Buttons should have disabled attribute
      assert html =~ "disabled"
    end
  end
end
