//! cloudset: a sans-IO cloud storage client.
//!
//! The component only builds HTTP requests, parses responses, and advances state machines; transport, keychain storage,
//! and browser sign-in are up to the caller. That way one protocol implementation can be driven from any language and any
//! HTTP stack, and tested fully deterministically. See [`Operation`] and the README for usage.
//!
//! Independence: no dependency on caller business logic or on any FFI framework; no file reads, no environment
//! variables, no system clock.

mod authorized;
mod client;
mod connection;
mod dropbox;
mod entry;
mod error;
mod gdrive;
mod http;
mod multistatus;
pub mod nextcloud;
pub mod oauth;
mod onedrive;
mod operation;
mod path;
mod providers;
#[cfg(feature = "testing")]
pub mod testing;
mod webdav;

pub use client::{Client, ClientConfig};
pub use connection::{AccessScope, CertificatePin, Connection, Endpoint, PinnedCertificate, ProviderKind, Transport};
pub use entry::{Entry, File, Precondition, Revision};
pub use error::CloudError;
pub use http::{HttpRequest, HttpResponse, Limits, Method};
pub use oauth::{Authorization, DropboxAppRequest, OAuthClient};
pub use operation::{BoxOperation, Done, Operation, Progress, Step, Subtask, drive, map};
pub use path::RemotePath;
