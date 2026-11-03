#!/usr/bin/env python3
"""Alfred Script Filter for Kakey: keyword `kk` + query.

Filters accounts by service name and account name using Kakey's own
`find accounts <query>` AppleScript command (Kakey.sdef) — never a locally
readable plaintext file. The matching itself happens inside Kakey against
full, unmasked values; this script only ever receives already-matched,
already-masked results (never a secret or code) and requires the same macOS
Automation permission as `copy code`, so only an app the user has explicitly
approved to control Kakey can call it. Deliberately never shows a
verification code here, even if Kakey happens to already be unlocked:
revealing a code always requires a *fresh* Touch ID / system password
verification at the moment of copying (see reveal.sh + Kakey.sdef's
`copy code`), so a malicious local process can never silently read codes
just because the app happens to be sitting unlocked.
"""

import json
import os
import subprocess
import sys

# Mirrors Kakey's own L10n.resolvedLanguageCode(for: .system): match the
# user's ordered preferred-language list against the app's three shipped
# languages, falling back to English if none match.
SUPPORTED_LANGUAGES = ["en", "zh-Hans", "zh-Hant"]
FALLBACK_LANGUAGE = "en"

# Sentinel `arg` values recognized by reveal.sh, for items whose Enter action
# isn't "copy this account's code".
OPEN_AUTOMATION_SETTINGS_ARG = "__kakey_open_automation_settings__"
OPEN_KAKEY_ARG = "__kakey_open_app__"

# Result-list copy is generated here by Apple/Mac/scripts/build-alfred-workflow.py from
# Apple/Shared/Resources/Localizable.xcstrings (the single source for all three
# languages, 2026-10-27); the source tree keeps the table empty.
STRINGS = {}  # @@KAKEY_ALFRED_STRINGS@@


def detect_language():
    # Manual override via the workflow's "kakey_language" configuration
    # variable (Alfred Preferences → this workflow → gear icon). Blank/unset
    # (the default) falls through to system-language detection below.
    override = os.environ.get("kakey_language", "").strip()
    if override in SUPPORTED_LANGUAGES:
        return override

    try:
        raw = subprocess.run(
            ["defaults", "read", "-g", "AppleLanguages"],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return FALLBACK_LANGUAGE

    # `defaults read` prints an old-style plist array, one quoted tag per line, e.g. "zh-Hans-CN".
    preferred = [line.strip().strip('",') for line in raw.splitlines() if line.strip().startswith('"')]
    for tag in preferred:
        lower = tag.lower()
        for code in SUPPORTED_LANGUAGES:
            if lower.startswith(code.lower()):
                return code
    return FALLBACK_LANGUAGE


# Passing `query` as an osascript positional argument (via `on run argv`)
# rather than interpolating it into the script text avoids any manual
# quote/backslash escaping — the query can contain anything and is never
# parsed as AppleScript source.
FIND_ACCOUNTS_SCRIPT = (
    'on run argv\n'
    '    tell application "Kakey" to find accounts (item 1 of argv)\n'
    'end run'
)


def is_kakey_running():
    """Checked via `pgrep`, not AppleScript: `tell application "Kakey"` would
    launch Kakey itself as a side effect of merely asking whether it's
    running, and Script Filters re-run on every keystroke — that would cold
    launch the app just from typing, before the user has committed to
    anything."""
    try:
        return subprocess.run(
            ["pgrep", "-x", "Kakey"], capture_output=True, timeout=2,
        ).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def load_index(query):
    """Returns (accounts, status) where status is one of "ok",
    "permission_denied", "disabled", "not_running", or "not_ready"."""
    if not is_kakey_running():
        return [], "not_running"

    try:
        result = subprocess.run(
            ["osascript", "-e", FIND_ACCOUNTS_SCRIPT, query],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return [], "not_ready"

    # AppleScript error -1743: "Not authorized to send Apple events to
    # Kakey." macOS shows the system permission prompt on the very first
    # Apple Event attempt only; if the user clicks Don't Allow there, every
    # later attempt fails the same way with no second prompt.
    if "-1743" in result.stderr:
        return [], "permission_denied"

    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, ValueError):
        return [], "not_ready"

    # Settings → Advanced → "Enable Third-Party Plugin Interface" is off by
    # default in Kakey's own Settings — distinct from (and checked
    # independently of) the macOS Automation permission above.
    if not payload.get("enabled", False):
        return [], "disabled"
    if not payload.get("ready", False):
        return [], "not_ready"
    return payload.get("accounts", []), "ok"


def main():
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    strings = STRINGS[detect_language()]
    index, status = load_index(query)

    if status == "not_running":
        print(json.dumps({"items": [{
            "title": strings["not_running_title"],
            "subtitle": strings["not_running_subtitle"],
            "arg": OPEN_KAKEY_ARG,
            "valid": True,
        }]}))
        return

    if status == "permission_denied":
        print(json.dumps({"items": [{
            "title": strings["permission_denied_title"],
            "subtitle": strings["permission_denied_subtitle"],
            "arg": OPEN_AUTOMATION_SETTINGS_ARG,
            "valid": True,
        }]}))
        return

    if status == "disabled":
        print(json.dumps({"items": [{
            "title": strings["disabled_title"],
            "subtitle": strings["disabled_subtitle"],
            "arg": OPEN_KAKEY_ARG,
            "valid": True,
        }]}))
        return

    if status == "not_ready":
        print(json.dumps({"items": [{
            "title": strings["not_ready_title"],
            "subtitle": strings["not_ready_subtitle"],
            "valid": False,
        }]}))
        return

    # `find accounts` already did the matching (against full, unmasked
    # issuer + username) and only returned hits — just cap how many the
    # Script Filter shows.
    matched = index[:12]
    if not matched:
        subtitle = strings["no_match_subtitle"].format(query) if query else strings["no_match_subtitle_empty"]
        print(json.dumps({"items": [{
            "title": strings["no_match_title"],
            "subtitle": subtitle,
            "valid": False,
        }]}))
        return

    items = [
        {
            "title": entry["issuer"],
            "subtitle": strings["subtitle"].format(entry["username"]),
            "arg": entry["id"],
            "valid": True,
        }
        for entry in matched
    ]
    print(json.dumps({"items": items}))


if __name__ == "__main__":
    main()
