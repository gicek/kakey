//! FFI boundary for cloud storage backups (see docs/TECHNICAL.md). The protocol lives in `cloudset`, Kakey's layout in
//! `kakey_core::backup`.
//!
//! - The "connection" the platform holds is an opaque blob (`cloudset::Connection::to_bytes`) stored as is in the
//!   Keychain / Keystore. It is passed in on every call and wrapped in `Zeroizing` as soon as it enters the core. When the
//!   connection changes during an operation (a token refresh), `Done` carries the new blob back.
//! - Each operation is a [`CoreCloudOperation`]: the platform calls `advance` in a loop, executing each returned request
//!   and passing the response back, until `Done`. Executor contract: no following redirects, no cookies, no cache, and
//!   read at most [`cloud_max_body_bytes`] + 1 bytes of a response body.
//! - Errors are [`CoreCloudError`]; text keys come from [`cloud_error_l10n_key`] (the table is in
//!   `kakey_core::backup::l10n_key`).

use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use cloudset::nextcloud::{self, LoginPoll};
use cloudset::oauth::{self, Authorization};
use cloudset::{
    AccessScope, BoxOperation, CertificatePin, Client, ClientConfig, CloudError, Connection, Endpoint, HttpRequest, HttpResponse, Limits,
    OAuthClient, PinnedCertificate, ProviderKind, RemotePath, Step, Transport,
};
use kakey_core::backup::{self, BackupMetadata, UploadMode};
use kakey_core::sync::RemoteVersion;
use zeroize::Zeroizing;

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHttpHeader {
    pub name: String,
    pub value: String,
}

/// A request built by the core for the platform to execute as is. `Debug` omits header values and the body.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<CoreHttpHeader>,
    pub body: Vec<u8>,
    /// Server certificate confirmed by the user (docs/SECURITY.md; SHA-256 of the leaf certificate DER, 32
    /// bytes). The executor runs system validation first and sends normally if it passes. If system validation fails,
    /// only a certificate with exactly this fingerprint is accepted (constant-time comparison; the host name is no longer
    /// checked in that case), and a mismatch reports "certificate changed". When empty, a system validation failure
    /// reports "certificate not trusted" and carries back the fingerprint of the server's leaf certificate.
    #[uniffi(default = None)]
    pub pinned_certificate: Option<Vec<u8>>,
}

impl fmt::Debug for CoreHttpRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreHttpRequest").field("method", &self.method).field("body_len", &self.body.len()).finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHttpResponse {
    pub status: u16,
    pub headers: Vec<CoreHttpHeader>,
    pub body: Vec<u8>,
}

impl fmt::Debug for CoreHttpResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreHttpResponse").field("status", &self.status).field("body_len", &self.body.len()).finish()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreCloudProvider {
    WebDav,
    Nextcloud,
    Dropbox,
    OneDrive,
    GoogleDrive,
}

impl From<ProviderKind> for CoreCloudProvider {
    fn from(value: ProviderKind) -> Self {
        match value {
            ProviderKind::WebDav => Self::WebDav,
            ProviderKind::Nextcloud => Self::Nextcloud,
            ProviderKind::Dropbox => Self::Dropbox,
            ProviderKind::OneDrive => Self::OneDrive,
            ProviderKind::GoogleDrive => Self::GoogleDrive,
        }
    }
}

/// Access scope of an OAuth provider (docs/TECHNICAL.md). With the app folder, backups go straight into the root
/// of that folder (the directory is passed as an empty string) and no directory is chosen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreCloudAccess {
    AppFolder,
    Full,
}

impl From<AccessScope> for CoreCloudAccess {
    fn from(value: AccessScope) -> Self {
        match value {
            AccessScope::AppFolder => Self::AppFolder,
            AccessScope::Full => Self::Full,
        }
    }
}

/// Connection details for display (no passwords or tokens).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreCloudConnectionInfo {
    pub provider: CoreCloudProvider,
    /// WebDAV / Nextcloud address; empty for OAuth providers.
    pub endpoint: String,
    pub host: String,
    pub username: String,
    /// False for plain HTTP; the UI keeps showing "unencrypted connection".
    pub is_secure: bool,
    /// A certificate confirmed by the user is pinned (docs/SECURITY.md); the UI keeps showing "certificate not
    /// verified".
    pub has_pinned_certificate: bool,
    /// Access scope of an OAuth provider; empty for WebDAV / Nextcloud.
    pub access: Option<CoreCloudAccess>,
}

/// OAuth providers available in this build (those with keys configured in `cloud-keys.toml`).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreOAuthProviderOption {
    pub provider: CoreCloudProvider,
    /// Whether "entire drive" can also be chosen (the matching key or switch is configured).
    pub full_access_available: bool,
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreRemoteBackup {
    pub data: Vec<u8>,
    pub version: Option<RemoteVersion>,
    pub device_name: Option<String>,
}

impl fmt::Debug for CoreRemoteBackup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreRemoteBackup").field("len", &self.data.len()).field("version", &self.version).finish()
    }
}

/// One item in the remote directory browser. `path` is relative to the storage root, split on `/`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreCloudEntry {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreUploadMode {
    /// The user explicitly chose to overwrite the remote.
    Overwrite,
    /// Write only if the remote is still the copy seen when deciding; `expected` of `None` means there was no remote
    /// backup then.
    IfUnchanged { expected: Option<RemoteVersion> },
}

/// Result of an operation. Each constructor yields only one of these; see each function's docs.
#[derive(uniffi::Enum)]
pub enum CoreCloudOutcome {
    Backup {
        backup: Option<CoreRemoteBackup>,
    },
    Uploaded {
        version: Option<RemoteVersion>,
    },
    Entries {
        entries: Vec<CoreCloudEntry>,
    },
    Completed,
    LoginStarted {
        login_url: String,
        login: Arc<CoreNextcloudLogin>,
    },
    LoginPolled {
        connection: Option<Vec<u8>>,
    },
    /// OAuth sign-in finished: the new connection blob.
    Connected {
        connection: Vec<u8>,
    },
}

