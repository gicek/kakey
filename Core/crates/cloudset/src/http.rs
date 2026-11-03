//! Plain-data HTTP requests / responses and shared handling: origin checks, redirects, size limits, status code mapping.

use std::fmt;
use std::time::Duration;

use url::Url;

use crate::error::CloudError;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Method {
    Get,
    Put,
    Patch,
    Post,
    Delete,
    Propfind,
    Mkcol,
}

impl Method {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Put => "PUT",
            Self::Patch => "PATCH",
            Self::Post => "POST",
            Self::Delete => "DELETE",
            Self::Propfind => "PROPFIND",
            Self::Mkcol => "MKCOL",
        }
    }
}

/// A request built by the component for the caller to execute. The caller sends it as is: no following redirects, no
/// cookies, no cache.
#[derive(Clone, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: Method,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }
}

/// `Debug` omits header values and the body: they may contain credentials or user data.
impl fmt::Debug for HttpRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let names: Vec<&str> = self.headers.iter().map(|(name, _)| name.as_str()).collect();
        f.debug_struct("HttpRequest")
            .field("method", &self.method)
            .field("url", &redacted_url(&self.url))
            .field("headers", &names)
            .field("body_len", &self.body.len())
            .finish()
    }
}

/// The response the caller fills in after executing the request. Header names are case-insensitive.
#[derive(Clone, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn new(status: u16) -> Self {
        Self { status, headers: Vec::new(), body: Vec::new() }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }

    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

impl fmt::Debug for HttpResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HttpResponse").field("status", &self.status).field("body_len", &self.body.len()).finish()
    }
}

fn find_header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value.trim())
}

/// Keeps only scheme, host, and path, dropping the query string (it may carry a token).
fn redacted_url(url: &str) -> String {
    match Url::parse(url) {
        Ok(mut parsed) => {
            parsed.set_query(None);
            parsed.set_fragment(None);
            parsed.to_string()
        }
        Err(_) => "<invalid url>".to_owned(),
    }
}

/// Resource limits: data from the remote is checked against them before parsing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Maximum bytes in a single response body; the caller's executor should also truncate reads at this size.
    pub max_body_bytes: usize,
    /// Maximum entries accepted from one directory listing.
    pub max_entries: usize,
    /// Maximum redirects followed for one request.
    pub max_redirects: u8,
}

impl Default for Limits {
    fn default() -> Self {
        Self { max_body_bytes: 16 * 1024 * 1024, max_entries: 10_000, max_redirects: 5 }
    }
}

/// Scheme + host + port. Requests may only go to the origin configured for the connection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Origin {
    secure: bool,
    host: String,
    port: Option<u16>,
}

impl Origin {
    pub(crate) fn of(url: &Url) -> Self {
        Self {
            secure: url.scheme() == "https",
            host: url.host_str().unwrap_or_default().to_ascii_lowercase(),
            port: url.port_or_known_default(),
        }
    }

    /// Same origin, or an upgrade from HTTP to HTTPS on the same host (ports compared using scheme defaults). Downgrades are
    /// never accepted.
    pub(crate) fn admits(&self, url: &Url) -> bool {
        let other = Self::of(url);
        if other.host != self.host {
            return false;
        }
        match (self.secure, other.secure) {
            (true, true) | (false, false) => other.port == self.port,
            (false, true) => other.port == Some(443) && self.port == Some(80),
            (true, false) => false,
        }
    }
}

/// One request round trip: follows same-origin redirects, checks the response size, and hands the final response to the
/// caller to interpret.
#[derive(Clone, Debug)]
pub(crate) struct Exchange {
    request: HttpRequest,
    redirects: u8,
}

pub(crate) enum Received {
    /// Must be sent again (redirect).
    Resend(HttpRequest),
    /// Final response.
    Final(HttpResponse),
}

impl Exchange {
    pub(crate) fn new(request: HttpRequest) -> Self {
        Self { request, redirects: 0 }
    }

    pub(crate) fn request(&self) -> HttpRequest {
        self.request.clone()
    }

    pub(crate) fn receive(&mut self, response: HttpResponse, origin: &Origin, limits: &Limits) -> Result<Received, CloudError> {
        if response.body.len() > limits.max_body_bytes {
            return Err(CloudError::TooLarge);
        }
        if !matches!(response.status, 301 | 302 | 303 | 307 | 308) {
            return Ok(Received::Final(response));
        }
        if self.redirects >= limits.max_redirects {
            return Err(CloudError::TooManyRedirects);
        }
        let location = response.header("Location").ok_or(CloudError::InvalidResponse("redirect without location"))?;
        let current = Url::parse(&self.request.url).map_err(|_| CloudError::InvalidResponse("request url"))?;
        let target = current.join(location).map_err(|_| CloudError::InvalidResponse("redirect location"))?;
        if !origin.admits(&target) || (current.scheme() == "https" && target.scheme() != "https") {
            return Err(CloudError::InsecureRedirect);
        }
        self.redirects += 1;
        self.request.url = target.to_string();
        // 303 always becomes a GET without a body; other codes keep the method and body (WebDAV methods must be kept on 301 /
        // 302 too).
        if response.status == 303 {
            self.request.method = Method::Get;
            self.request.body.clear();
            self.request.headers.retain(|(name, _)| !name.eq_ignore_ascii_case("Content-Type"));
        }
        Ok(Received::Resend(self.request.clone()))
    }
}

