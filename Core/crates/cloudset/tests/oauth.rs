//! OAuth providers end to end: sign-in (PKCE), automatic refresh, conditional writes, paging, and revocation, run against
//! in-memory Dropbox / OneDrive / Google Drive. Every case runs once per provider × access scope; the in-memory servers
//! isolate the app folder from the whole drive the way the real ones do.

use std::time::{Duration, UNIX_EPOCH};

use cloudset::oauth::begin;
use cloudset::testing::oauth::{DROPBOX_FULL_APP_KEY, FakeProvider, GOOGLE_APP_FOLDER, MemoryCloud, ONEDRIVE_DOWNLOAD_HOST};
use cloudset::{
    AccessScope, BoxOperation, Client, ClientConfig, CloudError, Connection, OAuthClient, Precondition, ProviderKind, RemotePath, drive,
};

fn provider_kind(provider: FakeProvider) -> ProviderKind {
    match provider {
        FakeProvider::Dropbox => ProviderKind::Dropbox,
        FakeProvider::OneDrive => ProviderKind::OneDrive,
        FakeProvider::GoogleDrive => ProviderKind::GoogleDrive,
    }
}

const PROVIDERS: [FakeProvider; 3] = [FakeProvider::Dropbox, FakeProvider::OneDrive, FakeProvider::GoogleDrive];

fn config() -> ClientConfig {
    ClientConfig::new("cloudset-test/1").with_now(UNIX_EPOCH + Duration::from_secs(1_000))
}

/// On Dropbox the scope is fixed by the app, so full access uses a different app key; on OneDrive and Google the same
/// client differs by scope. Google needs the name of the folder that serves as the app folder.
fn oauth_client(provider: FakeProvider, access: AccessScope) -> OAuthClient {
    let client_id = match (provider, access) {
        (FakeProvider::Dropbox, AccessScope::Full) => DROPBOX_FULL_APP_KEY,
        _ => "client",
    };
    OAuthClient::new(client_id, "com.example.app.oauth://callback").with_folder_name(GOOGLE_APP_FOLDER)
}

fn sign_in(server: &mut MemoryCloud, access: AccessScope) -> Connection {
    let authorization = begin(provider_kind(server.provider), access, oauth_client(server.provider, access), &[42; 64]).unwrap();
    let callback = server.authorize(authorization.url());
    let mut operation = authorization.complete(&callback, &config()).unwrap();
    let connection = drive(operation.as_mut(), |request| server.handle(request)).unwrap().value;
    assert_eq!(server.granted, Some(access), "{:?}: the server grants the requested scope", server.provider);
    connection
}

fn path(text: &str) -> RemotePath {
    RemotePath::parse(text).unwrap()
}

/// Runs an operation to completion, switching to the new connection when it was refreshed.
fn run<T>(server: &mut MemoryCloud, client: &mut Client, make: impl FnOnce(&Client) -> BoxOperation<T>) -> Result<T, CloudError> {
    let mut operation = make(client);
    let done = drive(operation.as_mut(), |request| server.handle(request))?;
    if let Some(connection) = done.connection {
        *client = client.with_connection(connection);
    }
    Ok(done.value)
}

const SCOPES: [AccessScope; 2] = [AccessScope::AppFolder, AccessScope::Full];

/// Every access scope of every provider.
fn cases() -> Vec<(MemoryCloud, AccessScope)> {
    PROVIDERS.into_iter().flat_map(|provider| SCOPES.map(|access| (MemoryCloud::new(provider), access))).collect()
}

/// Signed-in servers and clients.
fn signed_in() -> Vec<(MemoryCloud, Client, AccessScope)> {
    cases()
        .into_iter()
        .map(|(mut server, access)| {
            let client = Client::new(sign_in(&mut server, access), config());
            (server, client, access)
        })
        .collect()
}

