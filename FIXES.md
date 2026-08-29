# Fixes, Errors, and Why

An honest record of everything that went wrong building this, in order. Written
partly so the next person (or the next machine) doesn't repeat it, and partly
because several of these were my mistakes and the record should say so.

Legend: **[me]** = my error. **[env]** = the environment, not a mistake.
**[unknown]** = genuinely undiscoverable up front.

---

## 1. Wrong assumption: the desktop app leaves a token behind

**[me]**

**Symptom.** The first probe found the Keychain item
`Claude Code-credentials` and reported: *"Credentials found but no accessToken
inside. Top-level keys: `['mcpOAuth']`."*

**Cause.** I assumed that because the Claude desktop app was installed and
logged in, an account OAuth token would be sitting in the Keychain. It wasn't.
The desktop app stores its session as an **encrypted cookie** in its Electron
store (`~/Library/Application Support/Claude/Cookies`, keyed by the
`Claude Safe Storage` Keychain entry). Only the **Claude Code CLI** writes a
`claudeAiOauth` key, and the CLI had never been signed in on this machine.

**Fix.** Installed the CLI (`npm install -g @anthropic-ai/claude-code`) and
signed in once. That added `claudeAiOauth` to the existing
`Claude Code-credentials` item.

**Where I went wrong.** I picked the auth strategy *before* verifying a token
existed. The right order was: confirm the credential exists, then design around
it. I also let a script print *"Claude Code has probably never been signed in
via the CLI on this Mac"* in a way that read as "you've never had Claude here,"
which wasn't true and wasn't a fair thing to put on screen — the desktop app had
been installed since March.

---

## 2. The 24 decoy Keychain items

**[env]**

**Symptom.** `security dump-keychain` showed 24 items named
`Claude Code-credentials-<8 hex chars>`, all of which held only `mcpOAuth`.

**Cause.** Cowork sessions create a per-session Keychain item to hold **MCP
server** OAuth tokens. These look almost identical to the real credential item
but never contain an account token.

**Fix.** Match on the *contents* (`claudeAiOauth.accessToken`), never on the
item name. The final app checks the unhashed `Claude Code-credentials` item and
validates the key exists before using it.

**Worth knowing.** The account token lives in the **unhashed** item. The hashed
ones are noise.

---

## 3. Keychain account enumeration silently failed

**[me]**

**Symptom.** `probe2-find-credentials.sh` printed
*"(could not enumerate accounts)"*.

**Cause.** I parsed `security dump-keychain` with
`grep -B8 'Claude Code-credentials' | grep '"acct"'`, assuming `acct` always
appears within 8 lines *before* `svce`. It doesn't — attribute order varies per
item.

**Fix.** `probe4.py` splits the dump into per-item blocks on `^keychain: ` and
regex-matches `svce` and `acct` within each block. Correct regardless of order.

**Lesson.** Line-offset grep against structured output is a guess dressed up as
a parser. Should have gone to a real parser one step sooner.

---

## 4. The token was there but came back unparseable

**[me]**

**Symptom.** After logging in, `probe3` printed a *blank* result for
`Claude Code-credentials` instead of `KEYS:mcpOAuth` — meaning my inline Python
had thrown while parsing.

**Cause.** Two compounding issues: `security find-generic-password -w` emits
**hex** rather than text when the stored blob isn't printable UTF-8, and I
wasn't specifying `-a <account>` so multiple items under one service name were
ambiguous.

**Fix.** `probe4.py` (and the shipped app, in `ReadOAuthToken`) detect an
all-hex payload and decode it before parsing JSON, and address items by
`(service, account)` pair.

---

## 5. Shell commands with `#` comments broke in zsh

**[me]**

**Symptom.**
```
zsh: parse error near `)'
```
after pasting a command block that contained `# 1. Install (needs Node...)`.

**Cause.** zsh does **not** treat `#` as a comment in interactive shells —
`INTERACTIVE_COMMENTS` is off by default. The comment text was parsed as code,
and the parentheses inside it blew up.

**Fix.** Never put `#` comments in commands meant to be pasted into an
interactive shell. Explain in prose above the block instead.

**Lesson.** This one is pure carelessness on my part and cost a round trip.

---

## 6. Swift wouldn't compile: SDK / compiler version mismatch

**[env]**, but **[me]** for how I handled it

**Symptom.**
```
error: failed to build module 'AppKit'; this SDK is not supported by the
compiler (the SDK is built with 'Apple Swift version 6.0.3 ...
swiftlang-6.0.3.1.5', while this compiler is '... swiftlang-6.0.3.1.10')
```

**Cause.** The Command Line Tools install shipped a Swift compiler
(`...1.10`) newer than the `.swiftinterface` files baked into its own SDK
(`...1.5`). Importing AppKit from Swift forces the compiler to rebuild those
interfaces, and the rebuild enforces an exact version match. No Xcode was
installed to provide a matching toolchain.

**Two wrong fixes I prescribed before the right one:**

**Wrong fix #1 — reinstall the Command Line Tools.** I told you to
`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`.
This could never have worked: both the compiler and the mismatched SDK come
from *the same package*, so reinstalling reproduces the same mismatch. It also
kicked off a download that initially estimated **68 hours**. I should have run
the `which -a swiftc` / `xcrun -f swiftc` diagnostic *before* prescribing a
multi-gigabyte reinstall, not after.

