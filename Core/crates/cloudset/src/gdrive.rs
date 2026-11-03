//! Google Drive (Drive API v3, <https://developers.google.com/workspace/drive/api/reference/rest/v3>).
//!
//! Drive addresses items by ID, and names are not unique within a folder, so a path is resolved one segment at a time
//! from the drive root ([`Walk`]): one name lookup per segment, folders only for the intermediate ones. Among items with
//! the same name the oldest wins (creation time, then ID), so every device picks the same one.
//!
//! The root depends on the access scope. `drive.file` only reaches files the app created, and Drive has no app folder of
//! its own: the app folder is a visible folder in My Drive named by the caller ([`crate::OAuthClient::folder_name`]),
//! created on first access. `drive` uses My Drive itself (`root`).
//!
//! The version is the file's `headRevisionId`. Reading downloads `alt=media`, then fetches the metadata again to check the
//! version, retrying if it changed in between (at most 3 times).
//!
//! Drive v3 has no conditional writes, so they are emulated:
//! - `Matches(rev)`: compare the head revision before uploading; after uploading, list the revisions and check that the
//!   one right before ours is still `rev`. If another device wrote in between, its revision is downloaded and uploaded
//!   again on top of ours (so its data stays the current version and no one's write is silently lost), and the write
//!   reports `PreconditionFailed`. Only a third write inside that window, or Drive pruning revisions within seconds,
//!   escapes this; the check is best-effort when the revision list cannot be read.
//! - `Absent`: look the name up before creating; after creating, look it up again. If another device created the same
//!   name concurrently, the oldest file wins and the newer one is deleted by its writer, which reports
//!   `PreconditionFailed`. Folders created along the way are deduplicated the same way.
//!
//! New files are created with one multipart upload (metadata + content), so no device ever sees an empty file.

use std::collections::HashSet;
use std::time::SystemTime;

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::authorized::{Authorized, Next, Outgoing, Steps};
use crate::client::ClientConfig;
use crate::connection::{AccessScope, Connection};
use crate::entry::{Entry, File, Precondition, Revision};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse, Method, retry_after, status_error};
use crate::operation::{BoxOperation, Ready};
use crate::path::RemotePath;
use crate::providers::{json_request, parse_utc};

const API: &str = "https://www.googleapis.com/drive/v3";
const UPLOAD: &str = "https://www.googleapis.com/upload/drive/v3";
const REVOKE: &str = "https://oauth2.googleapis.com/revoke";
const FOLDER: &str = "application/vnd.google-apps.folder";
const FIELDS: &str = "id,name,mimeType,size,modifiedTime,createdTime,headRevisionId";
const READ_ATTEMPTS: u8 = 3;
/// Name lookups return every duplicate (they are rare) so that all devices pick the same one.
const LOOKUP_PAGE: usize = 100;
/// The maximum page size of `files.list` and `revisions.list`.
const LIST_PAGE: usize = 1000;
/// Drive IDs are `[A-Za-z0-9_-]`; anything else is encoded anyway before it goes into a URL path.
const ID: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_');

// MARK: - Items and requests

#[derive(Clone, Debug)]
struct Item {
    id: String,
    name: String,
    is_dir: bool,
    size: Option<u64>,
    modified_at: Option<SystemTime>,
    created_at: Option<SystemTime>,
    revision: Option<Revision>,
}

impl Item {
    /// My Drive (`root` is an alias Drive accepts wherever an ID is expected).
    fn drive_root() -> Self {
        Self { id: "root".into(), name: String::new(), is_dir: true, size: None, modified_at: None, created_at: None, revision: None }
    }

    fn parse(value: &Value) -> Result<Self, CloudError> {
        let text = |key: &str| value.get(key).and_then(Value::as_str);
        let id = text("id").filter(|id| !id.is_empty()).ok_or(CloudError::InvalidResponse("file id"))?;
        let is_dir = text("mimeType") == Some(FOLDER);
        // `size` is an int64 written as a JSON string.
        let size = match value.get("size") {
            Some(Value::String(size)) => size.parse().ok(),
            Some(size) => size.as_u64(),
            None => None,
        };
        Ok(Self {
            id: id.to_owned(),
            name: text("name").unwrap_or_default().to_owned(),
            is_dir,
            size: if is_dir { None } else { size },
            modified_at: text("modifiedTime").and_then(parse_utc),
            created_at: text("createdTime").and_then(parse_utc),
            revision: if is_dir { None } else { text("headRevisionId").map(Revision::new) },
        })
    }

    fn entry(&self, path: RemotePath) -> Entry {
        Entry { path, is_dir: self.is_dir, size: self.size, modified_at: self.modified_at, revision: self.revision.clone() }
    }
}