#[test]
fn signs_in_with_pkce_and_names_the_account() {
    for (mut server, access) in cases() {
        let connection = sign_in(&mut server, access);
        let expected = match server.provider {
            FakeProvider::Dropbox => "alice@example.com",
            FakeProvider::OneDrive => "alice@outlook.com",
            FakeProvider::GoogleDrive => "alice@gmail.com",
        };
        assert_eq!(connection.username(), expected);
        assert_eq!(connection.access_scope(), Some(access));
        let restored = Connection::from_bytes(&connection.to_bytes()).unwrap();
        assert_eq!(restored, connection);
        assert_eq!(restored.access_scope(), Some(access), "{:?}: serialization keeps the access scope", server.provider);
    }
}

#[test]
fn reused_or_tampered_callbacks_are_refused() {
    let mut server = MemoryCloud::new(FakeProvider::Dropbox);
    let client = oauth_client(FakeProvider::Dropbox, AccessScope::AppFolder);
    let first = begin(ProviderKind::Dropbox, AccessScope::AppFolder, client.clone(), &[1; 64]).unwrap();
    let second = begin(ProviderKind::Dropbox, AccessScope::AppFolder, client, &[2; 64]).unwrap();
    // A callback from a different authorization (different state) is rejected before any request is sent.
    let callback = server.authorize(first.url());
    assert_eq!(second.complete(&callback, &config()).err(), Some(CloudError::StateMismatch));
    // The verifier does not match the challenge: the token endpoint rejects it.
    server.authorize(second.url());
    let mut operation = first.complete(&callback, &config()).unwrap();
    let result = drive(operation.as_mut(), |request| server.handle(request));
    assert_eq!(result.err(), Some(CloudError::ReauthRequired));
}

#[test]
fn round_trips_files_with_conditional_writes() {
    for (mut server, mut client, access) in signed_in() {
        let case = format!("{:?} {access:?}", server.provider);
        let file = path("Backups/备份 #1.bin");
        let stored = server.storage_path("Backups/备份 #1.bin");
        let written = run(&mut server, &mut client, |c| c.write(file.clone(), b"one".to_vec(), Precondition::Absent)).unwrap();
        let revision = written.revision.clone().expect("revision");
        assert_eq!((written.is_dir, written.size), (false, Some(3)));
        assert!(server.exists(&server.storage_path("Backups")), "{case}: writing creates the parent directory");
        assert_eq!(server.data(&stored).as_deref(), Some(&b"one"[..]), "{case}: written under this scope's root");

        let read = run(&mut server, &mut client, |c| c.read(file.clone())).unwrap().unwrap();
        assert_eq!(
            (read.data.as_slice(), read.entry.revision.as_ref()),
            (&b"one"[..], Some(&revision)),
            "{case}: read and write versions agree"
        );
        let stat = run(&mut server, &mut client, |c| c.stat(file.clone())).unwrap().unwrap();
        assert_eq!(stat.revision.as_ref(), Some(&revision));
        assert!(stat.modified_at.is_some());

        assert_eq!(
            run(&mut server, &mut client, |c| c.write(file.clone(), b"x".to_vec(), Precondition::Absent)).err(),
            Some(CloudError::PreconditionFailed)
        );
        server.put_external(&stored, b"other device");
        assert_eq!(
            run(&mut server, &mut client, |c| c.write(file.clone(), b"two".to_vec(), Precondition::Matches(revision.clone()))).err(),
            Some(CloudError::PreconditionFailed),
            "{case}"
        );
        assert_eq!(server.data(&stored).unwrap(), b"other device");
        let current = run(&mut server, &mut client, |c| c.stat(file.clone())).unwrap().unwrap().revision.unwrap();
        run(&mut server, &mut client, |c| c.write(file.clone(), b"two".to_vec(), Precondition::Matches(current))).unwrap();
        run(&mut server, &mut client, |c| c.write(file.clone(), b"three".to_vec(), Precondition::None)).unwrap();
        assert_eq!(server.data(&stored).as_deref(), Some(&b"three"[..]), "{case}");

        assert_eq!(run(&mut server, &mut client, |c| c.read(path("Backups/missing"))).unwrap(), None);
        assert_eq!(run(&mut server, &mut client, |c| c.stat(path("missing"))).unwrap(), None);
        run(&mut server, &mut client, |c| c.delete(file.clone())).unwrap();
        run(&mut server, &mut client, |c| c.delete(file.clone())).unwrap();
        assert!(!server.exists(&stored), "{case}");
    }
}

