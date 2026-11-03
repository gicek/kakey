//! In-memory Dropbox / OneDrive / Google Drive for tests (`testing` feature): implements the endpoints the component uses with the
//! request and response shapes of the official APIs, plus authorization pages and token endpoints. The authorization page
//! records the PKCE challenge and the token exchange checks the verifier, so sign-in can be tested end to end.
//!
//! Access scopes are isolated like the real services: authorization records the scope from the Dropbox app key (app
//! type) or the scope requested from OneDrive. Under the app folder scope, Dropbox paths are rooted at [`APP_FOLDER`],
//! OneDrive's `special/approot` maps to [`APP_FOLDER`], and accessing `root` returns 403. Google Drive (an ID-based store,
//! see `testing_gdrive.rs`) keeps its app folder at [`GOOGLE_APP_FOLDER`] in My Drive and hides files the app did not
//! create under `drive.file`. `put_external` / `data` / `exists` take paths within the whole drive; [`MemoryCloud::app_folder`]
//! gives the provider's app folder location.

use std::collections::{BTreeMap, HashMap};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use percent_encoding::{NON_ALPHANUMERIC, percent_decode_str, utf8_percent_encode};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use url::Url;

use crate::connection::AccessScope;
use crate::http::{HttpRequest, HttpResponse, Method};

#[path = "testing_gdrive.rs"]
mod gdrive;
pub use gdrive::{GOOGLE_APP_FOLDER, Races};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FakeProvider {
    Dropbox,
    OneDrive,
    GoogleDrive,
}

#[derive(Clone, Debug)]
enum Node {
    Dir,
    File { data: Vec<u8>, version: u32 },
}

/// Location of the app-specific folder within the whole drive (the root of a Dropbox App folder app, and OneDrive's
/// `special/approot`).
pub const APP_FOLDER: &str = "Apps/cloudset-test";

/// Dropbox sets the permission type per app: authorizing with this app key grants the whole drive, any other key the app
/// folder.
pub const DROPBOX_FULL_APP_KEY: &str = "full-app-key";

/// In-memory cloud drive: one tree represents the whole drive; the root always exists.
pub struct MemoryCloud {
    pub provider: FakeProvider,
    /// Access scope from the most recent authorization; every token issued afterwards has this scope.
    pub granted: Option<AccessScope>,
    nodes: BTreeMap<Vec<String>, Node>,
    next_version: u32,
    pub requests: Vec<HttpRequest>,
    /// The currently valid access token; anything else gets a 401.
    pub access_token: String,
    pub refresh_token: String,
    /// Whether refreshing rotates the refresh token (Microsoft does).
    pub rotate_refresh_token: bool,
    /// The refresh token was revoked: refreshing returns 400 invalid_grant.
    pub revoked: bool,
    /// Maximum children per page (for testing paging).
    pub page_size: usize,
    /// Before each of the next N downloads, "another device" modifies the target file first.
    pub modify_before_download: u8,
    issued: u32,
    challenge: Option<String>,
    code: Option<String>,
    google: gdrive::Store,
}

/// Origin of OneDrive's pre-signed download URLs (a different origin from Graph, without credentials).
pub const ONEDRIVE_DOWNLOAD_HOST: &str = "public.dl.example.net";

fn response(status: u16, body: Value) -> HttpResponse {
    HttpResponse { status, headers: vec![("Content-Type".into(), "application/json".into())], body: body.to_string().into_bytes() }
}

fn dropbox_error(summary: &str) -> HttpResponse {
    response(409, json!({ "error_summary": summary, "error": {} }))
}

fn graph_error(status: u16, code: &str) -> HttpResponse {
    response(status, json!({ "error": { "code": code, "message": code } }))
}

fn split(path: &str) -> Vec<String> {
    path.split('/').filter(|part| !part.is_empty()).map(str::to_owned).collect()
}

impl MemoryCloud {
    pub fn new(provider: FakeProvider) -> Self {
        let mut nodes = BTreeMap::new();
        nodes.insert(Vec::new(), Node::Dir);
        Self {
            provider,
            granted: None,
            nodes,
            next_version: 1,
            requests: Vec::new(),
            access_token: String::new(),
            refresh_token: String::new(),
            rotate_refresh_token: provider == FakeProvider::OneDrive,
            revoked: false,
            page_size: 2,
            modify_before_download: 0,
            issued: 0,
            challenge: None,
            code: None,
            google: gdrive::Store::new(),
        }
    }

