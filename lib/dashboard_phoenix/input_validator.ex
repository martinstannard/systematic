defmodule DashboardPhoenix.InputValidator do
  @moduledoc """
  Input validation functions to prevent command injection and ensure data integrity.
  
  This module provides validation functions for user inputs that could be used in
  shell commands or other security-sensitive operations.
  """

  @doc """
  Validates a process ID (PID).
  
  PIDs must be positive integers.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_pid("1234")
      {:ok, 1234}
      
      iex> DashboardPhoenix.InputValidator.validate_pid("-123")
      {:error, "PID must be a positive integer"}
      
      iex> DashboardPhoenix.InputValidator.validate_pid("abc")
      {:error, "PID must be a positive integer"}
  """
  def validate_pid(pid_string) when is_binary(pid_string) do
    case Integer.parse(pid_string) do
      {pid, ""} when pid > 0 ->
        {:ok, pid}
      
      {_pid, _remainder} ->
        {:error, "PID must be a positive integer"}
      
      :error ->
        {:error, "PID must be a positive integer"}
    end
  end

  def validate_pid(_), do: {:error, "PID must be a string"}

  @doc """
  Validates a Git branch name.
  
  Branch names must contain only alphanumeric characters, hyphens, underscores, 
  dots, and forward slashes. They cannot contain shell metacharacters or 
  dangerous characters that could be used for command injection.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_branch_name("feature/my-branch")
      {:ok, "feature/my-branch"}
      
      iex> DashboardPhoenix.InputValidator.validate_branch_name("feature/branch_v1.2")
      {:ok, "feature/branch_v1.2"}
      
      iex> DashboardPhoenix.InputValidator.validate_branch_name("feature; rm -rf /")
      {:error, "Branch name contains invalid characters"}
      
      iex> DashboardPhoenix.InputValidator.validate_branch_name("")
      {:error, "Branch name cannot be empty"}
  """
  def validate_branch_name(branch_name) when is_binary(branch_name) do
    cond do
      String.length(branch_name) == 0 ->
        {:error, "Branch name cannot be empty"}
      
      String.length(branch_name) > 200 ->
        {:error, "Branch name too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9._\/-]+$/, branch_name) ->
        {:ok, branch_name}
      
      true ->
        {:error, "Branch name contains invalid characters"}
    end
  end

  def validate_branch_name(_), do: {:error, "Branch name must be a string"}

  @doc """
  Validates a Linear ticket ID.
  
  Linear ticket IDs typically follow the format: TEAM-123 where TEAM is uppercase
  letters and numbers and 123 is a number.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_linear_ticket_id("ENG-123")
      {:ok, "ENG-123"}
      
      iex> DashboardPhoenix.InputValidator.validate_linear_ticket_id("PLATFORM-456")
      {:ok, "PLATFORM-456"}
      
      iex> DashboardPhoenix.InputValidator.validate_linear_ticket_id("'; DROP TABLE tickets; --")
      {:error, "Invalid ticket ID format"}
      
      iex> DashboardPhoenix.InputValidator.validate_linear_ticket_id("")
      {:error, "Ticket ID cannot be empty"}
  """
  def validate_linear_ticket_id(ticket_id) when is_binary(ticket_id) do
    cond do
      String.length(ticket_id) == 0 ->
        {:error, "Ticket ID cannot be empty"}
      
      String.length(ticket_id) > 50 ->
        {:error, "Ticket ID too long"}
      
      Regex.match?(~r/^[A-Z][A-Z0-9]*-[0-9]+$/, ticket_id) ->
        {:ok, ticket_id}
      
      true ->
        {:error, "Invalid ticket ID format"}
    end
  end

  def validate_linear_ticket_id(_), do: {:error, "Ticket ID must be a string"}

  @doc """
  Validates a Chainlink issue ID.
  
  Chainlink issue IDs must be positive integers.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_chainlink_issue_id("123")
      {:ok, 123}
      
      iex> DashboardPhoenix.InputValidator.validate_chainlink_issue_id("0")
      {:error, "Issue ID must be a positive integer"}
      
      iex> DashboardPhoenix.InputValidator.validate_chainlink_issue_id("abc")
      {:error, "Issue ID must be a positive integer"}
  """
  def validate_chainlink_issue_id(issue_id_string) when is_binary(issue_id_string) do
    case Integer.parse(issue_id_string) do
      {issue_id, ""} when issue_id > 0 ->
        {:ok, issue_id}
      
      {_issue_id, _remainder} ->
        {:error, "Issue ID must be a positive integer"}
      
      :error ->
        {:error, "Issue ID must be a positive integer"}
    end
  end

  def validate_chainlink_issue_id(_), do: {:error, "Issue ID must be a string"}

  @doc """
  Validates a session ID.
  
  Session IDs must be alphanumeric with hyphens and underscores only.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_session_id("session-123_abc")
      {:ok, "session-123_abc"}
      
      iex> DashboardPhoenix.InputValidator.validate_session_id("session; rm -rf /")
      {:error, "Session ID contains invalid characters"}
      
      iex> DashboardPhoenix.InputValidator.validate_session_id("")
      {:error, "Session ID cannot be empty"}
  """
  def validate_session_id(session_id) when is_binary(session_id) do
    cond do
      String.length(session_id) == 0 ->
        {:error, "Session ID cannot be empty"}
      
      String.length(session_id) > 100 ->
        {:error, "Session ID too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9._-]+$/, session_id) ->
        {:ok, session_id}
      
      true ->
        {:error, "Session ID contains invalid characters"}
    end
  end

  def validate_session_id(_), do: {:error, "Session ID must be a string"}

  @doc """
  Validates user prompt text.
  
  Prompts must not be empty and must have a reasonable length limit.
  We strip dangerous shell characters but allow most text.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_prompt("Hello, how are you?")
      {:ok, "Hello, how are you?"}
      
      iex> DashboardPhoenix.InputValidator.validate_prompt("")
      {:error, "Prompt cannot be empty"}
      
      iex> DashboardPhoenix.InputValidator.validate_prompt(String.duplicate("a", 10001))
      {:error, "Prompt too long"}
  """
  def validate_prompt(prompt) when is_binary(prompt) do
    cond do
      String.length(prompt) == 0 ->
        {:error, "Prompt cannot be empty"}
      
      String.length(prompt) > 10_000 ->
        {:error, "Prompt too long"}
      
      true ->
        {:ok, prompt}
    end
  end

  def validate_prompt(_), do: {:error, "Prompt must be a string"}

  @doc """
  Validates a model name.
  
  Model names must be alphanumeric with hyphens, underscores, dots, and slashes only.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_model_name("claude-3-5-sonnet-20241022")
      {:ok, "claude-3-5-sonnet-20241022"}
      
      iex> DashboardPhoenix.InputValidator.validate_model_name("model; rm -rf /")
      {:error, "Model name contains invalid characters"}
      
      iex> DashboardPhoenix.InputValidator.validate_model_name("")
      {:error, "Model name cannot be empty"}
  """
  def validate_model_name(model_name) when is_binary(model_name) do
    cond do
      String.length(model_name) == 0 ->
        {:error, "Model name cannot be empty"}
      
      String.length(model_name) > 100 ->
        {:error, "Model name too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9._\/-]+$/, model_name) ->
        {:ok, model_name}
      
      true ->
        {:error, "Model name contains invalid characters"}
    end
  end

  def validate_model_name(_), do: {:error, "Model name must be a string"}

  @doc """
  Validates a filter/status string.
  
  These are typically predefined values but we still validate for safety.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_filter_string("Triage")
      {:ok, "Triage"}
      
      iex> DashboardPhoenix.InputValidator.validate_filter_string("filter; rm -rf /")
      {:error, "Filter contains invalid characters"}
  """
  def validate_filter_string(filter) when is_binary(filter) do
    cond do
      String.length(filter) == 0 ->
        {:error, "Filter cannot be empty"}
      
      String.length(filter) > 50 ->
        {:error, "Filter too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9 _-]+$/, filter) ->
        {:ok, filter}
      
      true ->
        {:error, "Filter contains invalid characters"}
    end
  end

  def validate_filter_string(_), do: {:error, "Filter must be a string"}

  @doc """
  Validates a timestamp string.
  
  For progress component timestamps.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_timestamp_string("1640995200")
      {:ok, "1640995200"}
      
      iex> DashboardPhoenix.InputValidator.validate_timestamp_string("timestamp; rm -rf /")
      {:error, "Timestamp contains invalid characters"}
  """
  def validate_timestamp_string(ts_string) when is_binary(ts_string) do
    cond do
      String.length(ts_string) == 0 ->
        {:error, "Timestamp cannot be empty"}
      
      String.length(ts_string) > 20 ->
        {:error, "Timestamp too long"}
      
      Regex.match?(~r/^[0-9.]+$/, ts_string) ->
        {:ok, ts_string}
      
      true ->
        {:error, "Timestamp contains invalid characters"}
    end
  end

  def validate_timestamp_string(_), do: {:error, "Timestamp must be a string"}

  @doc """
  Validates a general ID that could contain various formats.
  
  Used for ticket IDs that might be Linear or other formats.
  More permissive than specific validators.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_general_id("ENG-123")
      {:ok, "ENG-123"}
      
      iex> DashboardPhoenix.InputValidator.validate_general_id("12345")
      {:ok, "12345"}
      
      iex> DashboardPhoenix.InputValidator.validate_general_id("id; rm -rf /")
      {:error, "ID contains invalid characters"}
  """
  def validate_general_id(id) when is_binary(id) do
    cond do
      String.length(id) == 0 ->
        {:error, "ID cannot be empty"}
      
      String.length(id) > 100 ->
        {:error, "ID too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9._-]+$/, id) ->
        {:ok, id}
      
      true ->
        {:error, "ID contains invalid characters"}
    end
  end

  def validate_general_id(_), do: {:error, "ID must be a string"}

  @doc """
  Validates a panel name.
  
  Panel names should be predefined strings.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_panel_name("coding_agents")
      {:ok, "coding_agents"}
      
      iex> DashboardPhoenix.InputValidator.validate_panel_name("panel; rm -rf /")
      {:error, "Panel name contains invalid characters"}
  """
  def validate_panel_name(panel_name) when is_binary(panel_name) do
    cond do
      String.length(panel_name) == 0 ->
        {:error, "Panel name cannot be empty"}
      
      String.length(panel_name) > 50 ->
        {:error, "Panel name too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9_]+$/, panel_name) ->
        {:ok, panel_name}
      
      true ->
        {:error, "Panel name contains invalid characters"}
    end
  end

  def validate_panel_name(_), do: {:error, "Panel name must be a string"}

  @doc """
  Validates an agent/coding agent name.
  
  Agent names should be simple alphanumeric strings.
  
  ## Examples
  
      iex> DashboardPhoenix.InputValidator.validate_agent_name("opencode")
      {:ok, "opencode"}
      
      iex> DashboardPhoenix.InputValidator.validate_agent_name("agent; rm -rf /")
      {:error, "Agent name contains invalid characters"}
  """
  def validate_agent_name(agent_name) when is_binary(agent_name) do
    cond do
      String.length(agent_name) == 0 ->
        {:error, "Agent name cannot be empty"}
      
      String.length(agent_name) > 50 ->
        {:error, "Agent name too long"}
      
      Regex.match?(~r/^[a-zA-Z0-9_-]+$/, agent_name) ->
        {:ok, agent_name}
      
      true ->
        {:error, "Agent name contains invalid characters"}
    end
  end

  def validate_agent_name(_), do: {:error, "Agent name must be a string"}
end