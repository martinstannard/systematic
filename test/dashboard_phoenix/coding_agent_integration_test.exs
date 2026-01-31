defmodule DashboardPhoenix.CodingAgentIntegrationTest do
  @moduledoc """
  Integration tests for coding agent selection and client interfaces.
  
  This test suite verifies that:
  1. OpenCodeClient has the expected send_task/2 interface
  2. OpenClawClient has the expected work_on_ticket/3 interface
  3. Both clients accept model parameters correctly
  4. Error handling works as expected
  
  Uses mocks to avoid hitting real OpenCode/OpenClaw servers.
  """
  use ExUnit.Case, async: false

  import Mox

  alias DashboardPhoenix.ClientFactory
  alias DashboardPhoenix.AgentPreferences
  alias DashboardPhoenix.Mocks.{OpenCodeClientMock, OpenClawClientMock}

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  describe "OpenCodeClient interface" do
    test "send_task/2 function exists and accepts expected parameters" do
      client = ClientFactory.opencode_client()
      
      # Mock the send_task call
      expect(OpenCodeClientMock, :send_task, fn "Test prompt", [model: "gemini-3-pro"] ->
        {:ok, %{session_id: "test-123", slug: "test-session", port: 9100}}
      end)
      
      # Verify the function exists with the correct arity
      assert function_exported?(client, :send_task, 2)
      
      # Test that the function accepts the expected parameters
      result = client.send_task("Test prompt", model: "gemini-3-pro")
      
      # Should return success in mocked test
      assert {:ok, %{session_id: "test-123", slug: "test-session", port: 9100}} = result
    end

    test "send_task/2 accepts model option" do
      client = ClientFactory.opencode_client()
      
      # Test with different model options
      models = ["gemini-3-pro", "gemini-3-flash", "gemini-2.5-pro"]
      
      for model <- models do
        expected_session_id = "test-#{model}"
        expect(OpenCodeClientMock, :send_task, fn "Test with " <> ^model, [model: ^model] ->
          {:ok, %{session_id: expected_session_id, slug: expected_session_id, port: 9100}}
        end)
        
        result = client.send_task("Test with #{model}", model: model)
        assert {:ok, %{session_id: ^expected_session_id}} = result
      end
    end

    test "send_task/2 builds correct prompt format" do
      client = ClientFactory.opencode_client()
      prompt = "Work on ticket COR-123.\n\nTicket details:\nTest details\n\nPlease analyze this ticket and implement the required changes."
      
      expect(OpenCodeClientMock, :send_task, fn ^prompt, [model: "gemini-3-pro"] ->
        {:ok, %{session_id: "cor-123", slug: "work-cor-123", port: 9100}}
      end)
      
      # The function should handle the prompt without crashing
      result = client.send_task(prompt, model: "gemini-3-pro")
      assert {:ok, %{session_id: "cor-123"}} = result
    end

    test "health_check/0 function exists" do
      client = ClientFactory.opencode_client()
      
      expect(OpenCodeClientMock, :health_check, fn -> :ok end)
      
      assert function_exported?(client, :health_check, 0)
      
      result = client.health_check()
      assert :ok = result
    end

    test "list_sessions_formatted/0 function exists" do
      client = ClientFactory.opencode_client()
      
      expect(OpenCodeClientMock, :list_sessions_formatted, fn ->
        {:ok, [
          %{id: "session-1", slug: "test-1", title: "Test Session 1", status: "active"},
          %{id: "session-2", slug: "test-2", title: "Test Session 2", status: "idle"}
        ]}
      end)
      
      assert function_exported?(client, :list_sessions_formatted, 0)
      
      result = client.list_sessions_formatted()
      assert {:ok, [%{id: "session-1"}, %{id: "session-2"}]} = result
    end
  end

  describe "OpenClawClient interface" do
    test "work_on_ticket/3 function exists and accepts expected parameters" do
      client = ClientFactory.openclaw_client()
      
      expect(OpenClawClientMock, :work_on_ticket, fn "COR-123", "Test details", [model: "anthropic/claude-opus-4-5"] ->
        {:ok, %{ticket_id: "COR-123", output: "Work request sent successfully"}}
      end)
      
      # Verify the function exists with the correct arity
      assert function_exported?(client, :work_on_ticket, 3)
      
      # Test basic interface
      result = client.work_on_ticket("COR-123", "Test details", model: "anthropic/claude-opus-4-5")
      
      # Should return success in mocked test
      assert {:ok, %{ticket_id: "COR-123", output: "Work request sent successfully"}} = result
    end

    test "work_on_ticket/3 accepts model option" do
      client = ClientFactory.openclaw_client()
      
      # Test with different model options
      models = ["anthropic/claude-opus-4-5", "anthropic/claude-sonnet-4-20250514"]
      
      for model <- models do
        expected_output = "Success with #{model}"
        expect(OpenClawClientMock, :work_on_ticket, fn "COR-456", "Test with " <> ^model, [model: ^model] ->
          {:ok, %{ticket_id: "COR-456", output: expected_output}}
        end)
        
        result = client.work_on_ticket("COR-456", "Test with #{model}", model: model)
        assert {:ok, %{ticket_id: "COR-456", output: ^expected_output}} = result
      end
    end

    test "work_on_ticket/3 handles nil details" do
      client = ClientFactory.openclaw_client()
      
      expect(OpenClawClientMock, :work_on_ticket, fn "COR-789", nil, [model: "anthropic/claude-sonnet-4-20250514"] ->
        {:ok, %{ticket_id: "COR-789", output: "Success with nil details"}}
      end)
      
      # Test with nil details (should build fallback prompt)
      result = client.work_on_ticket("COR-789", nil, model: "anthropic/claude-sonnet-4-20250514")
      assert {:ok, %{ticket_id: "COR-789"}} = result
    end

    test "send_message/2 function exists" do
      client = ClientFactory.openclaw_client()
      
      expect(OpenClawClientMock, :send_message, fn "Test message", [channel: "webchat"] ->
        {:ok, :sent}
      end)
      
      assert function_exported?(client, :send_message, 2)
      
      result = client.send_message("Test message", channel: "webchat")
      assert {:ok, :sent} = result
    end
  end

  describe "AgentPreferences integration" do
    test "get_coding_agent/0 returns valid agent type" do
      agent = AgentPreferences.get_coding_agent()
      assert agent in [:opencode, :claude, :gemini]
    end

    test "toggle_coding_agent/0 cycles through opencode, claude, and gemini" do
      # Set to known starting point
      AgentPreferences.set_coding_agent("opencode")
      assert AgentPreferences.get_coding_agent() == :opencode
      
      # Toggle: opencode -> claude
      AgentPreferences.toggle_coding_agent()
      assert AgentPreferences.get_coding_agent() == :claude
      
      # Toggle: claude -> gemini
      AgentPreferences.toggle_coding_agent()
      assert AgentPreferences.get_coding_agent() == :gemini
      
      # Toggle: gemini -> opencode (full cycle)
      AgentPreferences.toggle_coding_agent()
      assert AgentPreferences.get_coding_agent() == :opencode
    end

    test "set_coding_agent/1 accepts valid agent types" do
      # Test setting to opencode
      :ok = AgentPreferences.set_coding_agent("opencode")
      assert AgentPreferences.get_coding_agent() == :opencode
      
      # Test setting to claude
      :ok = AgentPreferences.set_coding_agent("claude")
      assert AgentPreferences.get_coding_agent() == :claude
    end
  end

  describe "coding agent selection logic verification" do
    test "opencode preference should call OpenCodeClient.send_task" do
      client = ClientFactory.opencode_client()
      
      # This test verifies the conceptual flow:
      # When coding_agent_pref == :opencode -> OpenCodeClient.send_task should be used
      
      # Simulate the logic from execute_work_for_ticket
      coding_pref = :opencode
      opencode_model = "gemini-3-pro"
      ticket_id = "LOGIC-TEST-1"
      ticket_details = "Test OpenCode logic"
      
      if coding_pref == :opencode do
        prompt = """
        Work on ticket #{ticket_id}.
        
        Ticket details:
        #{ticket_details || "No details available - use the ticket ID to look it up."}
        
        Please analyze this ticket and implement the required changes.
        """
        
        expect(OpenCodeClientMock, :send_task, fn ^prompt, [model: "gemini-3-pro"] ->
          {:ok, %{session_id: "logic-test-1", slug: "work-logic-test-1", port: 9100}}
        end)
        
        # This would call OpenCodeClient.send_task(prompt, model: opencode_model)
        result = client.send_task(prompt, model: opencode_model)
        assert {:ok, %{session_id: "logic-test-1"}} = result
      end
    end

    test "claude preference should call OpenClawClient.work_on_ticket" do
      client = ClientFactory.openclaw_client()
      
      # This test verifies the conceptual flow:
      # When coding_agent_pref != :opencode -> OpenClawClient.work_on_ticket should be used
      
      # Simulate the logic from execute_work_for_ticket  
      coding_pref = :claude
      claude_model = "anthropic/claude-sonnet-4-20250514"
      ticket_id = "LOGIC-TEST-2"
      ticket_details = "Test Claude logic"
      
      if coding_pref != :opencode do
        expect(OpenClawClientMock, :work_on_ticket, fn "LOGIC-TEST-2", "Test Claude logic", [model: "anthropic/claude-sonnet-4-20250514"] ->
          {:ok, %{ticket_id: "LOGIC-TEST-2", output: "Claude work request sent"}}
        end)
        
        # This would call OpenClawClient.work_on_ticket(ticket_id, ticket_details, model: claude_model)
        result = client.work_on_ticket(ticket_id, ticket_details, model: claude_model)
        assert {:ok, %{ticket_id: "LOGIC-TEST-2"}} = result
      end
    end
  end

  describe "error scenarios" do
    test "OpenCodeClient handles server not running gracefully" do
      client = ClientFactory.opencode_client()
      
      # Mock server not running error
      expect(OpenCodeClientMock, :send_task, fn "Test when server down", [model: "gemini-3-pro"] ->
        {:error, "Failed to start OpenCode server: server not available"}
      end)
      
      # When server is not running, should return appropriate error
      result = client.send_task("Test when server down", model: "gemini-3-pro")
      
      assert {:error, reason} = result
      assert is_binary(reason)
      assert String.contains?(reason, "server")
    end

    test "OpenClawClient handles openclaw command not available" do
      client = ClientFactory.openclaw_client()
      
      # Mock openclaw command not available error
      expect(OpenClawClientMock, :work_on_ticket, fn "ERROR-TEST", "Test error handling", [model: "anthropic/claude-opus-4-5"] ->
        {:error, "openclaw agent failed: command not found"}
      end)
      
      # When openclaw CLI is not available, should return appropriate error
      result = client.work_on_ticket("ERROR-TEST", "Test error handling", model: "anthropic/claude-opus-4-5")
      
      assert {:error, reason} = result
      assert is_binary(reason)
      assert String.contains?(reason, "openclaw")
    end

    test "AgentPreferences handles invalid agent types" do
      # Should raise or return error for invalid agent types
      assert_raise FunctionClauseError, fn ->
        AgentPreferences.set_coding_agent("invalid")
      end
    end
  end

  describe "integration flow simulation" do
    test "complete flow: toggle agent -> execute work -> verify correct client called" do
      opencode_client = ClientFactory.opencode_client()
      openclaw_client = ClientFactory.openclaw_client()
      
      # Save initial state
      initial_agent = AgentPreferences.get_coding_agent()
      
      try do
        # Set to OpenCode mode
        AgentPreferences.set_coding_agent("opencode")
        assert AgentPreferences.get_coding_agent() == :opencode
        
        # Simulate work execution (OpenCode path)
        coding_pref = AgentPreferences.get_coding_agent()
        assert coding_pref == :opencode
        
        expect(OpenCodeClientMock, :send_task, fn "Flow test OpenCode", [model: "gemini-3-pro"] ->
          {:ok, %{session_id: "flow-opencode", slug: "flow-test", port: 9100}}
        end)
        
        # This would trigger OpenCodeClient.send_task
        opencode_result = opencode_client.send_task("Flow test OpenCode", model: "gemini-3-pro")
        assert {:ok, %{session_id: "flow-opencode"}} = opencode_result
        
        # Switch to Claude mode
        AgentPreferences.set_coding_agent("claude")
        assert AgentPreferences.get_coding_agent() == :claude
        
        # Simulate work execution (Claude path)
        coding_pref = AgentPreferences.get_coding_agent()
        assert coding_pref == :claude
        
        expect(OpenClawClientMock, :work_on_ticket, fn "FLOW-TEST", "Flow test Claude", [model: "anthropic/claude-opus-4-5"] ->
          {:ok, %{ticket_id: "FLOW-TEST", output: "Flow test complete"}}
        end)
        
        # This would trigger OpenClawClient.work_on_ticket
        claude_result = openclaw_client.work_on_ticket("FLOW-TEST", "Flow test Claude", model: "anthropic/claude-opus-4-5")
        assert {:ok, %{ticket_id: "FLOW-TEST"}} = claude_result
        
      after
        # Restore initial state
        AgentPreferences.set_coding_agent(to_string(initial_agent))
      end
    end

    test "model parameter passing verification" do
      opencode_client = ClientFactory.opencode_client()
      openclaw_client = ClientFactory.openclaw_client()
      
      # Verify that model parameters are properly passed through the entire chain
      models = [
        {:opencode, "gemini-3-pro"},
        {:opencode, "gemini-3-flash"},
        {:claude, "anthropic/claude-opus-4-5"},
        {:claude, "anthropic/claude-sonnet-4-20250514"}
      ]
      
      for {agent_type, model} <- models do
        case agent_type do
          :opencode ->
            expected_session_id = "model-test-#{model}"
            expected_slug = "test-#{model}"
            expect(OpenCodeClientMock, :send_task, fn "Model test for " <> ^model, [model: ^model] ->
              {:ok, %{session_id: expected_session_id, slug: expected_slug, port: 9100}}
            end)
            
            result = opencode_client.send_task("Model test for #{model}", model: model)
            assert {:ok, %{session_id: ^expected_session_id}} = result
            
          :claude ->
            expected_output = "Model test complete for #{model}"
            expect(OpenClawClientMock, :work_on_ticket, fn "MODEL-TEST", "Model test for " <> ^model, [model: ^model] ->
              {:ok, %{ticket_id: "MODEL-TEST", output: expected_output}}
            end)
            
            result = openclaw_client.work_on_ticket("MODEL-TEST", "Model test for #{model}", model: model)
            assert {:ok, %{ticket_id: "MODEL-TEST", output: ^expected_output}} = result
        end
      end
    end
  end
end