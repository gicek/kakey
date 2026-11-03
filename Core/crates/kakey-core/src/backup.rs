//! Kakey backups on cloud storage backends (see docs/TECHNICAL.md): remote layout, metadata, the fetch and upload
//! composite operations, and the mapping from `cloudset` errors to localization keys. The protocol itself lives in the
//! generic `cloudset` component; only Kakey's conventions are here.
//!
//! The layout matches the folder backend: `vault.kakeyvault` (the encrypted envelope, verbatim) and
//! `vault.metadata.json` (device name and time, not sensitive) in the chosen directory. The envelope is written first,
//! then the metadata on a best-effort basis; missing or corrupt metadata does not affect sync decisions.

use std::fmt;
use std::time::SystemTime;

use cloudset::{
    BoxOperation, Client, CloudError, Connection, Done, Entry, File, HttpResponse, Operation, Precondition, Progress, RemotePath, Revision,
    Step, Subtask,
};
use serde::Deserialize;

use crate::json;
use crate::sync::RemoteVersion;

pub const VAULT_FILE_NAME: &str = "vault.kakeyvault";
pub const METADATA_FILE_NAME: &str = "vault.metadata.json";
/// Default directory name for the "Kakey folder" option and under the WebDAV root.
pub const DEFAULT_FOLDER: &str = "Kakey";

/// A fetched remote backup. `Debug` only prints the length.
#[derive(Clone, PartialEq, Eq)]
pub struct RemoteBackup {
    pub data: Vec<u8>,
    pub version: Option<RemoteVersion>,
    pub device_name: Option<String>,
}

impl fmt::Debug for RemoteBackup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteBackup")
            .field("len", &self.data.len())
            .field("version", &self.version)
            .field("device_name", &self.device_name)
            .finish()
    }
}

/// What the upload requires of the remote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UploadMode {
    /// The user explicitly chose to overwrite (manual backup, or keeping the local copy in a conflict).
    Overwrite,
    /// Write only if the remote is still the copy seen when the sync decision was made; `None` means there was no remote
    /// backup then. A remote with only a modification time and no ETag cannot be written conditionally and is overwritten.
    IfUnchanged(Option<RemoteVersion>),
}

impl UploadMode {
    fn precondition(&self) -> Precondition {
        match self {
            Self::Overwrite | Self::IfUnchanged(Some(RemoteVersion::ModifiedAt { .. })) => Precondition::None,
            Self::IfUnchanged(None) => Precondition::Absent,
            Self::IfUnchanged(Some(RemoteVersion::Revision { value })) => Precondition::Matches(Revision::new(value.clone())),
        }
    }
}

/// Contents of `vault.metadata.json`; field names match those written by the Apple folder backend.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackupMetadata {
    pub device_name: String,
    pub vault_updated_at: SystemTime,
    pub saved_at: SystemTime,
}

impl BackupMetadata {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::json!({
            "schemaVersion": 1,
            "deviceName": self.device_name,
            "vaultUpdatedAt": json::format_date(self.vault_updated_at),
            "savedAt": json::format_date(self.saved_at),
        })
        .to_string()
        .into_bytes()
    }

    /// Reads only the device name; returns `None` if unreadable.
    pub fn device_name(data: &[u8]) -> Option<String> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Partial {
            device_name: String,
        }
        let name = serde_json::from_slice::<Partial>(data).ok()?.device_name;
        let trimmed = name.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    }
}

/// Whether this remote directory can be used as the backup directory:
/// - It already has a Kakey backup (`vault.kakeyvault`): yes, regardless of other files; whether it can sync is decided
///   by the key check when linking ([`crate::sync`]).
/// - No backup: only an empty directory (ignoring hidden files starting with `.`), so backups do not land in unrelated
///   directories.
pub fn is_usable_folder<S: AsRef<str>>(names: &[S]) -> bool {
    let mut names = names.iter().map(AsRef::as_ref);
    names.clone().any(|name| name == VAULT_FILE_NAME) || names.all(|name| name.starts_with('.') || name == METADATA_FILE_NAME)
}

/// Whether this remote directory contains a Kakey backup: only such directories can be chosen when restoring. Names are
/// case-sensitive, matching [`is_usable_folder`].
pub fn folder_has_backup<S: AsRef<str>>(names: &[S]) -> bool {
    names.iter().any(|name| name.as_ref() == VAULT_FILE_NAME)
}