#[derive(uniffi::Enum)]
pub enum CoreCloudStep {
    Send {
        request: CoreHttpRequest,
    },
    /// When `connection` is non-empty, it replaces the connection the platform stored.
    Done {
        outcome: CoreCloudOutcome,
        connection: Option<Vec<u8>>,
    },
}

/// Cloud storage errors. Transport failures (offline, timeout, TLS) are not here; the platform reports those itself.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreCloudError {
    #[error("authentication required")]
    ReauthRequired,
    #[error("access denied")]
    Forbidden,
    #[error("not found")]
    NotFound,
    /// A conditional write was rejected: the remote changed after the decision.
    #[error("remote changed")]
    Conflict,
    #[error("quota exceeded")]
    QuotaExceeded,
    #[error("rate limited")]
    RateLimited { retry_after_seconds: Option<u64> },
    #[error("server error {status}")]
    Server { status: u16 },
    #[error("invalid response")]
    InvalidResponse,
    #[error("response too large")]
    TooLarge,
    #[error("insecure redirect")]
    InsecureRedirect,
    /// The address is `http://` and the caller did not allow it; the UI asks the user to confirm.
    #[error("plain http not allowed")]
    InsecureAddress,
    #[error("invalid address")]
    InvalidAddress,
    #[error("invalid path")]
    InvalidPath,
    #[error("invalid stored connection")]
    InvalidConnection,
    /// The user denied authorization on the sign-in page, or the provider returned an error.
    #[error("authorization denied")]
    AuthorizationDenied,
    /// The callback does not match this sign-in (mismatched `state`, etc.) and was discarded; sign in again.
    #[error("authorization failed")]
    AuthorizationFailed,
    /// Programming errors such as driving operations out of order.
    #[error("internal error")]
    Internal,
}

impl From<CloudError> for CoreCloudError {
    fn from(value: CloudError) -> Self {
        match value {
            CloudError::ReauthRequired => Self::ReauthRequired,
            CloudError::Forbidden => Self::Forbidden,
            CloudError::NotFound => Self::NotFound,
            CloudError::PreconditionFailed => Self::Conflict,
            CloudError::QuotaExceeded => Self::QuotaExceeded,
            CloudError::RateLimited { retry_after } => Self::RateLimited { retry_after_seconds: retry_after.map(|d| d.as_secs()) },
            CloudError::Server { status } => Self::Server { status },
            CloudError::InvalidResponse(_) | CloudError::TooManyRedirects => Self::InvalidResponse,
            CloudError::TooLarge => Self::TooLarge,
            CloudError::InsecureRedirect => Self::InsecureRedirect,
            CloudError::InsecureEndpoint => Self::InsecureAddress,
            CloudError::InvalidEndpoint(_) => Self::InvalidAddress,
            CloudError::InvalidPath => Self::InvalidPath,
            CloudError::InvalidConnection => Self::InvalidConnection,
            CloudError::AuthorizationDenied => Self::AuthorizationDenied,
            CloudError::StateMismatch => Self::AuthorizationFailed,
            CloudError::OutOfOrder => Self::Internal,
        }
    }
}

impl CoreCloudError {
    /// Maps back to a representative `CloudError` to look up the key, so the table is maintained only once, in
    /// `kakey_core::backup`.
    fn l10n_key(&self) -> &'static str {
        let representative = match self {
            Self::ReauthRequired => CloudError::ReauthRequired,
            Self::Forbidden => CloudError::Forbidden,
            Self::NotFound => CloudError::NotFound,
            Self::Conflict => CloudError::PreconditionFailed,
            Self::QuotaExceeded => CloudError::QuotaExceeded,
            Self::RateLimited { .. } => CloudError::RateLimited { retry_after: None },
            Self::Server { status } => CloudError::Server { status: *status },
            Self::InvalidResponse => CloudError::InvalidResponse(""),
            Self::TooLarge => CloudError::TooLarge,
            Self::InsecureRedirect => CloudError::InsecureRedirect,
            Self::InsecureAddress => CloudError::InsecureEndpoint,
            Self::InvalidAddress => CloudError::InvalidEndpoint(""),
            Self::InvalidPath => CloudError::InvalidPath,
            Self::InvalidConnection => CloudError::InvalidConnection,
            Self::AuthorizationDenied => CloudError::AuthorizationDenied,
            Self::AuthorizationFailed => CloudError::StateMismatch,
            Self::Internal => CloudError::OutOfOrder,
        };
        backup::l10n_key(&representative)
    }
}

/// Localization key for an error; the text for `Server` takes one integer argument (the HTTP status code).
#[uniffi::export(name = "core_cloud_error_l10n_key")]
pub fn cloud_error_l10n_key(error: CoreCloudError) -> String {
    error.l10n_key().to_owned()
}

/// Maximum response body bytes the executor reads; when exceeded, it hands back one extra byte and the core reports
/// `TooLarge`.
#[uniffi::export(name = "core_cloud_max_body_bytes")]
pub fn cloud_max_body_bytes() -> u64 {
    Limits::default().max_body_bytes as u64
}

/// A cloud storage operation in progress. Pass `None` to the first `advance`, then the response to the previous request;
/// do not call it again after `Done` or an error.
#[derive(uniffi::Object)]
pub struct CoreCloudOperation {
    inner: Mutex<BoxOperation<CoreCloudOutcome>>,
    /// Requests to the origin of the pinned certificate carry it (docs/SECURITY.md).
    pin: Option<CertificatePin>,
}

impl CoreCloudOperation {
    fn wrap(operation: BoxOperation<CoreCloudOutcome>, pin: Option<CertificatePin>) -> Arc<Self> {
        Arc::new(Self { inner: Mutex::new(operation), pin })
    }

    fn request(&self, request: HttpRequest) -> CoreHttpRequest {
        let pinned_certificate =
            self.pin.as_ref().filter(|pin| pin.applies_to(&request.url)).map(|pin| pin.certificate().as_bytes().to_vec());
        CoreHttpRequest { pinned_certificate, ..request.into() }
    }
}

