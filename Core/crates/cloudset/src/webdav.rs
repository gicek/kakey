//! WebDAV (RFC 4918). Nextcloud also goes through here after sign-in.
//!
//! Versions always come from `getetag` in `PROPFIND`: on some servers the ETag in `GET` / `PUT` response headers is not
//! written the same way as `getetag`, and mixing them makes the caller think the remote changed when it did not. So a
//! read is "PROPFIND for the version -> GET with `If-Match`" (retried if the file changes in between), and a write is
//! "conditional PUT -> PROPFIND for the new version". Weak ETags cannot be used in conditional requests, so those fall
//! back to comparing before writing (with a brief race window).

use percent_encoding::percent_decode_str;
use url::Url;

use crate::client::ClientConfig;
use crate::connection::{Connection, Endpoint};
use crate::entry::{Entry, File, Precondition, Revision};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse, Method, status_error};
use crate::multistatus::{self, DavEntry};
use crate::operation::{BoxOperation, Call, CallStep, Done, Operation, Ready, Single, Step};
use crate::path::RemotePath;

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>"#;
/// Maximum retries when the file changes during a read.
const READ_ATTEMPTS: u8 = 3;

#[derive(Clone)]
pub(crate) struct Dav {
    connection: Connection,
    endpoint: Endpoint,
    config: ClientConfig,
}

impl Dav {
    /// Only for connections with a WebDAV URL (WebDAV, Nextcloud); [`crate::Client`] dispatches other connections to
    /// their own providers.
    pub(crate) fn new(connection: Connection, config: ClientConfig) -> Result<Self, CloudError> {
        let endpoint = connection.endpoint().cloned().ok_or(CloudError::InvalidConnection)?;
        Ok(Self { connection, endpoint, config })
    }

