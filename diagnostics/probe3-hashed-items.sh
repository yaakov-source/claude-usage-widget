#!/bin/bash
# Walks every "Claude Code-credentials*" keychain item looking for one that
# holds a real Claude account OAuth token, then probes the usage endpoints.
#
# macOS will prompt for keychain access per item. Click "Always Allow".
# The script stops at the FIRST item that has a token, so you probably won't
# see all of them. Token values are never printed.

set -uo pipefail

echo "Collecting Claude Code credential items..."
SERVICES=$(security dump-keychain 2>/dev/null \
  | grep '"svce"' \
  | sed 's/.*<blob>="\(.*\)"/\1/' \
  | grep '^Claude Code-credentials' \
  | sort -u)

COUNT=$(echo "$SERVICES" | grep -c . || true)
echo "Found $COUNT candidate item(s)."
echo "You'll get a keychain prompt per item — click 'Always Allow'."
echo

TOKEN=""
FOUND_SVC=""

while IFS= read -r svc; do
  [ -z "$svc" ] && continue
  RAW=$(security find-generic-password -s "$svc" -w 2>/dev/null) || continue
  [ -z "$RAW" ] && continue

  RESULT=$(printf '%s' "$RAW" | python3 -c '
import json,sys,datetime
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
o=d.get("claudeAiOauth")
if not isinstance(o,dict):
    print("KEYS:"+",".join(list(d.keys())[:6]))
    sys.exit(2)
t=o.get("accessToken")
if not isinstance(t,str) or not t:
    print("KEYS:"+",".join(list(d.keys())[:6]))
    sys.exit(2)
exp=o.get("expiresAt")
info=""
if exp:
    ts=exp/1000 if exp>1e12 else exp
    dt=datetime.datetime.fromtimestamp(ts)
    info=f" expires={dt} ({'EXPIRED' if dt<datetime.datetime.now() else 'valid'})"
print("TOKEN:"+t)
print("META: sub="+str(o.get("subscriptionType"))+info, file=sys.stderr)
' 2>/tmp/claudemeta.$$)
  STATUS=$?

  if [ $STATUS -eq 0 ] && [[ "$RESULT" == TOKEN:* ]]; then
    TOKEN="${RESULT#TOKEN:}"
    FOUND_SVC="$svc"
    echo "HIT  $svc"
    cat /tmp/claudemeta.$$ 2>/dev/null
    rm -f /tmp/claudemeta.$$
    break
  else
    echo "skip $svc  ${RESULT}"
  fi
  rm -f /tmp/claudemeta.$$
done <<< "$SERVICES"

if [ -z "$TOKEN" ]; then
  echo
  echo "No account token found in any keychain item."
  echo "Claude Code has probably never been signed in via the CLI on this Mac."
  exit 1
fi

echo
echo "Using item: $FOUND_SVC"
echo "Token length: ${#TOKEN}, prefix: ${TOKEN:0:12}..."
echo
echo "=== Probing endpoints ==="

ORG=$(python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.claude.json')))
print(d.get('oauthAccount',{}).get('organizationUuid',''))
" 2>/dev/null)
echo "Org UUID: ${ORG:-unknown}"

try() {
  local url="$1"
  echo
  echo "--- $url"
  local out code body
  out=$(curl -sS --max-time 20 -w $'\n__HTTP__%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" \
    -H "User-Agent: ClaudeUsageBar/1.0" \
    "$url" 2>&1)
  code="${out##*__HTTP__}"
  body="${out%$'\n'__HTTP__*}"
  echo "HTTP $code"
  echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body" | head -c 1200
}

try "https://api.anthropic.com/api/oauth/usage"
try "https://api.anthropic.com/api/oauth/profile"
try "https://api.anthropic.com/api/oauth/claude_cli/usage"
if [ -n "$ORG" ]; then
  try "https://api.anthropic.com/api/organizations/$ORG/usage"
fi

echo
echo "=== Done. Winning item was: $FOUND_SVC ==="
