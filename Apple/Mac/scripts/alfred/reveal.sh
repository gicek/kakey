#!/bin/bash
# Alfred Run Script for Kakey, connected to search.py's Script Filter output.
# Receives the selected item's `arg` (an account id, never a secret) as $1.
#
# "copy code" always makes Kakey prompt for fresh Touch ID / system password
# verification before copying, regardless of whether Kakey happens to already
# be unlocked (see Kakey.sdef / VaultStore.requestSecureCopy). If the user
# chooses "Enter Password" in the Touch ID sheet, Kakey itself brings its own
# lock screen forward and finishes the copy once the password unlock
# succeeds; this script doesn't need to do anything in that case. The master
# password never passes through this script, Alfred, or AppleScript.
#
# This script only prints the notification text to stdout — it does not call
# `display notification` itself. Alfred's own "Post Notification" object,
# connected downstream in the workflow, picks that text up as `{query}` and
# posts it as Alfred, so the notification shows Alfred's own icon (left) and
# Kakey's icon (badge) instead of a generic script-runner icon.

set -euo pipefail

account_id="$1"

# Sentinel from search.py: the user denied the macOS Automation permission
# prompt once, so every Apple Event to Kakey now fails silently with no
# second system prompt. Send them straight to the right System Settings pane
# instead of trying (and silently failing) `copy code`.
if [ "$account_id" = "__kakey_open_automation_settings__" ]; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    exit 0
fi

# Sentinel from search.py: Settings → Advanced → "Enable Third-Party Plugin
# Interface" is off (off by default). Just bring Kakey forward so the user can turn it on
# themselves — not worth scripting System Settings' internal UI to expand a
# specific settings row for this.
if [ "$account_id" = "__kakey_open_app__" ]; then
    open -a "Kakey"
    exit 0
fi

# Mirrors Kakey's own L10n.resolvedLanguageCode(for: .system): the first
# entry in the user's ordered preferred-language list that matches one of
# the app's three shipped languages wins — not "does zh-Hans appear
# anywhere in the list" (that would ignore priority order and could pick
# the wrong language, e.g. when English is preferred first but Chinese is
# a lower-priority secondary language).
detect_language() {
    # Manual override via the workflow's "kakey_language" configuration
    # variable (Alfred Preferences → this workflow → gear icon). Blank/unset
    # (the default) falls through to system-language detection below.
    case "${kakey_language:-}" in
        zh-Hans|zh-Hant|en) echo "$kakey_language"; return ;;
    esac

    local line lower
    while IFS= read -r line; do
        line="${line//\"/}"
        line="${line//,/}"
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue
        lower="$(echo "$line" | tr '[:upper:]' '[:lower:]')"
        case "$lower" in
            zh-hans*) echo "zh-Hans"; return ;;
            zh-hant*) echo "zh-Hant"; return ;;
            en*) echo "en"; return ;;
        esac
    done < <(defaults read -g AppleLanguages 2>/dev/null)
    echo "en"
}

# `copy code` returns the TOTP code text itself (already on the clipboard by
# the time it returns), or an empty string if verification failed/was
# cancelled or the id wasn't found — never a boolean. See Kakey.sdef.
#
# Passed as an osascript positional argument (`on run argv`) rather than
# interpolated into the script text, mirroring search.py's `find accounts`
# call — avoids any manual quote/backslash escaping of $account_id.
code="$(osascript -e 'on run argv
    tell application "Kakey" to copy code (item 1 of argv)
end run' "$account_id" 2>/dev/null || echo "")"

# Notification copy is generated here by Apple/Mac/scripts/build-alfred-workflow.py
# from Apple/Shared/Resources/Localizable.xcstrings (2026-10-27); `%s` stands for
# the code. The source tree keeps the variables empty.
COPIED_MESSAGE_en=""
COPIED_MESSAGE_zh_Hans=""
COPIED_MESSAGE_zh_Hant=""
# @@KAKEY_ALFRED_COPIED_MESSAGE@@

if [ -n "$code" ]; then
    case "$(detect_language)" in
        zh-Hans) message="$COPIED_MESSAGE_zh_Hans" ;;
        zh-Hant) message="$COPIED_MESSAGE_zh_Hant" ;;
        *) message="$COPIED_MESSAGE_en" ;;
    esac
    # Substitute instead of printf: translations must never be parsed as a format string.
    printf '%s\n' "${message//%s/$code}"
fi
