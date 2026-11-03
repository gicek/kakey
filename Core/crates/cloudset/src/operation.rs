//! Operation state machines: the component does no IO; every operation is a loop of "emit a request -> receive the
//! response -> emit the next request or a result".
//!
//! ```text
//! let mut response = None;
//! loop {
//!     match operation.advance(response.take())? {
//!         Step::Send(request) => response = Some(execute(request)),
//!         Step::Done(done) => break done,
//!     }
//! }
//! ```

use crate::connection::Connection;
use crate::error::CloudError;
use crate::http::{Exchange, HttpRequest, HttpResponse, Limits, Origin, Received};

pub enum Step<T> {
    /// Execute this request and pass the response to the next `advance`.
    Send(HttpRequest),
    Done(Done<T>),
}

pub struct Done<T> {
    pub value: T,
    /// When the connection data changed (a token refresh, for example), carries the new value; the caller replaces its
    /// stored copy.
    pub connection: Option<Connection>,
}

impl<T> Done<T> {
    pub(crate) fn value(value: T) -> Self {
        Self { value, connection: None }
    }
}

pub trait Operation: Send {
    type Output;

    /// Pass `None` on the first call, then the response to the previous request. Must not be called again after it
    /// returns `Done` or an error.
    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<Self::Output>, CloudError>;
}

pub type BoxOperation<T> = Box<dyn Operation<Output = T>>;

/// Runs an operation to completion with a synchronous transport function: for tests and Rust callers that do not need
/// async.
pub fn drive<T>(
    operation: &mut dyn Operation<Output = T>,
    mut transport: impl FnMut(HttpRequest) -> HttpResponse,
) -> Result<Done<T>, CloudError> {
    let mut response = None;
    loop {
        match operation.advance(response.take())? {
            Step::Send(request) => response = Some(transport(request)),
            Step::Done(done) => return Ok(done),
        }
    }
}

/// Send state of one request (including redirects).
pub(crate) struct Call {
    exchange: Exchange,
    origin: Origin,
    limits: Limits,
    sent: bool,
}

pub(crate) enum CallStep {
    Send(HttpRequest),
    Response(HttpResponse),
}

impl Call {
    pub(crate) fn new(request: HttpRequest, origin: Origin, limits: Limits) -> Self {
        Self { exchange: Exchange::new(request), origin, limits, sent: false }
    }

    pub(crate) fn advance(&mut self, response: Option<HttpResponse>) -> Result<CallStep, CloudError> {
        match (self.sent, response) {
            (false, None) => {
                self.sent = true;
                Ok(CallStep::Send(self.exchange.request()))
            }
            (true, Some(response)) => match self.exchange.receive(response, &self.origin, &self.limits)? {
                Received::Resend(request) => Ok(CallStep::Send(request)),
                Received::Final(response) => Ok(CallStep::Response(response)),
            },
            _ => Err(CloudError::OutOfOrder),
        }
    }
}

/// An operation with a single request: the final response goes to `interpret`.
pub(crate) struct Single<T, F> {
    call: Call,
    interpret: Option<F>,
    _output: std::marker::PhantomData<fn() -> T>,
}

impl<T, F> Single<T, F>
where
    F: FnOnce(HttpResponse) -> Result<T, CloudError> + Send,
{
    pub(crate) fn new(call: Call, interpret: F) -> Self {
        Self { call, interpret: Some(interpret), _output: std::marker::PhantomData }
    }
}

impl<T, F> Operation for Single<T, F>
where
    F: FnOnce(HttpResponse) -> Result<T, CloudError> + Send,
{
    type Output = T;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<T>, CloudError> {
        match self.call.advance(response)? {
            CallStep::Send(request) => Ok(Step::Send(request)),
            CallStep::Response(response) => {
                let interpret = self.interpret.take().ok_or(CloudError::OutOfOrder)?;
                Ok(Step::Done(Done::value(interpret(response)?)))
            }
        }
    }
}

/// An operation that needs no request and yields its result directly (for providers without a revocation endpoint, for
/// example).
pub(crate) struct Ready<T>(Option<Result<T, CloudError>>);

impl<T> Ready<T> {
    pub(crate) fn ok(value: T) -> Self {
        Self(Some(Ok(value)))
    }

    pub(crate) fn err(error: CloudError) -> Self {
        Self(Some(Err(error)))
    }
}