#[test]
fn lists_across_pages_and_creates_folders() {
    for (mut server, mut client, access) in signed_in() {
        let case = format!("{:?} {access:?}", server.provider);
        for name in ["c", "a", "b", "d", "e"] {
            server.put_external(&server.storage_path(&format!("Docs/{name}.txt")), name.as_bytes());
        }
        run(&mut server, &mut client, |c| c.create_dir(path("Docs/Sub"))).unwrap();
        run(&mut server, &mut client, |c| c.create_dir(path("Docs/Sub"))).unwrap();
        assert!(server.exists(&server.storage_path("Docs/Sub")), "{case}");
        assert_eq!(run(&mut server, &mut client, |c| c.create_dir(path("Docs/a.txt"))).err(), Some(CloudError::Forbidden));
        let entries = run(&mut server, &mut client, |c| c.list(path("Docs"))).unwrap();
        let names: Vec<_> = entries.iter().map(|entry| (entry.path.to_string(), entry.is_dir)).collect();
        assert_eq!(
            names,
            [
                ("Docs/Sub", true),
                ("Docs/a.txt", false),
                ("Docs/b.txt", false),
                ("Docs/c.txt", false),
                ("Docs/d.txt", false),
                ("Docs/e.txt", false)
            ]
            .map(|(name, dir)| (name.to_owned(), dir)),
            "{case}"
        );
        assert_eq!(run(&mut server, &mut client, |c| c.list(path("Nope"))).err(), Some(CloudError::NotFound));
        assert!(run(&mut server, &mut client, |c| c.stat(RemotePath::root())).unwrap().unwrap().is_dir);
    }
}

#[test]
fn app_folder_access_stays_inside_the_app_folder() {
    for (mut server, mut client, access) in signed_in() {
        let case = format!("{:?} {access:?}", server.provider);
        server.put_external("Private/secret.txt", b"secret");
        let app_folder = server.app_folder();
        server.put_external(&format!("{app_folder}/inside.txt"), b"inside");
        run(&mut server, &mut client, |c| c.write(path("new.txt"), b"new".to_vec(), Precondition::Absent)).unwrap();
        let root: Vec<String> = run(&mut server, &mut client, |c| c.list(RemotePath::root()))
            .unwrap()
            .into_iter()
            .map(|entry| entry.path.to_string())
            .collect();
        let secret = run(&mut server, &mut client, |c| c.read(path("Private/secret.txt"))).unwrap();
        match access {
            AccessScope::AppFolder => {
                assert_eq!(root, ["inside.txt", "new.txt"], "{case}: the root is the app folder");
                assert_eq!(secret, None, "{case}: files outside the app folder are invisible");
                assert!(server.exists(&format!("{app_folder}/new.txt")) && !server.exists("new.txt"), "{case}");
                if server.provider == FakeProvider::OneDrive {
                    assert!(
                        server.requests.iter().all(|request| !request.url.contains("/me/drive/root")),
                        "{case}: addressed only through special/approot"
                    );
                }
            }
            AccessScope::Full => {
                let mut expected = vec![app_folder.split('/').next().unwrap(), "Private", "new.txt"];
                expected.sort_unstable();
                assert_eq!(root, expected, "{case}: the root is the whole drive");
                assert_eq!(secret.unwrap().data, b"secret");
                assert!(server.exists("new.txt") && !server.exists(&format!("{app_folder}/new.txt")), "{case}");
            }
        }
    }
}

