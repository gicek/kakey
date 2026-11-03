#!/usr/bin/env python3
"""Generate Android string resources from the String Catalog (run by Gradle before the Android build, or by hand).

The single source for all three languages is `Apple/Shared/Resources/Localizable.xcstrings` (see docs/LOCALIZATION.md).
Android resource names cannot be English sentences, so this derives stable names from the keys, which Kotlin references
as `R.string.<name>` / `R.plurals.<name>`:

- Semantic keys (`err.vault.corrupt`): dots become underscores -> `err_vault_corrupt`.
- English source keys: placeholders become x, take the first 6 words, lowercase with underscores ->
  `Add Account` -> `add_account`, `Delete “%@”?` -> `delete_x`.
- When several keys derive the same name, each gets a 4-character hash of its own key; keys with no usable letters use
  the key hash.

Placeholder conversion: `%lld` / `%d` -> `%d`, `%@` -> `%s`, positional forms preserved (`%1$@` -> `%1$s`). English plural
variations produce `<plurals>`; substitutions with two independently varying counts degrade to plain strings (an Android
`<plurals>` has only one quantity).

Also copies the verification code font into `res/font/` (the same font file Apple uses).

Usage: python3 scripts/android_strings.py --out Build/Scratch/res
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

REPO = Path(__file__).resolve().parents[1]
CATALOG = REPO / "Apple/Shared/Resources/Localizable.xcstrings"
FONT = REPO / "Apple/Shared/Resources/Fonts/AtkinsonHyperlegibleMono-Variable.ttf"
SOURCE = "en"
LANG_DIRS = {"en": "values", "zh-Hans": "values-b+zh+Hans", "zh-Hant": "values-b+zh+Hant"}
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(#@\w+@|ll[du]|l[du]|[du@sfx%])")
JAVA_KEYWORDS = set("""abstract assert boolean break byte case catch char class const continue default do double else enum
extends final finally float for goto if implements import instanceof int interface long native new package private protected
public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false
null""".split())
SEMANTIC_KEY = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")


def load_catalog() -> dict[str, dict]:
    return json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]


def base_name(key: str) -> str:
    if SEMANTIC_KEY.match(key):
        return key.replace(".", "_")
    # Placeholders become x, so a string with arguments never collides with the same text without them (Delete / Delete “%@”?).
    words = re.findall(r"[a-z0-9]+", SPECIFIER.sub(" x ", key).lower().replace("’", "").replace("'", ""))
    name = "_".join(words[:6])
    if not name:
        return "str_" + hashlib.sha1(key.encode()).hexdigest()[:8]
    if not name[0].isalpha():
        name = "s_" + name
    # Resource names become Java field names on R.string, so they cannot be keywords (e.g. Import -> import).
    return name + "_label" if name in JAVA_KEYWORDS else name


def resource_names(keys) -> dict[str, str]:
    """Key -> resource name. Unique derived names are used as-is; when several keys derive the same name, each gets a
    short hash of its own key.

    No ordinal `_2`, `_3` suffixes: adding a colliding key would shift existing names, and Kotlin would still compile but
    show the wrong text. With per-key hashes, a collision makes the old name disappear, so references fail to compile
    instead of silently pointing at the wrong string.
    """
    keys = sorted(keys)
    bases = {key: base_name(key) for key in keys}
    counts: dict[str, int] = {}
    for base in bases.values():
        counts[base] = counts.get(base, 0) + 1
    return {
        key: base if counts[base] == 1 else f"{base}_{hashlib.sha1(key.encode()).hexdigest()[:4]}"
        for key, base in bases.items()
    }


def android_format(value: str) -> str:
    def convert(match: re.Match) -> str:
        position, kind = match.group(1), match.group(2)
        if kind == "%":
            return "%%"
        letter = "s" if kind == "@" else "d" if kind in ("lld", "llu", "ld", "lu", "d", "u") else kind
        return f"%{position}${letter}" if position else f"%{letter}"
    return SPECIFIER.sub(convert, value)


def android_text(value: str) -> str:
    text = xml_escape(android_format(value))
    text = text.replace("\\", "\\\\").replace("'", "\\'").replace('"', '\\"').replace("\n", "\\n")
    if text.startswith(("@", "?")):
        text = "\\" + text
    return text


def unit_value(loc: dict | None) -> str | None:
    return (loc or {}).get("stringUnit", {}).get("value")


def plural_forms(loc: dict | None) -> dict[str, str] | None:
    plural = (loc or {}).get("variations", {}).get("plural")
    if not plural:
        return None
    return {quantity: case["stringUnit"]["value"] for quantity, case in plural.items()}


def generate(out: Path) -> int:
    strings = load_catalog()
    names = resource_names(strings)
    # Keys with English plural variations produce <plurals> in every language (Chinese has only "other").
    plural_keys = {key for key, entry in strings.items() if plural_forms(entry.get("localizations", {}).get(SOURCE))}
    for lang, directory in LANG_DIRS.items():
        lines = ['<?xml version="1.0" encoding="utf-8"?>',
                 "<!-- Generated by scripts/android_strings.py from Apple/Shared/Resources/Localizable.xcstrings; do not edit by hand -->",
                 "<resources>"]
        for key in sorted(strings, key=lambda k: names[k]):
            entry = strings[key]
            if entry.get("shouldTranslate") is False and lang != SOURCE:
                continue
            loc = entry.get("localizations", {}).get(lang)
            name = names[key]
            if key in plural_keys:
                forms = plural_forms(loc) or {"other": unit_value(loc) or key}
                lines.append(f'    <plurals name="{name}">')
                for quantity in ("zero", "one", "two", "few", "many", "other"):
                    if quantity in forms:
                        lines.append(f'        <item quantity="{quantity}">{android_text(forms[quantity])}</item>')
                lines.append("    </plurals>")
                continue
            value = unit_value(loc)
            if lang == SOURCE and (value is None or "substitutions" in (loc or {})):
                value = key
            if value is None:
                continue
            lines.append(f'    <string name="{name}">{android_text(value)}</string>')
        lines.append("</resources>")
        target = out / directory / "strings.xml"
        target.parent.mkdir(parents=True, exist_ok=True)
        content = "\n".join(lines) + "\n"
        if not target.exists() or target.read_text(encoding="utf-8") != content:
            target.write_text(content, encoding="utf-8")
    font = out / "font" / "atkinson_hyperlegible_mono.ttf"
    font.parent.mkdir(parents=True, exist_ok=True)
    if not font.exists() or font.read_bytes() != FONT.read_bytes():
        shutil.copyfile(FONT, font)
    return len(strings)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True, type=Path, help="res directory to generate")
    parser.add_argument("--print-names", action="store_true", help="print key -> resource name, for writing Kotlin")
    args = parser.parse_args()
    count = generate(args.out)
    if args.print_names:
        for key, name in sorted(resource_names(load_catalog()).items(), key=lambda item: item[1]):
            print(f"{name}\t{key!r}")
    print(f"android strings: {count} keys × {len(LANG_DIRS)} languages → {args.out}")


if __name__ == "__main__":
    main()
