# Claude Usage Widget

A macOS menu bar gauge for Claude plan usage. Battery-style meter in the menu
bar; click for a popover with a progress bar per limit — the same three rows the
Claude desktop app shows under **Plan usage limits**.

```
▓▓▓▓▓░░░░ 55%          ← menu bar

Plan usage limits · Max (20x)
5-hour limit           Resets in 1 hr 10 min    0%
▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
Weekly · all models    Resets Mon 3:00 AM      55%
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
Weekly · Fable         Resets Mon 3:00 AM      10%
▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

**New here? Read [START-HERE.md](START-HERE.md) instead** — it's the same setup
without the explanations.

---

## What it does

- **Menu bar:** a battery outline tracking the **5-hour limit**, showing how
  much is **left** — 100% on an untouched plan, draining as you work. That is
  the one limit that actually stops you working, and a battery reading 0% when
  nothing has been used looks broken. Purple under 75% used, orange at 75%, red
  at 90% — or whatever `severity` the API reports, if that's more severe.
- **Hover:** every limit at once, as **usage** percentages.
- **Click:** popover with one row per limit — title, reset time, usage
  percentage, progress bar — plus Refresh and Quit. Refresh shows a spinner and
  reads "Refreshing…" while a fetch is in flight.

Only the menu bar inverts to remaining. The popover and tooltip stay phrased as
usage, matching the desktop app's own panel, so the two never disagree about
what a number means — they just answer different questions.
- Refreshes every 15 minutes. Opening the popover reuses data less than 60
  seconds old rather than making a request.
- No dock icon, no window, no background daemon. One process, ~2 MB of RAM.

## Requirements

| | |
|---|---|
| macOS | 12 or later |
| Xcode Command Line Tools | `xcode-select --install` |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code`, then `claude` and sign in once |
| Claude plan | Any plan with usage limits (Pro, Max 5x, Max 20x) |

## Install

```bash
./build.sh
```

Compiles `main.m`, assembles `ClaudeUsageBar.app`, ad-hoc signs it, copies it to
`/Applications`, and launches it. Use `./build.sh --no-install` to build into
`./build` without touching `/Applications`.

Start at login:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/ClaudeUsageBar.app", hidden:true}'
```

Uninstall:

```bash
pkill -f ClaudeUsageBar
rm -rf /Applications/ClaudeUsageBar.app ~/Library/Application\ Support/ClaudeUsageBar
osascript -e 'tell application "System Events" to delete login item "ClaudeUsageBar"'
```

---

## How it works

### Where the numbers come from

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
```

This is the endpoint Claude Code's own `/usage` command uses. It is **not a
documented public API** — it's an internal endpoint discovered by probing, and
Anthropic can change or remove it without notice. If a future update breaks the
widget, that's the likely reason; see [Diagnostics](#diagnostics) for how to
re-discover the shape.

The response carries both a legacy top-level form and a clean `limits` array.
The widget reads the array:

```json
{
  "limits": [
    { "kind": "session",       "percent": 0,  "severity": "normal",
      "resets_at": "2026-08-29T09:20:00.392082+00:00", "is_active": false },
    { "kind": "weekly_all",    "percent": 55, "severity": "normal",
      "resets_at": "2026-08-31T09:00:00.392113+00:00", "is_active": true },
    { "kind": "weekly_scoped", "percent": 10, "severity": "normal",
      "resets_at": "2026-08-31T09:00:00.392473+00:00",
      "scope": { "model": { "display_name": "Fable" } } }
  ]
}
```

Mapping to row titles:

| `kind` | Title |
|---|---|
| `session` | 5-hour limit |
| `weekly_all` | Weekly · all models |
| `weekly_scoped` | Weekly · *(scope.model.display_name)* |
| anything else | the `kind`, prettified |

If `limits` is ever absent, it falls back to the top-level `five_hour` /
`seven_day` / `seven_day_opus` objects and their `utilization` fields.

The plan name in the header comes from a separate call to
`/api/oauth/profile`, reading `organization.rate_limit_tier`
(`default_claude_max_20x` → "Max (20x)"). Fetched once per launch.

### Where the token comes from

macOS login Keychain, service **`Claude Code-credentials`**, key
`claudeAiOauth.accessToken`. The widget shells out to `/usr/bin/security` to
read it, which is why macOS asks permission the first time.

Two things worth knowing about that Keychain item:

1. **Claude Code writes it; the Claude desktop app does not.** The desktop app
   keeps its session as an encrypted cookie in its own Electron store. That's
   why you must sign in to the CLI once even if the desktop app is already
   logged in.
2. **There will be many similarly-named items.** Cowork sessions create
   `Claude Code-credentials-<hash>` items that hold *MCP server* tokens under an
   `mcpOAuth` key. Only the unhashed `Claude Code-credentials` item gets a
   `claudeAiOauth` key. The widget checks for that key rather than trusting the
   item name.

The reader also hex-decodes the blob if `security` returns hex instead of text,
which it does when the stored value isn't printable UTF-8.

### Network failures

Laptops sleep, wifi hands over, VPNs flap. The shared `NSURLSession` fails
instantly when the interface is down, which produced a steady drip of
`The request timed out` and `The Internet connection appears to be offline` —
eleven in one night — each one surfacing a raw error string in the popover.

The widget uses its own session with `waitsForConnectivity`, so URLSession holds
the request until there is a route rather than failing at one. Transient errors
(timeout, offline, connection lost, DNS, TLS handshake) keep the last numbers on
screen under a plain *"Offline — showing values from 2 hr ago"*, and are logged
at most once an hour so they don't bury the lines worth reading.

### Rate limiting

The endpoint returns **429** if polled casually, and it does not take much to
trip it. The widget is built to stay well under that:

| Guard | Behaviour |
|---|---|
| Poll interval | 15 minutes |
| Freshness window | Opening the popover reuses data under 60s old, no request |
| Plan name | Fetched once, then persisted to `NSUserDefaults` — not re-fetched per launch |
| On 429 or 5xx | Exponential backoff from 2 minutes, doubling to a 30-minute cap; honours `Retry-After` when present |
| While backing off | **Forced refresh is ignored.** Retrying into a 429 is what keeps it tripped |
| Concurrent requests | One chain at a time. A click landing on an in-flight fetch is dropped, not duplicated |
| Display | Last good numbers stay on screen with a footnote: *"Rate limited — these are the values from 9:42 PM. The server asked us to wait 4 more minutes."* |

The footnote distinguishes a cooldown the **server** asked for (`Retry-After`) from
one the widget imposed on itself. They are different problems and only the note
makes the difference visible.

The concurrent-request guard matters more than it looks. `_lastSuccess` is only
written once a response arrives, so before the guard existed a click landing
during the launch fetch sailed straight through the freshness check and issued a
second call. Two Refresh clicks did the same. On an endpoint that 429s if polled
casually, that was the app tripping its own limiter.

If you trip it anyway — usually by running the diagnostic probes repeatedly —
the only fix is to stop calling and wait. No client-side change makes a
rate-limited server answer sooner.

### Token expiry and renewal

Access tokens last roughly 8 hours. **The widget renews them itself**, the same
way Claude Code does, using the `refreshToken` stored beside the access token in
the same keychain item.

An earlier version of this README ruled that out as too risky. It was wrong
about the risk and right about the standard: touching a credential two apps
share is only safe if you do *exactly* what the other app does. So the flow is
lifted verbatim from the installed Claude Code binary rather than guessed at:

| Step | What happens |
|---|---|
| Detect | `expiresAt` is read from the blob before every request. An expired token is **never sent to the usage endpoint** — that's a 401, and enough 401s are a flat one-hour 429 |
| Renew | `POST https://platform.claude.com/v1/oauth/token` with `{grant_type: refresh_token, refresh_token, client_id, scope}` — Claude Code's own endpoint, client id, and body |
| Merge | The response is folded into the stored blob the way Claude Code folds it: new `accessToken` and `expiresAt`, the refresh token replaced only if the server rotated it, and **every other key carried through untouched** — including the `mcpOAuth` tokens Claude Code keeps beside it |
| Back up | Before writing, the item as it stood is copied to a second keychain entry, `ClaudeUsageBar-credentials-backup` |
| Write | `security -i` with `add-generic-password -U -a <acct> -s "Claude Code-credentials" -X <hex>` — the same tool, same item, same hex encoding Claude Code uses, so the item is updated in place and its existing access control applies |
| Use | The renewed token fetches usage immediately. A failed write is logged, not fatal: the token still works for this session and Claude Code renews its own copy next time it runs |

A renewal that fails outright (`invalid_grant` — the refresh token itself is
dead, usually because you signed out) is not retried on the timer. The popover
says so and offers **Open Terminal and run claude**; signing in again fixes it,
and the widget notices the new credential on its own.

