//! The Google Drive part of [`super::MemoryCloud`]: an ID-based store with the request and response shapes of Drive API
//! v3 (`files.list` with the query subset the component sends, metadata, `alt=media`, multipart create, media update,
//! revisions, `about`).
//!
//! Like the real service, names are not unique within a folder, and with the `drive.file` scope only files created by the
//! app are visible (anything else is 404 or missing from listings). Files written through [`Store::put_external`] count
//! as created by the app when they lie inside its folder ([`GOOGLE_APP_FOLDER`]), i.e. by the same app on another device.

use std::collections::{BTreeMap, HashMap};

use serde_json::{Value, json};
use url::Url;

use crate::http::{HttpRequest, HttpResponse, Method};

/// Name of the app folder in My Drive used by the tests (the caller's `OAuthClient::folder_name`).
pub const GOOGLE_APP_FOLDER: &str = "cloudset-test";

const FOLDER: &str = "application/vnd.google-apps.folder";
const ROOT: &str = "root-id";

#[derive(Clone, Debug)]
struct Item {
    name: String,
    parent: String,
    is_dir: bool,
    /// Revision IDs with their content, oldest first; the last is the head.
    revisions: Vec<(String, Vec<u8>)>,
    created: u32,
    by_app: bool,
}

/// Concurrent "other device" actions, each fired once before the matching request.
#[derive(Clone, Copy, Debug, Default)]
pub struct Races {
    /// Before the next media update, another device uploads `changed elsewhere` to the same file.
    pub before_update: bool,
    /// Before the next create (file or folder), another device creates the same name in the same folder.
    pub before_create: bool,
}

pub(super) struct Store {
    items: BTreeMap<String, Item>,
    next: u32,
    pub races: Races,
    /// Mirrors `MemoryCloud::modify_before_download`.
    pub(super) modify_before_download: u8,
}

fn response(status: u16, body: Value) -> HttpResponse {
    HttpResponse { status, headers: vec![("Content-Type".into(), "application/json".into())], body: body.to_string().into_bytes() }
}

fn error(status: u16, reason: &str) -> HttpResponse {
    response(status, json!({ "error": { "code": status, "message": reason, "errors": [{ "domain": "global", "reason": reason }] } }))
}

fn split(path: &str) -> Vec<String> {
    path.split('/').filter(|part| !part.is_empty()).map(str::to_owned).collect()
}

/// Splits a query on ` and ` outside string literals and reads each clause of the subset the component generates.
fn parse_query(query: &str) -> HashMap<&'static str, String> {
    let mut clauses = Vec::new();
    let (mut current, mut quoted, mut escaped) = (String::new(), false, false);
    let mut rest = query;
    while let Some(c) = rest.chars().next() {
        if !quoted && rest.starts_with(" and ") {
            clauses.push(std::mem::take(&mut current));
            rest = &rest[5..];
            continue;
        }
        if escaped {
            escaped = false;
        } else if c == '\\' {
            escaped = true;
        } else if c == '\'' {
            quoted = !quoted;
        }
        current.push(c);
        rest = &rest[c.len_utf8()..];
    }
    clauses.push(current);
    let literal = |text: &str| -> String {
        let inner = text.strip_prefix('\'').and_then(|text| text.strip_suffix('\'')).expect("string literal");
        let mut out = String::new();
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                out.push(chars.next().expect("escaped character"));
            } else {
                assert!(c != '\'', "unescaped quote in {text}");
                out.push(c);
            }
        }
        out
    };
    let mut parsed = HashMap::new();
    for clause in clauses {
        if let Some(parent) = clause.strip_suffix(" in parents") {
            parsed.insert("parent", literal(parent));
        } else if clause == "trashed = false" {
            parsed.insert("trashed", "false".into());
        } else if let Some(name) = clause.strip_prefix("name = ") {
            parsed.insert("name", literal(name));
        } else if let Some(mime) = clause.strip_prefix("mimeType = ") {
            parsed.insert("mimeType", literal(mime));
        } else {
            panic!("unsupported query clause: {clause}");
        }
    }
    assert!(parsed.contains_key("parent") && parsed.contains_key("trashed"), "queries are scoped to one folder: {query}");
    parsed
}