#[uniffi::export]
impl CoreCloudOperation {
    pub fn advance(&self, response: Option<CoreHttpResponse>) -> Result<CoreCloudStep, CoreCloudError> {
        let mut operation = self.inner.lock().map_err(|_| CoreCloudError::Internal)?;
        let response = response.map(|r| HttpResponse {
            status: r.status,
            headers: r.headers.into_iter().map(|h| (h.name, h.value)).collect(),
            body: r.body,
        });
        Ok(match operation.advance(response)? {
            Step::Send(request) => CoreCloudStep::Send { request: self.request(request) },
            Step::Done(done) => CoreCloudStep::Done { outcome: done.value, connection: done.connection.map(|c| c.to_bytes().to_vec()) },
        })
    }
}

impl From<HttpRequest> for CoreHttpRequest {
    fn from(request: HttpRequest) -> Self {
        Self {
            method: request.method.as_str().to_owned(),
            url: request.url,
            headers: request.headers.into_iter().map(|(name, value)| CoreHttpHeader { name, value }).collect(),
            body: request.body,
            pinned_certificate: None,
        }
    }
}

/// Poll credentials for Nextcloud sign-in (opaque; the platform only passes them back to [`nextcloud_poll_login`]).
#[derive(uniffi::Object)]
pub struct CoreNextcloudLogin {
    poll: LoginPoll,
    /// Server certificate confirmed when sign-in started: poll requests carry it, and the resulting connection pins it.
    pin: Option<CertificatePin>,
}

/// The system clock is read only here: OAuth tokens are refreshed before expiry based on it (a wrong clock costs at most
/// one extra 401 -> refresh).
fn config(user_agent: String) -> ClientConfig {
    ClientConfig::new(user_agent).with_now(SystemTime::now())
}

fn connection(bytes: Vec<u8>) -> Result<Connection, CoreCloudError> {
    let bytes = Zeroizing::new(bytes);
    Ok(Connection::from_bytes(&bytes)?)
}

fn client(connection_bytes: Vec<u8>, user_agent: String) -> Result<Client, CoreCloudError> {
    Ok(Client::new(connection(connection_bytes)?, config(user_agent)))
}

fn path(text: &str) -> Result<RemotePath, CoreCloudError> {
    Ok(RemotePath::parse(text)?)
}

fn transport(allow_insecure_http: bool) -> Transport {
    if allow_insecure_http { Transport::AllowInsecureHttp } else { Transport::RequireHttps }
}

fn pinned_certificate(bytes: Option<Vec<u8>>) -> Result<Option<PinnedCertificate>, CoreCloudError> {
    Ok(bytes.map(|bytes| PinnedCertificate::from_slice(&bytes)).transpose()?)
}

/// Operations on a connection: requests run with the connection's pinned certificate, if any.
fn wrap(client: &Client, operation: BoxOperation<CoreCloudOutcome>) -> Arc<CoreCloudOperation> {
    CoreCloudOperation::wrap(operation, client.connection().certificate_pin())
}

/// Completes the scheme of a server address typed by the user: without `scheme://`, IP addresses get `http://` and domain
/// names get `https://`. The WebDAV and Nextcloud forms call this before submitting and use the completed address to
/// decide whether plain HTTP must be confirmed first.
#[uniffi::export(name = "core_cloud_complete_address")]
pub fn cloud_complete_address(input: String) -> String {
    Endpoint::complete_address(&input)
}

/// Validates a WebDAV address and account and builds the connection blob. Pass `allow_insecure_http` = true only after
/// the user confirmed plain HTTP; pass `trusted_certificate` only after the user checked and confirmed the server
/// certificate fingerprint (docs/SECURITY.md, 32 bytes), and only for `https://` addresses.
#[uniffi::export(name = "core_cloud_webdav_connection")]
pub fn cloud_webdav_connection(
    url: String,
    username: String,
    password: String,
    allow_insecure_http: bool,
    trusted_certificate: Option<Vec<u8>>,
) -> Result<Vec<u8>, CoreCloudError> {
    let password = Zeroizing::new(password);
    let endpoint = Endpoint::parse(&url, transport(allow_insecure_http))?;
    let mut connection = Connection::webdav(endpoint, username.trim().to_owned(), password.to_string());
    if let Some(certificate) = pinned_certificate(trusted_certificate)? {
        connection = connection.with_pinned_certificate(certificate)?;
    }
    Ok(connection.to_bytes().to_vec())
}

#[uniffi::export(name = "core_cloud_connection_info")]
pub fn cloud_connection_info(connection_bytes: Vec<u8>) -> Result<CoreCloudConnectionInfo, CoreCloudError> {
    let connection = connection(connection_bytes)?;
    let shown = connection.server().or(connection.endpoint());
    Ok(CoreCloudConnectionInfo {
        provider: connection.provider().into(),
        endpoint: shown.map(|endpoint| endpoint.as_str().to_owned()).unwrap_or_default(),
        host: connection.host().to_owned(),
        username: connection.username().to_owned(),
        is_secure: connection.is_secure(),
        has_pinned_certificate: connection.certificate_pin().is_some(),
        access: connection.access_scope().map(Into::into),
    })
}

/// Fetches the backup in `folder`. Result: `Backup` (empty when the remote has no envelope).
#[uniffi::export(name = "core_cloud_fetch_backup")]
pub fn cloud_fetch_backup(connection: Vec<u8>, folder: String, user_agent: String) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
    let client = client(connection, user_agent)?;
    let operation = backup::fetch(client.clone(), path(&folder)?);
    Ok(wrap(
        &client,
        cloudset::map(operation, |backup| CoreCloudOutcome::Backup {
            backup: backup.map(|b| CoreRemoteBackup { data: b.data, version: b.version, device_name: b.device_name }),
        }),
    ))
}

