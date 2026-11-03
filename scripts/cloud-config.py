#!/usr/bin/env python3
"""Validate cloud-keys.toml and print the callback URLs to register in each console (make cloud-config).

The rules match Core/crates/kakey-ffi/build.rs and Android/app/build.gradle.kts:
Dropbox `db-<lowercase app key>://2/token`, Microsoft `msal<lowercase client id>://auth`, Google
`com.googleusercontent.apps.<id prefix>:/oauth2redirect` (the client ID in reverse DNS notation).
"""

import re
import sys
import tomllib
from pathlib import Path

ALLOWED = {
    "google": {"client_id": str, "full_access": bool},
    "dropbox": {"app_key": str, "full_app_key": str},
    "microsoft": {"client_id": str, "full_access": bool},
}
ID = re.compile(r"^[A-Za-z0-9-]*$")
GOOGLE_ID = re.compile(r"^([a-z0-9-]+\.apps\.googleusercontent\.com)?$")


def google_scheme(client_id: str) -> str:
    """`123-abc.apps.googleusercontent.com` -> `com.googleusercontent.apps.123-abc`."""
    return ".".join(reversed(client_id.split(".")))


def xcode_settings(path: Path) -> int:
    """iOS build setting: the redirect scheme for authorization through the official Dropbox app
    (`db-<lowercase app key>`), passed to xcodebuild by the Makefile. Prints nothing without cloud-keys.toml or a Dropbox
    key, so the project's placeholder scheme applies."""
    if not path.exists():
        return 0
    dropbox = tomllib.loads(path.read_text(encoding="utf-8")).get("dropbox", {})
    settings = []
    for setting, key in (("KAKEY_DROPBOX_URL_SCHEME", "app_key"), ("KAKEY_DROPBOX_FULL_URL_SCHEME", "full_app_key")):
        value = str(dropbox.get(key, "")).strip()
        if value and ID.match(value):
            settings.append(f"{setting}=db-{value.lower()}")
    print(" ".join(settings))
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--xcode-settings":
        return xcode_settings(Path(sys.argv[2] if len(sys.argv) > 2 else "cloud-keys.toml"))
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "cloud-keys.toml")
    if not path.exists():
        print(f"No {path}: all OAuth providers are hidden; only WebDAV / Nextcloud are available. See cloud-keys.example.toml for a template.")
        return 0
    try:
        keys = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        print(f"{path} is malformed: {error}")
        return 1
    errors = []
    for section, fields in keys.items():
        if section not in ALLOWED:
            errors.append(f"unknown section [{section}]")
            continue
        for name, value in fields.items():
            expected = ALLOWED[section].get(name)
            if expected is None:
                errors.append(f"[{section}] unknown key {name}")
            elif not isinstance(value, expected):
                errors.append(f"[{section}] {name} must be of type {expected.__name__}")
            elif expected is str and section == "google":
                if not GOOGLE_ID.match(value.strip()):
                    errors.append(f"[google] {name} must look like <number>-<letters>.apps.googleusercontent.com")
            elif expected is str and not ID.match(value.strip()):
                errors.append(f"[{section}] {name} may contain only letters, digits and -")
    if errors:
        print("\n".join(errors))
        return 1

    dropbox = keys.get("dropbox", {})
    microsoft = keys.get("microsoft", {})
    google = keys.get("google", {})
    print("Callback URLs to register in each console:")
    shown = False
    for label, key in (("Dropbox (App folder)", dropbox.get("app_key", "")), ("Dropbox (Full Dropbox)", dropbox.get("full_app_key", ""))):
        if key.strip():
            print(f"  {label}: db-{key.strip().lower()}://2/token")
            shown = True
    client_id = microsoft.get("client_id", "").strip()
    if client_id:
        scope = "Files.ReadWrite.AppFolder" + (", Files.ReadWrite" if microsoft.get("full_access") else "")
        print(f"  Microsoft (Mobile and desktop applications): msal{client_id.lower()}://auth  (delegated permissions: offline_access, User.Read, {scope})")
        shown = True
    google_id = google.get("client_id", "").strip()
    if google_id:
        scope = "drive.file" + (", drive (restricted)" if google.get("full_access") else "")
        print(f"  Google (client type iOS, Bundle ID com.gicek.kakey; also used by Android): {google_scheme(google_id)}:/oauth2redirect  (scopes: {scope})")
        shown = True
    if not shown:
        print("  (no Dropbox / Microsoft / Google configured)")
    if dropbox.get("full_app_key", "").strip() and not dropbox.get("app_key", "").strip():
        print("Note: with full_app_key but no app_key, Dropbox is hidden (the default Kakey app folder access needs an App folder app).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