/// Reads `multipart/related`: JSON metadata, then the content.
fn parse_multipart(request: &HttpRequest) -> (Value, Vec<u8>) {
    let content_type = request.header("Content-Type").expect("content type");
    let boundary = content_type.strip_prefix("multipart/related; boundary=").expect("multipart/related");
    let body = &request.body;
    let delimiter = format!("--{boundary}");
    let find = |from: usize, needle: &[u8]| body[from..].windows(needle.len()).position(|window| window == needle).map(|at| at + from);
    let mut parts = Vec::new();
    let mut at = find(0, delimiter.as_bytes()).expect("first boundary") + delimiter.len();
    while !body[at..].starts_with(b"--") {
        let headers_end = find(at, b"\r\n\r\n").expect("part headers") + 4;
        let end = find(headers_end, format!("\r\n{delimiter}").as_bytes()).expect("closing boundary");
        parts.push(body[headers_end..end].to_vec());
        at = end + 2 + delimiter.len();
    }
    assert_eq!(parts.len(), 2, "metadata and content");
    (serde_json::from_slice(&parts[0]).expect("metadata json"), parts[1].clone())
}

impl Store {
    pub(super) fn new() -> Self {
        let mut items = BTreeMap::new();
        items.insert(
            ROOT.to_owned(),
            Item { name: "My Drive".into(), parent: String::new(), is_dir: true, revisions: Vec::new(), created: 0, by_app: false },
        );
        Self { items, next: 1, races: Races::default(), modify_before_download: 0 }
    }

    fn id(&self, id: &str) -> String {
        if id == "root" { ROOT.to_owned() } else { id.to_owned() }
    }

    fn visible(&self, id: &str, app_only: bool) -> bool {
        self.items.get(id).is_some_and(|item| id == ROOT || !app_only || item.by_app)
    }

    /// Children named `name` (any visibility), oldest first.
    fn named(&self, parent: &str, name: &str) -> Vec<String> {
        let mut ids: Vec<(u32, String)> = self
            .items
            .iter()
            .filter(|(_, item)| item.parent == parent && item.name == name)
            .map(|(id, item)| (item.created, id.clone()))
            .collect();
        ids.sort();
        ids.into_iter().map(|(_, id)| id).collect()
    }

    fn insert(&mut self, parent: &str, name: &str, is_dir: bool, data: Option<Vec<u8>>, by_app: bool) -> String {
        self.next += 1;
        let id = format!("id{:04}", self.next);
        let revisions = data.map(|data| vec![(format!("rev{:04}", self.next), data)]).unwrap_or_default();
        self.items.insert(id.clone(), Item { name: name.into(), parent: parent.into(), is_dir, revisions, created: self.next, by_app });
        id
    }

    fn add_revision(&mut self, id: &str, data: Vec<u8>) {
        self.next += 1;
        let revision = format!("rev{:04}", self.next);
        if let Some(item) = self.items.get_mut(id) {
            item.revisions.push((revision, data));
        }
    }

    /// The item at a path from the drive root (oldest of duplicates), any visibility.
    fn resolve(&self, path: &str) -> Option<String> {
        let mut current = ROOT.to_owned();
        for segment in split(path) {
            current = self.named(&current, &segment).into_iter().next()?;
        }
        Some(current)
    }