/// Uploads the local envelope and metadata. Result: `Uploaded`; reports `Conflict` if the remote changed after the
/// decision.
#[uniffi::export(name = "core_cloud_upload_backup")]
#[allow(clippy::too_many_arguments)] // The three metadata fields are passed separately so platforms need no extra record type for one call
pub fn cloud_upload_backup(
    connection: Vec<u8>,
    folder: String,
    data: Vec<u8>,
    device_name: String,
    vault_updated_at: SystemTime,
    saved_at: SystemTime,
    mode: CoreUploadMode,
    user_agent: String,
) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
    let metadata = BackupMetadata { device_name, vault_updated_at, saved_at };
    let mode = match mode {
        CoreUploadMode::Overwrite => UploadMode::Overwrite,
        CoreUploadMode::IfUnchanged { expected } => UploadMode::IfUnchanged(expected),
    };
    let client = client(connection, user_agent)?;
    let operation = backup::upload(client.clone(), path(&folder)?, data, &metadata, &mode);
    Ok(wrap(&client, cloudset::map(operation, |version| CoreCloudOutcome::Uploaded { version })))
}

/// Lists the direct children of a directory (remote directory browser). Result: `Entries`, sorted by path.
#[uniffi::export(name = "core_cloud_list")]
pub fn cloud_list(connection: Vec<u8>, dir: String, user_agent: String) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
    let client = client(connection, user_agent)?;
    let operation = client.list(path(&dir)?);
    Ok(wrap(
        &client,
        cloudset::map(operation, |entries| CoreCloudOutcome::Entries {
            entries: entries
                .into_iter()
                .map(|entry| CoreCloudEntry {
                    name: entry.path.name().unwrap_or_default().to_owned(),
                    path: entry.path.to_string(),
                    is_dir: entry.is_dir,
                })
                .collect(),
        }),
    ))
}

/// Whether a listed directory can be used as the backup directory: only hidden files and Kakey backup files (see
/// `kakey_core::backup::is_usable_folder`). `names` are the names of all children (files and directories) returned by
/// [`cloud_list`].
#[uniffi::export(name = "core_cloud_is_usable_folder")]
pub fn cloud_is_usable_folder(names: Vec<String>) -> bool {
    backup::is_usable_folder(&names)
}

/// Whether a listed directory contains a Kakey backup (see `kakey_core::backup::folder_has_backup`): used when choosing a
/// directory to restore from.
#[uniffi::export(name = "core_cloud_folder_has_backup")]
pub fn cloud_folder_has_backup(names: Vec<String>) -> bool {
    backup::folder_has_backup(&names)
}

/// Creates a directory (an existing one counts as success). Result: `Completed`.
#[uniffi::export(name = "core_cloud_create_folder")]
pub fn cloud_create_folder(connection: Vec<u8>, folder: String, user_agent: String) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
    let client = client(connection, user_agent)?;
    let operation = client.create_dir(path(&folder)?);
    Ok(wrap(&client, cloudset::map(operation, |()| CoreCloudOutcome::Completed)))
}

/// Best-effort revocation of the server-side authorization on disconnect. Result: `Completed`.
#[uniffi::export(name = "core_cloud_revoke")]
pub fn cloud_revoke(connection: Vec<u8>, user_agent: String) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
    let client = client(connection, user_agent)?;
    let operation = client.revoke();
    Ok(wrap(&client, cloudset::map(operation, |()| CoreCloudOutcome::Completed)))
}

/// First step of Nextcloud sign-in. Result: `LoginStarted`; the platform opens `login_url` in the system browser, then
/// calls [`nextcloud_poll_login`] periodically. `trusted_certificate` works as in [`cloud_webdav_connection`]: later
/// polls and the resulting connection all pin this certificate.
#[uniffi::export(name = "core_nextcloud_begin_login")]
pub fn nextcloud_begin_login(
    server: String,
    allow_insecure_http: bool,
    trusted_certificate: Option<Vec<u8>>,
    user_agent: String,
) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
    let server = Endpoint::parse(&server, transport(allow_insecure_http))?;
    let pin = pinned_certificate(trusted_certificate)?.map(|certificate| CertificatePin::new(&server, certificate)).transpose()?;
    let operation = nextcloud::begin_login(&server, &config(user_agent));
    let login_pin = pin.clone();
    Ok(CoreCloudOperation::wrap(
        cloudset::map(operation, move |flow| CoreCloudOutcome::LoginStarted {
            login_url: flow.login_url,
            login: Arc::new(CoreNextcloudLogin { poll: flow.poll, pin: login_pin.clone() }),
        }),
        pin,
    ))
}

/// Polls for the sign-in result. Result: `LoginPolled`; `connection` is empty until the user finishes authorizing, and the
/// platform calls again a few seconds later.
#[uniffi::export(name = "core_nextcloud_poll_login")]
pub fn nextcloud_poll_login(login: Arc<CoreNextcloudLogin>, user_agent: String) -> Arc<CoreCloudOperation> {
    let operation = nextcloud::poll_login(&login.poll, &config(user_agent));
    let certificate = login.pin.as_ref().map(CertificatePin::certificate);
    CoreCloudOperation::wrap(
        cloudset::map(operation, move |connection| CoreCloudOutcome::LoginPolled {
            // If the pin cannot be applied (the server returned a non-https address), do not pin: later requests use system
            // validation only and fail if it fails, so nothing is relaxed.
            connection: connection.map(|c| match certificate {
                Some(certificate) => c.clone().with_pinned_certificate(certificate).unwrap_or(c).to_bytes().to_vec(),
                None => c.to_bytes().to_vec(),
            }),
        }),
        login.pin.clone(),
    )
}

// MARK: - OAuth (Dropbox, OneDrive, Google Drive)

mod keys {
    include!(concat!(env!("OUT_DIR"), "/cloud_keys.rs"));
}

/// The folder Kakey keeps in My Drive under the `drive.file` scope; Drive has no app folder of its own
/// (docs/TECHNICAL.md).
const GOOGLE_APP_FOLDER: &str = "Kakey";