#[test]
fn refreshes_on_401_once_and_hands_back_the_connection() {
    for (mut server, client, access) in signed_in() {
        let case = format!("{:?} {access:?}", server.provider);
        let connection = client.connection().clone();
        let mut client = client;
        server.put_external(&server.storage_path("Backups/v"), b"data");
        server.expire_access_token();
        let mut operation = client.read(path("Backups/v"));
        let done = drive(operation.as_mut(), |request| server.handle(request)).unwrap();
        assert_eq!(done.value.unwrap().data, b"data", "{case}");
        let refreshed = done.connection.expect("a refresh hands back the new connection");
        assert_ne!(refreshed, connection);
        assert_eq!(refreshed.access_scope(), Some(access), "{case}: refreshing keeps the access scope");
        client = client.with_connection(refreshed);
        // The new connection works directly without another refresh.
        let before = server.requests.len();
        run(&mut server, &mut client, |c| c.stat(path("Backups/v"))).unwrap();
        assert!(server.requests[before..].iter().all(|request| !request.url.ends_with("/token")), "{case}");

        // The refresh token is invalid too: sign-in is required, with no endless retries.
        server.expire_access_token();
        server.revoked = true;
        assert_eq!(run(&mut server, &mut client, |c| c.stat(path("Backups/v"))).err(), Some(CloudError::ReauthRequired));
    }
}

#[test]
fn onedrive_refresh_asks_for_the_granted_scope() {
    for access in SCOPES {
        let mut server = MemoryCloud::new(FakeProvider::OneDrive);
        let mut client = Client::new(sign_in(&mut server, access), config());
        server.expire_access_token();
        run(&mut server, &mut client, |c| c.stat(RemotePath::root())).unwrap();
        let refresh = server.requests.iter().rfind(|request| request.url.ends_with("/token")).unwrap();
        let form: Vec<(String, String)> = url::form_urlencoded::parse(&refresh.body).into_owned().collect();
        let scope = form.iter().find(|(key, _)| key == "scope").map(|(_, value)| value.as_str());
        let expected = match access {
            AccessScope::AppFolder => "offline_access User.Read Files.ReadWrite.AppFolder",
            AccessScope::Full => "offline_access User.Read Files.ReadWrite",
        };
        assert_eq!(scope, Some(expected), "{access:?}");
    }
}

#[test]
fn refreshes_before_expiry_when_the_clock_is_known() {
    for (mut server, client, access) in signed_in() {
        // Signed in at now = 1000 s with a 3600 s lifetime: 4590 s is inside the 60 s early-refresh window.
        let late = ClientConfig::new("t").with_now(UNIX_EPOCH + Duration::from_secs(4_590));
        let mut client = Client::new(client.connection().clone(), late);
        let before = server.requests.len();
        let done = {
            let mut operation = client.stat(path("anything"));
            drive(operation.as_mut(), |request| server.handle(request)).unwrap()
        };
        assert!(done.connection.is_some());
        assert!(
            server.requests[before].url.ends_with("/token"),
            "{:?} {access:?}: refresh before sending instead of taking a 401 first",
            server.provider
        );
        let refreshes = server.requests[before..].iter().filter(|request| request.url.ends_with("/token")).count();
        assert_eq!(refreshes, 1, "{:?} {access:?}: one refresh, and no 401 to retry", server.provider);
        client = client.with_connection(done.connection.unwrap());
        assert!(run(&mut server, &mut client, |c| c.stat(path("anything"))).is_ok());
    }
}

#[test]
fn onedrive_download_is_unauthenticated_and_verified() {
    for access in SCOPES {
        let mut server = MemoryCloud::new(FakeProvider::OneDrive);
        let mut client = Client::new(sign_in(&mut server, access), config());
        server.put_external(&server.storage_path("Backups/v"), b"original");
        server.modify_before_download = 1;
        let file = run(&mut server, &mut client, |c| c.read(path("Backups/v"))).unwrap().unwrap();
        assert_eq!(file.data, b"changed elsewhere", "{access:?}: changed during download, so fetch metadata again and re-download");
        let downloads = server.requests.iter().filter(|request| request.url.contains(ONEDRIVE_DOWNLOAD_HOST)).count();
        assert_eq!(downloads, 2);

        server.modify_before_download = 3;
        assert_eq!(run(&mut server, &mut client, |c| c.read(path("Backups/v"))).err(), Some(CloudError::PreconditionFailed));
    }
}

