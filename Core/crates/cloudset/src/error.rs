use std::time::Duration;

/// Why a cloud storage operation failed. Transport failures (offline, timeout, TLS) are reported by the caller's
/// executor, not here.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CloudError {
    /// Credentials are invalid or revoked: the user must sign in again.
    #[error("authentication required")]
    ReauthRequired,
    /// Authenticated but not allowed to access this location.
    #[error("access denied")]
    Forbidden,
    #[error("not found")]
    NotFound,
    /// A conditional write was rejected: the remote changed since it was last read (or it exists although "absent" was
    /// required).
    #[error("remote changed since it was last read")]
    PreconditionFailed,
    #[error("storage quota exceeded")]
    QuotaExceeded,
    #[error("rate limited")]
    RateLimited { retry_after: Option<Duration> },
    /// Any other unexpected status code.
    #[error("server returned HTTP {status}")]
    Server { status: u16 },
    /// The response does not follow the protocol; carries a short reason that contains no remote data.
    #[error("invalid response: {0}")]
    InvalidResponse(&'static str),
    /// The response body exceeds [`crate::Limits`].
    #[error("response too large")]
    TooLarge,
    /// A redirect to another origin, or a downgrade from HTTPS to HTTP.
    #[error("redirect to another origin refused")]
    InsecureRedirect,
    #[error("too many redirects")]
    TooManyRedirects,
    /// The URL is plain HTTP and the caller did not allow it ([`crate::Transport::RequireHttps`]).
    #[error("plain http is not allowed for this server")]
    InsecureEndpoint,
    /// The server address is invalid (scheme, host, user info, query string).
    #[error("invalid server address: {0}")]
    InvalidEndpoint(&'static str),
    /// The remote path is invalid (empty segment, `.` / `..`, control characters).
    #[error("invalid remote path")]
    InvalidPath,
    /// The OAuth callback `state` does not match the one sent (or is missing): possibly a forged callback, so it is
    /// discarded.
    #[error("authorization state mismatch")]
    StateMismatch,
    /// The user denied or cancelled on the authorization page, or the provider returned an error.
    #[error("authorization denied")]
    AuthorizationDenied,
    /// Persisted connection data cannot be read.
    #[error("invalid stored connection")]
    InvalidConnection,
    /// The operation was advanced after it finished, or given a response on its first advance: the caller's drive loop
    /// is wrong.
    #[error("operation driven out of order")]
    OutOfOrder,
}
