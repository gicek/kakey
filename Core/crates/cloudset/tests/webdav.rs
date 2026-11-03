//! WebDAV end to end: the component's operation state machines run against the in-memory server.

use cloudset::testing::{BASE, MemoryDav};
use cloudset::{
    Client, ClientConfig, CloudError, Connection, Endpoint, Entry, File, HttpResponse, Precondition, RemotePath, Revision, Step, Transport,
    drive,
};

const AUTH: &str = "Basic YWxpY2U6cHc="; // alice:pw

fn client() -> Client {
    let endpoint = Endpoint::parse(BASE, Transport::RequireHttps).unwrap();
    Client::new(Connection::webdav(endpoint, "alice".into(), "pw".into()), ClientConfig::new("cloudset-test/1"))
}

fn path(text: &str) -> RemotePath {
    RemotePath::parse(text).unwrap()
}

fn run<T>(server: &mut MemoryDav, mut operation: cloudset::BoxOperation<T>) -> Result<T, CloudError> {
    drive(operation.as_mut(), |request| server.handle(request)).map(|done| {
        assert!(done.connection.is_none(), "WebDAV never updates the connection");
        done.value
    })
}

fn write(server: &mut MemoryDav, at: &str, data: &[u8], precondition: Precondition) -> Result<Entry, CloudError> {
    run(server, client().write(path(at), data.to_vec(), precondition))
}

fn read(server: &mut MemoryDav, at: &str) -> Result<Option<File>, CloudError> {
    run(server, client().read(path(at)))
}

#[test]
fn writes_reads_and_versions_from_propfind() {
    let mut server = MemoryDav::new(AUTH);
    run(&mut server, client().create_dir(path("Backups"))).unwrap();
    let written = write(&mut server, "Backups/vault.bin", b"one", Precondition::Absent).unwrap();
    assert_eq!((written.is_dir, written.size), (false, Some(3)));
    let revision = written.revision.clone().unwrap();
    assert!(revision.as_str().starts_with('"'), "the version comes from getetag, not the PUT response header: {revision:?}");

    let file = read(&mut server, "Backups/vault.bin").unwrap().unwrap();
    assert_eq!(file.data, b"one");
    assert_eq!(file.entry, written, "metadata read back matches the metadata after the write");
    assert_eq!(run(&mut server, client().stat(path("Backups/vault.bin"))).unwrap(), Some(written));

    for request in &server.requests {
        assert_eq!(request.header("Authorization"), Some(AUTH));
        assert_eq!(request.header("User-Agent"), Some("cloudset-test/1"));
        assert!(request.url.starts_with(BASE), "{}", request.url);
    }
}

#[test]
fn conditional_writes() {
    let mut server = MemoryDav::new(AUTH);
    let first = write(&mut server, "vault", b"1", Precondition::Absent).unwrap().revision.unwrap();
    assert_eq!(write(&mut server, "vault", b"x", Precondition::Absent), Err(CloudError::PreconditionFailed));

    server.put_external("vault", b"other device");
    assert_eq!(write(&mut server, "vault", b"2", Precondition::Matches(first.clone())), Err(CloudError::PreconditionFailed));
    assert_eq!(server.data("vault").unwrap(), b"other device", "a rejected write leaves the remote unchanged");

    let current = run(&mut server, client().stat(path("vault"))).unwrap().unwrap().revision.unwrap();
    let second = write(&mut server, "vault", b"2", Precondition::Matches(current.clone())).unwrap().revision.unwrap();
    assert_ne!(second, current);
    write(&mut server, "vault", b"3", Precondition::None).unwrap();
    assert_eq!(server.data("vault").unwrap(), b"3");
}

#[test]
fn weak_etags_fall_back_to_check_then_write() {
    let mut server = MemoryDav::new(AUTH);
    server.weak_etags = true;
    let weak = write(&mut server, "vault", b"1", Precondition::Absent).unwrap().revision.unwrap();
    assert!(weak.as_str().starts_with("W/"));
    let next = write(&mut server, "vault", b"2", Precondition::Matches(weak.clone())).unwrap().revision.unwrap();
    assert_eq!(write(&mut server, "vault", b"3", Precondition::Matches(weak)), Err(CloudError::PreconditionFailed));
    assert_eq!(read(&mut server, "vault").unwrap().unwrap().entry.revision, Some(next), "reads with a weak ETag skip If-Match");
}

#[test]
fn read_retries_when_changed_between_stat_and_get() {
    let mut server = MemoryDav::new(AUTH);
    write(&mut server, "vault", b"a", Precondition::None).unwrap();
    server.modify_before_get = 1;
    let file = read(&mut server, "vault").unwrap().unwrap();
    assert_eq!(file.data, b"a+");
    assert_eq!(Some(file.entry), run(&mut server, client().stat(path("vault"))).unwrap(), "after a retry, version and contents agree");

    server.modify_before_get = 3;
    assert_eq!(read(&mut server, "vault").err(), Some(CloudError::PreconditionFailed));
}

