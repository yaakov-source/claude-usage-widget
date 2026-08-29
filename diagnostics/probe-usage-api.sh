#!/bin/bash
# Probe for the Claude usage endpoint.
# Reads the Claude Code OAuth token from your login Keychain and tries a few
# candidate endpoints. Prints the HTTP status and body of each so we can lock
# in the right one.
#
# Nothing is sent anywhere except api.anthropic.com / api.claude.ai.
# The token itself is never printed.

set -uo pipefail

echo "=== Locating credentials ==="

RAW=""
SOURCE=""

if RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null); then
  SOURCE="Keychain: Claude Code-credentials"
elif RAW=$(security find-generic-password -s "Claude Code" -w 2>/dev/null); then
  SOURCE="Keychain: Claude Code"
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  RAW=$(cat "$HOME/.claude/.credentials.json")
  SOURCE="File: ~/.claude/.credentials.json"
else
  echo "No Claude Code credentials found."
  echo
  echo "Checked:"
  echo "  - Keychain item 'Claude Code-credentials'"
  echo "  - Keychain item 'Claude Code'"
  echo "  - ~/.claude/.credentials.json"
  echo
  echo "Keychain items whose name mentions Claude:"
  security dump-keychain 2>/dev/null | grep -i -A1 '"svce"' | grep -i claude | sort -u || echo "  (none found)"
  exit 1
fi

echo "Found via -> $SOURCE"

TOKEN=$(printf '%s' "$RAW" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for path in (("claudeAiOauth","accessToken"), ("accessToken",), ("access_token",)):
    cur = d
    ok = True
    for k in path:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            ok = False
            break
    if ok and isinstance(cur, str):
        print(cur)
        break
')

if [ -z "$TOKEN" ]; then
  echo "Credentials found but no accessToken inside. Top-level keys:"
  printf '%s' "$RAW" | python3 -c 'import json,sys; print(list(json.load(sys.stdin).keys()))' 2>/dev/null
  exit 1
fi

echo "Token present (${#TOKEN} chars, starts ${TOKEN:0:12}...)"

# Show non-secret metadata: expiry, plan
printf '%s' "$RAW" | python3 -c '
import json,sys,datetime
d = json.load(sys.stdin)
o = d.get("claudeAiOauth", d)
exp = o.get("expiresAt")
if exp:
    ts = exp/1000 if exp > 1e12 else exp
    dt = datetime.datetime.fromtimestamp(ts)
    state = "EXPIRED" if dt < datetime.datetime.now() else "valid"
    print(f"Token expires: {dt}  ({state})")
for k in ("subscriptionType","scopes"):
    if k in o: print(f"{k}: {o[k]}")
' 2>/dev/null

echo
echo "=== Trying endpoints ==="

try() {
  local url="$1"; shift
  echo
  echo "--- $url"
  local out
  out=$(curl -sS -w $'\n__HTTP__%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" \
    -H "User-Agent: ClaudeUsageBar/1.0" \
    "$@" "$url" 2>&1)
  local code="${out##*__HTTP__}"
  local body="${out%$'\n'__HTTP__*}"
  echo "HTTP $code"
  echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body" | head -c 1500
}

try "https://api.anthropic.com/api/oauth/usage"
try "https://api.anthropic.com/api/oauth/profile"
try "https://api.anthropic.com/api/oauth/claude_cli/usage"
try "https://api.claude.ai/api/oauth/usage"

echo
echo "=== Done ==="
echo "Paste the output above back into the chat (the token is not included)."
