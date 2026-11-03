//! Kakey platform-independent core.
//!
//! Holds only pure logic that never touches the system: account model and deduplication, Base32 / TOTP, otpauth and
//! Google migration code parsing, user categories, vault envelope encryption, export and import, Authenticator import,
//! search, password strength, and sync conflict detection. File IO, Keychain / Keystore, biometrics, clipboard, and UI
//! state stay on each platform.
//!
//! Behavior matches the original Swift implementation on Mac and is pinned case by case by the vectors in `Core/golden/`.
//! Before changing any observable behavior, update the golden files first and document it in `Core/docs/TECHNICAL.md`.

pub mod authenticator;
pub mod backup;
pub mod base32;
pub mod canonical;
pub mod category;
pub mod dedup;
mod json;
pub mod merge;
pub mod model;
pub mod otpauth;
pub mod password;
pub mod search;
pub mod sync;
pub mod totp;
pub mod vault;

pub use model::{Account, Placeholders, TotpAlgorithm};