#[test]
fn missing_things_and_directories() {
    let mut server = MemoryDav::new(AUTH);
    assert_eq!(read(&mut server, "nope").unwrap(), None);
    assert_eq!(run(&mut server, client().stat(path("nope"))).unwrap(), None);
    assert_eq!(write(&mut server, "missing/vault", b"x", Precondition::None), Err(CloudError::NotFound));
    assert_eq!(run(&mut server, client().create_dir(path("a/b"))), Err(CloudError::NotFound));
    assert_eq!(run(&mut server, client().list(path("nope"))), Err(CloudError::NotFound));

    run(&mut server, client().create_dir(path("备份 1"))).unwrap();
    run(&mut server, client().create_dir(path("备份 1"))).unwrap();
    server.put_external("备份 1/b#?&.txt", b"b");
    server.put_external("备份 1/a.txt", b"a");
    server.mkdir_external("备份 1/sub");

    let listed = run(&mut server, client().list(path("备份 1"))).unwrap();
    let names: Vec<(String, bool)> = listed.iter().map(|e| (e.path.to_string(), e.is_dir)).collect();
    assert_eq!(names, [("备份 1/a.txt".into(), false), ("备份 1/b#?&.txt".into(), false), ("备份 1/sub".into(), true)]);
    assert_eq!(read(&mut server, "备份 1/b#?&.txt").unwrap().unwrap().data, b"b");

    let dir = run(&mut server, client().stat(path("备份 1/sub"))).unwrap().unwrap();
    assert!(dir.is_dir, "the server answers 301 for a directory without a trailing slash, and the component follows it");
    assert_eq!(read(&mut server, "备份 1/sub"), Err(CloudError::InvalidResponse("expected a file")));

    let root = run(&mut server, client().list(RemotePath::root())).unwrap();
    assert_eq!(root.len(), 1);

    run(&mut server, client().delete(path("备份 1/a.txt"))).unwrap();
    run(&mut server, client().delete(path("备份 1/a.txt"))).unwrap();
    assert_eq!(read(&mut server, "备份 1/a.txt").unwrap(), None);
}

#[test]
fn wrong_credentials_need_reauth() {
    let mut server = MemoryDav::new("Basic other");
    assert_eq!(read(&mut server, "vault"), Err(CloudError::ReauthRequired));
    assert_eq!(write(&mut server, "vault", b"x", Precondition::None), Err(CloudError::ReauthRequired));
}

#[test]
fn revoke_is_a_no_op_for_webdav() {
    let mut server = MemoryDav::new(AUTH);
    run(&mut server, client().revoke()).unwrap();
    assert!(server.requests.is_empty());
}

#[test]
fn rejects_out_of_order_driving() {
    let mut operation = client().stat(path("vault"));
    assert!(matches!(operation.advance(None), Ok(Step::Send(_))));
    assert_eq!(operation.advance(None).err(), Some(CloudError::OutOfOrder));

    let mut fresh = client().read(path("vault"));
    assert_eq!(fresh.advance(Some(HttpResponse::new(200))).err(), Some(CloudError::OutOfOrder));

    let mut finished = client().stat(path("vault"));
    finished.advance(None).unwrap();
    assert!(matches!(finished.advance(Some(HttpResponse::new(404))), Ok(Step::Done(_))));
    assert_eq!(finished.advance(Some(HttpResponse::new(404))).err(), Some(CloudError::OutOfOrder));
}

#[test]
fn revision_is_opaque() {
    assert_eq!(Revision::new("\"x\"").as_str(), "\"x\"");
}

#[test]
fn mkcol_405_is_checked_before_treating_it_as_existing() {
    let mut server = MemoryDav::new(AUTH);
    run(&mut server, client().create_dir(path("home"))).unwrap();
    run(&mut server, client().create_dir(path("home"))).unwrap();
    server.mkcol_forbidden_in.push(String::new());
    assert_eq!(
        run(&mut server, client().create_dir(path("Backups"))),
        Err(CloudError::Forbidden),
        "root is read-only: 405 does not mean it exists"
    );
    run(&mut server, client().create_dir(path("home"))).unwrap();
    run(&mut server, client().create_dir(path("home/Backups"))).unwrap();
    server.put_external("home/file", b"x");
    server.mkcol_forbidden_in.push("home".into());
    assert_eq!(run(&mut server, client().create_dir(path("home/file"))), Err(CloudError::Forbidden), "a file has that name");
}