/// Google's callback for an iOS-type client (used by all three platforms, docs/TECHNICAL.md): the client ID in reverse
/// DNS notation as the scheme (`123-abc.apps.googleusercontent.com` -> `com.googleusercontent.apps.123-abc`) and
/// `:/oauth2redirect`.
fn google_redirect(client_id: &str) -> String {
    let reversed: Vec<&str> = client_id.split('.').rev().collect();
    format!("{}:/oauth2redirect", reversed.join(".").to_ascii_lowercase())
}

/// Public client for a provider and access scope; `None` when no key is configured. Callback URLs follow each provider's
/// convention: Dropbox `db-<app key>://2/token`, Microsoft `msal<client id>://auth`, Google
/// `com.googleusercontent.apps.<id>:/oauth2redirect` (`make cloud-config` prints the values to register).
fn oauth_client(provider: ProviderKind, access: AccessScope) -> Option<OAuthClient> {
    let client = match (provider, access) {
        (ProviderKind::Dropbox, AccessScope::AppFolder) => {
            (keys::DROPBOX_APP_KEY, format!("db-{}://2/token", keys::DROPBOX_APP_KEY.to_ascii_lowercase()))
        }
        (ProviderKind::Dropbox, AccessScope::Full) => {
            (keys::DROPBOX_FULL_APP_KEY, format!("db-{}://2/token", keys::DROPBOX_FULL_APP_KEY.to_ascii_lowercase()))
        }
        (ProviderKind::OneDrive, AccessScope::AppFolder) => {
            (keys::MICROSOFT_CLIENT_ID, format!("msal{}://auth", keys::MICROSOFT_CLIENT_ID.to_ascii_lowercase()))
        }
        (ProviderKind::OneDrive, AccessScope::Full) if keys::MICROSOFT_FULL_ACCESS => {
            (keys::MICROSOFT_CLIENT_ID, format!("msal{}://auth", keys::MICROSOFT_CLIENT_ID.to_ascii_lowercase()))
        }
        (ProviderKind::GoogleDrive, AccessScope::AppFolder) => (keys::GOOGLE_CLIENT_ID, google_redirect(keys::GOOGLE_CLIENT_ID)),
        (ProviderKind::GoogleDrive, AccessScope::Full) if keys::GOOGLE_FULL_ACCESS => {
            (keys::GOOGLE_CLIENT_ID, google_redirect(keys::GOOGLE_CLIENT_ID))
        }
        _ => return None,
    };
    let (client_id, redirect_uri) = client;
    (!client_id.is_empty()).then(|| OAuthClient::new(client_id, redirect_uri).with_folder_name(GOOGLE_APP_FOLDER))
}

fn provider_kind(provider: CoreCloudProvider) -> ProviderKind {
    match provider {
        CoreCloudProvider::WebDav => ProviderKind::WebDav,
        CoreCloudProvider::Nextcloud => ProviderKind::Nextcloud,
        CoreCloudProvider::Dropbox => ProviderKind::Dropbox,
        CoreCloudProvider::OneDrive => ProviderKind::OneDrive,
        CoreCloudProvider::GoogleDrive => ProviderKind::GoogleDrive,
    }
}

fn access_scope(access: CoreCloudAccess) -> AccessScope {
    match access {
        CoreCloudAccess::AppFolder => AccessScope::AppFolder,
        CoreCloudAccess::Full => AccessScope::Full,
    }
}

/// A provider is listed only when its preferred access scope (the first of `access_scopes`, the app folder where there is
/// one) has a key configured; the UI defaults to the preferred scope.
fn available_providers(client: impl Fn(ProviderKind, AccessScope) -> Option<OAuthClient>) -> Vec<CoreOAuthProviderOption> {
    [ProviderKind::Dropbox, ProviderKind::OneDrive, ProviderKind::GoogleDrive]
        .into_iter()
        .filter(|&provider| provider.access_scopes().first().is_some_and(|&preferred| client(provider, preferred).is_some()))
        .map(|provider| CoreOAuthProviderOption {
            provider: provider.into(),
            full_access_available: client(provider, AccessScope::Full).is_some(),
        })
        .collect()
}

/// OAuth providers with keys configured in this build; those without are hidden in the UI.
#[uniffi::export(name = "core_cloud_oauth_providers")]
pub fn cloud_oauth_providers() -> Vec<CoreOAuthProviderOption> {
    available_providers(oauth_client)
}

/// Authorization parameters handed to the official Dropbox Android app (the extras of
/// `com.dropbox.android.AUTHENTICATE_V2`).
#[derive(uniffi::Record)]
pub struct CoreDropboxAppRequest {
    pub app_key: String,
    pub auth_state: String,
    pub query_params: String,
}

/// An OAuth sign-in in progress. The platform opens `url()` in the system authentication session, waits for a callback
/// with the `callback_scheme()` scheme, then passes the full callback URL to `complete`. The session object lives only in
/// memory and is never persisted; to abandon sign-in, just drop it.
#[derive(uniffi::Object)]
pub struct CoreOAuthSession {
    authorization: Authorization,
}

#[uniffi::export]
impl CoreOAuthSession {
    pub fn url(&self) -> String {
        self.authorization.url().to_owned()
    }

    pub fn callback_scheme(&self) -> String {
        self.authorization.callback_scheme()
    }

    /// Whether a callback belongs to this sign-in (both URL and `state` match), without consuming it.
    pub fn accepts(&self, callback_url: String) -> bool {
        self.authorization.accepts(&callback_url)
    }

    /// Parameters for authorizing through the official Dropbox Android app; `None` if the provider is not Dropbox.
    pub fn dropbox_app_request(&self) -> Option<CoreDropboxAppRequest> {
        self.authorization.dropbox_app_request().map(|request| CoreDropboxAppRequest {
            app_key: request.app_key,
            auth_state: request.auth_state,
            query_params: request.query_params,
        })
    }

    /// Whether a result returned by the Dropbox app belongs to this sign-in (`state` matches), without consuming it.
    pub fn accepts_dropbox_app(&self, state: String) -> bool {
        self.authorization.accepts_dropbox_app(&state)
    }

