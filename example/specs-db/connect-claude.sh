#!/usr/bin/env bash
# Verify the RAGFlow MCP endpoint and register it with Claude Code.
#
# Usage:
#   export RAGFLOW_API_KEY=ragflow-xxxxxxxx
#   example/specs-db/connect-claude.sh            # registers for your user (all projects)
#   SCOPE=project example/specs-db/connect-claude.sh   # writes .mcp.json in the current directory
#
# Project scope stores "${RAGFLOW_API_KEY}" literally in .mcp.json; Claude Code
# expands it from your environment at startup, so the key is never committed.
set -euo pipefail

: "${RAGFLOW_API_KEY:?set RAGFLOW_API_KEY}"
base="${RAGFLOW_URL:-http://localhost:9380}"
endpoint="${base}/api/v1/mcp"
name="${MCP_NAME:-specs}"
scope="${SCOPE:-user}"

echo "Checking ${endpoint} …"
resp="$(curl -sS "$endpoint" \
  -H "Authorization: Bearer ${RAGFLOW_API_KEY}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')"
tools="$(sed -n -e 's/^data: //' -e '/^{/p' <<<"$resp" | jq -r '.result.tools[].name' 2>/dev/null || true)"
if [[ -z "$tools" ]]; then
  echo "MCP endpoint did not return tools. Response:" >&2
  echo "$resp" >&2
  exit 1
fi
echo "Tools available: $(tr '\n' ' ' <<<"$tools")"

command -v claude >/dev/null || {
  echo "Claude Code CLI not found. Add this to your MCP config manually:"
  jq -n --arg url "$endpoint" --arg n "$name" \
    '{mcpServers: {($n): {type:"http", url:$url, headers:{Authorization:"Bearer ${RAGFLOW_API_KEY}"}}}}'
  exit 0
}

if [[ "$scope" == "project" ]]; then
  # Single quotes keep ${RAGFLOW_API_KEY} unexpanded in .mcp.json.
  claude mcp add --scope project --transport http "$name" "$endpoint" \
    --header 'Authorization: Bearer ${RAGFLOW_API_KEY}'
else
  claude mcp add --scope "$scope" --transport http "$name" "$endpoint" \
    --header "Authorization: Bearer ${RAGFLOW_API_KEY}"
fi
echo "Registered MCP server '${name}'. Run 'claude mcp list' to confirm, then ask Claude about your specs."