#[test]
fn revoke_ends_the_grant() {
    for (mut server, mut client, access) in signed_in() {
        let before = server.requests.len();
        run(&mut server, &mut client, |c| c.revoke()).unwrap();
        match server.provider {
            FakeProvider::Dropbox => {
                assert!(server.revoked, "{access:?}");
                assert_eq!(run(&mut server, &mut client, |c| c.stat(path("x"))).err(), Some(CloudError::ReauthRequired));
            }
            // OneDrive has no revocation endpoint: succeeds directly without a request.
            FakeProvider::OneDrive => assert_eq!(server.requests.len(), before, "{access:?}"),
            // Google revokes the refresh token (and with it the whole grant) at the OAuth origin, without a bearer token.
            FakeProvider::GoogleDrive => {
                assert!(server.revoked, "{access:?}");
                assert!(server.requests[before].url.starts_with("https://oauth2.googleapis.com/revoke"));
                assert_eq!(run(&mut server, &mut client, |c| c.stat(path("x"))).err(), Some(CloudError::ReauthRequired));
                // Revoking again (already gone: 400) still counts as done.
                run(&mut server, &mut client, |c| c.revoke()).unwrap();
            }
        }
    }
}

#[test]
fn google_download_is_verified_against_the_head_revision() {
    for access in SCOPES {
        let mut server = MemoryCloud::new(FakeProvider::GoogleDrive);
        let mut client = Client::new(sign_in(&mut server, access), config());
        server.put_external(&server.storage_path("Backups/v"), b"original");
        server.modify_before_download = 1;
        let file = run(&mut server, &mut client, |c| c.read(path("Backups/v"))).unwrap().unwrap();
        assert_eq!(file.data, b"changed elsewhere", "{access:?}: changed during download, so download again");
        let current = run(&mut server, &mut client, |c| c.stat(path("Backups/v"))).unwrap().unwrap();
        assert_eq!(file.entry.revision, current.revision, "{access:?}: data and revision belong together");
        let downloads = server.requests.iter().filter(|request| request.url.contains("alt=media")).count();
        assert_eq!(downloads, 2);

        server.modify_before_download = 3;
        assert_eq!(run(&mut server, &mut client, |c| c.read(path("Backups/v"))).err(), Some(CloudError::PreconditionFailed));
    }
}

/// Drive has no conditional writes. A write that overtakes another device's write between the revision check and the
/// upload must not silently drop it: the other device's version is put back on top and the write reports a conflict.
#[test]
fn google_restores_a_revision_overwritten_by_a_racing_write() {
    for access in SCOPES {
        let mut server = MemoryCloud::new(FakeProvider::GoogleDrive);
        let mut client = Client::new(sign_in(&mut server, access), config());
        let file = path("vault.bin");
        let stored = server.storage_path("vault.bin");
        let first = run(&mut server, &mut client, |c| c.write(file.clone(), b"one".to_vec(), Precondition::Absent)).unwrap();

        server.races().before_update = true;
        let raced = run(&mut server, &mut client, |c| {
            c.write(file.clone(), b"two".to_vec(), Precondition::Matches(first.revision.clone().unwrap()))
        });
        assert_eq!(raced.err(), Some(CloudError::PreconditionFailed), "{access:?}");
        assert_eq!(
            server.data(&stored).as_deref(),
            Some(&b"changed elsewhere"[..]),
            "{access:?}: the other device's version is current again"
        );
        let restores = |server: &MemoryCloud| server.requests.iter().filter(|request| request.url.contains("/revisions/")).count();
        assert_eq!(restores(&server), 1, "{access:?}: the overwritten revision was downloaded to put it back");

        // Without a race the same check passes.
        let current = run(&mut server, &mut client, |c| c.stat(file.clone())).unwrap().unwrap().revision.unwrap();
        let written = run(&mut server, &mut client, |c| c.write(file.clone(), b"three".to_vec(), Precondition::Matches(current))).unwrap();
        assert_eq!(server.data(&stored).as_deref(), Some(&b"three"[..]));
        assert_eq!(restores(&server), 1, "{access:?}: nothing to restore without a race");
        let read = run(&mut server, &mut client, |c| c.read(file.clone())).unwrap().unwrap();
        assert_eq!(read.entry.revision, written.revision);
    }
}

