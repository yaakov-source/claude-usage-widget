#!/usr/bin/env python3
"""
Finds the Claude account OAuth token in the login Keychain and probes the
usage endpoints. Handles hex-encoded keychain blobs and multiple accounts
under the same service name.

Prints key names, lengths and endpoint responses. Never prints a token value.
"""

import json
import re
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

SECURITY = "/usr/bin/security"


def sh(args):
    try:
        p = subprocess.run(args, capture_output=True, timeout=60)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return 1, b"", str(e).encode()


def dump_items():
    """Yield (service, account) for every generic password item."""
    code, out, _ = sh([SECURITY, "dump-keychain"])
    text = out.decode("utf-8", "replace")
    blocks = re.split(r"^keychain: ", text, flags=re.M)
    for b in blocks:
        svce = re.search(r'"svce"<blob>="([^"]*)"', b)
        acct = re.search(r'"acct"<blob>="([^"]*)"', b)
        if svce:
            yield svce.group(1), (acct.group(1) if acct else None)


def read_secret(service, account):
    args = [SECURITY, "find-generic-password", "-s", service]
    if account:
        args += ["-a", account]
    args += ["-w"]
    code, out, err = sh(args)
    if code != 0:
        return None, f"security exit {code}: {err.decode('utf-8','replace').strip()[:80]}"
    raw = out.decode("utf-8", "replace").strip()
    if not raw:
        return None, "empty"

    # security prints hex when the blob isn't printable text
    if raw and not raw.lstrip().startswith("{") and re.fullmatch(r"[0-9a-fA-F]+", raw) and len(raw) % 2 == 0:
        try:
            raw = bytes.fromhex(raw).decode("utf-8", "replace")
        except Exception as e:
            return None, f"hex decode failed: {e}"

    try:
        return json.loads(raw), None
    except Exception as e:
        return None, f"not JSON ({len(raw)} chars, starts {raw[:20]!r}): {e}"


def find_token():
    seen = set()
    candidates = []
    for svce, acct in dump_items():
        if not svce.startswith("Claude Code-credentials"):
            continue
        key = (svce, acct)
        if key in seen:
            continue
        seen.add(key)
        candidates.append(key)

    print(f"Found {len(candidates)} candidate keychain item(s).\n")

    for svce, acct in candidates:
        label = f"{svce}" + (f"  [acct={acct}]" if acct else "")
        data, err = read_secret(svce, acct)
        if data is None:
            print(f"  skip  {label}  -> {err}")
            continue
        keys = list(data.keys())
        o = data.get("claudeAiOauth")
        if isinstance(o, dict) and isinstance(o.get("accessToken"), str) and o["accessToken"]:
            print(f"  HIT   {label}")
            print(f"        keys: {keys}")
            tok = o["accessToken"]
            print(f"        accessToken: <{len(tok)} chars, prefix {tok[:12]}...>")
            exp = o.get("expiresAt")
            if exp:
                ts = exp / 1000 if exp > 1e12 else exp
                dt = datetime.fromtimestamp(ts)
                state = "EXPIRED" if dt < datetime.now() else "valid"
                print(f"        expiresAt: {dt} ({state})")
            print(f"        subscriptionType: {o.get('subscriptionType')}")
            print(f"        scopes: {o.get('scopes')}")
            return tok
        print(f"  skip  {label}  -> keys={keys}")
    return None


def probe(url, token):
    print(f"\n--- {url}")
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("anthropic-beta", "oauth-2025-04-20")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "ClaudeUsageBar/1.0")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode("utf-8", "replace")
            print(f"HTTP {r.status}")
            try:
                print(json.dumps(json.loads(body), indent=2)[:3000])
            except Exception:
                print(body[:1200])
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        print(f"HTTP {e.code}")
        print(body[:600])
    except Exception as e:
        print(f"ERROR {e}")


def main():
    token = find_token()
    if not token:
        print("\nNo account token found.")
        sys.exit(1)

    org = ""
    try:
        cfg = json.loads(Path.home().joinpath(".claude.json").read_text())
        org = cfg.get("oauthAccount", {}).get("organizationUuid", "")
    except Exception:
        pass
    print(f"\nOrg UUID: {org or 'unknown'}")
    print("\n=== Probing endpoints ===")

    urls = [
        "https://api.anthropic.com/api/oauth/usage",
        "https://api.anthropic.com/api/oauth/profile",
        "https://api.anthropic.com/api/oauth/claude_cli/usage",
    ]
    if org:
        urls.append(f"https://api.anthropic.com/api/organizations/{org}/usage")
    for u in urls:
        probe(u, token)

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
