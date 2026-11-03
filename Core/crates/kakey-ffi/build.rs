//! Reads the developer keys at build time (see docs/DEVELOPMENT.md). When `KAKEY_CLOUD_CONFIG` points to a
//! `cloud-keys.toml`, that file is read; when it is unset or empty, no OAuth provider is compiled in (so `cargo test` does
//! not depend on local keys). A malformed file fails the build. These are all public client IDs, not secrets; the output
//! goes to `OUT_DIR/cloud_keys.rs`, never into the source tree.

use std::path::Path;
use std::{env, fs};

use serde::Deserialize;

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Keys {
    #[serde(default)]
    google: Google,
    #[serde(default)]
    dropbox: Dropbox,
    #[serde(default)]
    microsoft: Microsoft,
}

/// One client of type "iOS" serves all three platforms: Google no longer allows custom URI scheme callbacks on Android
/// clients (docs/TECHNICAL.md).
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Google {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    full_access: bool,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Dropbox {
    #[serde(default)]
    app_key: String,
    #[serde(default)]
    full_app_key: String,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Microsoft {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    full_access: bool,
}

/// IDs are spliced into the callback URL scheme, so only letters, digits, and `-` are allowed.
fn checked(field: &str, value: &str) -> String {
    let value = value.trim();
    if !value.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        panic!("cloud-keys.toml: {field} may only contain letters, digits, and -");
    }
    value.to_owned()
}

/// A Google client ID is `<project number>-<hash>.apps.googleusercontent.com`; reversed, it becomes the callback scheme.
fn checked_google(value: &str) -> String {
    let value = value.trim();
    let prefix = value.strip_suffix(".apps.googleusercontent.com");
    if !value.is_empty()
        && !prefix
            .is_some_and(|prefix| !prefix.is_empty() && prefix.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'))
    {
        panic!("cloud-keys.toml: google.client_id must look like <number>-<letters>.apps.googleusercontent.com");
    }
    value.to_owned()
}

fn main() {
    println!("cargo:rerun-if-env-changed=KAKEY_CLOUD_CONFIG");
    let keys = match env::var("KAKEY_CLOUD_CONFIG").ok().filter(|path| !path.trim().is_empty()) {
        Some(path) => {
            println!("cargo:rerun-if-changed={path}");
            let text = fs::read_to_string(Path::new(&path)).unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
            toml::from_str::<Keys>(&text).unwrap_or_else(|error| panic!("{path} is malformed: {error}"))
        }
        None => Keys::default(),
    };
    let dropbox_app = checked("dropbox.app_key", &keys.dropbox.app_key);
    let dropbox_full = checked("dropbox.full_app_key", &keys.dropbox.full_app_key);
    let microsoft = checked("microsoft.client_id", &keys.microsoft.client_id);
    let microsoft_full = keys.microsoft.full_access && !microsoft.is_empty();
    let google = checked_google(&keys.google.client_id);
    let google_full = keys.google.full_access && !google.is_empty();
    let generated = format!(
        "pub(crate) const DROPBOX_APP_KEY: &str = {dropbox_app:?};\n\
         pub(crate) const DROPBOX_FULL_APP_KEY: &str = {dropbox_full:?};\n\
         pub(crate) const MICROSOFT_CLIENT_ID: &str = {microsoft:?};\n\
         pub(crate) const MICROSOFT_FULL_ACCESS: bool = {microsoft_full};\n\
         pub(crate) const GOOGLE_CLIENT_ID: &str = {google:?};\n\
         pub(crate) const GOOGLE_FULL_ACCESS: bool = {google_full};\n"
    );
    let out = Path::new(&env::var("OUT_DIR").expect("OUT_DIR")).join("cloud_keys.rs");
    fs::write(out, generated).expect("write cloud_keys.rs");
}
