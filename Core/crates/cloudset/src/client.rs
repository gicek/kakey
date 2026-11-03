use std::time::SystemTime;

use crate::connection::{Connection, ProviderKind};
use crate::entry::{Entry, File, Precondition};
use crate::error::CloudError;
use crate::http::Limits;
use crate::operation::BoxOperation;
use crate::operation::Ready;
use crate::path::RemotePath;
use crate::webdav::Dav;
use crate::{dropbox, gdrive, nextcloud, onedrive};

/// Request parameters from the caller. `user_agent` is also the name shown under Nextcloud's "Devices & sessions".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientConfig {
    pub user_agent: String,
    pub limits: Limits,
    /// Current time (the component never reads the system clock). When given, OAuth tokens are refreshed proactively
    /// before they expire; otherwise only after a 401.
    pub now: Option<SystemTime>,
}

impl ClientConfig {
    pub fn new(user_agent: impl Into<String>) -> Self {
        Self { user_agent: user_agent.into(), limits: Limits::default(), now: None }
    }

    pub fn with_now(mut self, now: SystemTime) -> Self {
        self.now = Some(now);
        self
    }
}

/// File operations on one connection. Each method returns an independent operation state machine; see
/// [`crate::Operation`].
#[derive(Clone, Debug)]
pub struct Client {
    connection: Connection,
    config: ClientConfig,
}

impl Client {
    pub fn new(connection: Connection, config: ClientConfig) -> Self {
        Self { connection, config }
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// The same config with another connection (composite operations continue with it after a sub-operation refreshed
    /// the connection).
    pub fn with_connection(&self, connection: Connection) -> Self {
        Self { connection, config: self.config.clone() }
    }

    fn dav(&self) -> Result<Dav, CloudError> {
        Dav::new(self.connection.clone(), self.config.clone())
    }

    /// Metadata of a file or directory; `None` if it does not exist.
    pub fn stat(&self, path: RemotePath) -> BoxOperation<Option<Entry>> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => dispatch(self.dav(), |dav| dav.stat(path)),
            ProviderKind::Dropbox => dropbox::stat(&self.connection, &self.config, path),
            ProviderKind::OneDrive => onedrive::stat(&self.connection, &self.config, path),
            ProviderKind::GoogleDrive => gdrive::stat(&self.connection, &self.config, path),
        }
    }

    /// Direct children of a directory, sorted by path; a missing directory reports `NotFound`.
    pub fn list(&self, dir: RemotePath) -> BoxOperation<Vec<Entry>> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => dispatch(self.dav(), |dav| dav.list(dir)),
            ProviderKind::Dropbox => dropbox::list(&self.connection, &self.config, dir),
            ProviderKind::OneDrive => onedrive::list(&self.connection, &self.config, dir),
            ProviderKind::GoogleDrive => gdrive::list(&self.connection, &self.config, dir),
        }
    }

    /// File contents with the metadata of the same version; `None` if it does not exist.
    pub fn read(&self, path: RemotePath) -> BoxOperation<Option<File>> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => dispatch(self.dav(), |dav| dav.read(path)),
            ProviderKind::Dropbox => dropbox::read(&self.connection, &self.config, path),
            ProviderKind::OneDrive => onedrive::read(&self.connection, &self.config, path),
            ProviderKind::GoogleDrive => gdrive::read(&self.connection, &self.config, path),
        }
    }

    /// Writes and returns the metadata after the write; an unmet precondition reports `PreconditionFailed`. A missing
    /// parent directory reports `NotFound` on WebDAV; Dropbox, OneDrive and Google Drive create it automatically.
    pub fn write(&self, path: RemotePath, data: Vec<u8>, precondition: Precondition) -> BoxOperation<Entry> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => dispatch(self.dav(), |dav| dav.write(path, data, precondition)),
            ProviderKind::Dropbox => dropbox::write(&self.connection, &self.config, path, data, precondition),
            ProviderKind::OneDrive => onedrive::write(&self.connection, &self.config, path, data, precondition),
            ProviderKind::GoogleDrive => gdrive::write(&self.connection, &self.config, path, data, precondition),
        }
    }

    /// Creates a directory; an existing one counts as success, a file with the same name reports `Forbidden`, and a
    /// missing parent reports `NotFound`.
    pub fn create_dir(&self, path: RemotePath) -> BoxOperation<()> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => dispatch(self.dav(), |dav| dav.create_dir(path)),
            ProviderKind::Dropbox => dropbox::create_dir(&self.connection, &self.config, path),
            ProviderKind::OneDrive => onedrive::create_dir(&self.connection, &self.config, path),
            ProviderKind::GoogleDrive => gdrive::create_dir(&self.connection, &self.config, path),
        }
    }

    /// Deletes a file or directory; a missing one counts as success.
    pub fn delete(&self, path: RemotePath) -> BoxOperation<()> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => dispatch(self.dav(), |dav| dav.delete(path)),
            ProviderKind::Dropbox => dropbox::delete(&self.connection, &self.config, path),
            ProviderKind::OneDrive => onedrive::delete(&self.connection, &self.config, path),
            ProviderKind::GoogleDrive => gdrive::delete_path(&self.connection, &self.config, path),
        }
    }

    /// Best-effort revocation of the server-side authorization: Nextcloud deletes the app password, Dropbox and Google
    /// revoke the token (on Google, the whole grant). WebDAV and OneDrive have no revocation endpoint (on OneDrive the user removes the app under "App access"
    /// at account.live.com).
    pub fn revoke(&self) -> BoxOperation<()> {
        match self.connection.provider() {
            ProviderKind::WebDav | ProviderKind::Nextcloud => nextcloud::revoke(&self.connection, &self.config),
            ProviderKind::Dropbox => dropbox::revoke(&self.connection, &self.config),
            ProviderKind::GoogleDrive => gdrive::revoke(&self.connection, &self.config),
            ProviderKind::OneDrive => Box::new(Ready::ok(())),
        }
    }
}

fn dispatch<T: Send + 'static>(dav: Result<Dav, CloudError>, run: impl FnOnce(Dav) -> BoxOperation<T>) -> BoxOperation<T> {
    match dav {
        Ok(dav) => run(dav),
        Err(error) => Box::new(Ready::err(error)),
    }
}