/// Common mapping for unexpected status codes.
pub(crate) fn status_error(response: &HttpResponse) -> CloudError {
    match response.status {
        401 => CloudError::ReauthRequired,
        403 => CloudError::Forbidden,
        404 | 410 => CloudError::NotFound,
        412 => CloudError::PreconditionFailed,
        507 => CloudError::QuotaExceeded,
        429 | 503 => CloudError::RateLimited { retry_after: retry_after(response) },
        status => CloudError::Server { status },
    }
}

pub(crate) fn retry_after(response: &HttpResponse) -> Option<Duration> {
    let value = response.header("Retry-After")?;
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }
    // The HTTP-date form cannot be turned into a delay without the current time; leave it to the caller's default backoff.
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn origin(url: &str) -> Origin {
        Origin::of(&Url::parse(url).unwrap())
    }

    fn redirect(status: u16, location: &str) -> HttpResponse {
        HttpResponse { status, headers: vec![("location".into(), location.into())], body: Vec::new() }
    }

    fn request(method: Method, url: &str) -> HttpRequest {
        HttpRequest { method, url: url.into(), headers: vec![("Content-Type".into(), "text/xml".into())], body: b"x".to_vec() }
    }

    #[test]
    fn origin_rules() {
        let https = origin("https://Example.com/dav/");
        assert!(https.admits(&Url::parse("https://example.com:443/other").unwrap()));
        assert!(!https.admits(&Url::parse("http://example.com/dav/").unwrap()), "no downgrade");
        assert!(!https.admits(&Url::parse("https://example.com:8443/").unwrap()));
        assert!(!https.admits(&Url::parse("https://evil.com/").unwrap()));
        let http = origin("http://nas.local:8080/");
        assert!(http.admits(&Url::parse("http://nas.local:8080/x").unwrap()));
        assert!(!http.admits(&Url::parse("https://nas.local/x").unwrap()), "a non-default port is not treated as an upgrade");
        assert!(origin("http://nas.local/").admits(&Url::parse("https://nas.local/x").unwrap()), "default port upgrades to HTTPS");
    }

    #[test]
    fn follows_same_origin_redirects_preserving_method() {
        let limits = Limits::default();
        let origin = origin("https://example.com/");
        let mut exchange = Exchange::new(request(Method::Propfind, "https://example.com/dav/a"));
        let Received::Resend(next) = exchange.receive(redirect(301, "/dav/a/"), &origin, &limits).unwrap() else { panic!() };
        assert_eq!((next.method, next.url.as_str(), next.body.as_slice()), (Method::Propfind, "https://example.com/dav/a/", &b"x"[..]));
        let Received::Resend(next) = exchange.receive(redirect(303, "b"), &origin, &limits).unwrap() else { panic!() };
        assert_eq!((next.method, next.body.is_empty(), next.header("content-type")), (Method::Get, true, None));
    }

    #[test]
    fn refuses_unsafe_redirects() {
        let limits = Limits { max_redirects: 1, ..Limits::default() };
        let origin = origin("https://example.com/");
        let mut exchange = Exchange::new(request(Method::Get, "https://example.com/a"));
        assert_eq!(exchange.receive(redirect(302, "https://evil.com/"), &origin, &limits).err(), Some(CloudError::InsecureRedirect));
        assert_eq!(exchange.receive(redirect(302, "http://example.com/"), &origin, &limits).err(), Some(CloudError::InsecureRedirect));
        assert!(matches!(exchange.receive(redirect(302, "/b"), &origin, &limits), Ok(Received::Resend(_))));
        assert_eq!(exchange.receive(redirect(302, "/c"), &origin, &limits).err(), Some(CloudError::TooManyRedirects));
        let mut missing = Exchange::new(request(Method::Get, "https://example.com/a"));
        assert!(matches!(missing.receive(HttpResponse::new(302), &origin, &limits), Err(CloudError::InvalidResponse(_))));
    }

    #[test]
    fn enforces_body_limit_and_maps_status() {
        let limits = Limits { max_body_bytes: 2, ..Limits::default() };
        let origin = origin("https://example.com/");
        let mut exchange = Exchange::new(request(Method::Get, "https://example.com/a"));
        let big = HttpResponse { status: 200, headers: Vec::new(), body: vec![0; 3] };
        assert_eq!(exchange.receive(big, &origin, &limits).err(), Some(CloudError::TooLarge));

        let limited = HttpResponse { status: 429, headers: vec![("Retry-After".into(), "120".into())], body: Vec::new() };
        assert_eq!(status_error(&limited), CloudError::RateLimited { retry_after: Some(Duration::from_secs(120)) });
        assert_eq!(status_error(&HttpResponse::new(401)), CloudError::ReauthRequired);
        assert_eq!(status_error(&HttpResponse::new(507)), CloudError::QuotaExceeded);
        assert_eq!(status_error(&HttpResponse::new(500)), CloudError::Server { status: 500 });
    }

    #[test]
    fn debug_hides_secrets() {
        let mut request = request(Method::Get, "https://example.com/a?token=secret");
        request.headers.push(("Authorization".into(), "Basic c2VjcmV0".into()));
        let text = format!("{request:?}");
        assert!(!text.contains("secret") && !text.contains("c2VjcmV0"), "{text}");
    }
}
