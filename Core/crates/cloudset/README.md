# cloudset

A sans-IO cloud storage client. The crate only builds HTTP requests, parses responses and advances state machines; the
transport, keychain storage and browser sign-in belong to the caller. One protocol implementation can therefore be driven
from any language and any HTTP stack, and its tests are fully deterministic, with no network.

Supported: WebDAV (RFC 4918), Nextcloud (Login Flow v2 + WebDAV), Dropbox (API v2), OneDrive (Microsoft Graph) and Google
Drive (Drive API v3). The last three sign in with OAuth 2.0 + PKCE as a public client.

## Usage

```rust
use cloudset::{Client, ClientConfig, Connection, Endpoint, Precondition, RemotePath, Step, Transport};

let endpoint = Endpoint::parse("https://dav.example.com/remote.php/webdav/", Transport::RequireHttps)?;
let client = Client::new(Connection::webdav(endpoint, "alice".into(), password), ClientConfig::new("MyApp/1.0"));

let mut operation = client.write(RemotePath::parse("Backups/data.bin")?, bytes, Precondition::Absent);
let mut response = None;
let entry = loop {
    match operation.advance(response.take())? {
        Step::Send(request) => response = Some(my_http_stack.execute(request)), // send as is: no redirects, no cookies
        Step::Done(done) => break done.value,
    }
};
```

- Every file operation returns its own `Operation` state machine: `stat`, `list`, `read`, `write`, `create_dir`, `delete`,
  `revoke`.
- When `Done.connection` is set, the connection changed (a refreshed token, for example); replace the stored copy.
- `Connection::to_bytes` / `from_bytes` is an opaque, versioned blob; store it in the system keychain as is.
- Rust callers can run an operation to completion with `cloudset::drive(operation, |request| response)`.

## Access scopes

OAuth providers support two scopes (`AccessScope`), both fully implemented and tested; the caller chooses:

- `AppFolder`: read and write only the folder the provider gives the app (Dropbox "Apps › <app name>" for an App folder
  app, OneDrive `special/approot`, and on Google Drive a visible folder named `OAuthClient::folder_name` in the root of My
  Drive under the `drive.file` scope). Paths are relative to that folder, and a leaked token reaches nothing else.
- `Full`: the whole drive; paths are relative to its root and the user should pick a folder.

`ProviderKind::access_scopes()` lists the scopes in order of preference. Default to the first: where an app folder exists it
is `AppFolder`, which can be used directly as the working directory without browsing the remote; offer `Full` to users who
want their own folder layout. WebDAV and Nextcloud have no app folder and only offer `Full`.

Each provider asks for scopes differently. Dropbox decides by app type (App folder and Full Dropbox are two apps with two
app keys, so pass the matching `OAuthClient` per scope). OneDrive uses one client with different scopes
(`Files.ReadWrite.AppFolder` / `Files.ReadWrite`, sent again on refresh), plus `User.Read` for the account email, since
`/me/drive` returns 403 under the app folder scope. Google uses one client with `drive.file` / `drive` and reads the account
email from Drive's `about`; a grant without the Drive scope (the user can untick it) fails as `AuthorizationDenied`.

## Executor contract

- Send each `HttpRequest` as is (method, URL, headers, body). **Do not follow redirects**: hand 3xx responses back; the
  crate only follows same-origin redirects and never downgrades from HTTPS to HTTP. No cookies, no cache.
- Read at most `Limits::max_body_bytes` (+ 1) of a response body; the crate reports `TooLarge` beyond that.
- Transport failures (offline, timeout, TLS) are reported by the caller; they never enter the crate.
- **Pinned certificates**: `Connection::certificate_pin()` returns the server certificate the user confirmed (SHA-256 of
  the leaf certificate DER) and the origin it applies to; `CertificatePin::applies_to(url)` tells whether a request is
  covered. For covered requests run system validation first and proceed if it passes; otherwise accept only a certificate
  with exactly that fingerprint (constant-time comparison; the host name is not checked in that case) and report "certificate
  changed" on a mismatch. Other requests use system validation alone.
- Never log URL query strings, headers, request bodies or response bodies; the `Debug` output of `HttpRequest`,
  `HttpResponse` and `Connection` is already redacted.

## Behavior

- **Versions** (WebDAV): always the `getetag` from `PROPFIND`. Reads are `PROPFIND` then a `GET` with `If-Match` (retried up
  to 3 times if the file changes in between); writes are a conditional `PUT` then `PROPFIND`. The `ETag` header of `GET` /
  `PUT` responses is not used, because servers do not always write it the same way as `getetag`.
- **Conditional writes** (WebDAV): `Precondition::Absent` sends `If-None-Match: *`, `Matches(rev)` sends `If-Match`. A weak
  ETag (`W/"…"`) cannot be compared strongly, so it falls back to comparing the version before writing, which leaves a short
  race window.
