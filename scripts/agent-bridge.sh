#!/bin/bash
# Bridge script that runs a coding agent and streams progress to JSONL
# Usage: agent-bridge.sh <agent> <workdir> <label> <task>
#   agent: "opencode" or "claude"
#   workdir: working directory
#   label: agent label for tracking
#   task: the task/prompt

AGENT="$1"
WORKDIR="$2"
LABEL="$3"
TASK="$4"
PROGRESS_FILE="/tmp/agent-progress.jsonl"
SESSIONS_FILE="/tmp/agent-sessions.json"

log_progress() {
    local action="$1"
    local target="$2"
    local status="${3:-running}"
    local ts=$(date +%s%3N)
    echo "{\"ts\": $ts, \"agent\": \"$LABEL\", \"action\": \"$action\", \"target\": \"$target\", \"status\": \"$status\"}" >> "$PROGRESS_FILE"
}

update_session() {
    local status="$1"
    local current_action="$2"
    echo "{\"sessions\":[{\"id\":\"$LABEL\",\"label\":\"$LABEL\",\"status\":\"$status\",\"task\":\"${TASK:0:100}\",\"agent_type\":\"$AGENT\",\"current_action\":\"$current_action\"}]}" > "$SESSIONS_FILE"
}

# Register session
update_session "running" "Starting..."
log_progress "Start" "$AGENT" "running"

cd "$WORKDIR" || exit 1

# Build command based on agent type
if [ "$AGENT" = "opencode" ]; then
    CMD="opencode run \"$TASK\""
elif [ "$AGENT" = "claude" ]; then
    CMD="claude \"$TASK\""
else
    echo "Unknown agent: $AGENT"
    exit 1
fi

# Run the agent and parse output
# We use script to capture PTY output, then parse it
TEMP_LOG=$(mktemp)

log_progress "Think" "Starting $AGENT" "running"

# Run with unbuffered output, parse in real-time
script -q -c "$CMD" "$TEMP_LOG" 2>&1 | while IFS= read -r line; do
    # Strip ANSI codes for parsing
    clean=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r')
    
    # Parse common patterns from coding agents
    if [[ "$clean" =~ Read\(([^\)]+)\) ]] || [[ "$clean" =~ "⎿  Read" ]]; then
        target="${BASH_REMATCH[1]:-file}"
        log_progress "Read" "$target" "running"
        update_session "running" "Reading $target"
    elif [[ "$clean" =~ Edit\(([^\)]+)\) ]] || [[ "$clean" =~ Update\(([^\)]+)\) ]]; then
        target="${BASH_REMATCH[1]:-file}"
        log_progress "Edit" "$target" "running"
        update_session "running" "Editing $target"
    elif [[ "$clean" =~ Write\(([^\)]+)\) ]]; then
        target="${BASH_REMATCH[1]:-file}"
        log_progress "Write" "$target" "running"
        update_session "running" "Writing $target"
    elif [[ "$clean" =~ Bash\(([^\)]+)\) ]] || [[ "$clean" =~ "Running:" ]]; then
        target="${BASH_REMATCH[1]:-command}"
        log_progress "Bash" "$target" "running"
        update_session "running" "Running $target"
    elif [[ "$clean" =~ Search\(([^\)]+)\) ]]; then
        target="${BASH_REMATCH[1]:-pattern}"
        log_progress "Search" "$target" "running"
        update_session "running" "Searching $target"
    elif [[ "$clean" =~ "Thinking" ]] || [[ "$clean" =~ "Puzzling" ]] || [[ "$clean" =~ "Imagining" ]]; then
        log_progress "Think" "reasoning" "running"
        update_session "running" "Thinking..."
    elif [[ "$clean" =~ "error" ]] || [[ "$clean" =~ "Error" ]] || [[ "$clean" =~ "failed" ]]; then
        log_progress "Error" "$clean" "error"
    fi
done

# Check exit status
EXIT_CODE=${PIPESTATUS[0]}
if [ $EXIT_CODE -eq 0 ]; then
    log_progress "Done" "Completed successfully" "done"
    update_session "done" "Completed"
else
    log_progress "Error" "Exit code $EXIT_CODE" "error"
    update_session "error" "Failed with code $EXIT_CODE"
fi

rm -f "$TEMP_LOG"