    /// Where the provider keeps the app folder within the whole drive.
    pub fn app_folder(&self) -> &'static str {
        if self.provider == FakeProvider::GoogleDrive { GOOGLE_APP_FOLDER } else { APP_FOLDER }
    }

    /// Concurrent writes by another device (Google Drive), fired once before the matching request.
    pub fn races(&mut self) -> &mut Races {
        &mut self.google.races
    }

    /// Google Drive: how many items with the last segment's name are in that folder (names are not unique there).
    pub fn copies(&self, path: &str) -> usize {
        if self.provider == FakeProvider::GoogleDrive { self.google.copies(path) } else { usize::from(self.exists(path)) }
    }

    /// Simulates the user clicking "Allow" on the authorization page: records the challenge and returns the callback URL
    /// with the authorization code and the original `state`.
    pub fn authorize(&mut self, authorization_url: &str) -> String {
        let url = Url::parse(authorization_url).expect("authorization url");
        let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
        assert_eq!(query.get("code_challenge_method").map(String::as_str), Some("S256"));
        assert_eq!(query.get("response_type").map(String::as_str), Some("code"));
        self.challenge = query.get("code_challenge").cloned();
        let granted = match self.provider {
            FakeProvider::Dropbox if query.get("client_id").map(String::as_str) == Some(DROPBOX_FULL_APP_KEY) => AccessScope::Full,
            FakeProvider::Dropbox => AccessScope::AppFolder,
            FakeProvider::OneDrive => {
                let scopes = query.get("scope").map(String::as_str).unwrap_or_default();
                Self::onedrive_scope(scopes).expect("OneDrive authorization must include offline_access and a Files.* scope")
            }
            FakeProvider::GoogleDrive => match query.get("scope").map(String::as_str) {
                Some("https://www.googleapis.com/auth/drive.file") => AccessScope::AppFolder,
                Some("https://www.googleapis.com/auth/drive") => AccessScope::Full,
                other => panic!("unexpected Google scope {other:?}"),
            },
        };
        if granted == AccessScope::AppFolder && self.provider == FakeProvider::Dropbox {
            // Dropbox creates the app folder as soon as the user authorizes.
            self.ensure_dirs(&split(APP_FOLDER));
        }
        self.granted = Some(granted);
        self.code = Some(format!("code-{}", self.issued));
        let mut callback = Url::parse(&query["redirect_uri"]).expect("redirect uri");
        callback.query_pairs_mut().append_pair("code", self.code.as_deref().unwrap_or_default()).append_pair("state", &query["state"]);
        if self.provider == FakeProvider::GoogleDrive {
            // Google echoes the granted scope and its issuer.
            callback.query_pairs_mut().append_pair("scope", &query["scope"]).append_pair("iss", "https://accounts.google.com");
        }
        callback.into()
    }

    /// Invalidates the current access token (simulating expiry); the next request carrying it gets a 401.
    pub fn expire_access_token(&mut self) {
        self.access_token = "expired".into();
    }

    /// Location in the whole drive of a path as the caller sees it (relative to its root), for the current scope.
    pub fn storage_path(&self, path: &str) -> String {
        match self.granted {
            Some(AccessScope::AppFolder) => {
                [self.app_folder(), path].iter().filter(|part| !part.is_empty()).copied().collect::<Vec<_>>().join("/")
            }
            _ => path.to_owned(),
        }
    }

    /// `offline_access User.Read Files.ReadWrite[.AppFolder]` -> scope; `None` if any kind is missing.
    fn onedrive_scope(scopes: &str) -> Option<AccessScope> {
        let scopes: Vec<&str> = scopes.split(' ').collect();
        if !scopes.contains(&"offline_access") || !scopes.contains(&"User.Read") {
            return None;
        }
        if scopes.contains(&"Files.ReadWrite") {
            Some(AccessScope::Full)
        } else if scopes.contains(&"Files.ReadWrite.AppFolder") {
            Some(AccessScope::AppFolder)
        } else {
            None
        }
    }

    fn ensure_dirs(&mut self, key: &[String]) {
        for depth in 0..=key.len() {
            self.nodes.entry(key[..depth].to_vec()).or_insert(Node::Dir);
        }
    }

    pub fn put_external(&mut self, path: &str, data: &[u8]) {
        if self.provider == FakeProvider::GoogleDrive {
            return self.google.put_external(path, data);
        }
        let key = split(path);
        self.ensure_dirs(&key[..key.len().saturating_sub(1)]);
        let version = self.bump();
        self.nodes.insert(key, Node::File { data: data.to_vec(), version });
    }

    pub fn data(&self, path: &str) -> Option<Vec<u8>> {
        if self.provider == FakeProvider::GoogleDrive {
            return self.google.data(path);
        }
        match self.nodes.get(&split(path)) {
            Some(Node::File { data, .. }) => Some(data.clone()),
            _ => None,
        }
    }

    pub fn exists(&self, path: &str) -> bool {
        if self.provider == FakeProvider::GoogleDrive {
            return self.google.exists(path);
        }
        self.nodes.contains_key(&split(path))
    }

    fn bump(&mut self) -> u32 {
        self.next_version += 1;
        self.next_version
    }

    fn issue(&mut self) -> Value {
        self.issued += 1;
        self.access_token = format!("access-{}", self.issued);
        if self.refresh_token.is_empty() || self.rotate_refresh_token {
            self.refresh_token = format!("refresh-{}", self.issued);
        }
        let mut tokens =
            json!({ "access_token": self.access_token, "token_type": "bearer", "expires_in": 3600, "refresh_token": self.refresh_token });
        if self.provider == FakeProvider::GoogleDrive {
            tokens["scope"] = json!(match self.granted {
                Some(AccessScope::Full) => "https://www.googleapis.com/auth/drive",
                _ => "https://www.googleapis.com/auth/drive.file",
            });
        }
        tokens
    }

    pub fn handle(&mut self, request: HttpRequest) -> HttpResponse {
        self.requests.push(request.clone());
        let url = Url::parse(&request.url).expect("absolute url");
        let host = url.host_str().unwrap_or_default().to_owned();
        if url.path().ends_with("/token")
            && matches!(host.as_str(), "api.dropboxapi.com" | "login.microsoftonline.com" | "oauth2.googleapis.com")
        {
            return self.token(&request);
        }
        if host == "oauth2.googleapis.com" && url.path() == "/revoke" {
            assert!(request.header("Authorization").is_none(), "revocation carries the token in the body");
            let form: HashMap<String, String> = url::form_urlencoded::parse(&request.body).into_owned().collect();
            let token = form.get("token").cloned().unwrap_or_default();
            if self.revoked || (token != self.refresh_token && token != self.access_token) {
                return response(400, json!({ "error": "invalid_token" }));
            }
            self.revoked = true;
            self.access_token = "revoked".into();
            return response(200, json!({}));
        }
        if host == ONEDRIVE_DOWNLOAD_HOST {
            assert!(request.header("Authorization").is_none(), "pre-signed downloads must not carry credentials");
            return self.onedrive_download(&url);
        }
        let expected = format!("Bearer {}", self.access_token);
        if request.header("Authorization") != Some(expected.as_str()) {
            return response(401, json!({ "error_summary": "expired_access_token/", "error": { "code": "InvalidAuthenticationToken" } }));
        }
        match host.as_str() {
            "api.dropboxapi.com" | "content.dropboxapi.com" => self.dropbox(&url, &request),
            "graph.microsoft.com" => self.graph(&url, &request),
            "www.googleapis.com" => {
                let app_only = self.granted != Some(AccessScope::Full);
                self.google.modify_before_download = self.modify_before_download;
                let response = self.google.handle(&url, &request, app_only, self.page_size);
                self.modify_before_download = self.google.modify_before_download;
                response
            }
            _ => response(404, json!({})),
        }
    }

    fn token(&mut self, request: &HttpRequest) -> HttpResponse {
        assert_eq!(request.method, Method::Post);
        let form: HashMap<String, String> = url::form_urlencoded::parse(&request.body).into_owned().collect();
        assert!(!form.contains_key("client_secret"), "public clients do not send a secret");
        match form.get("grant_type").map(String::as_str) {
            Some("authorization_code") => {
                let verifier = form.get("code_verifier").cloned().unwrap_or_default();
                let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
                if form.get("code") != self.code.as_ref() || Some(&challenge) != self.challenge.as_ref() {
                    return response(400, json!({ "error": "invalid_grant" }));
                }
                self.code = None;
                let tokens = self.issue();
                response(200, tokens)
            }
            Some("refresh_token") if !self.revoked && form.get("refresh_token") == Some(&self.refresh_token) => {
                if self.provider == FakeProvider::OneDrive {
                    // Microsoft requires the scope on refresh too, and it may not exceed what the user granted.
                    let requested = form.get("scope").and_then(|scopes| Self::onedrive_scope(scopes));
                    if requested.is_none() || (requested == Some(AccessScope::Full) && self.granted != Some(AccessScope::Full)) {
                        return response(400, json!({ "error": "invalid_grant" }));
                    }
                }
                let mut tokens = self.issue();
                if !self.rotate_refresh_token
                    && let Some(map) = tokens.as_object_mut()
                {
                    map.remove("refresh_token");
                }
                response(200, tokens)
            }
            _ => response(400, json!({ "error": "invalid_grant" })),
        }
    }

    // MARK: - Dropbox

    /// Paths of an App folder app are rooted at [`APP_FOLDER`].
    fn dropbox_root(&self) -> Vec<String> {
        if self.granted == Some(AccessScope::Full) { Vec::new() } else { split(APP_FOLDER) }
    }

    fn dropbox_metadata(&self, key: &[String]) -> Option<Value> {
        let name = key.last().cloned().unwrap_or_default();
        let display = format!("/{}", key[self.dropbox_root().len().min(key.len())..].join("/"));
        match self.nodes.get(key)? {
            Node::Dir => Some(json!({ ".tag": "folder", "name": name, "path_display": display })),
            Node::File { data, version } => Some(json!({
                ".tag": "file",
                "name": name,
                "rev": format!("{version:09x}"),
                "size": data.len(),
                "server_modified": "2026-10-28T09:12:40Z",
            })),
        }
    }

    fn children(&self, key: &[String]) -> Vec<Vec<String>> {
        self.nodes.keys().filter(|candidate| candidate.len() == key.len() + 1 && candidate.starts_with(key)).cloned().collect()
    }

    fn dropbox_page(&self, key: &[String], offset: usize) -> HttpResponse {
        let children = self.children(key);
        let end = (offset + self.page_size).min(children.len());
        let entries: Vec<Value> = children[offset..end].iter().filter_map(|child| self.dropbox_metadata(child)).collect();
        let has_more = end < children.len();
        response(200, json!({ "entries": entries, "cursor": format!("{end}:/{}", key.join("/")), "has_more": has_more }))
    }

    fn dropbox(&mut self, url: &Url, request: &HttpRequest) -> HttpResponse {
        let args: Value = match request.header("Dropbox-API-Arg") {
            Some(header) => {
                assert!(header.is_ascii(), "Dropbox-API-Arg must be ASCII");
                serde_json::from_str(header).expect("arg json")
            }
            None => serde_json::from_slice(&request.body).unwrap_or(Value::Null),
        };
        let mut key = self.dropbox_root();
        key.extend(split(args.get("path").and_then(Value::as_str).unwrap_or_default()));
        match url.path() {
            "/2/users/get_current_account" => response(200, json!({ "email": "alice@example.com", "name": { "display_name": "Alice" } })),
            "/2/auth/token/revoke" => {
                self.revoked = true;
                self.access_token = "revoked".into();
                response(200, Value::Null)
            }
            "/2/files/get_metadata" => match self.dropbox_metadata(&key) {
                Some(metadata) => response(200, metadata),
                None => dropbox_error("path/not_found/.."),
            },
            "/2/files/list_folder" => match self.nodes.get(&key) {
                Some(Node::Dir) => self.dropbox_page(&key, 0),
                Some(Node::File { .. }) => dropbox_error("path/not_folder/.."),
                None => dropbox_error("path/not_found/.."),
            },
            "/2/files/list_folder/continue" => {
                let cursor = args.get("cursor").and_then(Value::as_str).unwrap_or_default();
                let (offset, path) = cursor.split_once(':').unwrap_or_default();
                self.dropbox_page(&split(path), offset.parse().unwrap_or(0))
            }
            "/2/files/download" => match self.nodes.get(&key) {
                Some(Node::File { data, .. }) => {
                    let data = data.clone();
                    let metadata = self.dropbox_file_metadata(&key);
                    HttpResponse { status: 200, headers: vec![("Dropbox-API-Result".into(), metadata.to_string())], body: data }
                }
                Some(Node::Dir) => dropbox_error("path/not_file/.."),
                None => dropbox_error("path/not_found/.."),
            },
            "/2/files/upload" => self.dropbox_upload(key, &args, &request.body),
            "/2/files/create_folder_v2" => match self.nodes.get(&key) {
                Some(Node::Dir) => dropbox_error("path/conflict/folder/.."),
                Some(Node::File { .. }) => dropbox_error("path/conflict/file/.."),
                None => {
                    self.ensure_dirs(&key);
                    response(200, json!({ "metadata": self.dropbox_metadata(&key) }))
                }
            },
            "/2/files/delete_v2" => {
                if self.nodes.remove(&key).is_none() {
                    return dropbox_error("path_lookup/not_found/..");
                }
                self.nodes.retain(|candidate, _| !candidate.starts_with(&key));
                response(200, json!({}))
            }
            _ => response(400, json!({ "error_summary": "unknown endpoint" })),
        }
    }

    fn dropbox_upload(&mut self, key: Vec<String>, args: &Value, body: &[u8]) -> HttpResponse {
        assert_eq!(args.get("strict_conflict"), Some(&json!(true)));
        let existing = self.nodes.get(&key).cloned();
        let allowed = match (args.get("mode"), &existing) {
            (_, Some(Node::Dir)) => false,
            (Some(mode), _) if mode == "overwrite" => true,
            (Some(mode), existing) if mode == "add" => existing.is_none(),
            (Some(mode), Some(Node::File { version, .. })) if mode.get(".tag") == Some(&json!("update")) => {
                mode.get("update").and_then(Value::as_str) == Some(format!("{version:09x}").as_str())
            }
            _ => false,
        };
        if !allowed {
            return dropbox_error("path/conflict/file/..");
        }
        self.ensure_dirs(&key[..key.len().saturating_sub(1)]);
        let version = self.bump();
        self.nodes.insert(key.clone(), Node::File { data: body.to_vec(), version });
        response(200, self.dropbox_file_metadata(&key))
    }

    /// Upload response and download result header: `FileMetadata` itself, without `.tag` (as on the real service).
    fn dropbox_file_metadata(&self, key: &[String]) -> Value {
        let mut metadata = self.dropbox_metadata(key).unwrap_or_default();
        if let Some(object) = metadata.as_object_mut() {
            object.remove(".tag");
        }
        metadata
    }

    // MARK: - OneDrive

    fn graph_item(&self, key: &[String]) -> Option<Value> {
        let name = key.last().cloned().unwrap_or_else(|| "root".into());
        Some(match self.nodes.get(key)? {
            Node::Dir => json!({ "name": name, "eTag": "\"dir\"", "folder": { "childCount": self.children(key).len() } }),
            Node::File { data, version } => json!({
                "name": name,
                "size": data.len(),
                "eTag": format!("\"{{ITEM}},{version}\""),
                "lastModifiedDateTime": "2026-10-28T09:12:40Z",
                "file": { "mimeType": "application/octet-stream" },
                "@microsoft.graph.downloadUrl": format!(
                    "https://{ONEDRIVE_DOWNLOAD_HOST}/{}?v={version}",
                    key.iter().map(|part| utf8_percent_encode(part, NON_ALPHANUMERIC).to_string()).collect::<Vec<_>>().join("/")
                ),
            }),
        })
    }

    /// Splits `…/me/drive/{special/approot|root}[:/a/b[:]][/children|/content]` into "is approot", the relative path,
    /// and the sub-resource.
    fn graph_target(url: &Url) -> Option<(bool, Vec<String>, String)> {
        let path = url.path().strip_prefix("/v1.0/me/drive/")?;
        let (approot, rest) = match path.strip_prefix("special/approot") {
            Some(rest) => (true, rest),
            None => (false, path.strip_prefix("root")?),
        };
        let (item, suffix) = if let Some(addressed) = rest.strip_prefix(":/") {
            match addressed.split_once(":/") {
                Some((item, suffix)) => (item, suffix),
                None => (addressed.trim_end_matches(':'), ""),
            }
        } else {
            ("", rest.trim_start_matches('/'))
        };
        let key =
            item.split('/').filter(|part| !part.is_empty()).map(|part| percent_decode_str(part).decode_utf8_lossy().into_owned()).collect();
        Some((approot, key, suffix.to_owned()))
    }

    fn graph(&mut self, url: &Url, request: &HttpRequest) -> HttpResponse {
        if url.path() == "/v1.0/me" {
            // Personal account: mail is null and the sign-in email is in userPrincipalName.
            return response(200, json!({ "displayName": "Alice Example", "mail": null, "userPrincipalName": "alice@outlook.com" }));
        }
        if url.path() == "/v1.0/me/drive" {
            // With only app folder access, information about the whole drive cannot be read (verified against the live API).
            if self.granted != Some(AccessScope::Full) {
                return graph_error(403, "accessDenied");
            }
            return response(200, json!({ "owner": { "user": { "displayName": "Alice Example" } } }));
        }
        let Some((approot, relative, suffix)) = Self::graph_target(url) else { return graph_error(400, "invalidRequest") };
        let mut key = if approot {
            // approot is created on first access; both scopes can reach it.
            let root = split(APP_FOLDER);
            self.ensure_dirs(&root);
            root
        } else if self.granted == Some(AccessScope::Full) {
            Vec::new()
        } else {
            return graph_error(403, "accessDenied");
        };
        key.extend(relative);
        let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
        match (request.method, suffix.as_str()) {
            (Method::Get, "") => match self.graph_item(&key) {
                // As on the real service: with `$select`, the pre-signed download URL is not returned, even when named in `$select`.
                Some(mut item) if query.contains_key("$select") => {
                    if let Some(object) = item.as_object_mut() {
                        object.remove("@microsoft.graph.downloadUrl");
                    }
                    response(200, item)
                }
                Some(item) => response(200, item),
                None => graph_error(404, "itemNotFound"),
            },
            (Method::Get, "children") => {
                if !matches!(self.nodes.get(&key), Some(Node::Dir)) {
                    return graph_error(404, "itemNotFound");
                }
                let children = self.children(&key);
                let offset: usize = query.get("$skiptoken").and_then(|token| token.parse().ok()).unwrap_or(0);
                let end = (offset + self.page_size).min(children.len());
                let value: Vec<Value> = children[offset..end].iter().filter_map(|child| self.graph_item(child)).collect();
                let mut body = json!({ "value": value });
                if end < children.len() {
                    let mut next = url.clone();
                    next.query_pairs_mut().clear().append_pair("$skiptoken", &end.to_string());
                    body["@odata.nextLink"] = json!(next.as_str());
                }
                response(200, body)
            }
            (Method::Put, "content") => self.graph_upload(key, &query, request),
            (Method::Post, "children") => {
                if !matches!(self.nodes.get(&key), Some(Node::Dir)) {
                    return graph_error(404, "itemNotFound");
                }
                let body: Value = serde_json::from_slice(&request.body).unwrap_or_default();
                let name = body.get("name").and_then(Value::as_str).unwrap_or_default();
                let mut child = key.clone();
                child.push(name.to_owned());
                if self.nodes.contains_key(&child) {
                    return graph_error(409, "nameAlreadyExists");
                }
                self.nodes.insert(child.clone(), Node::Dir);
                response(201, self.graph_item(&child).unwrap_or_default())
            }
            (Method::Delete, "") => {
                if self.nodes.remove(&key).is_none() {
                    return graph_error(404, "itemNotFound");
                }
                self.nodes.retain(|candidate, _| !candidate.starts_with(&key));
                HttpResponse { status: 204, headers: Vec::new(), body: Vec::new() }
            }
            _ => graph_error(400, "invalidRequest"),
        }
    }

    fn graph_upload(&mut self, key: Vec<String>, query: &HashMap<String, String>, request: &HttpRequest) -> HttpResponse {
        let existing = self.graph_item(&key);
        if let Some(expected) = request.header("If-Match") {
            match &existing {
                None => return graph_error(404, "itemNotFound"),
                Some(item) if item.get("eTag").and_then(Value::as_str) != Some(expected) => return graph_error(412, "resourceModified"),
                Some(_) => {}
            }
        }
        if existing.is_some() && query.get("@microsoft.graph.conflictBehavior").map(String::as_str) == Some("fail") {
            return graph_error(409, "nameAlreadyExists");
        }
        self.ensure_dirs(&key[..key.len().saturating_sub(1)]);
        let version = self.bump();
        let created = existing.is_none();
        self.nodes.insert(key.clone(), Node::File { data: request.body.clone(), version });
        response(if created { 201 } else { 200 }, self.graph_item(&key).unwrap_or_default())
    }

    fn onedrive_download(&mut self, url: &Url) -> HttpResponse {
        let key: Vec<String> = url
            .path()
            .split('/')
            .filter(|part| !part.is_empty())
            .map(|part| percent_decode_str(part).decode_utf8_lossy().into_owned())
            .collect();
        if self.modify_before_download > 0 {
            self.modify_before_download -= 1;
            let version = self.bump();
            self.nodes.insert(key.clone(), Node::File { data: b"changed elsewhere".to_vec(), version });
        }
        match self.nodes.get(&key) {
            Some(Node::File { data, .. }) => HttpResponse { status: 200, headers: Vec::new(), body: data.clone() },
            _ => HttpResponse { status: 404, headers: Vec::new(), body: Vec::new() },
        }
    }
}
