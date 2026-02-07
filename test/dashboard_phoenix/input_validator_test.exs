defmodule DashboardPhoenix.InputValidatorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.InputValidator

  describe "validate_pid/1" do
    test "accepts valid positive integer PIDs as strings" do
      assert {:ok, 1234} = InputValidator.validate_pid("1234")
      assert {:ok, 1} = InputValidator.validate_pid("1")
      assert {:ok, 999_999} = InputValidator.validate_pid("999999")
    end

    test "rejects negative PIDs" do
      assert {:error, "PID must be a positive integer"} = InputValidator.validate_pid("-123")
      assert {:error, "PID must be a positive integer"} = InputValidator.validate_pid("-1")
    end

    test "rejects zero PID" do
      assert {:error, "PID must be a positive integer"} = InputValidator.validate_pid("0")
    end

    test "rejects non-numeric strings" do
      assert {:error, "PID must be a positive integer"} = InputValidator.validate_pid("abc")
      assert {:error, "PID must be a positive integer"} = InputValidator.validate_pid("123abc")

      assert {:error, "PID must be a positive integer"} =
               InputValidator.validate_pid("123; rm -rf /")
    end

    test "rejects empty strings" do
      assert {:error, "PID must be a positive integer"} = InputValidator.validate_pid("")
    end

    test "rejects non-string inputs" do
      assert {:error, "PID must be a string"} = InputValidator.validate_pid(123)
      assert {:error, "PID must be a string"} = InputValidator.validate_pid(nil)
    end
  end

  describe "validate_branch_name/1" do
    test "accepts valid branch names" do
      assert {:ok, "main"} = InputValidator.validate_branch_name("main")
      assert {:ok, "feature/my-branch"} = InputValidator.validate_branch_name("feature/my-branch")
      assert {:ok, "hotfix/bug_123"} = InputValidator.validate_branch_name("hotfix/bug_123")
      assert {:ok, "release/v1.2.3"} = InputValidator.validate_branch_name("release/v1.2.3")

      assert {:ok, "user/john-doe/feature"} =
               InputValidator.validate_branch_name("user/john-doe/feature")
    end

    test "rejects branch names with shell metacharacters" do
      assert {:error, "Branch name contains invalid characters"} =
               InputValidator.validate_branch_name("feature; rm -rf /")

      assert {:error, "Branch name contains invalid characters"} =
               InputValidator.validate_branch_name("feature && echo pwned")

      assert {:error, "Branch name contains invalid characters"} =
               InputValidator.validate_branch_name("feature | cat /etc/passwd")

      assert {:error, "Branch name contains invalid characters"} =
               InputValidator.validate_branch_name("feature`whoami`")

      assert {:error, "Branch name contains invalid characters"} =
               InputValidator.validate_branch_name("feature$(whoami)")

      assert {:error, "Branch name contains invalid characters"} =
               InputValidator.validate_branch_name("feature\nrm -rf /")
    end

    test "rejects empty branch names" do
      assert {:error, "Branch name cannot be empty"} = InputValidator.validate_branch_name("")
    end

    test "rejects very long branch names" do
      long_name = String.duplicate("a", 201)
      assert {:error, "Branch name too long"} = InputValidator.validate_branch_name(long_name)
    end

    test "rejects non-string inputs" do
      assert {:error, "Branch name must be a string"} = InputValidator.validate_branch_name(nil)
      assert {:error, "Branch name must be a string"} = InputValidator.validate_branch_name(123)
    end
  end

  describe "validate_linear_ticket_id/1" do
    test "accepts valid Linear ticket IDs" do
      assert {:ok, "ENG-123"} = InputValidator.validate_linear_ticket_id("ENG-123")
      assert {:ok, "PLATFORM-456"} = InputValidator.validate_linear_ticket_id("PLATFORM-456")
      assert {:ok, "A-1"} = InputValidator.validate_linear_ticket_id("A-1")
      assert {:ok, "PRODUCT123-999"} = InputValidator.validate_linear_ticket_id("PRODUCT123-999")
    end

    test "rejects invalid Linear ticket ID formats" do
      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("eng-123")

      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("ENG123")

      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("123-ENG")

      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("ENG-")

      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("-123")
    end

    test "rejects malicious input" do
      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("'; DROP TABLE tickets; --")

      assert {:error, "Invalid ticket ID format"} =
               InputValidator.validate_linear_ticket_id("ENG-123; rm -rf /")
    end

    test "rejects empty strings" do
      assert {:error, "Ticket ID cannot be empty"} = InputValidator.validate_linear_ticket_id("")
    end

    test "rejects very long ticket IDs" do
      long_id = String.duplicate("A", 50) <> "-123"
      assert {:error, "Ticket ID too long"} = InputValidator.validate_linear_ticket_id(long_id)
    end

    test "rejects non-string inputs" do
      assert {:error, "Ticket ID must be a string"} =
               InputValidator.validate_linear_ticket_id(123)

      assert {:error, "Ticket ID must be a string"} =
               InputValidator.validate_linear_ticket_id(nil)
    end
  end

  describe "validate_chainlink_issue_id/1" do
    test "accepts valid positive integer issue IDs" do
      assert {:ok, 1} = InputValidator.validate_chainlink_issue_id("1")
      assert {:ok, 123} = InputValidator.validate_chainlink_issue_id("123")
      assert {:ok, 999_999} = InputValidator.validate_chainlink_issue_id("999999")
    end

    test "rejects zero and negative issue IDs" do
      assert {:error, "Issue ID must be a positive integer"} =
               InputValidator.validate_chainlink_issue_id("0")

      assert {:error, "Issue ID must be a positive integer"} =
               InputValidator.validate_chainlink_issue_id("-123")
    end

    test "rejects non-numeric strings" do
      assert {:error, "Issue ID must be a positive integer"} =
               InputValidator.validate_chainlink_issue_id("abc")

      assert {:error, "Issue ID must be a positive integer"} =
               InputValidator.validate_chainlink_issue_id("123abc")

      assert {:error, "Issue ID must be a positive integer"} =
               InputValidator.validate_chainlink_issue_id("123; rm -rf /")
    end

    test "rejects empty strings" do
      assert {:error, "Issue ID must be a positive integer"} =
               InputValidator.validate_chainlink_issue_id("")
    end

    test "rejects non-string inputs" do
      assert {:error, "Issue ID must be a string"} =
               InputValidator.validate_chainlink_issue_id(123)

      assert {:error, "Issue ID must be a string"} =
               InputValidator.validate_chainlink_issue_id(nil)
    end
  end

  describe "validate_session_id/1" do
    test "accepts valid session IDs" do
      assert {:ok, "session-123_abc"} = InputValidator.validate_session_id("session-123_abc")
      assert {:ok, "abc123"} = InputValidator.validate_session_id("abc123")
      assert {:ok, "test-session.v1"} = InputValidator.validate_session_id("test-session.v1")
    end

    test "rejects session IDs with dangerous characters" do
      assert {:error, "Session ID contains invalid characters"} =
               InputValidator.validate_session_id("session; rm -rf /")

      assert {:error, "Session ID contains invalid characters"} =
               InputValidator.validate_session_id("session && echo pwned")

      assert {:error, "Session ID contains invalid characters"} =
               InputValidator.validate_session_id("session|cat")
    end

    test "rejects empty session IDs" do
      assert {:error, "Session ID cannot be empty"} = InputValidator.validate_session_id("")
    end

    test "rejects very long session IDs" do
      long_id = String.duplicate("a", 101)
      assert {:error, "Session ID too long"} = InputValidator.validate_session_id(long_id)
    end

    test "rejects non-string inputs" do
      assert {:error, "Session ID must be a string"} = InputValidator.validate_session_id(123)
      assert {:error, "Session ID must be a string"} = InputValidator.validate_session_id(nil)
    end
  end

  describe "validate_prompt/1" do
    test "accepts valid prompts" do
      assert {:ok, "Hello, how are you?"} = InputValidator.validate_prompt("Hello, how are you?")

      assert {:ok, "Write some code for me"} =
               InputValidator.validate_prompt("Write some code for me")

      assert {:ok, "Multi\nline\nprompt"} = InputValidator.validate_prompt("Multi\nline\nprompt")
    end

    test "rejects empty prompts" do
      assert {:error, "Prompt cannot be empty"} = InputValidator.validate_prompt("")
    end

    test "rejects very long prompts" do
      long_prompt = String.duplicate("a", 10_001)
      assert {:error, "Prompt too long"} = InputValidator.validate_prompt(long_prompt)
    end

    test "accepts prompts at the length limit" do
      limit_prompt = String.duplicate("a", 10_000)
      assert {:ok, ^limit_prompt} = InputValidator.validate_prompt(limit_prompt)
    end

    test "rejects non-string inputs" do
      assert {:error, "Prompt must be a string"} = InputValidator.validate_prompt(123)
      assert {:error, "Prompt must be a string"} = InputValidator.validate_prompt(nil)
    end
  end

  describe "validate_model_name/1" do
    test "accepts valid model names" do
      assert {:ok, "claude-3-5-sonnet-20241022"} =
               InputValidator.validate_model_name("claude-3-5-sonnet-20241022")

      assert {:ok, "gpt-4"} = InputValidator.validate_model_name("gpt-4")
      assert {:ok, "model_v1.2"} = InputValidator.validate_model_name("model_v1.2")
      assert {:ok, "org/model"} = InputValidator.validate_model_name("org/model")
    end

    test "rejects model names with dangerous characters" do
      assert {:error, "Model name contains invalid characters"} =
               InputValidator.validate_model_name("model; rm -rf /")

      assert {:error, "Model name contains invalid characters"} =
               InputValidator.validate_model_name("model && echo pwned")

      assert {:error, "Model name contains invalid characters"} =
               InputValidator.validate_model_name("model|cat")
    end

    test "rejects empty model names" do
      assert {:error, "Model name cannot be empty"} = InputValidator.validate_model_name("")
    end

    test "rejects very long model names" do
      long_name = String.duplicate("a", 101)
      assert {:error, "Model name too long"} = InputValidator.validate_model_name(long_name)
    end

    test "rejects non-string inputs" do
      assert {:error, "Model name must be a string"} = InputValidator.validate_model_name(123)
      assert {:error, "Model name must be a string"} = InputValidator.validate_model_name(nil)
    end
  end

  describe "validate_filter_string/1" do
    test "accepts valid filter strings" do
      assert {:ok, "Triage"} = InputValidator.validate_filter_string("Triage")
      assert {:ok, "Todo"} = InputValidator.validate_filter_string("Todo")
      assert {:ok, "In Review"} = InputValidator.validate_filter_string("In Review")
      assert {:ok, "filter_name"} = InputValidator.validate_filter_string("filter_name")
    end

    test "rejects filter strings with dangerous characters" do
      assert {:error, "Filter contains invalid characters"} =
               InputValidator.validate_filter_string("filter; rm -rf /")

      assert {:error, "Filter contains invalid characters"} =
               InputValidator.validate_filter_string("filter && echo pwned")
    end

    test "rejects empty filter strings" do
      assert {:error, "Filter cannot be empty"} = InputValidator.validate_filter_string("")
    end

    test "rejects very long filter strings" do
      long_filter = String.duplicate("a", 51)
      assert {:error, "Filter too long"} = InputValidator.validate_filter_string(long_filter)
    end

    test "rejects non-string inputs" do
      assert {:error, "Filter must be a string"} = InputValidator.validate_filter_string(123)
      assert {:error, "Filter must be a string"} = InputValidator.validate_filter_string(nil)
    end
  end

  describe "validate_timestamp_string/1" do
    test "accepts valid timestamp strings" do
      assert {:ok, "1640995200"} = InputValidator.validate_timestamp_string("1640995200")
      assert {:ok, "1640995200.123"} = InputValidator.validate_timestamp_string("1640995200.123")
      assert {:ok, "0"} = InputValidator.validate_timestamp_string("0")
    end

    test "rejects timestamp strings with dangerous characters" do
      assert {:error, "Timestamp contains invalid characters"} =
               InputValidator.validate_timestamp_string("timestamp; rm -rf /")

      assert {:error, "Timestamp contains invalid characters"} =
               InputValidator.validate_timestamp_string("123abc")
    end

    test "rejects empty timestamp strings" do
      assert {:error, "Timestamp cannot be empty"} = InputValidator.validate_timestamp_string("")
    end

    test "rejects very long timestamp strings" do
      long_ts = String.duplicate("1", 21)
      assert {:error, "Timestamp too long"} = InputValidator.validate_timestamp_string(long_ts)
    end

    test "rejects non-string inputs" do
      assert {:error, "Timestamp must be a string"} =
               InputValidator.validate_timestamp_string(123)

      assert {:error, "Timestamp must be a string"} =
               InputValidator.validate_timestamp_string(nil)
    end
  end

  describe "validate_general_id/1" do
    test "accepts valid general IDs" do
      assert {:ok, "ENG-123"} = InputValidator.validate_general_id("ENG-123")
      assert {:ok, "12345"} = InputValidator.validate_general_id("12345")
      assert {:ok, "ticket_123"} = InputValidator.validate_general_id("ticket_123")
      assert {:ok, "test.id"} = InputValidator.validate_general_id("test.id")
    end

    test "rejects IDs with dangerous characters" do
      assert {:error, "ID contains invalid characters"} =
               InputValidator.validate_general_id("id; rm -rf /")

      assert {:error, "ID contains invalid characters"} =
               InputValidator.validate_general_id("id && echo pwned")
    end

    test "rejects empty IDs" do
      assert {:error, "ID cannot be empty"} = InputValidator.validate_general_id("")
    end

    test "rejects very long IDs" do
      long_id = String.duplicate("a", 101)
      assert {:error, "ID too long"} = InputValidator.validate_general_id(long_id)
    end

    test "rejects non-string inputs" do
      assert {:error, "ID must be a string"} = InputValidator.validate_general_id(123)
      assert {:error, "ID must be a string"} = InputValidator.validate_general_id(nil)
    end
  end

  describe "validate_panel_name/1" do
    test "accepts valid panel names" do
      assert {:ok, "coding_agents"} = InputValidator.validate_panel_name("coding_agents")
      assert {:ok, "system_processes"} = InputValidator.validate_panel_name("system_processes")
      assert {:ok, "panel123"} = InputValidator.validate_panel_name("panel123")
    end

    test "rejects panel names with dangerous characters" do
      assert {:error, "Panel name contains invalid characters"} =
               InputValidator.validate_panel_name("panel; rm -rf /")

      assert {:error, "Panel name contains invalid characters"} =
               InputValidator.validate_panel_name("panel-name")

      assert {:error, "Panel name contains invalid characters"} =
               InputValidator.validate_panel_name("panel.name")
    end

    test "rejects empty panel names" do
      assert {:error, "Panel name cannot be empty"} = InputValidator.validate_panel_name("")
    end

    test "rejects very long panel names" do
      long_name = String.duplicate("a", 51)
      assert {:error, "Panel name too long"} = InputValidator.validate_panel_name(long_name)
    end

    test "rejects non-string inputs" do
      assert {:error, "Panel name must be a string"} = InputValidator.validate_panel_name(123)
      assert {:error, "Panel name must be a string"} = InputValidator.validate_panel_name(nil)
    end
  end

  describe "validate_agent_name/1" do
    test "accepts valid agent names" do
      assert {:ok, "opencode"} = InputValidator.validate_agent_name("opencode")
      assert {:ok, "claude-code"} = InputValidator.validate_agent_name("claude-code")
      assert {:ok, "agent_123"} = InputValidator.validate_agent_name("agent_123")
    end

    test "rejects agent names with dangerous characters" do
      assert {:error, "Agent name contains invalid characters"} =
               InputValidator.validate_agent_name("agent; rm -rf /")

      assert {:error, "Agent name contains invalid characters"} =
               InputValidator.validate_agent_name("agent && echo pwned")
    end

    test "rejects empty agent names" do
      assert {:error, "Agent name cannot be empty"} = InputValidator.validate_agent_name("")
    end

    test "rejects very long agent names" do
      long_name = String.duplicate("a", 51)
      assert {:error, "Agent name too long"} = InputValidator.validate_agent_name(long_name)
    end

    test "rejects non-string inputs" do
      assert {:error, "Agent name must be a string"} = InputValidator.validate_agent_name(123)
      assert {:error, "Agent name must be a string"} = InputValidator.validate_agent_name(nil)
    end
  end
end
