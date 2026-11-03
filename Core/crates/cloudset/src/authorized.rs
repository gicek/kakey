//! Generic driver for OAuth provider operations. Each provider only writes its operation as [`Steps`]
//! ("request -> response -> next request or result"); this module adds `Authorization: Bearer`, refreshes and replays
//! (once) when the token is about to expire or a 401 comes back, and hands the refreshed connection back to the caller.
//!
//! Requests with credentials only go to the provider's API origins ([`crate::providers::is_api_url`]); requests without
//! credentials (OneDrive's pre-signed download URLs) must use HTTPS. Redirects still follow the [`crate::http`] rules:
//! same origin only, no downgrade.

use crate::client::ClientConfig;
use crate::connection::{Connection, OAuthCredential};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse};
use crate::oauth::{self, origin_of};
use crate::operation::{Call, CallStep, Done, Operation, Step};
use crate::providers;

/// A request to send. When `authorize` is true, the driver adds the access token.
pub(crate) struct Outgoing {
    pub request: HttpRequest,
    pub authorize: bool,
}

impl Outgoing {
    pub(crate) fn authorized(request: HttpRequest) -> Self {
        Self { request, authorize: true }
    }
}

pub(crate) enum Next<T> {
    Request(Outgoing),
    Done(T),
}

/// One provider operation, unconcerned with authentication and refresh.
pub(crate) trait Steps: Send {
    type Output: Send;

    fn first(&mut self) -> Result<Outgoing, CloudError>;

    /// Final response to the previous request (401s are already handled by the driver).
    fn next(&mut self, response: HttpResponse) -> Result<Next<Self::Output>, CloudError>;
}

enum Phase {
    Start,
    Refreshing { call: Call, pending: Outgoing, after_unauthorized: bool },
    Sending { call: Call, outgoing: Outgoing, retried: bool },
    Finished,
}

pub(crate) struct Authorized<S> {
    steps: S,
    credential: OAuthCredential,
    config: ClientConfig,
    refreshed: bool,
    phase: Phase,
}

impl<S: Steps> Authorized<S> {
    pub(crate) fn new(steps: S, connection: &Connection, config: &ClientConfig) -> Result<Self, CloudError> {
        let credential = connection.oauth_credential().cloned().ok_or(CloudError::InvalidConnection)?;
        Ok(Self { steps, credential, config: config.clone(), refreshed: false, phase: Phase::Start })
    }

    fn send(&mut self, outgoing: Outgoing, retried: bool) -> Result<Step<S::Output>, CloudError> {
        if outgoing.authorize && !retried && oauth::needs_refresh(&self.credential, &self.config) {
            return self.refresh(outgoing, false);
        }
        let mut request = outgoing.request.clone();
        if outgoing.authorize {
            if !providers::is_api_url(self.credential.provider, &request.url) {
                return Err(CloudError::InsecureRedirect);
            }
            request.headers.push(("Authorization".into(), format!("Bearer {}", self.credential.access_token.as_str())));
        } else if !request.url.starts_with("https://") {
            return Err(CloudError::InsecureRedirect);
        }
        request.headers.push(("User-Agent".into(), self.config.user_agent.clone()));
        let mut call = Call::new(request.clone(), origin_of(&request.url)?, self.config.limits);
        let step = call.advance(None)?;
        self.phase = Phase::Sending { call, outgoing, retried };
        sent(step)
    }

    fn refresh(&mut self, pending: Outgoing, after_unauthorized: bool) -> Result<Step<S::Output>, CloudError> {
        let request = oauth::refresh_request(&self.credential, &self.config)?;
        let mut call = Call::new(request.clone(), origin_of(&request.url)?, self.config.limits);
        let step = call.advance(None)?;
        self.phase = Phase::Refreshing { call, pending, after_unauthorized };
        sent(step)
    }
}

fn sent<T>(step: CallStep) -> Result<Step<T>, CloudError> {
    match step {
        CallStep::Send(request) => Ok(Step::Send(request)),
        CallStep::Response(_) => Err(CloudError::OutOfOrder),
    }
}

impl<S: Steps> Operation for Authorized<S> {
    type Output = S::Output;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<S::Output>, CloudError> {
        match std::mem::replace(&mut self.phase, Phase::Finished) {
            Phase::Start if response.is_none() => {
                let outgoing = self.steps.first()?;
                self.send(outgoing, false)
            }
            Phase::Refreshing { mut call, pending, after_unauthorized } => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.phase = Phase::Refreshing { call, pending, after_unauthorized };
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    oauth::apply_refresh(&mut self.credential, &response, &self.config)?;
                    self.refreshed = true;
                    self.send(pending, after_unauthorized)
                }
            },
            Phase::Sending { mut call, outgoing, retried } => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.phase = Phase::Sending { call, outgoing, retried };
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) if response.status == 401 && outgoing.authorize => {
                    if retried {
                        Err(CloudError::ReauthRequired)
                    } else {
                        self.refresh(outgoing, true)
                    }
                }
                CallStep::Response(response) => match self.steps.next(response)? {
                    Next::Request(next) => self.send(next, false),
                    Next::Done(value) => {
                        Ok(Step::Done(Done { value, connection: self.refreshed.then(|| Connection::oauth(self.credential.clone())) }))
                    }
                },
            },
            Phase::Start | Phase::Finished => Err(CloudError::OutOfOrder),
        }
    }
}