/// Version of a remote entry: the ETag / rev when present, otherwise the modification time.
pub fn version_of(entry: &Entry) -> Option<RemoteVersion> {
    match (&entry.revision, entry.modified_at) {
        (Some(revision), _) => Some(RemoteVersion::Revision { value: revision.as_str().to_owned() }),
        (None, Some(at)) => Some(RemoteVersion::ModifiedAt { at }),
        (None, None) => None,
    }
}

fn file_in(folder: &RemotePath, name: &str) -> Result<RemotePath, CloudError> {
    folder.join(name)
}

/// Shared by the composite operations: the current client (updated when a sub-operation refreshes the connection) and the
/// latest connection to hand back to the caller.
struct Session {
    client: Client,
    connection: Option<Connection>,
}

impl Session {
    fn client(&self) -> Client {
        match &self.connection {
            Some(connection) => self.client.with_connection(connection.clone()),
            None => self.client.clone(),
        }
    }

    fn done<T>(&mut self, value: T) -> Step<T> {
        Step::Done(Done { value, connection: self.connection.take() })
    }
}

/// Fetches the backup: `None` when the remote has no envelope.
pub fn fetch(client: Client, folder: RemotePath) -> BoxOperation<Option<RemoteBackup>> {
    Box::new(Fetch { session: Session { client, connection: None }, folder, state: FetchState::Start })
}

enum FetchState {
    Start,
    Vault(Subtask<Option<File>>),
    Metadata(Subtask<Option<File>>, File),
    Finished,
}

struct Fetch {
    session: Session,
    folder: RemotePath,
    state: FetchState,
}

impl Fetch {
    fn on_vault(
        &mut self,
        subtask: Subtask<Option<File>>,
        progress: Progress<Option<File>>,
    ) -> Result<Step<Option<RemoteBackup>>, CloudError> {
        match progress {
            Progress::Send(request) => {
                self.state = FetchState::Vault(subtask);
                Ok(Step::Send(request))
            }
            Progress::Finished(result) => match result? {
                None => Ok(self.session.done(None)),
                Some(file) => {
                    let operation = self.session.client().read(file_in(&self.folder, METADATA_FILE_NAME)?);
                    let (subtask, progress) = Subtask::start(operation, &mut self.session.connection);
                    self.on_metadata(subtask, progress, file)
                }
            },
        }
    }

    fn on_metadata(
        &mut self,
        subtask: Subtask<Option<File>>,
        progress: Progress<Option<File>>,
        vault: File,
    ) -> Result<Step<Option<RemoteBackup>>, CloudError> {
        match progress {
            Progress::Send(request) => {
                self.state = FetchState::Metadata(subtask, vault);
                Ok(Step::Send(request))
            }
            Progress::Finished(result) => {
                let device_name = result.ok().flatten().and_then(|metadata| BackupMetadata::device_name(&metadata.data));
                let version = version_of(&vault.entry);
                Ok(self.session.done(Some(RemoteBackup { data: vault.data, version, device_name })))
            }
        }
    }
}