    /// iOS: URL that launches the Dropbox app (`scheme` is `dbapi-2` or `dbapi-8-emm`); `None` if the provider is not
    /// Dropbox.
    pub fn dropbox_app_url(&self, scheme: String) -> Option<String> {
        self.authorization.dropbox_app_url(&scheme)
    }

    /// iOS: whether the app's return URL belongs to this sign-in (including cancellation in the app), without consuming
    /// it.
    pub fn accepts_dropbox_app_callback(&self, callback_url: String) -> bool {
        self.authorization.accepts_dropbox_app_callback(&callback_url)
    }

    /// iOS: validates the app's return URL, exchanges tokens, and looks up the account name. Result: `Connected`. A
    /// cancellation reports `AuthorizationDenied`.
    pub fn complete_dropbox_app_callback(
        &self,
        callback_url: String,
        user_agent: String,
    ) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
        let operation = self.authorization.complete_dropbox_app_callback(&callback_url, &config(user_agent))?;
        // OAuth providers use system validation only; no certificate is pinned
        Ok(CoreCloudOperation::wrap(
            cloudset::map(operation, |connection| CoreCloudOutcome::Connected { connection: connection.to_bytes().to_vec() }),
            None,
        ))
    }

    /// Validates the result returned by the Dropbox app (`token_type` is the intent's `ACCESS_TOKEN`, the authorization
    /// code is `ACCESS_SECRET`), exchanges tokens, and looks up the account name. Result: `Connected`. A mismatched `state`
    /// reports `AuthorizationFailed` and a user cancellation `AuthorizationDenied`; neither sends a request.
    pub fn complete_dropbox_app(
        &self,
        token_type: String,
        code: String,
        state: String,
        user_agent: String,
    ) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
        let code = Zeroizing::new(code);
        let operation = self.authorization.complete_dropbox_app(&token_type, &code, &state, &config(user_agent))?;
        // OAuth providers use system validation only; no certificate is pinned
        Ok(CoreCloudOperation::wrap(
            cloudset::map(operation, |connection| CoreCloudOutcome::Connected { connection: connection.to_bytes().to_vec() }),
            None,
        ))
    }

    /// Validates the callback, exchanges tokens, and looks up the account name. Result: `Connected`. A callback that does
    /// not belong to this sign-in reports `AuthorizationFailed`, and a user denial `AuthorizationDenied`; neither sends a
    /// request.
    pub fn complete(&self, callback_url: String, user_agent: String) -> Result<Arc<CoreCloudOperation>, CoreCloudError> {
        let operation = self.authorization.complete(&callback_url, &config(user_agent))?;
        // OAuth providers use system validation only; no certificate is pinned
        Ok(CoreCloudOperation::wrap(
            cloudset::map(operation, |connection| CoreCloudOutcome::Connected { connection: connection.to_bytes().to_vec() }),
            None,
        ))
    }
}

fn begin_oauth(client: Option<OAuthClient>, provider: ProviderKind, access: AccessScope) -> Result<Arc<CoreOAuthSession>, CoreCloudError> {
    let client = client.ok_or(CoreCloudError::InvalidConnection)?;
    let mut random = Zeroizing::new([0u8; 64]);
    getrandom::fill(random.as_mut()).map_err(|_| CoreCloudError::Internal)?;
    let authorization = oauth::begin(provider, access, client, &random)?;
    Ok(Arc::new(CoreOAuthSession { authorization }))
}

