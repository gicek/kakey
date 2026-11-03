//! OneDrive (Microsoft Graph v1.0, <https://learn.microsoft.com/graph/api/resources/onedrive>).
//!
//! The root depends on the access scope: `Files.ReadWrite.AppFolder` uses the app folder `special/approot` (shown in
//! OneDrive as "Apps › <app name>", created on first access); `Files.ReadWrite` uses the drive root. Items are addressed
//! by path: `{root}:/a/b:`.
//!
//! The version is the item's `eTag`. Reading downloads from `@microsoft.graph.downloadUrl` in the metadata (a pre-signed
//! HTTPS URL without credentials), then fetches the metadata again to check the `eTag`, retrying if it changed in between
//! (at most 3 times). Writing uploads small files with `PUT …:/content`, using `If-Match` (412 on a version mismatch) or
//! `conflictBehavior=fail` (409 if it already exists).

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde_json::{Value, json};

use crate::authorized::{Authorized, Next, Outgoing, Steps};
use crate::client::ClientConfig;
use crate::connection::{AccessScope, Connection};
use crate::entry::{Entry, File, Precondition, Revision};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse, Method, status_error};
use crate::operation::{BoxOperation, Ready};
use crate::path::RemotePath;
use crate::providers::{json_request, parse_utc};

const GRAPH: &str = "https://graph.microsoft.com/v1.0/me/drive";
const SELECT: &str = "$select=name,size,eTag,lastModifiedDateTime,folder,file";
const READ_ATTEMPTS: u8 = 3;
/// Percent-encodes everything in a path segment except unreserved characters (including `:`, which separates Graph
/// path addressing).
const SEGMENT: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');

#[derive(Clone)]
struct Drive {
    root: &'static str,
}

impl Drive {
    fn of(connection: &Connection) -> Result<Self, CloudError> {
        let root = match connection.access_scope().ok_or(CloudError::InvalidConnection)? {
            AccessScope::AppFolder => "special/approot",
            AccessScope::Full => "root",
        };
        Ok(Self { root })
    }

    /// Item URL; `suffix` is a sub-resource (`children`, `content`), and an empty string means the item itself.
    fn url(&self, path: &RemotePath, suffix: &str) -> String {
        let mut url = format!("{GRAPH}/{}", self.root);
        if !path.is_root() {
            let encoded: Vec<String> = path.segments().iter().map(|segment| utf8_percent_encode(segment, SEGMENT).to_string()).collect();
            url.push_str(":/");
            url.push_str(&encoded.join("/"));
            if !suffix.is_empty() {
                url.push(':');
            }
        }
        if !suffix.is_empty() {
            url.push('/');
            url.push_str(suffix);
        }
        url
    }
}

fn get(url: String) -> Outgoing {
    Outgoing::authorized(json_request(Method::Get, &url, None))
}

fn json_body(response: &HttpResponse) -> Result<Value, CloudError> {
    serde_json::from_slice(&response.body).map_err(|_| CloudError::InvalidResponse("json"))
}

fn error_code(response: &HttpResponse) -> String {
    serde_json::from_slice::<Value>(&response.body)
        .ok()
        .and_then(|json| json.pointer("/error/code").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default()
}

fn error_for(response: &HttpResponse) -> CloudError {
    match response.status {
        409 => CloudError::PreconditionFailed,
        // Graph reports insufficient storage as 403 + quotaLimitReached or as 507.
        403 if error_code(response) == "quotaLimitReached" => CloudError::QuotaExceeded,
        400 if error_code(response) == "invalidRequest" => CloudError::InvalidPath,
        _ => status_error(response),
    }
}

fn entry(item: &Value, path: RemotePath) -> Entry {
    Entry {
        path,
        is_dir: item.get("folder").is_some(),
        size: item.get("size").and_then(Value::as_u64),
        modified_at: item.get("lastModifiedDateTime").and_then(Value::as_str).and_then(parse_utc),
        revision: item.get("eTag").and_then(Value::as_str).map(Revision::new),
    }
}

fn op<S: Steps + 'static>(steps: Result<S, CloudError>, connection: &Connection, config: &ClientConfig) -> BoxOperation<S::Output> {
    match steps.and_then(|steps| Authorized::new(steps, connection, config)) {
        Ok(operation) => Box::new(operation),
        Err(error) => Box::new(Ready::err(error)),
    }
}

// MARK: - Metadata and listing

struct Stat {
    drive: Drive,
    path: RemotePath,
}

impl Steps for Stat {
    type Output = Option<Entry>;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        Ok(get(format!("{}?{SELECT}", self.drive.url(&self.path, ""))))
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Option<Entry>>, CloudError> {
        match response.status {
            200 => Ok(Next::Done(Some(entry(&json_body(&response)?, self.path.clone())))),
            404 => Ok(Next::Done(None)),
            _ => Err(error_for(&response)),
        }
    }
}

