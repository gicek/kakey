#!/usr/bin/env python3
"""Package Kakey's .alfredworkflow at build time; it ships inside the app in Contents/Resources/.

Writes Apple/Mac/Resources/Kakey.alfredworkflow: an info.plist with fixed UIDs, two
runtime scripts (scripts/alfred/search.py and reveal.sh) and the app icon. The scripts
ship only inside the workflow, not in the app's Contents/Resources. Everything here is
static content known at build time, so nothing is generated when the user clicks
"Install in Alfred" (see AlfredWorkflowExporter.swift).

The fixed text Alfred renders itself from info.plist (readme, description, placeholder
subtext) is hard-coded English and does not follow Kakey's language setting: Alfred's
Workflow Configuration panel only offers Checkbox / File Picker / Text fields, with no
pop-up menu, so there is no way to pick a language at import time. The text users
actually see, the result list and the copy notification, comes in all three languages
from Apple/Shared/Resources/Localizable.xcstrings (the single source of UI text): this
script reads the catalog at packaging time and writes generated tables into the
placeholders of both scripts, which pick the language at runtime (detected from the
system language, or overridden manually with the kakey_language variable).

Output is byte-for-byte deterministic (zip entry order and timestamps are fixed), so an
unchanged workflow produces no noise in git status or the app bundle.
"""

import json
import plistlib
import re
import zipfile
from pathlib import Path

# This script lives in Apple/Mac/scripts/: parents[1] is the Mac app directory, parents[3] the repo root.
APP_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
RESOURCES = APP_DIR / "Resources"
OUTPUT = RESOURCES / "Kakey.alfredworkflow"
PBXPROJ = APP_DIR.parent / "Kakey.xcodeproj" / "project.pbxproj"

SEARCH_SCRIPT = APP_DIR / "scripts" / "alfred" / "search.py"
REVEAL_SCRIPT = APP_DIR / "scripts" / "alfred" / "reveal.sh"
CATALOG = REPO_ROOT / "Apple" / "Shared" / "Resources" / "Localizable.xcstrings"

# Same three languages as the app; the first is the source language, whose keys are the English text itself.
LANGUAGES = ["en", "zh-Hans", "zh-Hant"]
# STRINGS table for search.py: short name in the script -> String Catalog key (English source string).
# `%@` becomes `{}` in search.py (str.format) and `%s` in reveal.sh (bash substitution).
SEARCH_STRINGS = {
    "not_running_title": "Kakey isn’t running",
    "not_running_subtitle": "Press Enter to open Kakey",
    "not_ready_title": "Kakey isn’t ready yet",
    "not_ready_subtitle": "The vault hasn’t been unlocked since Kakey started",
    "permission_denied_title": "Kakey automation access is off",
    "permission_denied_subtitle": "Press Enter to open System Settings and allow Alfred to control Kakey",
    "disabled_title": "Third-party plugin interface is off",
    "disabled_subtitle": "Press Enter to open Kakey, then turn it on in Settings → Advanced",
    "no_match_title": "No matching accounts",
    "no_match_subtitle": "No results for “%@”",
    "no_match_subtitle_empty": "Type a service or account name to filter",
    "subtitle": "%@ · Press Enter to copy the code",
}
COPIED_MESSAGE_KEY = "Code copied to clipboard: %@"
SEARCH_PLACEHOLDER = "STRINGS = {}  # @@KAKEY_ALFRED_STRINGS@@"
REVEAL_PLACEHOLDER = "# @@KAKEY_ALFRED_COPIED_MESSAGE@@"


def catalog_text(strings: dict, key: str, language: str) -> str:
    """Text for a key in a language; for the source language without its own translation, the key itself."""
    entry = strings.get(key)
    if entry is None:
        raise SystemExit(f"Localizable.xcstrings is missing key '{key}'")
    unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
    value = unit.get("value", "")
    if not value:
        if language == LANGUAGES[0]:
            return key
        raise SystemExit(f"Key '{key}' has no {language} translation")
    return value


