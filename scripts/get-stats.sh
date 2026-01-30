#!/bin/bash
# Get usage stats from coding agents

echo "=== OpenCode (Gemini) Stats ==="
opencode stats 2>/dev/null | grep -v "INFO.*refreshing"

echo ""
echo "=== Claude Code Stats ==="
if [ -f ~/.claude/stats-cache.json ]; then
    jq -r '
        "Total Sessions: \(.totalSessions)",
        "Total Messages: \(.totalMessages)",
        "",
        "Model Usage:",
        (.modelUsage | to_entries[] | "  \(.key):",
            "    Input: \(.value.inputTokens | . / 1000 | floor)K",
            "    Output: \(.value.outputTokens | . / 1000 | floor)K", 
            "    Cache Read: \(.value.cacheReadInputTokens | . / 1000000 | . * 10 | floor / 10)M",
            "    Cache Write: \(.value.cacheCreationInputTokens | . / 1000000 | . * 10 | floor / 10)M"
        )
    ' ~/.claude/stats-cache.json
else
    echo "No stats cache found"
fi