    fn request(
        &self,
        method: Method,
        path: &RemotePath,
        is_dir: bool,
        mut headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> Result<HttpRequest, CloudError> {
        let url = self.endpoint.resolve(path, is_dir)?;
        headers.push(("Authorization".into(), self.connection.basic_authorization().to_string()));
        headers.push(("User-Agent".into(), self.config.user_agent.clone()));
        Ok(HttpRequest { method, url: url.into(), headers, body })
    }

    fn call(&self, request: HttpRequest) -> Call {
        Call::new(request, self.endpoint.origin(), self.config.limits)
    }

    fn propfind(&self, path: &RemotePath, depth: &str, is_dir: bool) -> Result<Call, CloudError> {
        let headers = vec![("Depth".into(), depth.into()), ("Content-Type".into(), "application/xml; charset=utf-8".into())];
        Ok(self.call(self.request(Method::Propfind, path, is_dir, headers, PROPFIND_BODY.as_bytes().to_vec())?))
    }

    /// Converts an `href` (absolute URL or absolute path) to a path relative to the root; `None` if it is outside the
    /// root or has an invalid segment.
    fn path_of(&self, href: &str) -> Option<RemotePath> {
        let base = self.endpoint.url();
        let url = base.join(href).ok()?;
        let segments = decoded_segments(&url)?;
        let base_segments = decoded_segments(base)?;
        let rest = segments.strip_prefix(base_segments.as_slice())?;
        RemotePath::from_segments(rest.iter().cloned()).ok()
    }

    fn entries(&self, response: &HttpResponse) -> Result<Vec<Entry>, CloudError> {
        let entries = multistatus::parse(&response.body, self.config.limits.max_entries)?;
        Ok(entries.into_iter().filter_map(|entry| self.entry(entry)).collect())
    }

    fn entry(&self, dav: DavEntry) -> Option<Entry> {
        Some(Entry {
            path: self.path_of(&dav.href)?,
            is_dir: dav.is_dir,
            size: dav.size,
            modified_at: dav.modified_at,
            revision: dav.etag.map(Revision::new),
        })
    }

    /// Final response of `PROPFIND Depth: 0` -> the entry at that path; 404 yields `None`.
    fn stat_result(&self, path: &RemotePath, response: &HttpResponse) -> Result<Option<Entry>, CloudError> {
        match response.status {
            207 => self
                .entries(response)?
                .into_iter()
                .find(|entry| &entry.path == path)
                .map(Some)
                .ok_or(CloudError::InvalidResponse("missing entry")),
            404 => Ok(None),
            _ => Err(status_error(response)),
        }
    }

    pub(crate) fn stat(&self, path: RemotePath) -> BoxOperation<Option<Entry>> {
        let call = match self.propfind(&path, "0", false) {
            Ok(call) => call,
            Err(error) => return Box::new(Ready::err(error)),
        };
        let dav = self.clone();
        Box::new(Single::new(call, move |response| dav.stat_result(&path, &response)))
    }

    pub(crate) fn list(&self, dir: RemotePath) -> BoxOperation<Vec<Entry>> {
        let call = match self.propfind(&dir, "1", true) {
            Ok(call) => call,
            Err(error) => return Box::new(Ready::err(error)),
        };
        let dav = self.clone();
        Box::new(Single::new(call, move |response| match response.status {
            207 => {
                let mut entries: Vec<Entry> = dav.entries(&response)?.into_iter().filter(|entry| entry.path != dir).collect();
                entries.sort_by(|a, b| a.path.cmp(&b.path));
                Ok(entries)
            }
            _ => Err(status_error(&response)),
        }))
    }

    pub(crate) fn create_dir(&self, path: RemotePath) -> BoxOperation<()> {
        Box::new(CreateDir { dav: self.clone(), path, state: CreateDirState::Start })
    }

    pub(crate) fn delete(&self, path: RemotePath) -> BoxOperation<()> {
        let request = match self.request(Method::Delete, &path, false, Vec::new(), Vec::new()) {
            Ok(request) => request,
            Err(error) => return Box::new(Ready::err(error)),
        };
        Box::new(Single::new(self.call(request), |response| match response.status {
            200 | 202 | 204 | 404 => Ok(()),
            _ => Err(status_error(&response)),
        }))
    }

    pub(crate) fn read(&self, path: RemotePath) -> BoxOperation<Option<File>> {
        Box::new(Read { dav: self.clone(), path, attempts: 0, state: ReadState::Start })
    }

    pub(crate) fn write(&self, path: RemotePath, data: Vec<u8>, precondition: Precondition) -> BoxOperation<Entry> {
        Box::new(Write { dav: self.clone(), path, data: Some(data), precondition, state: WriteState::Start })
    }
}

fn decoded_segments(url: &Url) -> Option<Vec<String>> {
    url.path_segments()?
        .filter(|segment| !segment.is_empty())
        .map(|segment| percent_decode_str(segment).decode_utf8().ok().map(|decoded| decoded.into_owned()))
        .collect()
}

enum CreateDirState {
    Start,
    Mkcol(Call),
    /// MKCOL returned 405: in RFC 4918 that means "already exists", but quite a few servers (Synology, for example) also
    /// return 405 when permission is denied, so one lookup tells which it is.
    Verify(Call),
    Finished,
}

struct CreateDir {
    dav: Dav,
    path: RemotePath,
    state: CreateDirState,
}

impl Operation for CreateDir {
    type Output = ();

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<()>, CloudError> {
        match std::mem::replace(&mut self.state, CreateDirState::Finished) {
            CreateDirState::Start if response.is_none() => {
                let mut call = self.dav.call(self.dav.request(Method::Mkcol, &self.path, true, Vec::new(), Vec::new())?);
                let step = call.advance(None)?;
                self.state = CreateDirState::Mkcol(call);
                send(step)
            }
            CreateDirState::Mkcol(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = CreateDirState::Mkcol(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => match response.status {
                    200 | 201 | 204 => Ok(Step::Done(Done::value(()))),
                    405 => {
                        let mut call = self.dav.propfind(&self.path, "0", true)?;
                        let step = call.advance(None)?;
                        self.state = CreateDirState::Verify(call);
                        send(step)
                    }
                    409 => Err(CloudError::NotFound),
                    _ => Err(status_error(&response)),
                },
            },
            CreateDirState::Verify(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = CreateDirState::Verify(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => match response.status {
                    207 if self.dav.stat_result(&self.path, &response)?.is_some_and(|entry| entry.is_dir) => {
                        Ok(Step::Done(Done::value(())))
                    }
                    // Missing (or a file is there, or the lookup itself was refused): creating the directory is not allowed here.
                    207 | 403 | 404 | 405 => Err(CloudError::Forbidden),
                    _ => Err(status_error(&response)),
                },
            },
            CreateDirState::Start | CreateDirState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

enum ReadState {
    Start,
    Stat(Call),
    Get(Call, Entry),
    Finished,
}

struct Read {
    dav: Dav,
    path: RemotePath,
    attempts: u8,
    state: ReadState,
}

impl Read {
    fn start_stat(&mut self) -> Result<Step<Option<File>>, CloudError> {
        self.attempts += 1;
        let mut call = self.dav.propfind(&self.path, "0", false)?;
        let step = call.advance(None)?;
        self.state = ReadState::Stat(call);
        send(step)
    }
}

impl Operation for Read {
    type Output = Option<File>;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<Option<File>>, CloudError> {
        match std::mem::replace(&mut self.state, ReadState::Finished) {
            ReadState::Start if response.is_none() => self.start_stat(),
            ReadState::Stat(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = ReadState::Stat(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    let Some(entry) = self.dav.stat_result(&self.path, &response)? else {
                        return Ok(Step::Done(Done::value(None)));
                    };
                    if entry.is_dir {
                        return Err(CloudError::InvalidResponse("expected a file"));
                    }
                    let mut headers = Vec::new();
                    if let Some(revision) = entry.revision.as_ref().filter(|revision| !revision.is_weak()) {
                        headers.push(("If-Match".into(), revision.as_str().to_owned()));
                    }
                    let mut call = self.dav.call(self.dav.request(Method::Get, &self.path, false, headers, Vec::new())?);
                    let step = call.advance(None)?;
                    self.state = ReadState::Get(call, entry);
                    send(step)
                }
            },
            ReadState::Get(mut call, entry) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = ReadState::Get(call, entry);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => match response.status {
                    200 => Ok(Step::Done(Done::value(Some(File { data: response.body, entry })))),
                    404 => Ok(Step::Done(Done::value(None))),
                    412 if self.attempts < READ_ATTEMPTS => self.start_stat(),
                    _ => Err(status_error(&response)),
                },
            },
            ReadState::Start | ReadState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

enum WriteState {
    Start,
    /// Weak ETag: compare the version first, then write unconditionally.
    Check(Call),
    Put(Call),
    Stat(Call),
    Finished,
}

struct Write {
    dav: Dav,
    path: RemotePath,
    data: Option<Vec<u8>>,
    precondition: Precondition,
    state: WriteState,
}

impl Write {
    fn start_put(&mut self, conditional: bool) -> Result<Step<Entry>, CloudError> {
        let mut headers = vec![("Content-Type".into(), "application/octet-stream".into())];
        if conditional {
            match &self.precondition {
                Precondition::None => {}
                Precondition::Absent => headers.push(("If-None-Match".into(), "*".into())),
                Precondition::Matches(revision) => headers.push(("If-Match".into(), revision.as_str().to_owned())),
            }
        }
        let data = self.data.take().ok_or(CloudError::OutOfOrder)?;
        let mut call = self.dav.call(self.dav.request(Method::Put, &self.path, false, headers, data)?);
        let step = call.advance(None)?;
        self.state = WriteState::Put(call);
        send(step)
    }
}

impl Operation for Write {
    type Output = Entry;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<Entry>, CloudError> {
        match std::mem::replace(&mut self.state, WriteState::Finished) {
            WriteState::Start if response.is_none() => match &self.precondition {
                Precondition::Matches(revision) if revision.is_weak() => {
                    let mut call = self.dav.propfind(&self.path, "0", false)?;
                    let step = call.advance(None)?;
                    self.state = WriteState::Check(call);
                    send(step)
                }
                _ => self.start_put(true),
            },
            WriteState::Check(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = WriteState::Check(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    let current = self.dav.stat_result(&self.path, &response)?.and_then(|entry| entry.revision);
                    match &self.precondition {
                        Precondition::Matches(expected) if current.as_ref() == Some(expected) => self.start_put(false),
                        _ => Err(CloudError::PreconditionFailed),
                    }
                }
            },
            WriteState::Put(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = WriteState::Put(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => match response.status {
                    200 | 201 | 204 => {
                        let mut call = self.dav.propfind(&self.path, "0", false)?;
                        let step = call.advance(None)?;
                        self.state = WriteState::Stat(call);
                        send(step)
                    }
                    409 => Err(CloudError::NotFound),
                    _ => Err(status_error(&response)),
                },
            },
            WriteState::Stat(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = WriteState::Stat(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    let entry = self.dav.stat_result(&self.path, &response)?.ok_or(CloudError::InvalidResponse("written file missing"))?;
                    Ok(Step::Done(Done::value(entry)))
                }
            },
            WriteState::Start | WriteState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

fn send<T>(step: CallStep) -> Result<Step<T>, CloudError> {
    match step {
        CallStep::Send(request) => Ok(Step::Send(request)),
        CallStep::Response(_) => Err(CloudError::OutOfOrder),
    }
}