pub(crate) fn stat(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<Option<Entry>> {
    op(Drive::of(connection).map(|drive| Stat { drive, path }), connection, config)
}

struct List {
    drive: Drive,
    dir: RemotePath,
    entries: Vec<Entry>,
    max_entries: usize,
}

impl Steps for List {
    type Output = Vec<Entry>;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        Ok(get(format!("{}?{SELECT}&$top=200", self.drive.url(&self.dir, "children"))))
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Vec<Entry>>, CloudError> {
        if response.status != 200 {
            return Err(error_for(&response));
        }
        let json = json_body(&response)?;
        for item in json.get("value").and_then(Value::as_array).ok_or(CloudError::InvalidResponse("children"))? {
            let name = item.get("name").and_then(Value::as_str).ok_or(CloudError::InvalidResponse("name"))?;
            let Ok(path) = self.dir.join(name) else { continue };
            if self.entries.len() >= self.max_entries {
                return Err(CloudError::TooLarge);
            }
            self.entries.push(entry(item, path));
        }
        // The next page is a full URL; the driver checks that it is still on the Graph origin before sending credentials.
        if let Some(next) = json.get("@odata.nextLink").and_then(Value::as_str) {
            return Ok(Next::Request(get(next.to_owned())));
        }
        let mut entries = std::mem::take(&mut self.entries);
        entries.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(Next::Done(entries))
    }
}

pub(crate) fn list(connection: &Connection, config: &ClientConfig, dir: RemotePath) -> BoxOperation<Vec<Entry>> {
    op(
        Drive::of(connection).map(|drive| List { drive, dir, entries: Vec::new(), max_entries: config.limits.max_entries }),
        connection,
        config,
    )
}

// MARK: - Reading

enum ReadState {
    Metadata,
    Download(Entry),
    Verify(Entry, Vec<u8>),
}

struct Read {
    drive: Drive,
    path: RemotePath,
    attempts: u8,
    state: ReadState,
}

impl Read {
    /// No `$select`: only the default response includes `@microsoft.graph.downloadUrl`, and naming it in `$select` still
    /// omits it (verified against the live API).
    fn metadata_request(&self) -> Outgoing {
        get(self.drive.url(&self.path, ""))
    }
}

impl Steps for Read {
    type Output = Option<File>;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        self.attempts = 1;
        Ok(self.metadata_request())
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Option<File>>, CloudError> {
        match std::mem::replace(&mut self.state, ReadState::Metadata) {
            ReadState::Metadata => {
                match response.status {
                    200 => {}
                    404 => return Ok(Next::Done(None)),
                    _ => return Err(error_for(&response)),
                }
                let item = json_body(&response)?;
                let entry = entry(&item, self.path.clone());
                if entry.is_dir {
                    return Err(CloudError::InvalidResponse("expected a file"));
                }
                let url =
                    item.get("@microsoft.graph.downloadUrl").and_then(Value::as_str).ok_or(CloudError::InvalidResponse("download url"))?;
                self.state = ReadState::Download(entry);
                // The pre-signed URL is the credential itself: no Authorization header, and the driver only allows HTTPS.
                Ok(Next::Request(Outgoing {
                    request: HttpRequest { method: Method::Get, url: url.to_owned(), headers: Vec::new(), body: Vec::new() },
                    authorize: false,
                }))
            }
            ReadState::Download(entry) => match response.status {
                200 => {
                    self.state = ReadState::Verify(entry, response.body);
                    Ok(Next::Request(get(format!("{}?{SELECT}", self.drive.url(&self.path, "")))))
                }
                404 => Ok(Next::Done(None)),
                _ => Err(status_error(&response)),
            },
            ReadState::Verify(entry, data) => {
                match response.status {
                    200 => {}
                    404 => return Ok(Next::Done(None)),
                    _ => return Err(error_for(&response)),
                }
                let current = self::entry(&json_body(&response)?, self.path.clone());
                if current.revision.is_some() && current.revision == entry.revision {
                    return Ok(Next::Done(Some(File { data, entry })));
                }
                if self.attempts >= READ_ATTEMPTS {
                    return Err(CloudError::PreconditionFailed);
                }
                self.attempts += 1;
                Ok(Next::Request(self.metadata_request()))
            }
        }
    }
}

pub(crate) fn read(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<Option<File>> {
    if path.is_root() {
        return Box::new(Ready::err(CloudError::InvalidPath));
    }
    op(Drive::of(connection).map(|drive| Read { drive, path, attempts: 0, state: ReadState::Metadata }), connection, config)
}

// MARK: - Writing

struct Write {
    drive: Drive,
    path: RemotePath,
    data: Option<Vec<u8>>,
    precondition: Precondition,
}

impl Steps for Write {
    type Output = Entry;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        let behavior = match self.precondition {
            Precondition::Absent => "fail",
            Precondition::None | Precondition::Matches(_) => "replace",
        };
        let url = format!("{}?@microsoft.graph.conflictBehavior={behavior}", self.drive.url(&self.path, "content"));
        let mut headers = vec![("Content-Type".to_owned(), "application/octet-stream".to_owned())];
        if let Precondition::Matches(revision) = &self.precondition {
            headers.push(("If-Match".into(), revision.as_str().to_owned()));
        }
        let body = self.data.take().ok_or(CloudError::OutOfOrder)?;
        Ok(Outgoing::authorized(HttpRequest { method: Method::Put, url, headers, body }))
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Entry>, CloudError> {
        match response.status {
            200 | 201 => Ok(Next::Done(entry(&json_body(&response)?, self.path.clone()))),
            // With If-Match, the file no longer exists: it was deleted since the last read, which also counts as "changed".
            404 if matches!(self.precondition, Precondition::Matches(_)) => Err(CloudError::PreconditionFailed),
            _ => Err(error_for(&response)),
        }
    }
}

pub(crate) fn write(
    connection: &Connection,
    config: &ClientConfig,
    path: RemotePath,
    data: Vec<u8>,
    precondition: Precondition,
) -> BoxOperation<Entry> {
    if path.is_root() {
        return Box::new(Ready::err(CloudError::InvalidPath));
    }
    op(Drive::of(connection).map(|drive| Write { drive, path, data: Some(data), precondition }), connection, config)
}

// MARK: - Directories and deletion

enum CreateState {
    Create,
    /// The name is taken: succeed only if the existing item is a folder.
    Check,
}

struct CreateDir {
    drive: Drive,
    path: RemotePath,
    state: CreateState,
}

impl Steps for CreateDir {
    type Output = ();

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        let parent = self.path.parent().unwrap_or_else(RemotePath::root);
        let name = self.path.name().ok_or(CloudError::InvalidPath)?;
        let body = json!({ "name": name, "folder": {}, "@microsoft.graph.conflictBehavior": "fail" });
        Ok(Outgoing::authorized(json_request(Method::Post, &self.drive.url(&parent, "children"), Some(&body))))
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<()>, CloudError> {
        match self.state {
            CreateState::Create => match response.status {
                200 | 201 => Ok(Next::Done(())),
                409 => {
                    self.state = CreateState::Check;
                    Ok(Next::Request(get(format!("{}?{SELECT}", self.drive.url(&self.path, "")))))
                }
                _ => Err(error_for(&response)),
            },
            CreateState::Check => match response.status {
                200 if json_body(&response)?.get("folder").is_some() => Ok(Next::Done(())),
                200 => Err(CloudError::Forbidden),
                _ => Err(error_for(&response)),
            },
        }
    }
}

pub(crate) fn create_dir(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<()> {
    if path.is_root() {
        return Box::new(Ready::ok(()));
    }
    op(Drive::of(connection).map(|drive| CreateDir { drive, path, state: CreateState::Create }), connection, config)
}

struct Delete {
    drive: Drive,
    path: RemotePath,
}

impl Steps for Delete {
    type Output = ();

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        Ok(Outgoing::authorized(json_request(Method::Delete, &self.drive.url(&self.path, ""), None)))
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<()>, CloudError> {
        match response.status {
            200 | 204 | 404 => Ok(Next::Done(())),
            _ => Err(error_for(&response)),
        }
    }
}

pub(crate) fn delete(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<()> {
    if path.is_root() {
        return Box::new(Ready::err(CloudError::InvalidPath));
    }
    op(Drive::of(connection).map(|drive| Delete { drive, path }), connection, config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_items_by_path() {
        let app = Drive { root: "special/approot" };
        let path = RemotePath::parse("Backups/a b:c#.bin").unwrap();
        assert_eq!(app.url(&RemotePath::root(), ""), "https://graph.microsoft.com/v1.0/me/drive/special/approot");
        assert_eq!(app.url(&RemotePath::root(), "children"), "https://graph.microsoft.com/v1.0/me/drive/special/approot/children");
        assert_eq!(app.url(&path, ""), "https://graph.microsoft.com/v1.0/me/drive/special/approot:/Backups/a%20b%3Ac%23.bin");
        assert_eq!(
            app.url(&path, "content"),
            "https://graph.microsoft.com/v1.0/me/drive/special/approot:/Backups/a%20b%3Ac%23.bin:/content"
        );
        let full = Drive { root: "root" };
        assert_eq!(
            full.url(&RemotePath::parse("备份").unwrap(), "children"),
            "https://graph.microsoft.com/v1.0/me/drive/root:/%E5%A4%87%E4%BB%BD:/children"
        );
    }
}
