//! In-memory WebDAV server for tests (`testing` feature): implements the methods and conditional-request semantics the
//! component uses, and can simulate concurrent modification, weak ETags, and directory redirects. Callers' tests use it
//! to drive the real operation state machines without a network.

use std::collections::BTreeMap;

use percent_encoding::{AsciiSet, CONTROLS, percent_decode_str, utf8_percent_encode};

use crate::http::{HttpRequest, HttpResponse, Method};

/// In-memory Dropbox / OneDrive with their authorization pages and token endpoints.
#[path = "testing_oauth.rs"]
pub mod oauth;

/// WebDAV root URL of the server; use it for the connection's `Endpoint`.
pub const BASE: &str = "https://dav.example.com/dav/";
const SEGMENT: &AsciiSet = &CONTROLS.add(b' ').add(b'#').add(b'?').add(b'%').add(b'&').add(b'<').add(b'>').add(b'"');

#[derive(Clone, Debug)]
enum Node {
    Dir,
    File { data: Vec<u8>, version: u32 },
}

/// In-memory WebDAV server. Paths are split on `/`; the root directory always exists.
pub struct MemoryDav {
    nodes: BTreeMap<Vec<String>, Node>,
    pub authorization: String,
    pub weak_etags: bool,
    /// Before each of the next N GETs, "another device" modifies the target file first.
    pub modify_before_get: u8,
    pub requests: Vec<HttpRequest>,
    /// MKCOL under these directories always returns 405 (simulates servers such as Synology that also return 405 when
    /// permission is denied).
    pub mkcol_forbidden_in: Vec<String>,
    next_version: u32,
}

impl MemoryDav {
    /// `authorization` is the exact expected `Authorization` header; anything else gets a 401.
    pub fn new(authorization: &str) -> Self {
        let mut nodes = BTreeMap::new();
        nodes.insert(Vec::new(), Node::Dir);
        Self {
            nodes,
            authorization: authorization.into(),
            weak_etags: false,
            modify_before_get: 0,
            requests: Vec::new(),
            mkcol_forbidden_in: Vec::new(),
            next_version: 1,
        }
    }

    /// Writes directly as "another device" (bypassing the component).
    pub fn put_external(&mut self, path: &str, data: &[u8]) {
        let key: Vec<String> = path.split('/').map(str::to_owned).collect();
        let version = self.bump();
        self.nodes.insert(key, Node::File { data: data.to_vec(), version });
    }

    pub fn mkdir_external(&mut self, path: &str) {
        self.nodes.insert(path.split('/').map(str::to_owned).collect(), Node::Dir);
    }

    pub fn data(&self, path: &str) -> Option<Vec<u8>> {
        match self.nodes.get(&path.split('/').map(str::to_owned).collect::<Vec<_>>()) {
            Some(Node::File { data, .. }) => Some(data.clone()),
            _ => None,
        }
    }

    fn bump(&mut self) -> u32 {
        self.next_version += 1;
        self.next_version
    }

    fn etag(&self, version: u32) -> String {
        if self.weak_etags { format!("W/\"v{version}\"") } else { format!("\"v{version}\"") }
    }

    fn href(key: &[String], is_dir: bool) -> String {
        let mut href = "/dav/".to_owned();
        href.push_str(&key.iter().map(|s| utf8_percent_encode(s, SEGMENT).to_string()).collect::<Vec<_>>().join("/"));
        if is_dir && !key.is_empty() {
            href.push('/');
        }
        href
    }

    fn response_xml(&self, key: &[String], node: &Node) -> String {
        let (props, is_dir) = match node {
            Node::Dir => ("<d:resourcetype><d:collection/></d:resourcetype><d:getetag>\"dir\"</d:getetag>".to_owned(), true),
            Node::File { data, version } => (
                format!(
                    "<d:resourcetype/><d:getcontentlength>{}</d:getcontentlength><d:getlastmodified>Wed, 28 Oct 2026 10:00:{:02} GMT</d:getlastmodified><d:getetag>{}</d:getetag>",
                    data.len(),
                    version % 60,
                    self.etag(*version).replace('"', "&quot;")
                ),
                false,
            ),
        };
        format!(
            "<d:response><d:href>{}</d:href><d:propstat><d:prop>{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>",
            Self::href(key, is_dir)
        )
    }