- **Plain HTTP**: `http://` addresses are only accepted with `Transport::AllowInsecureHttp`; the caller must get the user's
  explicit consent first.
- **Pinned certificates**: only WebDAV / Nextcloud connections whose addresses are all `https://` can use
  `with_pinned_certificate`; OAuth providers and plain HTTP cannot. It serializes as `pinnedCertificate` (64 lowercase hex
  digits); on any other connection it makes the blob `InvalidConnection`.
- **Untrusted input**: XML with a `DOCTYPE` is rejected, custom entities are not expanded, nesting depth and entry counts are
  capped; remote paths (`href`) outside the root, or containing `..` or control characters, are dropped.
- **Nextcloud**: the poll endpoint, the login page and the returned server address must share the origin the user entered;
  `revoke` deletes the app password.
- **OAuth**: `oauth::begin(provider, access, client, &random)` derives the PKCE verifier and `state` from 64 bytes the caller
  takes from a CSPRNG and returns an `Authorization` (`url()` for the sign-in page, the callback scheme). Open it in the
  system authentication session and pass the callback URL to `complete`, which checks the URL and `state` before sending
  anything (with a host, an empty path equals `/`, since Microsoft appends one). `accepts` only checks whether a callback
  belongs to this sign-in. There is no client secret.
- **Refresh**: OAuth operations refresh the token shortly before it expires (60 seconds early when `ClientConfig::now` is
  set) or after a 401, then replay once; a second 401 is `ReauthRequired`. A refreshed connection comes back in
  `Done.connection`. Requests carrying credentials only go to the provider's API origin.
- **Dropbox**: paths are relative to the app folder or the whole drive; the version is `rev` (the `Dropbox-API-Result` of
  downloads and the upload response agree); conditional writes use the upload `mode` (`update` / `add` / `overwrite`, with
  `strict_conflict`). `revoke` revokes the token.
- **OneDrive**: the root is `special/approot` (`Files.ReadWrite.AppFolder`) or `root`; the version is `eTag`. Reads download
  the pre-signed `downloadUrl` from the metadata without credentials, then check the `eTag` (retried up to 3 times). Writes
  use `If-Match` / `conflictBehavior=fail`. Microsoft has no revocation endpoint, so `revoke` succeeds without a request.
- **Google Drive**: items are addressed by ID and names are not unique, so paths resolve one segment at a time from the root
  (intermediate segments match folders only), and among duplicates the oldest item (creation time, then ID) always wins, in
  listings too. The version is `headRevisionId`; reads download `alt=media` and check the version again (retried up to 3
  times). Drive v3 has no conditional writes, so they are emulated: `Matches(rev)` compares the head revision before
  uploading and lists the revisions afterwards; if another writer got in between, its revision is uploaded again on top and
  the write reports `PreconditionFailed`, so no write is silently lost. `Absent` looks the name up again after creating, and
  the newer of two concurrent files is deleted by its writer. New files are one `multipart/related` upload, so an empty file
  is never visible. `revoke` revokes the refresh token, ending the whole grant.

## Independence

No dependency on any caller crate or FFI framework; no file reads, environment variables, system clock or randomness (the
current time and random bytes come from the caller). While it lives inside another repository, that host's CI should check
with `cargo tree -p cloudset` that neither its own crates nor FFI frameworks appear in the dependency graph. The crate
builds and tests on its own outside the host workspace; see `RELEASING.md`.

## Tests

- Unit tests in `src/`: origin checks, redirects, status mapping, paths, addresses, connection serialization, hostile XML,
  Drive queries and multipart bodies.
- `tests/webdav.rs`: every operation against the in-memory WebDAV server, including concurrent changes, weak ETags,
  redirects and wrong credentials.
- `tests/golden.rs`: `golden/multistatus.json` holds `PROPFIND` responses in the style of Nextcloud (sabre/dav), Apache
  mod_dav and NAS devices; `golden/oauth.json` holds Dropbox, Microsoft Graph and Google Drive metadata, listing, download,
  upload and error responses (including fields the crate ignores and rate-limit `Retry-After`).
- `tests/nextcloud.rs`: Login Flow v2 and revocation, with response shapes from the Nextcloud documentation.
- `tests/oauth.rs`: sign-in, reads and writes with preconditions, paging, folders, deletion, refresh and replay, early
  refresh and revocation against in-memory Dropbox / OneDrive / Google Drive (`testing::oauth::MemoryCloud`, shaped after
  the official APIs: the authorization page records the challenge and the token endpoint checks the verifier), each case
  once per provider × access scope. The servers isolate the scopes like the real ones (the app folder under
  `testing::oauth::APP_FOLDER` or `GOOGLE_APP_FOLDER`, OneDrive answering 403 for `root` under the app folder scope, Google
  hiding files the app did not create under `drive.file`). Google Drive races (an upload overtaken by another device,
  concurrent creates of the same name) have their own cases. PKCE is also checked against the RFC 7636 Appendix B vector.

License: MIT.