/// Starts OAuth sign-in (random bytes for PKCE and `state` come from the system CSPRNG). Reports `InvalidConnection` when
/// the provider or access scope has no key configured.
#[uniffi::export(name = "core_cloud_begin_oauth")]
pub fn cloud_begin_oauth(provider: CoreCloudProvider, access: CoreCloudAccess) -> Result<Arc<CoreOAuthSession>, CoreCloudError> {
    let (provider, access) = (provider_kind(provider), access_scope(access));
    begin_oauth(oauth_client(provider, access), provider, access)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, UNIX_EPOCH};

    use cloudset::Method;
    use cloudset::testing::oauth::{FakeProvider, GOOGLE_APP_FOLDER as TEST_GOOGLE_FOLDER, MemoryCloud};
    use cloudset::testing::{BASE, MemoryDav};

    use super::*;

    fn run(server: &mut MemoryDav, operation: &CoreCloudOperation) -> Result<(CoreCloudOutcome, Option<Vec<u8>>), CoreCloudError> {
        run_with(|request| server.handle(request), operation)
    }

    fn run_with(
        mut handle: impl FnMut(HttpRequest) -> HttpResponse,
        operation: &CoreCloudOperation,
    ) -> Result<(CoreCloudOutcome, Option<Vec<u8>>), CoreCloudError> {
        let mut response = None;
        loop {
            match operation.advance(response.take())? {
                CoreCloudStep::Send { request } => {
                    let method = match request.method.as_str() {
                        "GET" => Method::Get,
                        "PUT" => Method::Put,
                        "PATCH" => Method::Patch,
                        "PROPFIND" => Method::Propfind,
                        "MKCOL" => Method::Mkcol,
                        "DELETE" => Method::Delete,
                        _ => Method::Post,
                    };
                    let reply = handle(HttpRequest {
                        method,
                        url: request.url,
                        headers: request.headers.into_iter().map(|h| (h.name, h.value)).collect(),
                        body: request.body,
                    });
                    response = Some(CoreHttpResponse {
                        status: reply.status,
                        headers: reply.headers.into_iter().map(|(name, value)| CoreHttpHeader { name, value }).collect(),
                        body: reply.body,
                    });
                }
                CoreCloudStep::Done { outcome, connection } => return Ok((outcome, connection)),
            }
        }
    }

    fn test_client(provider: ProviderKind, access: AccessScope) -> Option<OAuthClient> {
        let id = match (provider, access) {
            (ProviderKind::Dropbox, AccessScope::AppFolder) => "AppKey1",
            (ProviderKind::OneDrive, _) => "00000000-aaaa-bbbb-cccc-000000000000",
            (ProviderKind::GoogleDrive, AccessScope::AppFolder) => "123-abc.apps.googleusercontent.com",
            _ => return None,
        };
        let redirect = match provider {
            ProviderKind::Dropbox => format!("db-{}://2/token", id.to_ascii_lowercase()),
            ProviderKind::OneDrive => format!("msal{}://auth", id.to_ascii_lowercase()),
            _ => google_redirect(id),
        };
        Some(OAuthClient::new(id, redirect).with_folder_name(TEST_GOOGLE_FOLDER))
    }

    #[test]
    fn google_redirect_reverses_the_client_id() {
        assert_eq!(google_redirect("123-abc.apps.googleusercontent.com"), "com.googleusercontent.apps.123-abc:/oauth2redirect");
    }

    /// Google Drive through the boundary: sign-in, then a backup lands in the app folder in My Drive.
    #[test]
    fn google_drive_backup_lands_in_the_app_folder() {
        let mut server = MemoryCloud::new(FakeProvider::GoogleDrive);
        let session =
            begin_oauth(test_client(ProviderKind::GoogleDrive, AccessScope::AppFolder), ProviderKind::GoogleDrive, AccessScope::AppFolder)
                .unwrap();
        assert_eq!(session.callback_scheme(), "com.googleusercontent.apps.123-abc");
        let callback = server.authorize(&session.url());
        assert!(session.accepts(callback.clone()));
        let complete = session.complete(callback, "t".into()).unwrap();
        let CoreCloudOutcome::Connected { connection } = run_with(|request| server.handle(request), &complete).unwrap().0 else {
            panic!("expected Connected")
        };
        let info = cloud_connection_info(connection.clone()).unwrap();
        assert_eq!(
            (info.provider, info.host.as_str(), info.username.as_str(), info.access),
            (CoreCloudProvider::GoogleDrive, "drive.google.com", "alice@gmail.com", Some(CoreCloudAccess::AppFolder))
        );
        let at = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let upload = cloud_upload_backup(
            connection.clone(),
            String::new(),
            b"sealed".to_vec(),
            "Pixel".into(),
            at,
            at,
            CoreUploadMode::IfUnchanged { expected: None },
            "t".into(),
        )
        .unwrap();
        run_with(|request| server.handle(request), &upload).unwrap();
        assert_eq!(server.data(&format!("{TEST_GOOGLE_FOLDER}/vault.kakeyvault")).as_deref(), Some(&b"sealed"[..]));
        let fetch = cloud_fetch_backup(connection, String::new(), "t".into()).unwrap();
        let CoreCloudOutcome::Backup { backup: Some(backup) } = run_with(|request| server.handle(request), &fetch).unwrap().0 else {
            panic!("expected Backup")
        };
        assert_eq!((backup.data.as_slice(), backup.device_name.as_deref()), (&b"sealed"[..], Some("Pixel")));
    }

    #[test]
    fn oauth_providers_follow_the_configured_keys() {
        // `cargo test` does not pass KAKEY_CLOUD_CONFIG: there are no OAuth providers, and starting sign-in fails immediately
        assert!(cloud_oauth_providers().is_empty());
        assert_eq!(
            cloud_begin_oauth(CoreCloudProvider::Dropbox, CoreCloudAccess::AppFolder).err(),
            Some(CoreCloudError::InvalidConnection)
        );
        assert_eq!(
            available_providers(test_client),
            [
                CoreOAuthProviderOption { provider: CoreCloudProvider::Dropbox, full_access_available: false },
                CoreOAuthProviderOption { provider: CoreCloudProvider::OneDrive, full_access_available: true },
                CoreOAuthProviderOption { provider: CoreCloudProvider::GoogleDrive, full_access_available: false },
            ]
        );
    }

    #[test]
    fn oauth_sign_in_and_backup_through_the_boundary() {
        let mut server = MemoryCloud::new(FakeProvider::Dropbox);
        let session =
            begin_oauth(test_client(ProviderKind::Dropbox, AccessScope::AppFolder), ProviderKind::Dropbox, AccessScope::AppFolder).unwrap();
        assert_eq!(session.callback_scheme(), "db-appkey1");
        assert!(!session.accepts("db-appkey1://2/token?code=x&state=forged".into()));
        let callback = server.authorize(&session.url());
        assert_eq!(
            session.complete("db-appkey1://2/token?code=x&state=forged".into(), "t".into()).err(),
            Some(CoreCloudError::AuthorizationFailed)
        );
        let denied =
            callback.split('?').next().unwrap().to_owned() + "?error=access_denied&state=" + callback.split("state=").nth(1).unwrap();
        assert_eq!(session.complete(denied, "t".into()).err(), Some(CoreCloudError::AuthorizationDenied));

        let complete = session.complete(callback, "Kakey-test".into()).unwrap();
        let CoreCloudOutcome::Connected { connection } = run_with(|request| server.handle(request), &complete).unwrap().0 else {
            panic!("expected Connected")
        };
        let info = cloud_connection_info(connection.clone()).unwrap();
        assert_eq!(
            (info.provider, info.host.as_str(), info.username.as_str(), info.is_secure, info.access, info.endpoint.as_str()),
            (CoreCloudProvider::Dropbox, "dropbox.com", "alice@example.com", true, Some(CoreCloudAccess::AppFolder), "")
        );

        // App folder: the backup goes straight into its root
        let at = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let upload = cloud_upload_backup(
            connection.clone(),
            String::new(),
            b"sealed".to_vec(),
            "Mac".into(),
            at,
            at,
            CoreUploadMode::IfUnchanged { expected: None },
            "t".into(),
        )
        .unwrap();
        run_with(|request| server.handle(request), &upload).unwrap();
        assert_eq!(server.data(&server.storage_path("vault.kakeyvault")).as_deref(), Some(&b"sealed"[..]));
        assert!(!server.exists("vault.kakeyvault"), "written only inside the app folder");

        // Token expired: the operation refreshes internally and hands the new connection back to the platform to store
        server.expire_access_token();
        let fetch = cloud_fetch_backup(connection, String::new(), "t".into()).unwrap();
        let (outcome, refreshed) = run_with(|request| server.handle(request), &fetch).unwrap();
        let CoreCloudOutcome::Backup { backup: Some(backup) } = outcome else { panic!("expected Backup") };
        assert_eq!((backup.data.as_slice(), backup.device_name.as_deref()), (&b"sealed"[..], Some("Mac")));
        assert!(refreshed.is_some());
        assert_eq!(cloud_error_l10n_key(CoreCloudError::AuthorizationDenied), "err.cloud.authorization_denied");
    }

    #[test]
    fn upload_fetch_and_conflict_through_the_boundary() {
        let mut server = MemoryDav::new("Basic YWxpY2U6cHc=");
        let connection = cloud_webdav_connection(BASE.into(), " alice ".into(), "pw".into(), false, None).unwrap();
        let info = cloud_connection_info(connection.clone()).unwrap();
        assert_eq!(
            (info.provider, info.host.as_str(), info.username.as_str(), info.is_secure),
            (CoreCloudProvider::WebDav, "dav.example.com", "alice", true)
        );

        let at = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let upload = |data: &[u8], mode: CoreUploadMode| {
            cloud_upload_backup(connection.clone(), "Kakey".into(), data.to_vec(), "Mac".into(), at, at, mode, "Kakey-test".into()).unwrap()
        };
        let (outcome, updated) = run(&mut server, &upload(b"one", CoreUploadMode::IfUnchanged { expected: None })).unwrap();
        assert!(updated.is_none());
        let CoreCloudOutcome::Uploaded { version } = outcome else { panic!("expected Uploaded") };

        let fetch = cloud_fetch_backup(connection.clone(), "Kakey".into(), "Kakey-test".into()).unwrap();
        let CoreCloudOutcome::Backup { backup: Some(backup) } = run(&mut server, &fetch).unwrap().0 else { panic!("expected Backup") };
        assert_eq!((backup.data.as_slice(), &backup.version, backup.device_name.as_deref()), (&b"one"[..], &version, Some("Mac")));

        server.put_external("Kakey/vault.kakeyvault", b"other");
        assert_eq!(
            run(&mut server, &upload(b"two", CoreUploadMode::IfUnchanged { expected: version })).err(),
            Some(CoreCloudError::Conflict)
        );

        let list = cloud_list(connection.clone(), "Kakey".into(), "t".into()).unwrap();
        let CoreCloudOutcome::Entries { entries } = run(&mut server, &list).unwrap().0 else { panic!("expected Entries") };
        assert_eq!(entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["vault.kakeyvault", "vault.metadata.json"]);

        let done = fetch.advance(None);
        assert_eq!(done.err(), Some(CoreCloudError::Internal), "advancing after completion is a programming error");
    }

    #[test]
    fn pinned_certificate_rides_on_requests_to_its_server() {
        let pin = vec![0x5a; 32];
        let connection = cloud_webdav_connection(BASE.into(), "a".into(), "b".into(), false, Some(pin.clone())).unwrap();
        assert!(cloud_connection_info(connection.clone()).unwrap().has_pinned_certificate);
        let list = cloud_list(connection, "Kakey".into(), "t".into()).unwrap();
        let Ok(CoreCloudStep::Send { request }) = list.advance(None) else { panic!("expected a request") };
        assert_eq!(request.pinned_certificate, Some(pin.clone()));

        let plain = cloud_webdav_connection(BASE.into(), "a".into(), "b".into(), false, None).unwrap();
        assert!(!cloud_connection_info(plain.clone()).unwrap().has_pinned_certificate);
        let Ok(CoreCloudStep::Send { request }) = cloud_list(plain, String::new(), "t".into()).unwrap().advance(None) else {
            panic!("expected a request")
        };
        assert_eq!(request.pinned_certificate, None);

        assert_eq!(
            cloud_webdav_connection("http://nas.local/".into(), "a".into(), "b".into(), true, Some(pin.clone())).unwrap_err(),
            CoreCloudError::InvalidAddress,
            "plain HTTP has no certificate to pin"
        );
        assert_eq!(
            cloud_webdav_connection(BASE.into(), "a".into(), "b".into(), false, Some(vec![0; 20])).unwrap_err(),
            CoreCloudError::InvalidAddress
        );

        let Ok(CoreCloudStep::Send { request }) =
            nextcloud_begin_login("https://cloud.example.com/".into(), false, Some(pin.clone()), "t".into()).unwrap().advance(None)
        else {
            panic!("expected a request")
        };
        assert_eq!(request.pinned_certificate, Some(pin));
    }

    #[test]
    fn validates_inputs_and_maps_errors() {
        assert_eq!(
            cloud_webdav_connection("http://nas.local/".into(), "a".into(), "b".into(), false, None).unwrap_err(),
            CoreCloudError::InsecureAddress
        );
        assert!(cloud_webdav_connection("http://nas.local/".into(), "a".into(), "b".into(), true, None).is_ok());
        assert_eq!(
            cloud_webdav_connection("nas.local".into(), "a".into(), "b".into(), true, None).unwrap_err(),
            CoreCloudError::InvalidAddress
        );
        assert_eq!(cloud_connection_info(b"garbage".to_vec()).unwrap_err(), CoreCloudError::InvalidConnection);
        let connection = cloud_webdav_connection(BASE.into(), "a".into(), "b".into(), false, None).unwrap();
        assert_eq!(cloud_fetch_backup(connection, "../x".into(), "t".into()).err(), Some(CoreCloudError::InvalidPath));
        assert_eq!(cloud_error_l10n_key(CoreCloudError::Server { status: 500 }), "err.cloud.server");
        assert_eq!(cloud_error_l10n_key(CoreCloudError::InsecureAddress), "err.cloud.insecure_address");
        assert_eq!(cloud_max_body_bytes(), 16 * 1024 * 1024);
    }
}
