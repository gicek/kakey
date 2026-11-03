#!/usr/bin/env python3
"""The three localization guards (see docs/LOCALIZATION.md). Called by `make test-mac` / `make test-ios` /
`make test-android`; exits with status 1 if any guard fails.

  1. Source scan: fails if a string literal in source contains non-source-language script (CJK, etc.); a
     character-level lexer skips comments. Literals that are genuinely not UI text (e.g. language names written in
     their own language) are allowed with `// i18n-guard: allow <reason>` on the same line.
  2. Complete translations: every String Catalog key has a non-empty translation in every target language and no
     undeclared languages; strings with several arguments use positional placeholders (%1$@), and every language's
     placeholders match the source language; no orphan keys (keys referenced by no Swift, Kotlin or Rust core source);
     no string ends with an ellipsis in any language.
  3. Keys resolve: every literal key passed to a localization call in source (L10n.tr / L10n.format, Text("..."),
     R.string.<name>, etc.) exists in the String Catalog.

Usage:
  python3 scripts/i18n-guard.py --platform apple --root Apple/Mac --extra Apple/Shared --langs en,zh-Hans,zh-Hant
  python3 scripts/i18n-guard.py --platform android --root Android/app/src/main --langs en,zh-Hans,zh-Hant

All three platforms run guard 2 against the same catalog (--catalog, default Apple/Shared/Resources). Android's
strings.xml is generated from it by scripts/android_strings.py: guard 1 scans Kotlin sources, and guard 3 checks that
every `R.string.<name>` / `R.plurals.<name>` in Kotlin maps back to a catalog key under android_strings.py's naming
rules (the repo has no hand-written strings.xml). The orphan key check also counts these resource name references.

The first --langs entry is the source language. --min-files asserts that at least N source files were scanned, so a
broken path does not let the test pass silently. --refs adds directories searched for key references (orphan check
only, not guards 1/3); defaults to Apple, Core/crates and Android/app/src/main.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True  # importing android_strings must not leave __pycache__ in the source tree
import android_strings  # noqa: E402  resource naming rules are shared with the Android generator

SKIP_DIRS = {"Build", "build", ".build", "DerivedData", "node_modules", "Tests", "test", "tests", "docs", "scripts", ".git"}
SOURCE_EXT = {"apple": {".swift"}, "android": {".kt"}}
ALLOW_MARKER = "i18n-guard: allow"

# Non-source-language scripts (the source language is English): letters from these Unicode blocks in a literal count as
# hard-coded UI text.
FOREIGN_RANGES = [
    (0x0400, 0x04FF), (0x0590, 0x05FF), (0x0600, 0x06FF), (0x0900, 0x097F), (0x0E00, 0x0E7F),
    (0x3040, 0x30FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xAC00, 0xD7AF), (0xF900, 0xFAFF),
]
# Full-width punctuation likewise belongs only in translations: parentheses, corner brackets, comma, period, colon,
# semicolon, exclamation and question marks, and the ideographic comma.
FULLWIDTH_PUNCT = set("\uff08\uff09\u300c\u300d\u300e\u300f\uff0c\u3002\uff1a\uff1b\uff01\uff1f\u3001")


def is_foreign(ch: str) -> bool:
    if ch in FULLWIDTH_PUNCT:
        return True
    cp = ord(ch)
    return unicodedata.category(ch).startswith("L") and any(a <= cp <= b for a, b in FOREIGN_RANGES)


def iter_source_files(roots: list[Path], exts: set[str], skip: set[str] = SKIP_DIRS):
    for root in roots:
        if not root.exists():
            continue
        for p in root.rglob("*"):
            if p.suffix in exts and not (set(p.relative_to(root).parts) & skip):
                yield p


def tokenize(text: str):
    """Yield ("str", content, line number); comments and code are dropped. Handles // /* */ "..." and Swift triple quotes."""
    i, n, line = 0, len(text), 1
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            seg = text[i:] if j < 0 else text[i:j + 2]
            line += seg.count("\n")
            i = n if j < 0 else j + 2
            continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            seg = text[i + 3:] if j < 0 else text[i + 3:j]
            yield ("str", seg, line)
            line += seg.count("\n")
            i = n if j < 0 else j + 3
            continue
        if text[i] == '"':
            j, out = i + 1, []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    out.append(text[j:j + 2]); j += 2; continue
                if text[j] == "\n":
                    break
                out.append(text[j]); j += 1
            yield ("str", "".join(out), line)
            i = j + 1
            continue
        if text[i] == "\n":
            line += 1
        i += 1