def load_tables() -> tuple[dict[str, dict[str, str]], dict[str, str]]:
    """Return (search.py's {language: {short name: text}}, reveal.sh's {language: text})."""
    strings = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    search = {
        language: {name: catalog_text(strings, key, language) for name, key in SEARCH_STRINGS.items()}
        for language in LANGUAGES
    }
    copied = {language: catalog_text(strings, COPIED_MESSAGE_KEY, language) for language in LANGUAGES}
    return search, copied


def render_search_script(source: str, tables: dict[str, dict[str, str]]) -> str:
    if SEARCH_PLACEHOLDER not in source:
        raise SystemExit(f"{SEARCH_SCRIPT} is missing placeholder {SEARCH_PLACEHOLDER}")
    python_tables = {
        language: {name: text.replace("{", "{{").replace("}", "}}").replace("%@", "{}") for name, text in table.items()}
        for language, table in tables.items()
    }
    literal = json.dumps(python_tables, ensure_ascii=False, indent=4, sort_keys=True)
    return source.replace(SEARCH_PLACEHOLDER, f"STRINGS = {literal}")


def render_reveal_script(source: str, copied: dict[str, str]) -> str:
    if REVEAL_PLACEHOLDER not in source:
        raise SystemExit(f"{REVEAL_SCRIPT} is missing placeholder {REVEAL_PLACEHOLDER}")
    lines = []
    for language in LANGUAGES:
        value = copied[language].replace("%@", "%s").replace("'", "'\\''")
        lines.append(f"COPIED_MESSAGE_{language.replace('-', '_')}='{value}'")
    return source.replace(REVEAL_PLACEHOLDER, "\n".join(lines))


def marketing_version() -> str:
    """The single source of the version is the project build settings, not duplicated here;
    reads the same file and field as the Makefile's VERSION variable."""
    match = re.search(r"MARKETING_VERSION\s*=\s*([0-9.]+);", PBXPROJ.read_text())
    if not match:
        raise SystemExit(f"Could not read MARKETING_VERSION from {PBXPROJ}")
    return match.group(1)
ICON_SOURCE = RESOURCES / "Assets.xcassets" / "AppIcon.appiconset" / "icon_512x512@2x.png"

SCRIPT_FILTER_UID = "1B6F1F2E-7A0E-4C0A-9C3D-KAKEYSEARCH01"
RUN_SCRIPT_UID = "2C7A2F3F-8B1F-4D1B-8D4E-KAKEYREVEAL02"
NOTIFICATION_UID = "3D8B3A4A-9C2A-4E2C-9E5F-KAKEYNOTIFY03"

README = (
    "Usage: type kk followed by a service or account name to filter, then press "
    "Enter to copy the code.\n\n"
    "Security: the first use will prompt for macOS Automation permission — please "
    "allow it. Please note: for security, every code copy requires fresh Touch ID "
    "or system login password verification — Kakey will not provide any secret or "
    "code information without successful verification. Kakey's master password and "
    "account secrets are never granted to any third-party app.\n\n"
    "Language: results and notifications automatically follow your Mac's system "
    "language (English / Simplified Chinese / Traditional Chinese). To override, "
    "open this workflow's configuration (gear icon in Alfred Preferences) and set "
    "the “kakey_language” variable to one of: en, zh-Hans, zh-Hant. Leave it "
    "blank to keep following the system language."
)

