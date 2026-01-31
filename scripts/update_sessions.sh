#!/bin/bash
# Updates /tmp/openclaw-sessions.json with current coding agent processes

OUTPUT_FILE="/tmp/openclaw-sessions.json"

# Get coding agent processes and format as JSON
ps aux --sort=-start_time | grep -E "claude|opencode|codex" | grep -v grep | head -10 | awk '
BEGIN { 
    print "{\"sessions\":["
    first=1 
}
{
    if (!first) print ","
    first=0
    
    pid=$2
    cpu=$3
    mem=$4
    stat=$8
    start=$9
    time=$10
    
    # Get command (everything from $11 onwards)
    cmd=""
    for(i=11;i<=NF;i++) cmd=cmd" "$i
    gsub(/^[ \t]+/, "", cmd)
    gsub(/"/, "\\\"", cmd)
    
    # Determine status
    status="running"
    if (stat ~ /T/) status="stopped"
    if (stat ~ /Z/) status="zombie"
    if (cpu+0 < 1) status="idle"
    
    # Determine agent type
    agent_type="shell"
    if (tolower(cmd) ~ /claude/) agent_type="claude"
    else if (tolower(cmd) ~ /opencode/) agent_type="opencode"
    else if (tolower(cmd) ~ /codex/) agent_type="codex"
    
    # Extract task from command (first quoted string)
    task=cmd
    if (match(cmd, /"[^"]+"/)) {
        task=substr(cmd, RSTART+1, RLENGTH-2)
    } else if (match(cmd, /\047[^\047]+\047/)) {
        task=substr(cmd, RSTART+1, RLENGTH-2)
    }
    if (length(task) > 80) task=substr(task, 1, 77)"..."
    
    printf "  {\"id\":\"%s\",\"pid\":\"%s\",\"status\":\"%s\",\"agent_type\":\"%s\",\"cpu\":\"%s%%\",\"memory\":\"%s%%\",\"start_time\":\"%s\",\"runtime\":\"%s\",\"command\":\"%s\"}", pid, pid, status, agent_type, cpu, mem, start, time, task
}
END { 
    print ""
    print "]}"
}' > "$OUTPUT_FILE.tmp.$$" && mv "$OUTPUT_FILE.tmp.$$" "$OUTPUT_FILE"
