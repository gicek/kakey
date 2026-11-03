# cloudset changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic versioning.

## [Unreleased]

### Added

- OAuth 2.0 authorization code + PKCE S256 (public client): `oauth::begin` derives the verifier and `state` from random
  bytes supplied by the caller; `Authorization::complete` checks the callback (URL, with an empty path equal to `/` when
  there is a host; `state` compared in constant time; `error`) before exchanging the code and looking up the account
  name; `accepts` only checks. The scope is sent to the token endpoint only where the provider requires it (Microsoft).
  New errors `CloudError::StateMismatch` / `AuthorizationDenied`.
- A shared driver for OAuth operations: adds the bearer token, refreshes before expiry (`ClientConfig::now`) or after a
  401 and replays once, sends credentials only to the provider's API origin, and hands a refreshed connection back in
  `Done.connection`.
- `AccessScope` (app folder / whole drive), listed in order of preference by `ProviderKind::access_scopes()`.
- Dropbox (API v2): `stat`, `list` (paged), `read`, `write` (three preconditions), `create_dir`, `delete`, `revoke`.
  Authorization through the official Dropbox app: `Authorization::dropbox_app_request` / `complete_dropbox_app` (Android
  app-to-app protocol) and `dropbox_app_url` / `complete_dropbox_app_callback` (iOS URL scheme protocol, accepting both
  `oauth_code` and `oauth_token=oauth2code:` callbacks).
- OneDrive (Microsoft Graph): `stat`, `list` (paged), `read`, `write` (three preconditions), `create_dir`, `delete`.
  Both scopes request `User.Read` and the account name comes from `/me`, since `/me/drive` returns 403 under the app
  folder scope.
- Google Drive (Drive API v3): `ProviderKind::GoogleDrive` with `stat`, `list` (paged), `read`, `write` (all three
  preconditions), `create_dir`, `delete` and `revoke`. Paths resolve one segment at a time from the root; among items
  with the same name the oldest (creation time, then ID) wins everywhere, listings included. Conditional writes are
  emulated (Drive v3 has none): `Matches` checks `headRevisionId` before uploading and the revision list afterwards, and
  puts an overtaken writer's revision back on top before reporting `PreconditionFailed`; `Absent` looks the name up again
  after creating and the newer of two concurrent files is deleted by its writer. Folders created on the way are
  deduplicated the same way. New files are a single `multipart/related` upload. Sign-in checks the scopes actually
  granted: without the Drive scope it reports `AuthorizationDenied`. The account name comes from Drive's `about`.
- `OAuthClient` (`OAuthClient::new` / `with_folder_name`): `folder_name` is the app folder for providers that have none of
  their own; Google Drive's `drive.file` scope keeps it as a visible folder in the root of My Drive, created on first
  access. Stored in the connection as `appFolder`, required exactly for Google Drive with the app folder scope.
- `Method::Patch`.
- `Endpoint::complete_address`: adds `http://` (IPv4, bracketed IPv6) or `https://` to addresses typed without a scheme.
- Pinned certificates: `PinnedCertificate` (SHA-256 of the leaf certificate DER), `CertificatePin::applies_to`,
  `Connection::with_pinned_certificate` / `certificate_pin`; only WebDAV / Nextcloud with all-`https://` addresses, and the
  serialized `pinnedCertificate` field makes any other connection `InvalidConnection`.
- `testing::oauth::MemoryCloud`: in-memory Dropbox / OneDrive / Google Drive with authorization pages and token endpoints,
  isolating the access scopes like the real services (Google Drive as an ID-based store with duplicate names,
  `drive.file` visibility, revisions and multipart uploads), plus `Races` to simulate another device writing at the wrong
  moment; `golden/oauth.json` with the real response formats of all three.

### Changed

- `Connection` gained OAuth connections (a flat table validated per `provider`; WebDAV / Nextcloud fields unchanged);
  `endpoint()` now returns an `Option`; new `host()`, `is_secure()`, `access_scope()`.
- The manifest no longer inherits workspace fields, so the crate builds outside a host workspace.

## 0.1.0 (2026-10-28)

### Added

- Sans-IO operation state machines (`Operation` / `Step` / `Done`) and the synchronous driver `drive`.
- Plain-data HTTP model, same-origin redirect following (never downgrading), response size limits, mapping of status
  codes to `CloudError`; redacted `Debug` output.
- `RemotePath` (rejects empty segments, `.` / `..`, control characters), `Endpoint` (checks scheme, host, user info and
  query; plain HTTP must be allowed explicitly), `Connection` (opaque versioned serialization; passwords are zeroized).
- WebDAV: `stat`, `list`, `read` (`PROPFIND` + conditional `GET`, retried on concurrent changes), `write` (conditional
  `PUT` + `PROPFIND`; weak ETags fall back to comparing before writing), `create_dir`, `delete`; safe multistatus parsing.
- Composition helpers: `map` (change the result type), `Subtask` / `Progress` (sub-operation errors go back to the
  composer, connection updates propagate upwards), `Client::with_connection`.
- `testing` feature: the in-memory WebDAV server `cloudset::testing::MemoryDav`, so callers can drive the real state
  machines in their tests.
- `CloudError::InsecureEndpoint`: a plain HTTP address that was not allowed, distinct from other address errors (so a UI
  can ask the user to confirm).
- `create_dir`: an `MKCOL` 405 is only treated as "exists" after confirming the folder is there, otherwise `Forbidden`
  (many servers also answer 405 without permission); `testing::MemoryDav::mkcol_forbidden_in` simulates such servers.
- Nextcloud: Login Flow v2 (`begin_login` / `poll_login`, looking up the user ID for the WebDAV address) and revocation of
  the app password.