impl Operation for Fetch {
    type Output = Option<RemoteBackup>;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<Option<RemoteBackup>>, CloudError> {
        match std::mem::replace(&mut self.state, FetchState::Finished) {
            FetchState::Start if response.is_none() => {
                let operation = self.session.client().read(file_in(&self.folder, VAULT_FILE_NAME)?);
                let (subtask, progress) = Subtask::start(operation, &mut self.session.connection);
                self.on_vault(subtask, progress)
            }
            FetchState::Vault(mut subtask) => {
                let progress = subtask.advance(response, &mut self.session.connection);
                self.on_vault(subtask, progress)
            }
            FetchState::Metadata(mut subtask, vault) => {
                let progress = subtask.advance(response, &mut self.session.connection);
                self.on_metadata(subtask, progress, vault)
            }
            FetchState::Start | FetchState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

/// Uploads the envelope and metadata and returns the remote version after the write. If the directory is missing, it is
/// created and the write retried once; an unmet precondition reports `PreconditionFailed`.
pub fn upload(
    client: Client,
    folder: RemotePath,
    data: Vec<u8>,
    metadata: &BackupMetadata,
    mode: &UploadMode,
) -> BoxOperation<Option<RemoteVersion>> {
    Box::new(Upload {
        session: Session { client, connection: None },
        folder,
        data,
        metadata: metadata.encode(),
        precondition: mode.precondition(),
        created_folder: false,
        state: UploadState::Start,
    })
}

enum UploadState {
    Start,
    Vault(Subtask<Entry>),
    Folder(Subtask<()>),
    Metadata(Subtask<Entry>, Entry),
    Finished,
}

struct Upload {
    session: Session,
    folder: RemotePath,
    data: Vec<u8>,
    metadata: Vec<u8>,
    precondition: Precondition,
    created_folder: bool,
    state: UploadState,
}

type UploadStep = Result<Step<Option<RemoteVersion>>, CloudError>;

impl Upload {
    fn write_vault(&mut self) -> UploadStep {
        let operation = self.session.client().write(file_in(&self.folder, VAULT_FILE_NAME)?, self.data.clone(), self.precondition.clone());
        let (subtask, progress) = Subtask::start(operation, &mut self.session.connection);
        self.on_vault(subtask, progress)
    }

    fn on_vault(&mut self, subtask: Subtask<Entry>, progress: Progress<Entry>) -> UploadStep {
        match progress {
            Progress::Send(request) => {
                self.state = UploadState::Vault(subtask);
                Ok(Step::Send(request))
            }
            Progress::Finished(Err(CloudError::NotFound)) if !self.created_folder => {
                self.created_folder = true;
                let operation = self.session.client().create_dir(self.folder.clone());
                let (subtask, progress) = Subtask::start(operation, &mut self.session.connection);
                self.on_folder(subtask, progress)
            }
            Progress::Finished(result) => {
                let entry = result?;
                let operation = self.session.client().write(
                    file_in(&self.folder, METADATA_FILE_NAME)?,
                    std::mem::take(&mut self.metadata),
                    Precondition::None,
                );
                let (subtask, progress) = Subtask::start(operation, &mut self.session.connection);
                self.on_metadata(subtask, progress, entry)
            }
        }
    }

    fn on_folder(&mut self, subtask: Subtask<()>, progress: Progress<()>) -> UploadStep {
        match progress {
            Progress::Send(request) => {
                self.state = UploadState::Folder(subtask);
                Ok(Step::Send(request))
            }
            Progress::Finished(result) => {
                result?;
                self.write_vault()
            }
        }
    }

    fn on_metadata(&mut self, subtask: Subtask<Entry>, progress: Progress<Entry>, vault: Entry) -> UploadStep {
        match progress {
            Progress::Send(request) => {
                self.state = UploadState::Metadata(subtask, vault);
                Ok(Step::Send(request))
            }
            // The metadata is only for display: a failed write does not affect the result of this upload.
            Progress::Finished(_) => Ok(self.session.done(version_of(&vault))),
        }
    }
}

impl Operation for Upload {
    type Output = Option<RemoteVersion>;

    fn advance(&mut self, response: Option<HttpResponse>) -> UploadStep {
        match std::mem::replace(&mut self.state, UploadState::Finished) {
            UploadState::Start if response.is_none() => self.write_vault(),
            UploadState::Vault(mut subtask) => {
                let progress = subtask.advance(response, &mut self.session.connection);
                self.on_vault(subtask, progress)
            }
            UploadState::Folder(mut subtask) => {
                let progress = subtask.advance(response, &mut self.session.connection);
                self.on_folder(subtask, progress)
            }
            UploadState::Metadata(mut subtask, vault) => {
                let progress = subtask.advance(response, &mut self.session.connection);
                self.on_metadata(subtask, progress, vault)
            }
            UploadState::Start | UploadState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

/// Localization key for a cloud storage error (a semantic String Catalog key; Android uses a resource of the same name).
/// `err.cloud.server` takes a status code argument.
pub fn l10n_key(error: &CloudError) -> &'static str {
    match error {
        CloudError::ReauthRequired => "err.cloud.reauth",
        CloudError::Forbidden => "err.cloud.forbidden",
        CloudError::NotFound => "err.cloud.not_found",
        CloudError::PreconditionFailed => "err.cloud.conflict",
        CloudError::QuotaExceeded => "err.cloud.quota",
        CloudError::RateLimited { .. } => "err.cloud.rate_limited",
        CloudError::Server { .. } => "err.cloud.server",
        CloudError::InvalidResponse(_) | CloudError::TooManyRedirects => "err.cloud.invalid_response",
        CloudError::TooLarge => "err.cloud.too_large",
        CloudError::InsecureRedirect => "err.cloud.insecure_redirect",
        CloudError::InsecureEndpoint => "err.cloud.insecure_address",
        CloudError::InvalidEndpoint(_) => "err.cloud.invalid_address",
        CloudError::InvalidPath => "err.cloud.invalid_path",
        CloudError::InvalidConnection => "err.cloud.invalid_connection",
        CloudError::AuthorizationDenied => "err.cloud.authorization_denied",
        CloudError::StateMismatch => "err.cloud.authorization_failed",
        CloudError::OutOfOrder => "err.cloud.internal",
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, UNIX_EPOCH};

    use cloudset::testing::{BASE, MemoryDav};
    use cloudset::{ClientConfig, Endpoint, Method, Transport, drive};

    use super::*;

    const AUTH: &str = "Basic YWxpY2U6cHc=";

    fn client() -> Client {
        let endpoint = Endpoint::parse(BASE, Transport::RequireHttps).unwrap();
        Client::new(Connection::webdav(endpoint, "alice".into(), "pw".into()), ClientConfig::new("Kakey-test"))
    }

    fn folder() -> RemotePath {
        RemotePath::parse(DEFAULT_FOLDER).unwrap()
    }

    fn metadata(device: &str) -> BackupMetadata {
        BackupMetadata {
            device_name: device.into(),
            vault_updated_at: UNIX_EPOCH + Duration::from_secs(1_800_000_000),
            saved_at: UNIX_EPOCH,
        }
    }

    fn run<T>(server: &mut MemoryDav, mut operation: BoxOperation<T>) -> Result<T, CloudError> {
        drive(operation.as_mut(), |request| server.handle(request)).map(|done| done.value)
    }

    fn upload_with(server: &mut MemoryDav, data: &[u8], mode: UploadMode) -> Result<Option<RemoteVersion>, CloudError> {
        run(server, upload(client(), folder(), data.to_vec(), &metadata("Mac"), &mode))
    }

    #[test]
    fn first_upload_creates_the_folder_then_fetch_round_trips() {
        let mut server = MemoryDav::new(AUTH);
        assert_eq!(run(&mut server, fetch(client(), folder())).unwrap(), None);

        let version = upload_with(&mut server, b"envelope", UploadMode::IfUnchanged(None)).unwrap();
        assert!(matches!(version, Some(RemoteVersion::Revision { .. })));
        let mkcols = server.requests.iter().filter(|r| r.method == Method::Mkcol).count();
        assert_eq!(mkcols, 1, "the missing directory is created once");

        let fetched = run(&mut server, fetch(client(), folder())).unwrap().unwrap();
        assert_eq!(fetched, RemoteBackup { data: b"envelope".to_vec(), version, device_name: Some("Mac".into()) });
        let stored = server.data("Kakey/vault.metadata.json").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&stored).unwrap();
        assert_eq!((json["schemaVersion"].as_i64(), json["vaultUpdatedAt"].as_str()), (Some(1), Some("2027-01-15T08:00:00Z")));

        let before = server.requests.len();
        upload_with(&mut server, b"second", UploadMode::IfUnchanged(fetched.version)).unwrap();
        assert!(!server.requests[before..].iter().any(|r| r.method == Method::Mkcol), "no MKCOL once the directory exists");
    }

    #[test]
    fn conditional_upload_detects_remote_changes() {
        let mut server = MemoryDav::new(AUTH);
        let first = upload_with(&mut server, b"one", UploadMode::IfUnchanged(None)).unwrap();
        assert_eq!(
            upload_with(&mut server, b"x", UploadMode::IfUnchanged(None)),
            Err(CloudError::PreconditionFailed),
            "the remote already has a backup"
        );

        server.put_external("Kakey/vault.kakeyvault", b"other device");
        assert_eq!(upload_with(&mut server, b"two", UploadMode::IfUnchanged(first)), Err(CloudError::PreconditionFailed));
        assert_eq!(server.data("Kakey/vault.kakeyvault").unwrap(), b"other device");

        upload_with(&mut server, b"mine", UploadMode::Overwrite).unwrap();
        assert_eq!(server.data("Kakey/vault.kakeyvault").unwrap(), b"mine");
    }

    #[test]
    fn missing_or_broken_metadata_is_tolerated() {
        let mut server = MemoryDav::new(AUTH);
        server.mkdir_external("Kakey");
        server.put_external("Kakey/vault.kakeyvault", b"v");
        assert_eq!(run(&mut server, fetch(client(), folder())).unwrap().unwrap().device_name, None);
        server.put_external("Kakey/vault.metadata.json", b"{not json");
        assert_eq!(run(&mut server, fetch(client(), folder())).unwrap().unwrap().device_name, None);
        server.put_external("Kakey/vault.metadata.json", br#"{"deviceName":"  "}"#);
        assert_eq!(run(&mut server, fetch(client(), folder())).unwrap().unwrap().device_name, None);
    }

    #[test]
    fn errors_propagate() {
        let mut server = MemoryDav::new("Basic other");
        assert_eq!(run(&mut server, fetch(client(), folder())), Err(CloudError::ReauthRequired));
        assert_eq!(upload_with(&mut server, b"x", UploadMode::Overwrite), Err(CloudError::ReauthRequired));
        let nested = RemotePath::parse("a/b").unwrap();
        let mut server = MemoryDav::new(AUTH);
        let result = run(&mut server, upload(client(), nested, b"x".to_vec(), &metadata("Mac"), &UploadMode::Overwrite));
        assert_eq!(result, Err(CloudError::NotFound), "only one directory level is created; a missing parent is an error");
    }

    #[test]
    fn usable_folders_hold_only_hidden_files_and_kakey_backups() {
        assert!(is_usable_folder::<&str>(&[]));
        assert!(is_usable_folder(&[".DS_Store", "._x", ".sync"]));
        assert!(is_usable_folder(&[VAULT_FILE_NAME, METADATA_FILE_NAME, ".DS_Store"]), "already has a Kakey backup");
        assert!(!is_usable_folder(&["notes.txt"]));
        assert!(is_usable_folder(&[VAULT_FILE_NAME, "photos", "notes.txt"]), "other files do not matter when a backup exists");
        assert!(!is_usable_folder(&["Vault.kakeyvault"]), "different case is not a Kakey file");
    }

    #[test]
    fn only_folders_with_a_vault_file_have_a_backup() {
        assert!(folder_has_backup(&[VAULT_FILE_NAME, "notes.txt"]));
        assert!(!folder_has_backup::<&str>(&[]), "an empty directory can hold backups but has none to restore");
        assert!(!folder_has_backup(&[METADATA_FILE_NAME, ".DS_Store"]), "metadata alone is not a backup");
        assert!(!folder_has_backup(&["Vault.kakeyvault"]));
    }

    #[test]
    fn upload_mode_preconditions() {
        let at = RemoteVersion::ModifiedAt { at: UNIX_EPOCH };
        assert_eq!(UploadMode::Overwrite.precondition(), Precondition::None);
        assert_eq!(UploadMode::IfUnchanged(None).precondition(), Precondition::Absent);
        assert_eq!(UploadMode::IfUnchanged(Some(at)).precondition(), Precondition::None);
        let rev = RemoteVersion::Revision { value: "\"1\"".into() };
        assert_eq!(UploadMode::IfUnchanged(Some(rev)).precondition(), Precondition::Matches(Revision::new("\"1\"")));
    }

    #[test]
    fn every_error_has_a_key() {
        let errors = [
            CloudError::ReauthRequired,
            CloudError::Forbidden,
            CloudError::NotFound,
            CloudError::PreconditionFailed,
            CloudError::QuotaExceeded,
            CloudError::RateLimited { retry_after: None },
            CloudError::Server { status: 500 },
            CloudError::InvalidResponse("x"),
            CloudError::TooLarge,
            CloudError::InsecureRedirect,
            CloudError::TooManyRedirects,
            CloudError::InsecureEndpoint,
            CloudError::InvalidEndpoint("x"),
            CloudError::InvalidPath,
            CloudError::InvalidConnection,
            CloudError::AuthorizationDenied,
            CloudError::StateMismatch,
            CloudError::OutOfOrder,
        ];
        for error in errors {
            assert!(l10n_key(&error).starts_with("err.cloud."));
        }
    }
}