KEY_CALLS = re.compile(
    r'(?:\bL10n\.(?:tr|format)\(|String\(localized:|LocalizedStringKey\(|\bText\(|\bLabel\(|\bButton\(|\bToggle\(|\bSection\(|NSLocalizedString\()'
    r'\s*"((?:[^"\\]|\\.)*)"'
)
# printf-style placeholders: %@ %lld %d %1$@ %#@name@ (%% does not count)
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(#@\w+@|@|ll[du]|l[du]|[dusfx])")


class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.notes: list[str] = []

    def err(self, m):
        self.errors.append(m)

    def note(self, m):
        self.notes.append(m)


def guard1_source_scan(files: list[Path], r: Report) -> None:
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        for _, content, line in tokenize(text):
            bad = [ch for ch in content if is_foreign(ch)]
            if bad and ALLOW_MARKER not in lines[line - 1]:
                r.err(f"guard 1 {f}:{line} string literal contains non-source-language text \"{''.join(bad[:8])}...\": use an English source string and translate it in the String Catalog")


def unescape(key: str) -> str:
    """Turn common escapes in a Swift literal into real characters; other escapes such as interpolation stay as-is (such
    literals are not fixed keys anyway)."""
    return re.sub(r'\\([n"\\t])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), key)


def unit_values(loc: dict) -> list[str]:
    """All values for one language (including plural variations and variations inside substitutions)."""
    values = []
    if "stringUnit" in loc:
        values.append(loc["stringUnit"].get("value", ""))
    for variation in loc.get("variations", {}).values():
        for case in variation.values():
            values.extend(unit_values(case))
    for sub in loc.get("substitutions", {}).values():
        values.extend(unit_values(sub))
    return values


def specifiers(value: str) -> list[tuple[str | None, str]]:
    return [(m.group(1), "@" if m.group(2) == "@" else "d" if m.group(2) not in ("s", "f", "x") else m.group(2))
            for m in SPECIFIER.finditer(value.replace("%%", "")) if not m.group(2).startswith("#@")]


def check_placeholders(key: str, entry: dict, langs: list[str], r: Report) -> None:
    locs = entry.get("localizations", {})
    # Source language: use its own stringUnit if present (semantic keys); otherwise the key itself is the English source
    # string (a plural "one" variation may omit the count).
    source = locs.get(langs[0], {})
    base = specifiers(source["stringUnit"]["value"] if "stringUnit" in source and "substitutions" not in source else key)
    if len(base) > 1 and any(pos is None for pos, _ in base):
        r.err(f"guard 2 key \"{key}\" has {len(base)} arguments but uses unnumbered placeholders: use %1$@, %2$lld so translations can reorder them")
    expected = sorted(kind for _, kind in base)
    for lang in langs[1:]:
        if lang not in locs or "substitutions" in locs[lang]:
            continue
        for value in unit_values(locs[lang]):
            got = specifiers(value)
            # A plural "one" variation may drop the count (spelling out "one" instead of "1"); all others must match.
            if sorted(kind for _, kind in got) != expected and not (lang != langs[0] and len(got) < len(base)):
                r.err(f"guard 2 key \"{key}\": {lang} placeholders {[k for _, k in got]} do not match the source language {expected}")


ANDROID_REF = re.compile(r"\bR\.(?:string|plurals)\.(\w+)")


def find_catalogs(dirs: list[Path]) -> list[Path]:
    seen: dict[Path, Path] = {}
    for d in dirs:
        if not d.exists():
            continue
        for p in d.rglob("*.xcstrings"):
            if not (set(p.parts) & {"Build", "DerivedData"}):
                seen.setdefault(p.resolve(), p)
    return list(seen.values())


def catalog_guards(catalogs: list[Path], refs: list[Path], langs: list[str], r: Report) -> dict[str, dict] | None:
    """Guard 2: checks on the catalog itself (all three platforms share one catalog). Returns the Localizable.xcstrings
    key table for guard 3."""
    if not catalogs:
        r.note("guards 2/3 skipped: no .xcstrings found")
        return None
    source, targets = langs[0], langs[1:]
    strings: dict[str, dict] = {}
    for catalog in catalogs:
        data = json.loads(catalog.read_text(encoding="utf-8"))
        if data.get("sourceLanguage") != source:
            r.err(f"guard 2 {catalog} has source language {data.get('sourceLanguage')}, expected {source}")
        for key, entry in data.get("strings", {}).items():
            if entry.get("shouldTranslate") is False:
                continue
            locs = entry.get("localizations", {})
            for lang in targets:
                if not any(unit_values(locs.get(lang, {}))):
                    r.err(f"guard 2 key \"{key}\" is missing the {lang} translation ({catalog.name})")
            for lang in langs:
                values = unit_values(locs.get(lang, {})) or ([key] if lang == source else [])
                if any(value.endswith(("…", "...")) for value in values):
                    r.err(f"guard 2 key \"{key}\": {lang} text ends with an ellipsis, which no language uses (see docs/LOCALIZATION.md)")
            for lang in locs:
                if lang not in langs:
                    r.err(f"guard 2 key \"{key}\" has a translation in undeclared language {lang}: the language set is defined in docs/LOCALIZATION.md")
            check_placeholders(key, entry, langs, r)
        if catalog.name == "Localizable.xcstrings":
            strings.update(data.get("strings", {}))

    # Orphan keys: keys that appear as a literal in no Swift / Rust source and are referenced by resource name in no Kotlin.
    referenced: set[str] = set()
    ref_files = list(iter_source_files(refs, {".swift", ".rs", ".kt"}, {"Build", "DerivedData", ".git", "target", "test"}))
    by_resource_name = {name: key for key, name in android_strings.resource_names(strings).items()}
    for f in ref_files:
        text = f.read_text(encoding="utf-8", errors="replace")
        if f.suffix == ".kt":
            referenced.update(by_resource_name[name] for name in ANDROID_REF.findall(text) if name in by_resource_name)
        else:
            referenced.update(unescape(m) for m in re.findall(r'"((?:[^"\\]|\\.)*)"', text))
    for key in sorted(set(strings) - referenced):
        r.err(f"guard 2 Localizable.xcstrings has orphan key \"{key}\": nothing in source references it, so delete it")
    return strings


def apple_guards(roots: list[Path], catalogs: list[Path], refs: list[Path], langs: list[str], r: Report) -> list[Path]:
    files = list(iter_source_files(roots, SOURCE_EXT["apple"]))
    guard1_source_scan(files, r)
    strings = catalog_guards(catalogs, refs, langs, r)
    if strings is None:
        return files
    # Guard 3: literal keys in code must exist in Localizable.xcstrings.
    for f in files:
        for m in KEY_CALLS.finditer(f.read_text(encoding="utf-8", errors="replace")):
            key = unescape(m.group(1))
            if key and "\\(" not in m.group(1) and key not in strings:
                r.err(f"guard 3 {f} localization key \"{key}\" is not in Localizable.xcstrings")
    return files


def android_guards(roots: list[Path], catalogs: list[Path], refs: list[Path], langs: list[str], r: Report) -> list[Path]:
    files = list(iter_source_files(roots, SOURCE_EXT["android"]))
    guard1_source_scan(files, r)
    strings = catalog_guards(catalogs, refs, langs, r)
    if strings is None:
        return files
    # Guard 3: resource names referenced from Kotlin must map back to catalog keys under android_strings.py's naming rules
    # (the compiler also rejects a missing R.string, but this needs no Gradle run and says which key to add to the catalog).
    names = set(android_strings.resource_names(strings).values())
    for f in files:
        for name in ANDROID_REF.findall(f.read_text(encoding="utf-8", errors="replace")):
            if name not in names:
                r.err(f"guard 3 {f} resource name \"{name}\" is not derived from Localizable.xcstrings: add the string to the catalog first (scripts/android_strings.py --print-names lists resource names)")
    return files


def main() -> int:
    p = argparse.ArgumentParser(description="The three localization guards")
    p.add_argument("--platform", required=True, choices=("apple", "android"))
    p.add_argument("--root", required=True, help="component directory, e.g. Apple/Mac")
    p.add_argument("--extra", action="append", default=[], help="additional directory to scan, e.g. Apple/Shared")
    p.add_argument("--refs", action="append", default=None, help="additional directory searched for key references (orphan check)")
    p.add_argument("--catalog", default="Apple/Shared/Resources", help="String Catalog directory (shared by all platforms)")
    p.add_argument("--langs", default="en", help="comma-separated languages; the first is the source language")
    p.add_argument("--min-files", type=int, default=1, help="minimum number of source files that must be scanned")
    a = p.parse_args()

    roots = [Path(a.root)] + [Path(x) for x in a.extra]
    refs = [Path(x) for x in (a.refs or ["Apple", "Core/crates", "Android/app/src/main"])]
    langs = [x.strip() for x in a.langs.split(",") if x.strip()]
    catalogs = find_catalogs(roots + [Path(a.catalog)])
    r = Report()
    guards = apple_guards if a.platform == "apple" else android_guards
    files = guards(roots, catalogs, refs, langs, r)

    if len(files) < a.min_files:
        r.err(f"scanned {len(files)} source files, fewer than --min-files {a.min_files}: path resolution may be broken")
    for n in r.notes:
        print(f"! {n}")
    for e in r.errors:
        print(f"✗ {e}")
    print(f"i18n-guard [{a.platform}] {', '.join(map(str, roots))}: scanned {len(files)} files, {len(r.errors)} problems.")
    return 1 if r.errors else 0


if __name__ == "__main__":
    sys.exit(main())
