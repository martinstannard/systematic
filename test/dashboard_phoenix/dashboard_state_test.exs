defmodule DashboardPhoenix.DashboardStateTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.DashboardState

  # Default state for reference
  @default_state %{
    panels: %{
      config: false,
      linear: false,
      chainlink: false,
      prs: false,
      branches: false,
      opencode: false,
      gemini: false,
      coding_agents: false,
      subagents: false,
      dave: false,
      live_progress: false,
      agent_activity: false,
      system_processes: false,
      process_relationships: false,
      chat: true,
      activity: false,
      work_panel: false
    },
    dismissed_sessions: [],
    models: %{
      claude_model: "anthropic/claude-opus-4-5",
      opencode_model: "gemini-3-pro"
    },
    updated_at: nil,
    persist_timer: nil
  }

  describe "GenServer behavior - init" do
    test "init returns a valid state structure" do
      {:ok, state} = DashboardState.init([])

      # State should have panels, dismissed_sessions, and models
      assert Map.has_key?(state, :panels)
      assert Map.has_key?(state, :dismissed_sessions)
      assert Map.has_key?(state, :models)
      assert Map.has_key?(state, :updated_at)
    end

    test "init returns default panel states" do
      {:ok, state} = DashboardState.init([])

      # Panels should be a map
      assert is_map(state.panels)
      # Should have all expected panel keys
      assert Map.has_key?(state.panels, :config)
      assert Map.has_key?(state.panels, :linear)
      assert Map.has_key?(state.panels, :prs)
    end

    test "init returns empty dismissed_sessions by default" do
      {:ok, state} = DashboardState.init([])

      assert is_list(state.dismissed_sessions)
    end

    test "init returns default model selections" do
      {:ok, state} = DashboardState.init([])

      assert is_map(state.models)
      assert Map.has_key?(state.models, :claude_model)
      assert Map.has_key?(state.models, :opencode_model)
    end

    test "init includes persist_timer for async persistence" do
      {:ok, state} = DashboardState.init([])

      assert Map.has_key?(state, :persist_timer)
      assert state.persist_timer == nil
    end
  end

  describe "GenServer behavior - handle_call for panels" do
    test "get_state returns current state" do
      state = @default_state

      {:reply, reply, new_state} = DashboardState.handle_call(:get_state, self(), state)

      assert reply == state
      assert new_state == state
    end

    test "set_panel updates a panel to collapsed" do
      state = @default_state

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:set_panel, :linear, true}, self(), state)

      assert new_state.panels.linear == true
      assert new_state.updated_at != nil
    end

    test "set_panel updates a panel to expanded" do
      state = put_in(@default_state.panels.linear, true)

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:set_panel, :linear, false}, self(), state)

      assert new_state.panels.linear == false
    end

    test "set_panels updates multiple panels at once" do
      state = @default_state
      panels = %{"linear" => true, "prs" => true, "config" => true}

      {:reply, :ok, new_state} = DashboardState.handle_call({:set_panels, panels}, self(), state)

      assert new_state.panels.linear == true
      assert new_state.panels.prs == true
      assert new_state.panels.config == true
      # Other panels should remain unchanged
      assert new_state.panels.branches == false
    end
  end

  describe "GenServer behavior - handle_call for dismissed sessions" do
    test "dismiss_session adds a session to the list" do
      state = @default_state

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:dismiss_session, "session-123"}, self(), state)

      assert "session-123" in new_state.dismissed_sessions
      assert new_state.updated_at != nil
    end

    test "dismiss_session is idempotent" do
      state = put_in(@default_state.dismissed_sessions, ["session-123"])

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:dismiss_session, "session-123"}, self(), state)

      # Should still only have one entry
      assert Enum.count(new_state.dismissed_sessions, &(&1 == "session-123")) == 1
    end

    test "dismiss_sessions adds multiple sessions at once" do
      state = @default_state
      session_ids = ["session-1", "session-2", "session-3"]

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:dismiss_sessions, session_ids}, self(), state)

      assert "session-1" in new_state.dismissed_sessions
      assert "session-2" in new_state.dismissed_sessions
      assert "session-3" in new_state.dismissed_sessions
    end

    test "clear_dismissed_sessions removes all dismissed sessions" do
      state = put_in(@default_state.dismissed_sessions, ["session-1", "session-2", "session-3"])

      {:reply, :ok, new_state} =
        DashboardState.handle_call(:clear_dismissed_sessions, self(), state)

      assert new_state.dismissed_sessions == []
    end
  end

  describe "GenServer behavior - handle_call for models" do
    test "set_model updates claude_model" do
      state = @default_state

      {:reply, :ok, new_state} =
        DashboardState.handle_call(
          {:set_model, :claude_model, "anthropic/claude-sonnet-4-20250514"},
          self(),
          state
        )

      assert new_state.models.claude_model == "anthropic/claude-sonnet-4-20250514"
      assert new_state.updated_at != nil
    end

    test "set_model updates opencode_model" do
      state = @default_state

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:set_model, :opencode_model, "gemini-2.5-pro"}, self(), state)

      assert new_state.models.opencode_model == "gemini-2.5-pro"
    end

    test "set_models updates multiple models at once" do
      state = @default_state
      models = %{claude_model: "new-claude", opencode_model: "new-opencode"}

      {:reply, :ok, new_state} = DashboardState.handle_call({:set_models, models}, self(), state)

      assert new_state.models.claude_model == "new-claude"
      assert new_state.models.opencode_model == "new-opencode"
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(DashboardState, :start_link, 1)
      assert function_exported?(DashboardState, :get_state, 0)
      assert function_exported?(DashboardState, :get_panels, 0)
      assert function_exported?(DashboardState, :get_panel, 1)
      assert function_exported?(DashboardState, :set_panel, 2)
      assert function_exported?(DashboardState, :set_panels, 1)
      assert function_exported?(DashboardState, :get_dismissed_sessions, 0)
      assert function_exported?(DashboardState, :dismiss_session, 1)
      assert function_exported?(DashboardState, :dismiss_sessions, 1)
      assert function_exported?(DashboardState, :clear_dismissed_sessions, 0)
      assert function_exported?(DashboardState, :session_dismissed?, 1)
      assert function_exported?(DashboardState, :get_models, 0)
      assert function_exported?(DashboardState, :set_claude_model, 1)
      assert function_exported?(DashboardState, :set_opencode_model, 1)
      assert function_exported?(DashboardState, :set_models, 1)
      assert function_exported?(DashboardState, :subscribe, 0)
    end
  end

  describe "panel state structure" do
    test "panels have expected keys" do
      {:ok, state} = DashboardState.init([])

      expected_panels = [
        :config,
        :linear,
        :chainlink,
        :prs,
        :branches,
        :opencode,
        :gemini,
        :coding_agents,
        :subagents,
        :dave,
        :live_progress,
        :agent_activity,
        :system_processes,
        :process_relationships,
        :chat,
        :activity,
        :work_panel
      ]

      for panel <- expected_panels do
        assert Map.has_key?(state.panels, panel),
               "Expected panel :#{panel} to be present in state.panels"
      end
    end

    test "all panel values are booleans" do
      {:ok, state} = DashboardState.init([])

      for {_panel, value} <- state.panels do
        assert is_boolean(value)
      end
    end
  end

  describe "models structure" do
    test "models have expected keys" do
      {:ok, state} = DashboardState.init([])

      assert Map.has_key?(state.models, :claude_model)
      assert Map.has_key?(state.models, :opencode_model)
    end

    test "model values are strings" do
      {:ok, state} = DashboardState.init([])

      assert is_binary(state.models.claude_model)
      assert is_binary(state.models.opencode_model)
    end
  end

  describe "string key normalization" do
    test "set_panels normalizes string keys to atoms" do
      state = @default_state
      panels = %{"linear" => true, "config" => true}

      {:reply, :ok, new_state} = DashboardState.handle_call({:set_panels, panels}, self(), state)

      # Result should use atom keys
      assert new_state.panels.linear == true
      assert new_state.panels.config == true
    end

    test "set_models normalizes string keys to atoms" do
      state = @default_state
      models = %{"claude_model" => "new-model", "opencode_model" => "new-oc-model"}

      {:reply, :ok, new_state} = DashboardState.handle_call({:set_models, models}, self(), state)

      assert new_state.models.claude_model == "new-model"
      assert new_state.models.opencode_model == "new-oc-model"
    end
  end

  describe "async persistence" do
    test "state changes schedule a persist timer" do
      state = @default_state

      {:reply, :ok, new_state} =
        DashboardState.handle_call({:set_panel, :linear, true}, self(), state)

      # Timer should be set
      assert new_state.persist_timer != nil
      assert is_reference(new_state.persist_timer)

      # Cleanup timer
      Process.cancel_timer(new_state.persist_timer)
    end

    test "rapid state changes debounce to single timer" do
      state = @default_state

      # First change - sets timer
      {:reply, :ok, state1} =
        DashboardState.handle_call({:set_panel, :linear, true}, self(), state)

      timer1 = state1.persist_timer
      assert timer1 != nil

      # Second change - should cancel old timer and set new one
      {:reply, :ok, state2} =
        DashboardState.handle_call({:set_panel, :config, true}, self(), state1)

      timer2 = state2.persist_timer
      assert timer2 != nil
      assert timer2 != timer1

      # Cleanup
      Process.cancel_timer(timer2)
    end

    test "handle_info :persist clears the timer" do
      state = %{@default_state | persist_timer: make_ref()}

      {:noreply, new_state} = DashboardState.handle_info(:persist, state)

      assert new_state.persist_timer == nil
    end

    test "handle_info ignores unknown messages" do
      state = @default_state

      {:noreply, new_state} = DashboardState.handle_info(:unknown_message, state)

      assert new_state == state
    end
  end
end