    /// Handles one request; every request is recorded in order in `requests`.
    pub fn handle(&mut self, request: HttpRequest) -> HttpResponse {
        self.requests.push(request.clone());
        if request.header("Authorization") != Some(self.authorization.as_str()) {
            return HttpResponse::new(401);
        }
        let Some(rest) = request.url.strip_prefix(BASE.trim_end_matches('/')) else { return HttpResponse::new(404) };
        let trailing_slash = rest.ends_with('/') && rest.len() > 1;
        let key: Vec<String> =
            rest.split('/').filter(|s| !s.is_empty()).map(|s| percent_decode_str(s).decode_utf8_lossy().into_owned()).collect();
        let parent_exists = key.split_last().is_none_or(|(_, parent)| matches!(self.nodes.get(parent), Some(Node::Dir)));
        let current = self.nodes.get(&key).cloned();
        let current_etag = match &current {
            Some(Node::File { version, .. }) => Some(self.etag(*version)),
            _ => None,
        };
        let if_match_ok =
            request.header("If-Match").is_none_or(|expected| current_etag.as_deref() == Some(expected) && !expected.starts_with("W/"));
        match request.method {
            Method::Propfind => {
                let Some(node) = current else { return HttpResponse::new(404) };
                if matches!(node, Node::Dir) && !trailing_slash && !key.is_empty() {
                    return HttpResponse { status: 301, headers: vec![("Location".into(), format!("{}/", request.url))], body: Vec::new() };
                }
                let mut body = String::from(r#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">"#);
                body.push_str(&self.response_xml(&key, &node));
                if request.header("Depth") == Some("1") && matches!(node, Node::Dir) {
                    for (child, child_node) in self.nodes.iter().filter(|(k, _)| k.len() == key.len() + 1 && k.starts_with(&key)) {
                        body.push_str(&self.response_xml(child, child_node));
                    }
                }
                body.push_str("</d:multistatus>");
                HttpResponse { status: 207, headers: Vec::new(), body: body.into_bytes() }
            }
            Method::Get => {
                if self.modify_before_get > 0 {
                    self.modify_before_get -= 1;
                    let joined = key.join("/");
                    let data = self.data(&joined).unwrap_or_default();
                    self.put_external(&joined, &[data, b"+".to_vec()].concat());
                    return self.handle_without_log(request);
                }
                self.handle_get(&key, &request)
            }
            Method::Put => {
                if !parent_exists {
                    return HttpResponse::new(409);
                }
                if matches!(current, Some(Node::Dir)) {
                    return HttpResponse::new(405);
                }
                if request.header("If-None-Match") == Some("*") && current.is_some() {
                    return HttpResponse::new(412);
                }
                if !if_match_ok {
                    return HttpResponse::new(412);
                }
                let version = self.bump();
                self.nodes.insert(key, Node::File { data: request.body, version });
                // The ETag response header deliberately differs from getetag: the component must not use it as the version.
                HttpResponse {
                    status: if current.is_some() { 204 } else { 201 },
                    headers: vec![("ETag".into(), format!("v{version}"))],
                    body: Vec::new(),
                }
            }
            Method::Mkcol => {
                let parent = key.split_last().map(|(_, parent)| parent.join("/")).unwrap_or_default();
                if self.mkcol_forbidden_in.contains(&parent) {
                    return HttpResponse::new(405);
                }
                if current.is_some() {
                    return HttpResponse::new(405);
                }
                if !parent_exists {
                    return HttpResponse::new(409);
                }
                self.nodes.insert(key, Node::Dir);
                HttpResponse::new(201)
            }
            Method::Delete => {
                if current.is_none() {
                    return HttpResponse::new(404);
                }
                self.nodes.retain(|k, _| !k.starts_with(&key));
                HttpResponse::new(204)
            }
            Method::Post | Method::Patch => HttpResponse::new(405),
        }
    }

    fn handle_without_log(&mut self, request: HttpRequest) -> HttpResponse {
        let rest = request.url.strip_prefix(BASE.trim_end_matches('/')).unwrap_or_default().to_owned();
        let key: Vec<String> =
            rest.split('/').filter(|s| !s.is_empty()).map(|s| percent_decode_str(s).decode_utf8_lossy().into_owned()).collect();
        self.handle_get(&key, &request)
    }

    fn handle_get(&self, key: &[String], request: &HttpRequest) -> HttpResponse {
        match self.nodes.get(key) {
            Some(Node::File { data, version }) => {
                let etag = self.etag(*version);
                if request.header("If-Match").is_some_and(|expected| expected != etag) {
                    return HttpResponse::new(412);
                }
                HttpResponse { status: 200, headers: vec![("ETag".into(), format!("v{version}"))], body: data.clone() }
            }
            Some(Node::Dir) => HttpResponse::new(405),
            None => HttpResponse::new(404),
        }
    }
}
