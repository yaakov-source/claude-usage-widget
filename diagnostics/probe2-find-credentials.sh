#!/bin/bash
# Read-only discovery: where does a Claude account token live on this Mac?
# Prints key NAMES and metadata only — never a token value.

set -uo pipefail

echo "############ 1. Keychain items mentioning Claude/Anthropic ############"
security dump-keychain 2>/dev/null \
  | grep -E '0x00000007|"acct"|"svce"' \
  | grep -i -E 'claude|anthropic' \
  | sort -u \
  | head -60
echo "(end)"

echo
echo "############ 2. Accounts under 'Claude Code-credentials' ############"
ACCTS=$(security dump-keychain 2>/dev/null \
  | grep -B8 'Claude Code-credentials' \
  | grep '"acct"' \
  | sed 's/.*<blob>="\(.*\)"/\1/' \
  | sort -u)
if [ -z "$ACCTS" ]; then
  echo "(could not enumerate accounts)"
else
  echo "$ACCTS"
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    echo
    echo "--- account: $a"
    security find-generic-password -s "Claude Code-credentials" -a "$a" -w 2>/dev/null \
      | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("  (not JSON)"); raise SystemExit
def walk(o,p=""):
    if isinstance(o,dict):
        for k,v in o.items():
            np=f"{p}.{k}" if p else k
            if isinstance(v,(dict,list)):
                walk(v,np)
            else:
                kind=type(v).__name__
                low=k.lower()
                if "token" in low or "secret" in low or "key" in low:
                    print(f"  {np}: <{kind}, {len(str(v))} chars>")
                else:
                    print(f"  {np}: {v!r}"[:160])
walk(d)
' 2>/dev/null || echo "  (unreadable)"
  done <<< "$ACCTS"
fi

echo
echo "############ 3. ~/.claude ############"
ls -la "$HOME/.claude" 2>/dev/null | head -30 || echo "(no ~/.claude)"
for f in "$HOME/.claude/.credentials.json" "$HOME/.claude.json"; do
  if [ -f "$f" ]; then
    echo "--- $f (top-level keys)"
    python3 -c "
import json
d=json.load(open('$f'))
print(list(d.keys())[:40])
for k in ('oauthAccount','userID','organizationUUID','account'):
    if k in d: print(k, '=', d[k])
" 2>/dev/null || echo "(unparseable)"
  fi
done

echo
echo "############ 4. Claude Code CLI ############"
command -v claude && claude --version 2>/dev/null || echo "(claude CLI not on PATH)"
echo "Env:"
[ -n "${ANTHROPIC_API_KEY:-}" ] && echo "  ANTHROPIC_API_KEY is set" || echo "  ANTHROPIC_API_KEY not set"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "  CLAUDE_CODE_OAUTH_TOKEN is set" || echo "  CLAUDE_CODE_OAUTH_TOKEN not set"

echo
echo "############ 5. Desktop app storage ############"
APPDIR="$HOME/Library/Application Support/Claude"
ls -la "$APPDIR" 2>/dev/null | head -30 || echo "(none)"
echo "--- cookie/session-ish files:"
find "$APPDIR" -maxdepth 3 \( -iname "*Cookies*" -o -iname "*Local Storage*" -o -iname "*session*" \) 2>/dev/null | head -20

echo
echo "############ Done ############"