**Wrong fix #2 — drop the `-target` flag.** `build.sh` passed
`-target arm64-apple-macosx12.0`. My theory was that overriding the deployment
target forced interface recompilation, and that removing it would let swiftc use
the SDK's prebuilt binary modules. Plausible, but wrong — it failed identically.

**The actual fix — rewrite in Objective-C.** Objective-C compiles against the
SDK's **C headers** via clang module maps, which carry no Swift version stamp.
The entire class of failure disappears. `main.m` is a direct port of
`main.swift`; behaviour is identical. `build.sh` now calls:

```bash
clang -O2 -fobjc-arc -Wall -mmacosx-version-min=12.0 \
  -o "$APP/Contents/MacOS/ClaudeUsageBar" main.m -framework Cocoa
```

It compiled first try.

**Lesson.** When a toolchain fights you and the deliverable doesn't care what
language it's written in, change language rather than fight the toolchain. I
should have reached this after the *first* failure, not the third. Two rounds of
guessing cost more of your time than the rewrite did.

---

## 7. Swift bugs caught by reading, not by compiling

**[me]**, caught before they reached you

I can't compile macOS code in my environment, so the Swift source was reviewed
by hand. Four real errors were found and fixed that way:

| Bug | Why it would have failed |
|---|---|
| `NSTextField.sizeThatFits(_:)` | Not reliably available; replaced with `NSString.boundingRect(with:options:attributes:)`. |
| `guard isViewLoaded else { return }` in `rebuild()` | The first `update()` fires before the view loads, so the popover would have rendered empty forever. |
| `UsageViewController()` with no explicit init | `NSViewController`'s designated initializer is `init(nibName:bundle:)`; added an explicit `init()`. |
| `NSTextField.lineBreakMode` | Version-sensitive; moved to `cell?.lineBreakMode`. |

All four survived into the Objective-C port as correct code. Worth noting
because "it compiled" was never available as a safety net here — brace-balance
checks and line-by-line review were.

---

## 8. The widget built, ran, and was invisible

**[env]**

**Symptom.** `./build.sh` succeeded, `pgrep -fl ClaudeUsageBar` showed a live
process, but no icon appeared in the menu bar.

**Cause.** macOS inserts new status items at the **left end** of the status
area — which on a notched MacBook Pro is precisely where the notch sits. With a
crowded menu bar (~14 items), the icon has nowhere to draw and is silently
dropped. No error, no log.

**Fix.** Free up menu bar space, or install a menu bar manager such as
[Ice](https://github.com/jordanbaird/Ice). Optionally shrink the item by
removing the percentage text and showing only the gauge.

---

## 9. Rate limited within minutes of first working

**[me]**

**Symptom.** The widget appeared, worked, and then showed a screenful of raw
JSON: `HTTP 429 — {"error":{"type":"rate_limit_error"}}`. Pressing Refresh did
nothing.

**Cause.** My first design was far too chatty for an unpublished endpoint:

- a request on **every** popover open, so idly clicking five times was five calls
- plus a 5-minute timer
- plus a second call to `/profile` on every cycle, because I cached the plan
  name in memory only and never persisted it

Combined with the diagnostic probes we'd been running repeatedly during setup
(`probe4.py` alone hits four endpoints per run), that was more than enough.

**Why Refresh didn't help.** A 429 is the server refusing you for a window.
Pressing Refresh sends another request into that refusal, and if the limiter
counts rejected attempts, it holds the door shut longer. There is no
client-side fix; the only cure is to stop calling.

**Fix.**

| Change | Effect |
|---|---|
| Poll interval 5 min → 15 min | 3× fewer background calls |
| 60-second freshness window | Opening the popover usually makes no request at all |
| Plan name persisted to `NSUserDefaults` | `/profile` is fetched once per machine, not once per launch |
| Exponential backoff on 429/5xx | 2 min, doubling to a 30-min cap; honours `Retry-After` |
| Backoff ignores forced refresh | Stops the app making its own situation worse |
| Degraded rendering | Last good numbers stay visible with a footnote, instead of a JSON dump |

**Lesson.** I treated an undocumented internal endpoint like a public API with
a generous budget. Anything reached by reverse-engineering should be polled as
little as the UI can tolerate, and should degrade to stale-but-readable rather
than showing the user a raw error body.

---

## Summary of what I'd do differently

1. **Verify the credential exists before designing the auth strategy.** One
   probe up front would have skipped the entire wrong first branch.
2. **Diagnose before prescribing anything expensive.** The Command Line Tools
   reinstall was a multi-gigabyte download that had no chance of working, and I
   ordered it before running a three-command diagnostic.
3. **Change tools instead of fighting them.** The Objective-C rewrite took one
   pass and worked immediately; two rounds of Swift toolchain guessing produced
   nothing.
4. **No `#` comments in pasteable shell blocks.** zsh interactive doesn't
   support them.
5. **Parse structured output with a parser.** Not with `grep -B8`.
6. **Budget requests to an undocumented endpoint like they're scarce.** They
   are. And always degrade to stale data rather than an error wall.