/// Names are not unique on Drive: when two devices create the same file at once, the older one wins on both, and the
/// newer one is removed by its writer.
#[test]
fn google_concurrent_creates_converge_on_the_oldest() {
    for access in SCOPES {
        let mut server = MemoryCloud::new(FakeProvider::GoogleDrive);
        let mut client = Client::new(sign_in(&mut server, access), config());
        let stored = server.storage_path("Backups/vault.bin");
        run(&mut server, &mut client, |c| c.create_dir(path("Backups"))).unwrap_or_default();
        server.races().before_create = true;
        let raced = run(&mut server, &mut client, |c| c.write(path("Backups/vault.bin"), b"mine".to_vec(), Precondition::Absent));
        assert_eq!(raced.err(), Some(CloudError::PreconditionFailed), "{access:?}");
        assert_eq!((server.copies(&stored), server.data(&stored).as_deref()), (1, Some(&b"other device"[..])), "{access:?}");

        // Overwriting unconditionally lands in the surviving file instead of leaving a duplicate.
        server.races().before_create = true;
        run(&mut server, &mut client, |c| c.write(path("Backups/other.bin"), b"mine".to_vec(), Precondition::None)).unwrap();
        let other = server.storage_path("Backups/other.bin");
        assert_eq!((server.copies(&other), server.data(&other).as_deref()), (1, Some(&b"mine"[..])), "{access:?}");

        // Folders created along the way are deduplicated the same way.
        server.races().before_create = true;
        run(&mut server, &mut client, |c| c.write(path("New/v.bin"), b"v".to_vec(), Precondition::Absent)).unwrap();
        assert_eq!(server.copies(&server.storage_path("New")), 1, "{access:?}");
        assert_eq!(server.data(&server.storage_path("New/v.bin")).as_deref(), Some(&b"v"[..]));
    }
}

/// Duplicate names (left behind by other clients) resolve to the oldest item in every operation, including listings.
#[test]
fn google_duplicates_resolve_to_the_oldest_item() {
    let mut server = MemoryCloud::new(FakeProvider::GoogleDrive);
    let mut client = Client::new(sign_in(&mut server, AccessScope::Full), config());
    server.put_external("dup.bin", b"old");
    server.races().before_create = true;
    run(&mut server, &mut client, |c| c.write(path("fresh.bin"), b"x".to_vec(), Precondition::Absent)).unwrap_err();
    let entries = run(&mut server, &mut client, |c| c.list(RemotePath::root())).unwrap();
    let names: Vec<String> = entries.iter().map(|entry| entry.path.to_string()).collect();
    assert_eq!(names, ["dup.bin", "fresh.bin"], "each name listed once");
    assert_eq!(run(&mut server, &mut client, |c| c.read(path("dup.bin"))).unwrap().unwrap().data, b"old");
    assert_eq!(run(&mut server, &mut client, |c| c.read(path("fresh.bin"))).unwrap().unwrap().data, b"other device");
}

/// With `drive.file`, the app folder is created in My Drive on first access, and the client finds it again by name
/// instead of creating another one.
#[test]
fn google_app_folder_is_created_once() {
    let mut server = MemoryCloud::new(FakeProvider::GoogleDrive);
    let mut client = Client::new(sign_in(&mut server, AccessScope::AppFolder), config());
    assert!(!server.exists(GOOGLE_APP_FOLDER));
    assert_eq!(run(&mut server, &mut client, |c| c.list(RemotePath::root())).unwrap(), Vec::new());
    assert!(server.exists(GOOGLE_APP_FOLDER), "listing the root creates the app folder");
    run(&mut server, &mut client, |c| c.write(path("vault.bin"), b"v".to_vec(), Precondition::Absent)).unwrap();
    run(&mut server, &mut client, |c| c.stat(path("vault.bin"))).unwrap();
    assert_eq!(server.copies(GOOGLE_APP_FOLDER), 1);
}
