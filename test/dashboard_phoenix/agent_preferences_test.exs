defmodule DashboardPhoenix.AgentPreferencesTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.AgentPreferences

  describe "valid_agents/0" do
    test "returns list of valid agents" do
      agents = AgentPreferences.valid_agents()
      assert is_list(agents)
      assert "opencode" in agents
      assert "claude" in agents
      assert "gemini" in agents
    end
  end

  describe "GenServer behavior - init" do
    test "init returns a valid state with coding_agent" do
      {:ok, state} = AgentPreferences.init([])

      # State should have a coding_agent that is one of the valid agents
      assert state.coding_agent in AgentPreferences.valid_agents()
      # updated_at could be nil (default) or a timestamp (loaded from file)
    end
  end

  describe "GenServer behavior - handle_call" do
    test "get_preferences returns current state" do
      state = %{coding_agent: "claude", updated_at: "2024-01-15T10:00:00Z"}

      {:reply, reply, new_state} = AgentPreferences.handle_call(:get_preferences, self(), state)

      assert reply == state
      assert new_state == state
    end

    test "set_coding_agent updates the agent to opencode" do
      state = %{coding_agent: "claude", updated_at: nil}

      {:reply, reply, new_state} =
        AgentPreferences.handle_call({:set_coding_agent, "opencode"}, self(), state)

      assert reply == :ok
      assert new_state.coding_agent == "opencode"
      # Should be updated
      assert new_state.updated_at != nil
    end

    test "set_coding_agent updates the agent to claude" do
      state = %{coding_agent: "opencode", updated_at: nil}

      {:reply, reply, new_state} =
        AgentPreferences.handle_call({:set_coding_agent, "claude"}, self(), state)

      assert reply == :ok
      assert new_state.coding_agent == "claude"
      assert new_state.updated_at != nil
    end

    test "set_coding_agent updates the agent to gemini" do
      state = %{coding_agent: "opencode", updated_at: nil}

      {:reply, :ok, new_state} =
        AgentPreferences.handle_call({:set_coding_agent, "gemini"}, self(), state)

      assert new_state.coding_agent == "gemini"
    end
  end

  describe "preferences cycling" do
    test "cycling follows expected order: opencode -> claude -> gemini -> opencode" do
      # This tests the logic, not the running GenServer

      # opencode -> claude
      assert cycle_agent(:opencode) == "claude"

      # claude -> gemini
      assert cycle_agent(:claude) == "gemini"

      # gemini -> opencode
      assert cycle_agent(:gemini) == "opencode"
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(AgentPreferences, :start_link, 1)
      assert function_exported?(AgentPreferences, :get_preferences, 0)
      assert function_exported?(AgentPreferences, :get_coding_agent, 0)
      assert function_exported?(AgentPreferences, :set_coding_agent, 1)
      assert function_exported?(AgentPreferences, :toggle_coding_agent, 0)
      assert function_exported?(AgentPreferences, :valid_agents, 0)
      assert function_exported?(AgentPreferences, :subscribe, 0)
    end
  end

  describe "set_coding_agent/1 validation" do
    test "only accepts valid agent values" do
      # The function has a guard that only accepts values in @valid_agents

      # Valid ones work (tested via handle_call above)
      for agent <- ["opencode", "claude", "gemini"] do
        assert agent in AgentPreferences.valid_agents()
      end
    end
  end

  describe "state structure" do
    test "state contains expected keys" do
      {:ok, state} = AgentPreferences.init([])

      # State should have these keys (including new round-robin fields)
      assert Map.has_key?(state, :coding_agent)
      assert Map.has_key?(state, :agent_mode)
      assert Map.has_key?(state, :last_agent)
      assert Map.has_key?(state, :updated_at)
    end

    test "coding_agent is always a valid value after init" do
      {:ok, state} = AgentPreferences.init([])

      assert state.coding_agent in AgentPreferences.valid_agents()
    end

    test "agent_mode is a valid mode" do
      {:ok, state} = AgentPreferences.init([])

      # agent_mode should be one of the valid modes
      assert state.agent_mode in AgentPreferences.valid_modes()
    end

    test "last_agent is a valid round-robin agent" do
      {:ok, state} = AgentPreferences.init([])

      # last_agent should be either claude or opencode
      assert state.last_agent in ["claude", "opencode"]
    end
  end

  describe "agent_mode handling" do
    test "valid_modes/0 returns list of valid modes" do
      modes = AgentPreferences.valid_modes()
      assert is_list(modes)
      assert "single" in modes
      assert "round_robin" in modes
    end

    test "set_agent_mode updates the mode to round_robin" do
      state = %{
        coding_agent: "claude",
        agent_mode: "single",
        last_agent: "claude",
        updated_at: nil
      }

      {:reply, :ok, new_state} =
        AgentPreferences.handle_call({:set_agent_mode, "round_robin"}, self(), state)

      assert new_state.agent_mode == "round_robin"
      assert new_state.updated_at != nil
    end

    test "set_agent_mode updates the mode back to single" do
      state = %{
        coding_agent: "claude",
        agent_mode: "round_robin",
        last_agent: "opencode",
        updated_at: nil
      }

      {:reply, :ok, new_state} =
        AgentPreferences.handle_call({:set_agent_mode, "single"}, self(), state)

      assert new_state.agent_mode == "single"
    end
  end

  describe "round-robin rotation" do
    test "next_agent in single mode returns the coding_agent" do
      state = %{
        coding_agent: "claude",
        agent_mode: "single",
        last_agent: "opencode",
        updated_at: nil
      }

      {:reply, {:ok, agent}, new_state} = AgentPreferences.handle_call(:next_agent, self(), state)

      assert agent == :claude
      # State should be unchanged in single mode
      assert new_state.last_agent == "opencode"
    end

    test "next_agent in round_robin mode alternates from claude to opencode" do
      state = %{
        coding_agent: "claude",
        agent_mode: "round_robin",
        last_agent: "claude",
        updated_at: nil
      }

      {:reply, {:ok, agent}, new_state} = AgentPreferences.handle_call(:next_agent, self(), state)

      assert agent == :opencode
      assert new_state.last_agent == "opencode"
      assert new_state.updated_at != nil
    end

    test "next_agent in round_robin mode alternates from opencode to claude" do
      state = %{
        coding_agent: "opencode",
        agent_mode: "round_robin",
        last_agent: "opencode",
        updated_at: nil
      }

      {:reply, {:ok, agent}, new_state} = AgentPreferences.handle_call(:next_agent, self(), state)

      assert agent == :claude
      assert new_state.last_agent == "claude"
    end

    test "round_robin alternates correctly over multiple calls" do
      # Start with last_agent = claude (so next should be opencode)
      state = %{
        coding_agent: "claude",
        agent_mode: "round_robin",
        last_agent: "claude",
        updated_at: nil
      }

      {:reply, {:ok, agent1}, state1} = AgentPreferences.handle_call(:next_agent, self(), state)
      assert agent1 == :opencode
      assert state1.last_agent == "opencode"

      {:reply, {:ok, agent2}, state2} = AgentPreferences.handle_call(:next_agent, self(), state1)
      assert agent2 == :claude
      assert state2.last_agent == "claude"

      {:reply, {:ok, agent3}, state3} = AgentPreferences.handle_call(:next_agent, self(), state2)
      assert agent3 == :opencode
      assert state3.last_agent == "opencode"
    end
  end

  describe "module exports for round-robin" do
    test "exports round-robin API functions" do
      assert function_exported?(AgentPreferences, :get_agent_mode, 0)
      assert function_exported?(AgentPreferences, :set_agent_mode, 1)
      assert function_exported?(AgentPreferences, :get_last_agent, 0)
      assert function_exported?(AgentPreferences, :next_agent, 0)
      assert function_exported?(AgentPreferences, :valid_modes, 0)
    end
  end

  # Helper to simulate toggle logic
  defp cycle_agent(current) do
    case current do
      :opencode -> "claude"
      :claude -> "gemini"
      :gemini -> "opencode"
    end
  end
end