    pub(super) fn put_external(&mut self, path: &str, data: &[u8]) {
        let segments = split(path);
        let by_app = segments.first().map(String::as_str) == Some(GOOGLE_APP_FOLDER);
        let mut current = ROOT.to_owned();
        for (index, segment) in segments.iter().enumerate() {
            let last = index + 1 == segments.len();
            current = match self.named(&current, segment).into_iter().next() {
                Some(id) if last => {
                    self.add_revision(&id, data.to_vec());
                    return;
                }
                Some(id) => id,
                None if last => {
                    self.insert(&current, segment, false, Some(data.to_vec()), by_app);
                    return;
                }
                None => self.insert(&current, segment, true, None, by_app),
            };
        }
    }

    pub(super) fn data(&self, path: &str) -> Option<Vec<u8>> {
        let item = self.items.get(&self.resolve(path)?)?;
        item.revisions.last().map(|(_, data)| data.clone())
    }

    pub(super) fn exists(&self, path: &str) -> bool {
        self.resolve(path).is_some()
    }

    /// How many items named like the last segment sit in that folder.
    pub(super) fn copies(&self, path: &str) -> usize {
        let segments = split(path);
        let Some((name, parents)) = segments.split_last() else { return 1 };
        self.resolve(&parents.join("/")).map_or(0, |parent| self.named(&parent, name).len())
    }

