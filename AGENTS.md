# AGENTS.md - Systematic Dashboard

This is a Phoenix/Elixir dashboard for monitoring and controlling AI agents (Claude, OpenCode, Gemini).

## Project Structure

```
lib/
├── dashboard_phoenix/           # Core business logic
│   ├── application.ex          # Supervision tree
│   ├── linear_monitor.ex       # Linear API integration
│   └── branch_monitor.ex       # Git branch tracking
├── dashboard_phoenix_web/
│   ├── live/
│   │   ├── home_live.ex        # Main dashboard LiveView (⚠️ 2400+ lines, being refactored)
│   │   └── components/         # LiveComponents (LinearComponent, etc.)
│   └── components/             # Function components
assets/
├── js/
│   ├── app.js                  # Hooks and JS logic
│   └── relationship_graph.js   # D3 force-directed graph
test/                           # ExUnit tests
```

## Development Commands

```bash
# Start dev server
mix phx.server

# Run tests
mix test

# Run specific test file
mix test test/dashboard_phoenix_web/live/home_live_test.exs

# Format code
mix format
```

## Git Workflow

### Always Use Worktrees for Feature Work

```bash
# Create worktree for task
cd ~/code/systematic
git fetch origin
git worktree add ../systematic-<task-name> -b <task-name> main
cd ../systematic-<task-name>

# Do work, run tests, commit...

# When done, merge back to main
cd ~/code/systematic
git merge <task-name>
git worktree remove ../systematic-<task-name>
```

### Commit Messages

Use conventional commits:
- `feat:` New feature
- `fix:` Bug fix
- `perf:` Performance improvement
- `refactor:` Code refactoring
- `test:` Adding tests
- `docs:` Documentation

Example: `feat: Add Gemini agents to relationship diagram`

## Issue Tracking (Chainlink)

This project uses Chainlink for local issue tracking.

```bash
# View open issues
chainlink list

# Start working on an issue
chainlink session start
chainlink session work <id>

# Add progress notes
chainlink comment <id> "Implemented X, working on Y"

# Close when done
chainlink close <id>

# End session with handoff
chainlink session end --notes "Completed X, next steps: Y"
```

## Code Patterns

### LiveView Events

```elixir
# Handle UI events
def handle_event("button_clicked", %{"id" => id}, socket) do
  # Do work
  {:noreply, assign(socket, :result, result)}
end

# Handle async messages
def handle_info({:data_loaded, data}, socket) do
  {:noreply, assign(socket, :data, data)}
end
```

### Async Loading Pattern

Use Task.Supervisor for async work (don't use bare Task.start):

```elixir
Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
  try do
    data = fetch_data()
    send(self, {:data_loaded, data})
  rescue
    e ->
      Logger.error("Failed to load data: #{inspect(e)}")
      send(self, {:data_loaded, {:error, e}})
  end
end)
```

### Pre-calculate Derived Data

Don't compute in templates:

```elixir
# ❌ Bad - computed on every render
<%= Enum.count(@tickets, & &1.status == "open") %>

# ✅ Good - pre-calculated in handle_info
linear_counts = Enum.frequencies_by(tickets, & &1.status)
socket = assign(socket, :linear_counts, linear_counts)

# Then in template:
<%= Map.get(@linear_counts, "open", 0) %>
```

## Testing

### Run Tests Before Committing

```bash
mix test
```

Some tests may have pre-existing failures unrelated to your changes — note them but don't let them block your work.

### Test Patterns

```elixir
defmodule DashboardPhoenixWeb.HomeLiveTest do
  use DashboardPhoenixWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#dashboard")
  end
end
```

## External Integrations

### Linear API
- Used for ticket management
- Credentials in environment
- See `LinearMonitor` for API calls

### GitHub
- Used for PR tracking, branch info
- Uses `gh` CLI when available
- See `BranchMonitor` for implementation

### OpenClaw / OpenCode
- AI agent communication
- **OpenCode ACP:** port 9101 (Agent Client Protocol - default for dashboard integration)
- **OpenClaw Control UI:** port 18789

#### OpenCode ACP Server

The ACP (Agent Client Protocol) server provides REST endpoints for querying session data. Start it with:

```bash
# Start ACP server on specific port (default port is random if not specified)
opencode acp --port 9101 --hostname 0.0.0.0 --cwd /path/to/project

# Options:
#   --port      Port to listen on (default: 0 = random)
#   --hostname  Hostname to bind (default: 127.0.0.1, use 0.0.0.0 for network access)
#   --mdns      Enable mDNS service discovery
#   --cwd       Working directory for the session
#   --print-logs Print logs to stderr for debugging
```

#### ACP REST Endpoints

```bash
# List all sessions
curl http://localhost:9101/sessions

# Get specific session details
curl http://localhost:9101/sessions/<session-id>

# Get session messages/conversation
curl http://localhost:9101/sessions/<session-id>/messages
```

Response includes session metadata (model, start time, token usage, etc.) useful for dashboard monitoring.

#### Configuration

OpenCode config is stored in `~/.config/opencode/opencode.json`. Key settings:
- `model`: Default model to use (e.g., "google/gemini-3-flash-preview")
- `mcp`: Model Context Protocol server configurations
- `permission.lsp`: LSP integration permissions

## Current Refactoring (Milestone: Dashboard Refactor)

The main `home_live.ex` is being refactored into smaller LiveComponents:
- LinearComponent ✓ (extracted)
- PRComponent (planned)
- LiveFeedComponent (planned)
- SystemProcessesComponent (planned)

Check `chainlink list` for current ticket status.

## Common Issues

### Port Already in Use
If tests fail with "port 4002 in use":
```bash
lsof -i :4002  # Find process
kill <pid>     # Kill it
```

### Worktree Conflicts
If you see merge conflicts, you may have edited the same file from multiple worktrees. Resolve manually:
```bash
git status
# Edit conflicted files
git add .
git commit
```

## Agent Behavior

When working on this codebase:
1. **Use worktrees** — always work in an isolated worktree, not main
2. **Run tests** — `mix test` before committing
3. **Commit often** — small, focused commits with good messages
4. **Update chainlink** — comment on tickets as you progress, close when done
5. **Don't over-engineer** — keep changes minimal and focused on the ticket