impl<T: Send> Operation for Ready<T> {
    type Output = T;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<T>, CloudError> {
        if response.is_some() {
            return Err(CloudError::OutOfOrder);
        }
        Ok(Step::Done(Done::value(self.0.take().ok_or(CloudError::OutOfOrder)??)))
    }
}

/// Maps an operation's result to another type (leaves the request sequence and connection updates unchanged).
pub fn map<T: 'static, U: 'static>(operation: BoxOperation<T>, transform: impl FnMut(T) -> U + Send + 'static) -> BoxOperation<U> {
    Box::new(Map { operation, transform })
}

struct Map<T, F> {
    operation: BoxOperation<T>,
    transform: F,
}

impl<T, U, F: FnMut(T) -> U + Send> Operation for Map<T, F> {
    type Output = U;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<U>, CloudError> {
        Ok(match self.operation.advance(response)? {
            Step::Send(request) => Step::Send(request),
            Step::Done(done) => Step::Done(Done { value: (self.transform)(done.value), connection: done.connection }),
        })
    }
}

/// One sub-operation inside a composite operation: hands the sub-operation's errors back to the composer to decide
/// (creating a missing directory first, for example), and records connection updates it produces so the composer can
/// pass them to the caller when it finishes.
pub struct Subtask<T> {
    operation: BoxOperation<T>,
}

pub enum Progress<T> {
    Send(HttpRequest),
    Finished(Result<T, CloudError>),
}

impl<T> Subtask<T> {
    /// Starts the sub-operation and returns its first step.
    pub fn start(operation: BoxOperation<T>, connection: &mut Option<Connection>) -> (Self, Progress<T>) {
        let mut subtask = Self { operation };
        let progress = subtask.advance(None, connection);
        (subtask, progress)
    }

    /// Advances the sub-operation; if it finishes with a new connection, writes it to `connection`.
    pub fn advance(&mut self, response: Option<HttpResponse>, connection: &mut Option<Connection>) -> Progress<T> {
        match self.operation.advance(response) {
            Ok(Step::Send(request)) => Progress::Send(request),
            Ok(Step::Done(done)) => {
                if done.connection.is_some() {
                    *connection = done.connection;
                }
                Progress::Finished(Ok(done.value))
            }
            Err(error) => Progress::Finished(Err(error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::{Endpoint, Transport};

    /// An operation that sends one request, then finishes with a new connection after the response (simulates a token
    /// refresh).
    struct Refreshing(bool);

    impl Operation for Refreshing {
        type Output = u8;

        fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<u8>, CloudError> {
            match (self.0, response) {
                (false, None) => {
                    self.0 = true;
                    Ok(Step::Send(HttpRequest {
                        method: crate::Method::Get,
                        url: "https://x/".into(),
                        headers: Vec::new(),
                        body: Vec::new(),
                    }))
                }
                (true, Some(_)) => Ok(Step::Done(Done { value: 7, connection: Some(refreshed()) })),
                _ => Err(CloudError::OutOfOrder),
            }
        }
    }

    fn refreshed() -> Connection {
        Connection::webdav(Endpoint::parse("https://x/", Transport::RequireHttps).unwrap(), "u".into(), "new".into())
    }

    #[test]
    fn map_and_subtask_carry_connection_updates() {
        let mut mapped = map(Box::new(Refreshing(false)), |value| value * 2);
        let done = drive(mapped.as_mut(), |_| HttpResponse::new(200)).unwrap();
        assert_eq!((done.value, done.connection), (14, Some(refreshed())));

        let mut latest = None;
        let (mut subtask, progress) = Subtask::start(Box::new(Refreshing(false)), &mut latest);
        assert!(matches!(progress, Progress::Send(_)));
        assert!(latest.is_none());
        assert!(matches!(subtask.advance(Some(HttpResponse::new(200)), &mut latest), Progress::Finished(Ok(7))));
        assert_eq!(latest, Some(refreshed()));
        assert!(matches!(subtask.advance(None, &mut latest), Progress::Finished(Err(CloudError::OutOfOrder))));
        assert_eq!(latest, Some(refreshed()), "a failing sub-operation must not clear the recorded connection");
    }

    #[test]
    fn ready_operations() {
        let mut ok = Ready::ok(1u8);
        assert!(matches!(ok.advance(None), Ok(Step::Done(Done { value: 1, connection: None }))));
        assert_eq!(ok.advance(None).err(), Some(CloudError::OutOfOrder));
        assert_eq!(Ready::<u8>::err(CloudError::InvalidPath).advance(None).err(), Some(CloudError::InvalidPath));
    }
}