    fn timestamp(seconds: u32) -> String {
        format!("2026-10-28T{:02}:{:02}:{:02}Z", seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
    }

    fn metadata(&self, id: &str) -> Value {
        let item = &self.items[id];
        let mut value = json!({
            "kind": "drive#file",
            "id": id,
            "name": item.name,
            "mimeType": if item.is_dir { FOLDER } else { "application/octet-stream" },
            "createdTime": Self::timestamp(item.created),
            "modifiedTime": Self::timestamp(item.revisions.len() as u32 + item.created),
        });
        if let Some((revision, data)) = item.revisions.last() {
            value["size"] = json!(data.len().to_string());
            value["headRevisionId"] = json!(revision);
        }
        value
    }

    pub(super) fn handle(&mut self, url: &Url, request: &HttpRequest, app_only: bool, page_size: usize) -> HttpResponse {
        let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
        let path = url.path();
        if path == "/drive/v3/about" {
            return response(
                200,
                json!({ "user": { "kind": "drive#user", "displayName": "Alice Example", "emailAddress": "alice@gmail.com" } }),
            );
        }
        if path == "/drive/v3/files" && request.method == Method::Get {
            return self.list(&query, app_only, page_size);
        }
        if path == "/drive/v3/files" && request.method == Method::Post {
            let body: Value = serde_json::from_slice(&request.body).expect("metadata json");
            assert_eq!(body["mimeType"], FOLDER, "metadata-only creation is used for folders");
            return self.create(&body, None, app_only);
        }
        if path == "/upload/drive/v3/files" {
            assert_eq!((request.method, query.get("uploadType").map(String::as_str)), (Method::Post, Some("multipart")));
            let (metadata, data) = parse_multipart(request);
            return self.create(&metadata, Some(data), app_only);
        }
        let (upload, rest) = match (path.strip_prefix("/upload/drive/v3/files/"), path.strip_prefix("/drive/v3/files/")) {
            (Some(rest), _) => (true, rest),
            (None, Some(rest)) => (false, rest),
            _ => return error(404, "notFound"),
        };
        let mut parts = rest.splitn(3, '/');
        let id = self.id(parts.next().unwrap_or_default());
        if !self.visible(&id, app_only) {
            return error(404, "notFound");
        }
        match (upload, request.method, parts.next(), parts.next()) {
            (true, Method::Patch, None, None) => {
                assert_eq!(query.get("uploadType").map(String::as_str), Some("media"));
                if self.items[&id].is_dir {
                    return error(400, "invalid");
                }
                if std::mem::take(&mut self.races.before_update) {
                    self.add_revision(&id, b"changed elsewhere".to_vec());
                }
                self.add_revision(&id, request.body.clone());
                response(200, self.metadata(&id))
            }
            (false, Method::Get, None, None) if query.get("alt").map(String::as_str) == Some("media") => {
                if self.modify_before_download > 0 {
                    self.modify_before_download -= 1;
                    self.add_revision(&id, b"changed elsewhere".to_vec());
                }
                match self.items[&id].revisions.last() {
                    Some((_, data)) => HttpResponse { status: 200, headers: Vec::new(), body: data.clone() },
                    None => error(403, "fileNotDownloadable"),
                }
            }
            (false, Method::Get, None, None) => response(200, self.metadata(&id)),
            (false, Method::Delete, None, None) => {
                let mut doomed = vec![id];
                while let Some(id) = doomed.pop() {
                    self.items.remove(&id);
                    doomed.extend(self.items.iter().filter(|(_, item)| item.parent == id).map(|(child, _)| child.clone()));
                }
                HttpResponse::new(204)
            }
            (false, Method::Get, Some("revisions"), None) => {
                let all: Vec<Value> =
                    self.items[&id].revisions.iter().map(|(revision, _)| json!({ "kind": "drive#revision", "id": revision })).collect();
                let offset: usize = query.get("pageToken").and_then(|token| token.parse().ok()).unwrap_or(0);
                let end = (offset + page_size).min(all.len());
                let mut body = json!({ "revisions": all[offset..end] });
                if end < all.len() {
                    body["nextPageToken"] = json!(end.to_string());
                }
                response(200, body)
            }
            (false, Method::Get, Some("revisions"), Some(revision)) => {
                assert_eq!(query.get("alt").map(String::as_str), Some("media"));
                match self.items[&id].revisions.iter().find(|(candidate, _)| candidate == revision) {
                    Some((_, data)) => HttpResponse { status: 200, headers: Vec::new(), body: data.clone() },
                    None => error(404, "revisionNotFound"),
                }
            }
            _ => error(400, "invalid"),
        }
    }

    fn list(&self, query: &HashMap<String, String>, app_only: bool, page_size: usize) -> HttpResponse {
        let filter = parse_query(query.get("q").expect("q"));
        let parent = self.id(&filter["parent"]);
        if !self.visible(&parent, app_only) {
            return error(404, "notFound");
        }
        // Newest first: the component must not rely on the server's order.
        let mut ids: Vec<(u32, &String)> = self
            .items
            .iter()
            .filter(|(id, item)| {
                item.parent == parent
                    && self.visible(id, app_only)
                    && filter.get("name").is_none_or(|name| &item.name == name)
                    && filter.get("mimeType").is_none_or(|mime| (mime == FOLDER) == item.is_dir)
            })
            .map(|(id, item)| (item.created, id))
            .collect();
        ids.sort_by(|a, b| b.cmp(a));
        let size = query.get("pageSize").and_then(|size| size.parse().ok()).unwrap_or(100).min(page_size);
        let offset: usize = query.get("pageToken").and_then(|token| token.parse().ok()).unwrap_or(0);
        let end = (offset + size).min(ids.len());
        let files: Vec<Value> = ids[offset..end].iter().map(|(_, id)| self.metadata(id)).collect();
        let mut body = json!({ "kind": "drive#fileList", "incompleteSearch": false, "files": files });
        if end < ids.len() {
            body["nextPageToken"] = json!(end.to_string());
        }
        response(200, body)
    }

    fn create(&mut self, metadata: &Value, data: Option<Vec<u8>>, app_only: bool) -> HttpResponse {
        let name = metadata["name"].as_str().expect("name").to_owned();
        let parent = self.id(metadata["parents"][0].as_str().expect("one parent"));
        if !self.visible(&parent, app_only) {
            return error(404, "notFound");
        }
        let is_dir = data.is_none();
        if std::mem::take(&mut self.races.before_create) {
            self.insert(&parent, &name, is_dir, (!is_dir).then(|| b"other device".to_vec()), true);
        }
        let id = self.insert(&parent, &name, is_dir, data, true);
        response(200, self.metadata(&id))
    }
}
