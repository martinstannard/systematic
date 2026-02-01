defmodule DashboardPhoenixWeb.HomeLive.SessionEnricher do
  @moduledoc """
  Extracts ticket IDs and PR numbers from session data.

  This module performs one-time enrichment of session data by extracting
  structured information (ticket IDs like COR-123, PR numbers like #456)
  from session titles, labels, and task summaries.

  The enrichment is done once when sessions are received, making subsequent
  lookups O(1) instead of running regex on every access.
  """

  # Precompiled regex patterns - compiled once at compile time
  @ticket_regex ~r/([A-Z]{2,5}-\d+)/i
  @pr_regex ~r/(?:#(\d+)|(?:PR[-#]?)(\d+)|(?:fix|review|update|work-on)[-_]?pr[-_]?(\d+))/i

  @typedoc "Session with extracted ticket/PR data"
  @type enriched_session :: map()

  @doc """
  Enrich an OpenCode session with extracted ticket IDs and PR numbers.

  Extracts from the session title field.

  ## Examples

      iex> enrich_opencode_session(%{title: "Working on COR-123"})
      %{title: "Working on COR-123", extracted_tickets: ["COR-123"], extracted_prs: []}
  """
  @spec enrich_opencode_session(map()) :: enriched_session()
  def enrich_opencode_session(session) do
    title = session.title || ""
    ticket_ids = extract_ticket_ids(title)
    pr_numbers = extract_pr_numbers(title)

    Map.merge(session, %{extracted_tickets: ticket_ids, extracted_prs: pr_numbers})
  end

  @doc """
  Enrich an agent session with extracted ticket IDs and PR numbers.

  Extracts from both label and task_summary fields.

  ## Examples

      iex> enrich_agent_session(%{label: "ticket-COR-456", task_summary: "Fix PR #789"})
      %{label: "ticket-COR-456", task_summary: "Fix PR #789", 
        extracted_tickets: ["COR-456"], extracted_prs: [789]}
  """
  @spec enrich_agent_session(map()) :: enriched_session()
  def enrich_agent_session(session) do
    label = Map.get(session, :label) || ""
    task = Map.get(session, :task_summary) || ""
    text = "#{label} #{task}"

    ticket_ids = extract_ticket_ids(text)
    pr_numbers = extract_pr_numbers(text)

    Map.merge(session, %{extracted_tickets: ticket_ids, extracted_prs: pr_numbers})
  end

  @doc """
  Extract ticket IDs from text.

  Matches patterns like COR-123, FRE-456, ABC-1.

  ## Examples

      iex> extract_ticket_ids("Working on COR-123 and FRE-456")
      ["COR-123", "FRE-456"]
  """
  @spec extract_ticket_ids(String.t()) :: list(String.t())
  def extract_ticket_ids(text) do
    case Regex.scan(@ticket_regex, text) do
      [] -> []
      matches -> Enum.map(matches, fn [_, id] -> String.upcase(id) end)
    end
  end

  @doc """
  Extract PR numbers from text.

  Matches patterns like #123, PR-456, pr-789, fix-pr-101.

  ## Examples

      iex> extract_pr_numbers("Review PR #123 and fix-pr-456")
      [123, 456]
  """
  @spec extract_pr_numbers(String.t()) :: list(pos_integer())
  def extract_pr_numbers(text) do
    case Regex.scan(@pr_regex, text) do
      [] ->
        []

      matches ->
        Enum.flat_map(matches, fn match_groups ->
          pr_num =
            match_groups
            |> Enum.drop(1)
            |> Enum.find(fn g -> g != nil and g != "" end)

          if pr_num, do: [String.to_integer(pr_num)], else: []
        end)
    end
  end

  @doc """
  Enrich a list of OpenCode sessions.
  """
  @spec enrich_opencode_sessions(list(map())) :: list(enriched_session())
  def enrich_opencode_sessions(sessions) do
    Enum.map(sessions, &enrich_opencode_session/1)
  end

  @doc """
  Enrich a list of agent sessions.
  """
  @spec enrich_agent_sessions(list(map())) :: list(enriched_session())
  def enrich_agent_sessions(sessions) do
    Enum.map(sessions, &enrich_agent_session/1)
  end
end
