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

- **Menu bar:** a battery outline filled to whichever limit is closest to its
  cap, with the percentage beside it. Blue under 75%, orange at 75%, red at 90%
  — or whatever `severity` the API reports, if that's more severe. Hover for all
  limits at once.
- **Click:** popover with one row per limit — title, reset time, percentage,
  progress bar — plus Refresh and Quit.
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
| Display | Last good numbers stay on screen with a footnote: *"Rate limited. Showing values from 9:42 PM — retrying in 4 minutes."* |

If you trip it anyway — usually by running the diagnostic probes repeatedly —
the only fix is to stop calling and wait. No client-side change makes a
rate-limited server answer sooner.

### Token expiry

Access tokens last roughly 8 hours. **The widget does not refresh them** — it
detects 401/403, shows `!` in the menu bar, and tells you to run `claude` once,
which refreshes the token in place.

This is deliberate. Implementing the refresh grant means handling a rotating
refresh token, and getting it wrong risks invalidating your CLI login. If the
manual step becomes annoying, the honest fix is to test the refresh endpoint
carefully first — not to guess at it.

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
  bar the icon simply won't render. [Ice](https://github.com/jordanbaird/Ice)
  solves this.
- **Undocumented endpoint.** See above.
- **No token refresh.** See above.
- **Unsigned.** Ad-hoc signed at build time. Fine for a locally built app; it
  would need a Developer ID and notarization to distribute to others.
