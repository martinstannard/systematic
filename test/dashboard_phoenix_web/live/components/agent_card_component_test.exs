defmodule DashboardPhoenixWeb.Live.Components.AgentCardComponentTest do
  use DashboardPhoenixWeb.ConnCase

  import Phoenix.LiveViewTest
  alias DashboardPhoenixWeb.Live.Components.AgentCardComponent

  describe "AgentCardComponent short_model_name/1" do
    test "extracts opus from claude model strings" do
      assert "opus" = AgentCardComponent.short_model_name("claude-opus-4-5")
      assert "opus" = AgentCardComponent.short_model_name("anthropic/claude-opus-4-5")
      assert "opus" = AgentCardComponent.short_model_name("CLAUDE-OPUS-4")
    end

    test "extracts sonnet from claude model strings" do
      assert "sonnet" = AgentCardComponent.short_model_name("claude-sonnet-4-20250514")
      assert "sonnet" = AgentCardComponent.short_model_name("anthropic/claude-sonnet-4")
    end

    test "extracts haiku from claude model strings" do
      assert "haiku" = AgentCardComponent.short_model_name("claude-3-haiku")
      assert "haiku" = AgentCardComponent.short_model_name("anthropic/claude-haiku-3")
    end

    test "extracts gemini from google model strings" do
      assert "gemini" = AgentCardComponent.short_model_name("gemini-2.5-pro")
      assert "gemini" = AgentCardComponent.short_model_name("google/gemini-flash")
    end

    test "extracts gpt variants from openai model strings" do
      assert "gpt-4o" = AgentCardComponent.short_model_name("gpt-4o-mini")
      assert "gpt-4" = AgentCardComponent.short_model_name("gpt-4-turbo")
      assert "gpt-3" = AgentCardComponent.short_model_name("gpt-3.5-turbo")
    end

    test "extracts o1/o3 reasoning models" do
      assert "o1" = AgentCardComponent.short_model_name("o1-preview")
      assert "o3" = AgentCardComponent.short_model_name("o3-mini")
    end

    test "returns nil for unknown models" do
      assert nil == AgentCardComponent.short_model_name("unknown-model")
      assert nil == AgentCardComponent.short_model_name(nil)
      assert nil == AgentCardComponent.short_model_name("")
    end
  end

  describe "AgentCardComponent agent_type_info/1" do
    test "identifies Claude agents" do
      assert {:claude, "Claude", "🟣"} = AgentCardComponent.agent_type_info("claude")

      assert {:claude, "Claude", "🟣"} =
               AgentCardComponent.agent_type_info("anthropic/claude-sonnet")

      assert {:claude, "Claude", "🟣"} =
               AgentCardComponent.agent_type_info("anthropic/claude-opus-4-5")
    end

    test "identifies OpenCode agents" do
      assert {:opencode, "OpenCode", "🔷"} = AgentCardComponent.agent_type_info("opencode")
      assert {:opencode, "OpenCode", "🔷"} = AgentCardComponent.agent_type_info("opencode-model")
    end

    test "identifies Sub-agent type" do
      assert {:subagent, "Sub-agent", "🤖"} = AgentCardComponent.agent_type_info("subagent")
    end

    test "identifies Gemini agents" do
      assert {:gemini, "Gemini", "✨"} = AgentCardComponent.agent_type_info("gemini")
      assert {:gemini, "Gemini", "✨"} = AgentCardComponent.agent_type_info("google/gemini-3-pro")
    end

    test "identifies OpenAI agents" do
      assert {:openai, "OpenAI", "🔥"} = AgentCardComponent.agent_type_info("openai")
      assert {:openai, "OpenAI", "🔥"} = AgentCardComponent.agent_type_info("openai/gpt-4")
      assert {:openai, "OpenAI", "🔥"} = AgentCardComponent.agent_type_info("gpt-4-turbo")
    end

    test "returns unknown for unrecognized types" do
      assert {:unknown, "Agent", "⚡"} = AgentCardComponent.agent_type_info("unknown-model")
      assert {:unknown, "Agent", "⚡"} = AgentCardComponent.agent_type_info(nil)
    end
  end

  describe "AgentCardComponent normalize_state/1" do
    test "normalizes running states" do
      assert :running = AgentCardComponent.normalize_state("running")
      assert :running = AgentCardComponent.normalize_state("active")
    end

    test "normalizes completed states" do
      assert :completed = AgentCardComponent.normalize_state("completed")
      assert :completed = AgentCardComponent.normalize_state("done")
    end

    test "normalizes failed states" do
      assert :failed = AgentCardComponent.normalize_state("failed")
      assert :failed = AgentCardComponent.normalize_state("error")
    end

    test "normalizes idle states" do
      assert :idle = AgentCardComponent.normalize_state("idle")
      assert :idle = AgentCardComponent.normalize_state("ready")
      assert :idle = AgentCardComponent.normalize_state("stopped")
    end

    test "defaults to idle for unknown states" do
      assert :idle = AgentCardComponent.normalize_state("unknown")
      assert :idle = AgentCardComponent.normalize_state(nil)
    end
  end

  describe "AgentCardComponent rendering" do
    test "renders Claude agent card with correct icon" do
      agent = %{
        id: "claude-1",
        type: "claude",
        name: "Test Claude Agent",
        task: "Working on feature",
        status: "running",
        runtime: "2m 30s",
        updated_at: System.system_time(:millisecond) - 150_000
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Claude icon
      assert html =~ "🟣"
      assert html =~ "Test Claude Agent"
      assert html =~ "Working on feature"
      assert html =~ "running"
      assert html =~ "2m 30s"
    end

    test "renders OpenCode agent card with correct icon" do
      agent = %{
        id: "opencode-1",
        type: "opencode",
        name: "my-project",
        task: "Implementing tests",
        status: "active"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # OpenCode icon
      assert html =~ "🔷"
      assert html =~ "my-project"
      assert html =~ "Implementing tests"
      # "active" normalizes to "running"
      assert html =~ "running"
    end

    test "renders Sub-agent card with correct icon" do
      agent = %{
        id: "subagent-1",
        type: "subagent",
        name: "PR Review Agent",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Sub-agent icon
      assert html =~ "🤖"
      assert html =~ "PR Review Agent"
    end

    test "shows green state indicator for running agents" do
      agent = %{
        id: "running-agent",
        type: "claude",
        name: "Running Agent",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Green state indicator
      assert html =~ "bg-green-500"
      # Green badge text
      assert html =~ "text-green-400"
      # Running animation
      assert html =~ "animate-pulse"
    end

    test "shows blue state indicator for completed agents" do
      agent = %{
        id: "completed-agent",
        type: "claude",
        name: "Completed Agent",
        status: "completed",
        runtime: "5m 12s"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Blue state indicator
      assert html =~ "bg-blue-500"
      # Blue badge text
      assert html =~ "text-blue-400"
      # No animation for completed
      refute html =~ "animate-pulse"
    end

    test "shows red state indicator for failed agents" do
      agent = %{
        id: "failed-agent",
        type: "claude",
        name: "Failed Agent",
        status: "failed"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Red state indicator
      assert html =~ "bg-red-500"
      # Red badge text
      assert html =~ "text-red-400"
    end

    test "shows gray state indicator for idle agents" do
      agent = %{
        id: "idle-agent",
        type: "opencode",
        name: "Idle Agent",
        status: "idle"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Gray state indicator
      assert html =~ "bg-gray-500"
      # Gray badge text
      assert html =~ "text-gray-400"
    end

    test "includes LiveDuration hook for running agents" do
      agent = %{
        id: "running-agent",
        type: "claude",
        name: "Running Agent",
        status: "running",
        runtime: "1m 0s",
        updated_at: System.system_time(:millisecond) - 60_000
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "phx-hook=\"LiveDuration\""
      assert html =~ "data-start-time="
    end

    test "does not include LiveDuration hook for non-running agents" do
      agent = %{
        id: "completed-agent",
        type: "claude",
        name: "Completed Agent",
        status: "completed",
        runtime: "5m 12s"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      refute html =~ "phx-hook=\"LiveDuration\""
      # Static duration
      assert html =~ "5m 12s"
    end

    test "handles agents with minimal data" do
      agent = %{
        id: "minimal",
        status: "idle"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Unknown agent type icon
      assert html =~ "⚡"
      assert html =~ "idle"
      refute html =~ "phx-hook=\"LiveDuration\""
    end

    test "truncates long names" do
      agent = %{
        id: "long-name",
        type: "claude",
        name: "This is a very long agent name that should be truncated in the display",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "truncate"
      assert html =~ "This is a very long agent name that should be truncated in the display"
    end

    test "displays task description when provided" do
      agent = %{
        id: "with-task",
        type: "claude",
        name: "Working Agent",
        task: "Refactoring the authentication module",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "Refactoring the authentication module"
    end

    test "omits task description when not provided" do
      agent = %{
        id: "no-task",
        type: "claude",
        name: "Agent Without Task",
        status: "idle"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "Agent Without Task"
      # Task section should not be rendered
      refute html =~ "text-base-content/60 truncate"
    end

    test "extracts name from label fallback" do
      agent = %{
        id: "with-label",
        label: "My Custom Label",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "My Custom Label"
    end

    test "extracts name from slug fallback" do
      agent = %{
        id: "with-slug",
        slug: "project-slug",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "project-slug"
    end

    test "falls back to id for name" do
      agent = %{
        id: "agent-uuid-1234",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "agent-uuid-1234"
    end

    test "extracts task from task_summary fallback" do
      agent = %{
        id: "with-summary",
        name: "Agent",
        task_summary: "This is the task summary",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "This is the task summary"
    end

    test "detects agent type from model string" do
      agent = %{
        id: "model-detect",
        model: "anthropic/claude-opus-4-5",
        name: "Claude From Model",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Claude icon detected from model
      assert html =~ "🟣"
    end

    test "sets correct card border for running state" do
      agent = %{
        id: "running",
        type: "claude",
        name: "Running",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "border-green-500/40"
    end

    test "sets correct card border for completed state" do
      agent = %{
        id: "completed",
        type: "claude",
        name: "Completed",
        status: "completed"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "border-blue-500/30"
    end

    test "sets correct card border for failed state" do
      agent = %{
        id: "failed",
        type: "claude",
        name: "Failed",
        status: "failed"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "border-red-500/30"
    end

    test "includes data attributes for testing and styling" do
      agent = %{
        id: "test-agent",
        type: "claude",
        name: "Test Agent",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "data-agent-type=\"claude\""
      assert html =~ "data-state=\"running\""
    end
  end

  describe "AgentCardComponent with different model providers" do
    test "renders Gemini agent correctly" do
      agent = %{
        id: "gemini-1",
        model: "google/gemini-3-pro",
        name: "Gemini Agent",
        status: "running"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Gemini icon
      assert html =~ "✨"
      assert html =~ "Gemini Agent"
    end

    test "renders OpenAI agent correctly" do
      agent = %{
        id: "openai-1",
        model: "openai/gpt-4-turbo",
        name: "GPT Agent",
        status: "completed"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # OpenAI icon
      assert html =~ "🔥"
      assert html =~ "GPT Agent"
    end
  end

  describe "AgentCardComponent model display" do
    test "shows model name with duration for running agent" do
      agent = %{
        id: "model-test",
        type: "claude",
        model: "anthropic/claude-opus-4-5",
        name: "Test Agent",
        status: "running",
        runtime: "2m 30s"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "opus"
      assert html =~ "•"
      assert html =~ "2m 30s"
    end

    test "shows model name with duration for completed agent" do
      agent = %{
        id: "model-test",
        type: "claude",
        model: "claude-sonnet-4-20250514",
        name: "Test Agent",
        status: "completed",
        runtime: "5m 12s"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "sonnet"
      assert html =~ "•"
      assert html =~ "5m 12s"
    end

    test "shows only model name when no runtime" do
      agent = %{
        id: "model-only",
        type: "claude",
        model: "gemini-2.5-pro",
        name: "Test Agent",
        status: "idle"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "gemini"
    end

    test "shows only duration when model is unknown" do
      agent = %{
        id: "duration-only",
        type: "claude",
        model: "some-unknown-model",
        name: "Test Agent",
        status: "completed",
        runtime: "3m 45s"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "3m 45s"
      refute html =~ "•"
    end

    test "includes data-model attribute for LiveDuration hook" do
      agent = %{
        id: "data-attr-test",
        type: "claude",
        model: "claude-opus-4-5",
        name: "Test Agent",
        status: "running",
        runtime: "1m 0s"
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "data-model=\"opus\""
    end
  end

  describe "AgentCardComponent edge cases" do
    test "handles nil agent gracefully" do
      html = render_component(AgentCardComponent, id: "test-card", agent: nil)

      assert html =~ "agent-card"
      assert html =~ "idle"
    end

    test "handles empty agent map" do
      html = render_component(AgentCardComponent, id: "test-card", agent: %{})

      assert html =~ "agent-card"
      assert html =~ "Unknown"
      assert html =~ "idle"
    end

    test "computes start_time from created_at" do
      now = System.system_time(:millisecond)

      agent = %{
        id: "with-created",
        type: "claude",
        name: "Agent",
        status: "running",
        # 2 minutes ago
        created_at: now - 120_000
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      assert html =~ "data-start-time=\"#{now - 120_000}\""
    end

    test "computes start_time from updated_at and runtime" do
      now = System.system_time(:millisecond)

      agent = %{
        id: "with-updated",
        type: "claude",
        name: "Agent",
        status: "running",
        runtime: "2m 30s",
        updated_at: now
      }

      html = render_component(AgentCardComponent, id: "test-card", agent: agent)

      # Should have data-start-time = updated_at - 150 seconds (2m 30s)
      expected_start = now - 150 * 1000
      assert html =~ "data-start-time=\"#{expected_start}\""
    end
  end
end