INFO_PLIST: dict = {
    "bundleid": "com.gicek.kakey.alfred",
    "category": "Tools",
    "version": marketing_version(),
    "createdby": "Kakey.app",
    "description": "Search Kakey accounts and copy codes with a keyword",
    "disabled": False,
    "name": "Kakey",
    "readme": README,
    "webaddress": "",
    "variables": {"kakey_language": ""},
    "variablesdontexport": [],
    # Alfred's Workflow Configuration panel (gear icon) is driven by this array, a mechanism
    # separate from the classic variables table above. Without it, the panel shows "No
    # configuration for this Workflow" even though variables does contain kakey_language.
    # The schema was taken from a real installed workflow (textfield type).
    "userconfigurationconfig": [
        {
            "type": "textfield",
            "variable": "kakey_language",
            "label": "Language override",
            "description": "en / zh-Hans / zh-Hant — leave blank to follow the system language",
            "config": {
                "trim": True,
                "default": "",
                "placeholder": "en / zh-Hans / zh-Hant",
                "required": False,
            },
        }
    ],
    "connections": {
        SCRIPT_FILTER_UID: [
            {
                "destinationuid": RUN_SCRIPT_UID,
                "modifiers": 0,
                "modifiersubtext": "",
                "vitoclose": False,
            }
        ],
        RUN_SCRIPT_UID: [
            {
                "destinationuid": NOTIFICATION_UID,
                "modifiers": 0,
                "modifiersubtext": "",
                "vitoclose": False,
            }
        ],
    },
    "objects": [
        {
            "type": "alfred.workflow.input.scriptfilter",
            "uid": SCRIPT_FILTER_UID,
            "version": 3,
            "config": {
                "keyword": "kk",
                "title": "Kakey",
                "subtext": "Type a service or account name to filter Kakey accounts",
                "runningsubtext": "Searching…",
                "script": 'python3 search.py "{query}"',
                "type": 0,
                "withspace": True,
                "alfredfiltersresults": False,
                "argumenttype": 0,
                "queuemode": 1,
                "queuedelaymode": 0,
                "queuedelaycustom": 3,
                "queuedelayimmediatelyinitially": False,
            },
        },
        {
            "type": "alfred.workflow.action.script",
            "uid": RUN_SCRIPT_UID,
            "version": 2,
            "config": {
                "script": 'bash reveal.sh "{query}"',
                "type": 0,
                "scriptfile": "",
                "concurrently": False,
            },
        },
        # Alfred's own "Post Notification" node, so the notification comes from Alfred
        # (Alfred's icon on the left, with the icon.png referenced by the icon field as the
        # top-right badge) rather than the generic script icon of osascript's display
        # notification. Its text is what reveal.sh prints to stdout (it prints nothing when
        # copying fails, and onlyshowifquerypopulated skips that case instead of posting an
        # empty notification).
        {
            "type": "alfred.workflow.output.notification",
            "uid": NOTIFICATION_UID,
            "version": 1,
            "config": {
                "argument": 0,
                "title": "Kakey",
                "text": "{query}",
                "icon": "icon.png",
                "onlyshowifquerypopulated": True,
            },
        },
    ],
    "uidata": {
        SCRIPT_FILTER_UID: {"xpos": 170, "ypos": 90},
        RUN_SCRIPT_UID: {"xpos": 430, "ypos": 90},
        NOTIFICATION_UID: {"xpos": 690, "ypos": 90},
    },
}

# Fixed timestamp so rebuilding unchanged content yields a byte-identical zip.
FIXED_DATE_TIME = (2026, 1, 1, 0, 0, 0)


def _write_entry(zf: zipfile.ZipFile, arcname: str, data: bytes, executable: bool) -> None:
    info = zipfile.ZipInfo(arcname, date_time=FIXED_DATE_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    # The high 16 bits hold the Unix permission bits: shifting 0o644 / 0o755 left by 16 is the
    # standard encoding of zip external attributes.
    info.external_attr = ((0o755 if executable else 0o644) << 16)
    zf.writestr(info, data)


def main() -> None:
    for path in (SEARCH_SCRIPT, REVEAL_SCRIPT, ICON_SOURCE, CATALOG):
        if not path.exists():
            raise SystemExit(f"Missing source file: {path}")

    search_tables, copied_messages = load_tables()
    search_script = render_search_script(SEARCH_SCRIPT.read_text(encoding="utf-8"), search_tables)
    reveal_script = render_reveal_script(REVEAL_SCRIPT.read_text(encoding="utf-8"), copied_messages)
    plist_bytes = plistlib.dumps(INFO_PLIST, fmt=plistlib.FMT_XML)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if OUTPUT.exists():
        OUTPUT.unlink()

    with zipfile.ZipFile(OUTPUT, "w") as zf:
        _write_entry(zf, "info.plist", plist_bytes, executable=False)
        _write_entry(zf, "search.py", search_script.encode("utf-8"), executable=True)
        _write_entry(zf, "reveal.sh", reveal_script.encode("utf-8"), executable=True)
        _write_entry(zf, "icon.png", ICON_SOURCE.read_bytes(), executable=False)

    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