fn json_body(response: &HttpResponse) -> Result<Value, CloudError> {
    serde_json::from_slice(&response.body).map_err(|_| CloudError::InvalidResponse("json"))
}

/// Items of a `files.list` page, oldest first (ties broken by ID), and the next page token.
fn files(response: &HttpResponse) -> Result<(Vec<Item>, Option<String>), CloudError> {
    let json = json_body(response)?;
    let mut items = json
        .get("files")
        .and_then(Value::as_array)
        .ok_or(CloudError::InvalidResponse("files"))?
        .iter()
        .map(Item::parse)
        .collect::<Result<Vec<_>, _>>()?;
    oldest_first(&mut items);
    let next = json.get("nextPageToken").and_then(Value::as_str).filter(|token| !token.is_empty()).map(str::to_owned);
    Ok((items, next))
}

/// The oldest item named exactly `name` in a lookup response. The query already filters by name; comparing again keeps the
/// match exact whatever the server's notion of equal names (case, normalization).
fn oldest_named(response: &HttpResponse, name: &str) -> Result<Option<Item>, CloudError> {
    Ok(files(response)?.0.into_iter().find(|item| item.name == name))
}

fn oldest_first(items: &mut [Item]) {
    items.sort_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)));
}

fn reason(response: &HttpResponse) -> String {
    serde_json::from_slice::<Value>(&response.body)
        .ok()
        .and_then(|json| json.pointer("/error/errors/0/reason").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default()
}

/// Drive reports both a full drive and rate limits as 403 with a reason.
fn error_for(response: &HttpResponse) -> CloudError {
    if response.status != 403 {
        return status_error(response);
    }
    match reason(response).as_str() {
        "storageQuotaExceeded" => CloudError::QuotaExceeded,
        "userRateLimitExceeded" | "rateLimitExceeded" | "dailyLimitExceeded" | "sharingRateLimitExceeded" => {
            CloudError::RateLimited { retry_after: retry_after(response) }
        }
        _ => CloudError::Forbidden,
    }
}

/// A string literal in a `files.list` query: `'` and `\` are escaped with a backslash.
fn literal(text: &str) -> String {
    format!("'{}'", text.replace('\\', "\\\\").replace('\'', "\\'"))
}

fn children_query(parent: &str, name: Option<&str>, folders_only: bool) -> String {
    let mut query = format!("{} in parents and trashed = false", literal(parent));
    if let Some(name) = name {
        query.push_str(&format!(" and name = {}", literal(name)));
    }
    if folders_only {
        query.push_str(&format!(" and mimeType = '{FOLDER}'"));
    }
    query
}

/// Oldest first, so that the oldest of many duplicates is on the first page of a lookup; results are sorted again locally
/// (with the ID as tie-breaker) because servers need not agree on ties.
fn search_url(query: &str, page_size: usize, page_token: Option<&str>) -> String {
    let mut params = url::form_urlencoded::Serializer::new(String::new());
    params
        .append_pair("q", query)
        .append_pair("orderBy", "createdTime")
        .append_pair("fields", &format!("nextPageToken,files({FIELDS})"))
        .append_pair("pageSize", &page_size.to_string())
        .append_pair("spaces", "drive");
    if let Some(token) = page_token {
        params.append_pair("pageToken", token);
    }
    format!("{API}/files?{}", params.finish())
}

fn file_url(base: &str, id: &str, suffix: &str) -> String {
    format!("{base}/files/{}{suffix}", utf8_percent_encode(id, ID))
}

fn get(url: String) -> Outgoing {
    Outgoing::authorized(json_request(Method::Get, &url, None))
}

/// Media downloads carry no `Accept: application/json`.
fn download(url: String) -> Outgoing {
    Outgoing::authorized(HttpRequest { method: Method::Get, url, headers: Vec::new(), body: Vec::new() })
}

fn lookup(parent: &str, name: &str, folders_only: bool) -> Outgoing {
    get(search_url(&children_query(parent, Some(name), folders_only), LOOKUP_PAGE, None))
}

fn metadata(id: &str) -> Outgoing {
    get(file_url(API, id, &format!("?fields={FIELDS}")))
}

fn delete(id: &str) -> Outgoing {
    Outgoing::authorized(json_request(Method::Delete, &file_url(API, id, ""), None))
}

fn create_folder(parent: &str, name: &str) -> Outgoing {
    let body = json!({ "name": name, "mimeType": FOLDER, "parents": [parent] });
    Outgoing::authorized(json_request(Method::Post, &format!("{API}/files?fields={FIELDS}"), Some(&body)))
}

/// Creates a file with its content in one request (`multipart/related`: JSON metadata, then the bytes). The boundary is
/// derived from a hash of the content, so it cannot occur in it.
fn create_file(parent: &str, name: &str, data: &[u8]) -> Outgoing {
    let digest = Sha256::digest(data);
    let boundary = format!("cloudset-{}", digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>());
    let metadata = json!({ "name": name, "parents": [parent] });
    let mut body = format!(
        "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata}\r\n--{boundary}\r\nContent-Type: application/octet-stream\r\n\r\n"
    )
    .into_bytes();
    body.extend_from_slice(data);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    Outgoing::authorized(HttpRequest {
        method: Method::Post,
        url: format!("{UPLOAD}/files?uploadType=multipart&fields={FIELDS}"),
        headers: vec![
            ("Accept".into(), "application/json".into()),
            ("Content-Type".into(), format!("multipart/related; boundary={boundary}")),
        ],
        body,
    })
}

/// Replaces a file's content (a new head revision); the metadata is unchanged.
fn upload_content(id: &str, data: Vec<u8>) -> Outgoing {
    Outgoing::authorized(HttpRequest {
        method: Method::Patch,
        url: file_url(UPLOAD, id, &format!("?uploadType=media&fields={FIELDS}")),
        headers: vec![("Accept".into(), "application/json".into()), ("Content-Type".into(), "application/octet-stream".into())],
        body: data,
    })
}

fn revisions(id: &str, page_token: Option<&str>) -> Outgoing {
    let mut url = file_url(API, id, &format!("/revisions?fields=nextPageToken,revisions(id)&pageSize={LIST_PAGE}"));
    if let Some(token) = page_token {
        url.push_str("&pageToken=");
        url.push_str(&url::form_urlencoded::byte_serialize(token.as_bytes()).collect::<String>());
    }
    get(url)
}

// MARK: - Path resolution

#[derive(Clone)]
struct Drive {
    /// Name of the app folder in My Drive; `None` with the `drive` scope.
    app_folder: Option<String>,
}

impl Drive {
    fn of(connection: &Connection) -> Result<Self, CloudError> {
        let credential = connection.oauth_credential().ok_or(CloudError::InvalidConnection)?;
        let app_folder = match credential.access {
            AccessScope::AppFolder => Some(credential.folder_name.clone().ok_or(CloudError::InvalidConnection)?),
            AccessScope::Full => None,
        };
        Ok(Self { app_folder })
    }

    /// Resolves `path`; with `create_parents`, missing directories above the last segment are created. The app folder
    /// itself is always created when missing, so that it exists (and shows up in My Drive) right after sign-in.
    fn walk(&self, path: &RemotePath, create_parents: bool) -> Walk {
        let mut segments: Vec<String> = self.app_folder.iter().cloned().collect();
        let base = segments.len();
        segments.extend(path.segments().iter().cloned());
        let create = if create_parents { base.max(segments.len().saturating_sub(1)) } else { base };
        Walk { segments, create, depth: 0, current: Item::drive_root(), parent: None, state: WalkState::Idle }
    }

    /// Whether the operation on `path` needs no request to find it (the root of My Drive).
    fn is_drive_root(&self, path: &RemotePath) -> bool {
        self.app_folder.is_none() && path.is_root()
    }
}

enum WalkState {
    Idle,
    Lookup,
    Create,
    /// Created a folder; looking the name up again to see whether another device created one at the same time.
    Recheck(Item),
    /// Another device's folder is older: deleting ours, then continuing in theirs.
    Discard(Item),
}

/// Resolves a path segment by segment from the drive root.
struct Walk {
    /// From the drive root, including the app folder.
    segments: Vec<String>,
    /// Directories are created when missing at depths below this.
    create: usize,
    /// Segments resolved so far; `current` is the item at this depth.
    depth: usize,
    current: Item,
    parent: Option<Item>,
    state: WalkState,
}

enum Walked {
    Send(Outgoing),
    /// `item` is the whole path, `parent` the item one level above it (also when the last segment is missing).
    Found {
        item: Option<Item>,
        parent: Option<Item>,
    },
}

impl Walk {
    fn step(&mut self) -> Walked {
        if self.depth == self.segments.len() {
            return Walked::Found { item: Some(self.current.clone()), parent: self.parent.clone() };
        }
        self.state = WalkState::Lookup;
        Walked::Send(lookup(&self.current.id, &self.segments[self.depth], self.depth + 1 < self.segments.len()))
    }

    fn descend(&mut self, item: Item) -> Walked {
        self.parent = Some(std::mem::replace(&mut self.current, item));
        self.depth += 1;
        self.step()
    }

    fn receive(&mut self, response: HttpResponse) -> Result<Walked, CloudError> {
        match std::mem::replace(&mut self.state, WalkState::Idle) {
            WalkState::Lookup => {
                if response.status != 200 {
                    return Err(error_for(&response));
                }
                match oldest_named(&response, &self.segments[self.depth])? {
                    Some(item) => Ok(self.descend(item)),
                    None if self.depth < self.create => {
                        self.state = WalkState::Create;
                        Ok(Walked::Send(create_folder(&self.current.id, &self.segments[self.depth])))
                    }
                    None => {
                        let parent = (self.depth + 1 == self.segments.len()).then(|| self.current.clone());
                        Ok(Walked::Found { item: None, parent })
                    }
                }
            }
            WalkState::Create => {
                if response.status != 200 {
                    return Err(error_for(&response));
                }
                let created = Item::parse(&json_body(&response)?)?;
                self.state = WalkState::Recheck(created);
                Ok(Walked::Send(lookup(&self.current.id, &self.segments[self.depth], true)))
            }
            WalkState::Recheck(created) => {
                if response.status != 200 {
                    return Err(error_for(&response));
                }
                // An empty result (the listing lagging behind the create) keeps ours.
                match oldest_named(&response, &self.segments[self.depth])? {
                    Some(winner) if winner.id != created.id => {
                        let discard = delete(&created.id);
                        self.state = WalkState::Discard(winner);
                        Ok(Walked::Send(discard))
                    }
                    _ => Ok(self.descend(created)),
                }
            }
            WalkState::Discard(winner) => match response.status {
                200 | 204 | 404 => Ok(self.descend(winner)),
                _ => Err(error_for(&response)),
            },
            WalkState::Idle => Err(CloudError::OutOfOrder),
        }
    }
}

/// The first request of an operation: the walk must need one (operations whose walk finishes immediately are handled
/// before they start).
fn first_request(walked: Walked) -> Result<Outgoing, CloudError> {
    match walked {
        Walked::Send(outgoing) => Ok(outgoing),
        Walked::Found { .. } => Err(CloudError::OutOfOrder),
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
    walk: Walk,
    path: RemotePath,
}

impl Steps for Stat {
    type Output = Option<Entry>;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        first_request(self.walk.step())
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Option<Entry>>, CloudError> {
        match self.walk.receive(response)? {
            Walked::Send(outgoing) => Ok(Next::Request(outgoing)),
            Walked::Found { item, .. } => Ok(Next::Done(item.map(|item| item.entry(self.path.clone())))),
        }
    }
}

pub(crate) fn stat(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<Option<Entry>> {
    match Drive::of(connection) {
        Ok(drive) if drive.is_drive_root(&path) => Box::new(Ready::ok(Some(Item::drive_root().entry(path)))),
        drive => op(drive.map(|drive| Stat { walk: drive.walk(&path, false), path }), connection, config),
    }
}

struct List {
    walk: Walk,
    dir: RemotePath,
    folder: Option<String>,
    items: Vec<Item>,
    max_entries: usize,
}

impl List {
    fn page(&self, token: Option<&str>) -> Result<Outgoing, CloudError> {
        let folder = self.folder.as_deref().ok_or(CloudError::OutOfOrder)?;
        Ok(get(search_url(&children_query(folder, None, false), LIST_PAGE, token)))
    }

    fn found(&mut self, item: Option<Item>) -> Result<Outgoing, CloudError> {
        match item {
            Some(item) if item.is_dir => {
                self.folder = Some(item.id);
                self.page(None)
            }
            _ => Err(CloudError::NotFound),
        }
    }

    /// Duplicate names collapse to the oldest item, the one every other operation resolves to.
    fn finish(&mut self) -> Vec<Entry> {
        let mut items = std::mem::take(&mut self.items);
        oldest_first(&mut items);
        let mut seen = HashSet::new();
        let mut entries: Vec<Entry> = items
            .into_iter()
            .filter(|item| seen.insert(item.name.clone()))
            .filter_map(|item| self.dir.join(&item.name).ok().map(|path| item.entry(path)))
            .collect();
        entries.sort_by(|a, b| a.path.cmp(&b.path));
        entries
    }
}

impl Steps for List {
    type Output = Vec<Entry>;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        match self.walk.step() {
            Walked::Send(outgoing) => Ok(outgoing),
            Walked::Found { item, .. } => self.found(item),
        }
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Vec<Entry>>, CloudError> {
        if self.folder.is_none() {
            return match self.walk.receive(response)? {
                Walked::Send(outgoing) => Ok(Next::Request(outgoing)),
                Walked::Found { item, .. } => self.found(item).map(Next::Request),
            };
        }
        if response.status != 200 {
            return Err(match response.status {
                404 => CloudError::NotFound,
                _ => error_for(&response),
            });
        }
        let (items, next) = files(&response)?;
        if self.items.len() + items.len() > self.max_entries {
            return Err(CloudError::TooLarge);
        }
        self.items.extend(items);
        match next {
            Some(token) => self.page(Some(&token)).map(Next::Request),
            None => Ok(Next::Done(self.finish())),
        }
    }
}

pub(crate) fn list(connection: &Connection, config: &ClientConfig, dir: RemotePath) -> BoxOperation<Vec<Entry>> {
    op(
        Drive::of(connection).map(|drive| List {
            walk: drive.walk(&dir, false),
            dir,
            folder: None,
            items: Vec::new(),
            max_entries: config.limits.max_entries,
        }),
        connection,
        config,
    )
}

// MARK: - Reading

enum ReadState {
    Walking,
    Download(Item),
    Verify(Item, Vec<u8>),
}

struct Read {
    walk: Walk,
    path: RemotePath,
    attempts: u8,
    state: ReadState,
}

impl Read {
    fn download(&mut self, item: Item) -> Outgoing {
        self.attempts += 1;
        let request = download(file_url(API, &item.id, "?alt=media"));
        self.state = ReadState::Download(item);
        request
    }
}

impl Steps for Read {
    type Output = Option<File>;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        first_request(self.walk.step())
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Option<File>>, CloudError> {
        match std::mem::replace(&mut self.state, ReadState::Walking) {
            ReadState::Walking => match self.walk.receive(response)? {
                Walked::Send(outgoing) => Ok(Next::Request(outgoing)),
                Walked::Found { item: None, .. } => Ok(Next::Done(None)),
                Walked::Found { item: Some(item), .. } if item.is_dir => Err(CloudError::InvalidResponse("expected a file")),
                Walked::Found { item: Some(item), .. } => Ok(Next::Request(self.download(item))),
            },
            ReadState::Download(item) => match response.status {
                200 => {
                    let verify = metadata(&item.id);
                    self.state = ReadState::Verify(item, response.body);
                    Ok(Next::Request(verify))
                }
                404 => Ok(Next::Done(None)),
                _ => Err(error_for(&response)),
            },
            ReadState::Verify(item, data) => {
                match response.status {
                    200 => {}
                    404 => return Ok(Next::Done(None)),
                    _ => return Err(error_for(&response)),
                }
                let current = Item::parse(&json_body(&response)?)?;
                if current.revision.is_some() && current.revision == item.revision {
                    return Ok(Next::Done(Some(File { data, entry: item.entry(self.path.clone()) })));
                }
                if self.attempts >= READ_ATTEMPTS {
                    return Err(CloudError::PreconditionFailed);
                }
                Ok(Next::Request(self.download(current)))
            }
        }
    }
}

pub(crate) fn read(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<Option<File>> {
    if path.is_root() {
        return Box::new(Ready::err(CloudError::InvalidPath));
    }
    op(
        Drive::of(connection).map(|drive| Read { walk: drive.walk(&path, false), path, attempts: 0, state: ReadState::Walking }),
        connection,
        config,
    )
}

// MARK: - Writing

enum WriteState {
    Walking,
    /// Multipart create sent into this folder.
    Creating {
        parent: Item,
    },
    /// Looking the name up again after creating `ours`.
    Dedupe {
        ours: Item,
    },
    /// Another device's file is older: deleting ours.
    Discard {
        winner: Item,
    },
    Uploading,
    /// Listing the revisions of the file just written (`ours`) to check the one before it.
    Revisions {
        ours: Item,
        expected: Revision,
        ids: Vec<String>,
    },
    /// Another device's revision was overwritten: downloading it to put it back.
    Restore {
        ours: Item,
    },
    Restored,
}

struct Write {
    walk: Walk,
    path: RemotePath,
    data: Zeroizing<Vec<u8>>,
    precondition: Precondition,
    state: WriteState,
}

impl Write {
    fn name(&self) -> Result<&str, CloudError> {
        self.path.name().ok_or(CloudError::InvalidPath)
    }

    fn upload(&mut self, target: &Item) -> Next<Entry> {
        self.state = WriteState::Uploading;
        Next::Request(upload_content(&target.id, self.data.to_vec()))
    }

    fn found(&mut self, item: Option<Item>, parent: Option<Item>) -> Result<Next<Entry>, CloudError> {
        match (item, &self.precondition) {
            (Some(_), Precondition::Absent) => Err(CloudError::PreconditionFailed),
            (Some(item), Precondition::Matches(_)) if item.is_dir => Err(CloudError::PreconditionFailed),
            (Some(item), _) if item.is_dir => Err(CloudError::Forbidden),
            (Some(item), Precondition::Matches(expected)) if item.revision.as_ref() != Some(expected) => {
                Err(CloudError::PreconditionFailed)
            }
            (Some(item), _) => Ok(self.upload(&item)),
            (None, Precondition::Matches(_)) => Err(CloudError::PreconditionFailed),
            (None, _) => {
                let parent = parent.ok_or(CloudError::NotFound)?;
                let request = create_file(&parent.id, self.name()?, &self.data);
                self.state = WriteState::Creating { parent };
                Ok(Next::Request(request))
            }
        }
    }

    /// The verification after an upload could not run: the write itself succeeded, so report it as such.
    fn unverified(ours: &Item, path: &RemotePath) -> Next<Entry> {
        Next::Done(ours.entry(path.clone()))
    }
}

impl Steps for Write {
    type Output = Entry;

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        first_request(self.walk.step())
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<Entry>, CloudError> {
        match std::mem::replace(&mut self.state, WriteState::Walking) {
            WriteState::Walking => match self.walk.receive(response)? {
                Walked::Send(outgoing) => Ok(Next::Request(outgoing)),
                Walked::Found { item, parent } => self.found(item, parent),
            },
            WriteState::Creating { parent } => {
                if response.status != 200 {
                    return Err(error_for(&response));
                }
                let ours = Item::parse(&json_body(&response)?)?;
                let request = lookup(&parent.id, self.name()?, false);
                self.state = WriteState::Dedupe { ours };
                Ok(Next::Request(request))
            }
            WriteState::Dedupe { ours } => {
                if response.status != 200 {
                    return Ok(Self::unverified(&ours, &self.path));
                }
                match oldest_named(&response, self.name()?)? {
                    Some(winner) if winner.id != ours.id => {
                        self.state = WriteState::Discard { winner };
                        Ok(Next::Request(delete(&ours.id)))
                    }
                    _ => Ok(Next::Done(ours.entry(self.path.clone()))),
                }
            }
            WriteState::Discard { winner } => match (response.status, &self.precondition) {
                (200 | 204 | 404, Precondition::None) if !winner.is_dir => Ok(self.upload(&winner)),
                (200 | 204 | 404, Precondition::None) => Err(CloudError::Forbidden),
                (200 | 204 | 404, _) => Err(CloudError::PreconditionFailed),
                _ => Err(error_for(&response)),
            },
            WriteState::Uploading => match response.status {
                200 => {
                    let ours = Item::parse(&json_body(&response)?)?;
                    match &self.precondition {
                        Precondition::Matches(expected) => {
                            let request = revisions(&ours.id, None);
                            self.state = WriteState::Revisions { ours, expected: expected.clone(), ids: Vec::new() };
                            Ok(Next::Request(request))
                        }
                        _ => Ok(Next::Done(ours.entry(self.path.clone()))),
                    }
                }
                // Deleted since the lookup, which also counts as "changed".
                404 if matches!(self.precondition, Precondition::Matches(_)) => Err(CloudError::PreconditionFailed),
                _ => Err(error_for(&response)),
            },
            WriteState::Revisions { ours, expected, mut ids } => {
                if response.status != 200 {
                    return Ok(Self::unverified(&ours, &self.path));
                }
                let json = json_body(&response)?;
                let page = json.get("revisions").and_then(Value::as_array).ok_or(CloudError::InvalidResponse("revisions"))?;
                ids.extend(page.iter().filter_map(|revision| revision.get("id").and_then(Value::as_str)).map(str::to_owned));
                if let Some(token) = json.get("nextPageToken").and_then(Value::as_str).filter(|token| !token.is_empty()) {
                    let request = revisions(&ours.id, Some(token));
                    self.state = WriteState::Revisions { ours, expected, ids };
                    return Ok(Next::Request(request));
                }
                let head = ours.revision.as_ref().map(Revision::as_str);
                let previous =
                    ids.iter().position(|id| Some(id.as_str()) == head).and_then(|index| index.checked_sub(1)).map(|index| &ids[index]);
                match previous {
                    Some(previous) if previous != expected.as_str() => {
                        let request =
                            download(file_url(API, &ours.id, &format!("/revisions/{}?alt=media", utf8_percent_encode(previous, ID))));
                        self.state = WriteState::Restore { ours };
                        Ok(Next::Request(request))
                    }
                    _ => Ok(Next::Done(ours.entry(self.path.clone()))),
                }
            }
            WriteState::Restore { ours } => {
                if response.status != 200 {
                    return Err(CloudError::PreconditionFailed);
                }
                self.state = WriteState::Restored;
                Ok(Next::Request(upload_content(&ours.id, response.body)))
            }
            // Whether or not putting the other device's version back worked, this write lost the race.
            WriteState::Restored => Err(CloudError::PreconditionFailed),
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
    op(
        Drive::of(connection).map(|drive| Write {
            walk: drive.walk(&path, true),
            path,
            data: Zeroizing::new(data),
            precondition,
            state: WriteState::Walking,
        }),
        connection,
        config,
    )
}

// MARK: - Directories and deletion

enum CreateState {
    Walking,
    Creating { parent: Item },
    Dedupe { ours: Item },
    Discard,
}

struct CreateDir {
    walk: Walk,
    path: RemotePath,
    state: CreateState,
}

impl Steps for CreateDir {
    type Output = ();

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        first_request(self.walk.step())
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<()>, CloudError> {
        let name = self.path.name().ok_or(CloudError::InvalidPath)?;
        match std::mem::replace(&mut self.state, CreateState::Walking) {
            CreateState::Walking => match self.walk.receive(response)? {
                Walked::Send(outgoing) => Ok(Next::Request(outgoing)),
                Walked::Found { item: Some(item), .. } if item.is_dir => Ok(Next::Done(())),
                Walked::Found { item: Some(_), .. } => Err(CloudError::Forbidden),
                Walked::Found { item: None, parent: None } => Err(CloudError::NotFound),
                Walked::Found { item: None, parent: Some(parent) } => {
                    let request = create_folder(&parent.id, name);
                    self.state = CreateState::Creating { parent };
                    Ok(Next::Request(request))
                }
            },
            CreateState::Creating { parent } => {
                if response.status != 200 {
                    return Err(error_for(&response));
                }
                let ours = Item::parse(&json_body(&response)?)?;
                self.state = CreateState::Dedupe { ours };
                Ok(Next::Request(lookup(&parent.id, name, true)))
            }
            CreateState::Dedupe { ours } => match oldest_named(&response, name) {
                Ok(Some(winner)) if response.status == 200 && winner.id != ours.id => {
                    self.state = CreateState::Discard;
                    Ok(Next::Request(delete(&ours.id)))
                }
                _ => Ok(Next::Done(())),
            },
            // The folder exists either way; an orphaned duplicate is harmless.
            CreateState::Discard => Ok(Next::Done(())),
        }
    }
}

pub(crate) fn create_dir(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<()> {
    match Drive::of(connection) {
        Ok(drive) if drive.is_drive_root(&path) => Box::new(Ready::ok(())),
        drive => op(drive.map(|drive| CreateDir { walk: drive.walk(&path, false), path, state: CreateState::Walking }), connection, config),
    }
}

struct Delete {
    walk: Walk,
    deleting: bool,
}

impl Steps for Delete {
    type Output = ();

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        first_request(self.walk.step())
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<()>, CloudError> {
        if self.deleting {
            return match response.status {
                200 | 204 | 404 => Ok(Next::Done(())),
                _ => Err(error_for(&response)),
            };
        }
        match self.walk.receive(response)? {
            Walked::Send(outgoing) => Ok(Next::Request(outgoing)),
            Walked::Found { item: None, .. } => Ok(Next::Done(())),
            Walked::Found { item: Some(item), .. } => {
                self.deleting = true;
                Ok(Next::Request(delete(&item.id)))
            }
        }
    }
}

pub(crate) fn delete_path(connection: &Connection, config: &ClientConfig, path: RemotePath) -> BoxOperation<()> {
    if path.is_root() {
        return Box::new(Ready::err(CloudError::InvalidPath));
    }
    op(Drive::of(connection).map(|drive| Delete { walk: drive.walk(&path, false), deleting: false }), connection, config)
}

// MARK: - Revocation

/// Revoking the refresh token ends the whole grant. It goes to the OAuth origin without a bearer token; the token is the
/// form body. A token Google no longer knows (400) counts as revoked.
struct Revoke {
    token: Zeroizing<String>,
}

impl Steps for Revoke {
    type Output = ();

    fn first(&mut self) -> Result<Outgoing, CloudError> {
        let body = url::form_urlencoded::Serializer::new(String::new()).append_pair("token", &self.token).finish();
        Ok(Outgoing {
            request: HttpRequest {
                method: Method::Post,
                url: REVOKE.to_owned(),
                headers: vec![("Content-Type".into(), "application/x-www-form-urlencoded".into())],
                body: Zeroizing::new(body).as_bytes().to_vec(),
            },
            authorize: false,
        })
    }

    fn next(&mut self, response: HttpResponse) -> Result<Next<()>, CloudError> {
        match response.status {
            200 | 400 => Ok(Next::Done(())),
            _ => Err(status_error(&response)),
        }
    }
}

pub(crate) fn revoke(connection: &Connection, config: &ClientConfig) -> BoxOperation<()> {
    let token = connection.oauth_credential().map(|credential| credential.refresh_token.clone()).ok_or(CloudError::InvalidConnection);
    op(token.map(|token| Revoke { token }), connection, config)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response(status: u16, body: &str) -> HttpResponse {
        HttpResponse { status, headers: Vec::new(), body: body.as_bytes().to_vec() }
    }

    #[test]
    fn queries_escape_names() {
        assert_eq!(literal(r"O'Brien \ co"), r"'O\'Brien \\ co'");
        assert_eq!(
            children_query("root", Some("a'b"), true),
            "'root' in parents and trashed = false and name = 'a\\'b' and mimeType = 'application/vnd.google-apps.folder'"
        );
        let url = url::Url::parse(&search_url(&children_query("id-1", None, false), 7, Some("next/page"))).unwrap();
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query["q"], "'id-1' in parents and trashed = false");
        assert_eq!((query["pageSize"].as_str(), query["pageToken"].as_str(), query["spaces"].as_str()), ("7", "next/page", "drive"));
        assert_eq!(file_url(API, "a/b?c", "?alt=media"), "https://www.googleapis.com/drive/v3/files/a%2Fb%3Fc?alt=media");
    }

    #[test]
    fn parses_items_and_picks_the_oldest_duplicate() {
        let item = Item::parse(&json!({
            "id": "f1", "name": "vault.bin", "mimeType": "application/octet-stream", "size": "2741",
            "modifiedTime": "2026-10-28T09:12:40.123Z", "createdTime": "2026-10-01T00:00:00Z", "headRevisionId": "0B-rev"
        }))
        .unwrap();
        assert_eq!((item.is_dir, item.size, item.revision.as_ref().map(Revision::as_str)), (false, Some(2741), Some("0B-rev")));
        let folder = Item::parse(&json!({ "id": "d1", "name": "Docs", "mimeType": FOLDER, "headRevisionId": "x" })).unwrap();
        assert_eq!((folder.is_dir, folder.revision), (true, None));
        assert!(Item::parse(&json!({ "name": "no id" })).is_err());

        let page = response(
            200,
            r#"{"files":[
                {"id":"b","name":"x","createdTime":"2026-10-02T00:00:00Z"},
                {"id":"c","name":"x","createdTime":"2026-10-01T00:00:00Z"},
                {"id":"a","name":"x","createdTime":"2026-10-02T00:00:00Z"}
            ],"nextPageToken":"t"}"#,
        );
        let (items, next) = files(&page).unwrap();
        assert_eq!(items.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), ["c", "a", "b"], "creation time, then ID");
        assert_eq!(next.as_deref(), Some("t"));
    }

    #[test]
    fn lookups_match_names_exactly() {
        let page = response(
            200,
            r#"{"files":[
                {"id":"a","name":"Vault.bin","createdTime":"2026-10-01T00:00:00Z"},
                {"id":"b","name":"vault.bin","createdTime":"2026-10-02T00:00:00Z"}
            ]}"#,
        );
        assert_eq!(oldest_named(&page, "vault.bin").unwrap().map(|item| item.id), Some("b".to_owned()));
        assert!(oldest_named(&page, "VAULT.BIN").unwrap().is_none());
        let url = url::Url::parse(&search_url("'root' in parents", 1, None)).unwrap();
        assert!(url.query_pairs().any(|(key, value)| key == "orderBy" && value == "createdTime"));
    }

    #[test]
    fn maps_drive_errors() {
        let error = |status: u16, reason: &str| {
            error_for(&response(status, &json!({ "error": { "code": status, "errors": [{ "reason": reason }] } }).to_string()))
        };
        assert_eq!(error(403, "storageQuotaExceeded"), CloudError::QuotaExceeded);
        assert_eq!(error(403, "userRateLimitExceeded"), CloudError::RateLimited { retry_after: None });
        assert_eq!(error(403, "insufficientFilePermissions"), CloudError::Forbidden);
        assert_eq!(error(404, "notFound"), CloudError::NotFound);
        assert_eq!(error(429, "rateLimitExceeded"), CloudError::RateLimited { retry_after: None });
    }

    #[test]
    fn multipart_boundary_comes_from_the_content() {
        let outgoing = create_file("parent", "vault.bin", b"\x00ciphertext");
        let content_type = outgoing.request.header("Content-Type").unwrap().to_owned();
        let boundary = content_type.strip_prefix("multipart/related; boundary=").unwrap();
        assert!(boundary.starts_with("cloudset-") && boundary.len() == "cloudset-".len() + 32);
        let body = &outgoing.request.body;
        assert!(body.starts_with(format!("--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n").as_bytes()));
        assert!(body.ends_with(format!("\x00ciphertext\r\n--{boundary}--\r\n").as_bytes()));
        assert_ne!(create_file("parent", "vault.bin", b"other").request.header("Content-Type"), Some(content_type.as_str()));
    }
}