**Undo.** If a write ever goes wrong, the pre-write blob is one command away:

```
security add-generic-password -U -a "$USER" -s "Claude Code-credentials" \
  -w "$(security find-generic-password -s ClaudeUsageBar-credentials-backup -w)"
```

(`-a` must match the item's account attribute, which is normally your username.)

The backup is only as good as the write that made it, so every write is also
read straight back and compared byte-for-byte; a mismatch is reported as a
failure, never as success. If both the item and the backup are ever unreadable,
signing in again with `claude` rewrites the item cleanly — that is the true
fallback, and it takes about thirty seconds.

Why it matters: the endpoint rate limits **failed authentication**, and every
429 comes back with a flat `Retry-After: 3600` regardless of time already served,
so retries reset the hour rather than shorten it. Renewing the token before it
is ever sent makes the whole sequence impossible:

```
expired token -> 401 -> 401 -> 401 -> 401 -> 429 for an hour
```

If it ever happens anyway, `failures.log` records the status, `Retry-After` and
body of every failure — including renewal attempts, tagged `renew` — read it
before theorising.

### Why Objective-C

Swift was the original choice and the Swift source is preserved at
`diagnostics/main.swift.abandoned`. It could not be compiled on a stock Command
Line Tools install — see [FIXES.md](FIXES.md) for the full story. Objective-C
compiles against the SDK's C headers and is immune to that class of failure, so
this builds anywhere `clang` exists.

---

## Diagnostics

If the endpoint changes or the widget stops returning data, `diagnostics/`
holds the tools used to find all of this in the first place:

| File | Purpose |
|---|---|
| `probe4.py` | **Start here.** Finds the token across all Keychain items (handles hex blobs and multiple accounts) and dumps the response of every candidate endpoint. |
| `probe-usage-api.sh` | First-pass probe. Simpler, assumes the token is in the obvious place. |
| `probe2-find-credentials.sh` | Read-only survey: Keychain items, `~/.claude`, CLI presence, desktop app storage. |
| `probe3-hashed-items.sh` | Walks every `Claude Code-credentials*` item looking for an account token. |
| `main.swift.abandoned` | The Swift implementation, kept for reference. |

None of them print token values — only lengths, prefixes, and metadata.

The last successful raw response is always cached at:

```
~/Library/Application Support/ClaudeUsageBar/last-response.json
```

That file is the fastest way to see what the API actually returned.

Every failed request appends a line to:

```
~/Library/Application Support/ClaudeUsageBar/failures.log
```

with the timestamp, HTTP status, the server's `Retry-After`, and the first 200
characters of the body. If the widget is stuck showing stale numbers, read this
before theorising — it is the difference between knowing and guessing.

---

## Portability

The repo is self-contained: two files (`main.m`, `build.sh`) are all that's
needed. On a new Mac, clone it, satisfy the three requirements above, run
`./build.sh`.

Nothing is hard-coded to one account — no UUIDs, no tokens, no paths outside
`~`. It reads whatever account the local Claude Code CLI is signed in as.

## Known limitations

- **Menu bar overflow.** New status items are inserted at the left of the status
  area, which on notched MacBook Pros is where the notch is. On a crowded menu
  bar the icon simply won't render — macOS places it and hides it, with no error.

  The app logs its own placement at launch so this is checkable rather than
  guessable:

  ```
  log show --predicate 'senderImagePath CONTAINS "ClaudeUsageBar"' --last 5m | grep "status item"
  ```

  ```
  status item x=890-937 (width 47), screen 1728, notch spans 771-956 — has a slot
  ```

  A slot inside the notch range is the failure. Fixes, cheapest first: Cmd-drag
  the icon out from under the notch (the position now persists, via
  `autosaveName`), quit a menu bar app or two, or install
  [Ice](https://github.com/jordanbaird/Ice).

  The widget defaults to its narrowest style, ~26pt of text with no icon, to
  make itself easy to fit. `defaults write com.haicreative.claudeusagebar
  MenuBarStyle gauge` restores the battery, `icon` gives the battery alone.
- **Undocumented endpoint.** See above.
- **Shares a credential with Claude Code.** Renewal writes to the same keychain
  item Claude Code reads. It mirrors Claude Code's own write exactly and backs
  the item up first, but it is still two programs holding one secret — see
  *Token expiry and renewal* for the undo.
- **Unsigned.** Ad-hoc signed at build time. Fine for a locally built app; it
  would need a Developer ID and notarization to distribute to others.
