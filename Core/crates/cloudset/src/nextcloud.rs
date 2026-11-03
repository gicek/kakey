//! Nextcloud Login Flow v2: trades a browser sign-in for an app-specific password, then accesses files over WebDAV.
//!
//! 1. [`begin_login`]: `POST /index.php/login/v2` returns the login page URL and poll credentials; the caller opens the
//!    login page in the system browser.
//! 2. [`poll_login`]: the caller polls periodically; returns `None` until the user authorizes, then looks up the user
//!    ID and yields a [`Connection`].
//! 3. [`revoke`]: deletes the app password on disconnect.
//!
//! The poll endpoint, login page, and returned server URL must all share the origin of the server the user entered
//! (an upgrade to HTTPS on the same host is allowed).

use std::fmt;

use serde::Deserialize;
use url::Url;
use zeroize::Zeroizing;

use crate::client::ClientConfig;
use crate::connection::{Connection, Endpoint, Transport};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse, Method, status_error};
use crate::operation::{BoxOperation, Call, CallStep, Done, Operation, Ready, Single, Step};
use crate::path::RemotePath;

/// A login flow: open `login_url` in the system browser and pass `poll` to [`poll_login`].
#[derive(Clone, Debug)]
pub struct LoginFlow {
    pub login_url: String,
    pub poll: LoginPoll,
}

/// Data needed for polling. `Debug` does not print the token.
#[derive(Clone)]
pub struct LoginPoll {
    server: Endpoint,
    endpoint: Url,
    token: Zeroizing<String>,
}

impl fmt::Debug for LoginPoll {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginPoll").field("server", &self.server.as_str()).field("token", &"<redacted>").finish()
    }
}

#[derive(Deserialize)]
struct StartResponse {
    poll: PollInfo,
    login: String,
}

#[derive(Deserialize)]
struct PollInfo {
    token: String,
    endpoint: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Credentials {
    server: String,
    login_name: String,
    app_password: String,
}

#[derive(Deserialize)]
struct Ocs {
    ocs: OcsBody,
}

#[derive(Deserialize)]
struct OcsBody {
    data: OcsUser,
}

#[derive(Deserialize)]
struct OcsUser {
    id: String,
}

fn same_origin(server: &Endpoint, text: &str) -> Result<Url, CloudError> {
    let url = Url::parse(text).map_err(|_| CloudError::InvalidResponse("url"))?;
    if server.origin().admits(&url) { Ok(url) } else { Err(CloudError::InsecureRedirect) }
}

fn json<T: for<'de> Deserialize<'de>>(response: &HttpResponse) -> Result<T, CloudError> {
    serde_json::from_slice(&response.body).map_err(|_| CloudError::InvalidResponse("json"))
}

pub fn begin_login(server: &Endpoint, config: &ClientConfig) -> BoxOperation<LoginFlow> {
    let url = match server.join("index.php/login/v2") {
        Ok(url) => url,
        Err(error) => return Box::new(Ready::err(error)),
    };
    let request = HttpRequest {
        method: Method::Post,
        url: url.into(),
        headers: vec![("User-Agent".into(), config.user_agent.clone()), ("Accept".into(), "application/json".into())],
        body: Vec::new(),
    };
    let server = server.clone();
    Box::new(Single::new(Call::new(request, server.origin(), config.limits), move |response| {
        if response.status != 200 {
            return Err(status_error(&response));
        }
        let start: StartResponse = json(&response)?;
        let login = same_origin(&server, &start.login)?;
        let endpoint = same_origin(&server, &start.poll.endpoint)?;
        Ok(LoginFlow { login_url: login.into(), poll: LoginPoll { server, endpoint, token: Zeroizing::new(start.poll.token) } })
    }))
}

/// Yields `None` while the user has not finished authorizing; the caller polls again a few seconds later.
pub fn poll_login(poll: &LoginPoll, config: &ClientConfig) -> BoxOperation<Option<Connection>> {
    let body = url::form_urlencoded::Serializer::new(String::new()).append_pair("token", &poll.token).finish().into_bytes();
    let request = HttpRequest {
        method: Method::Post,
        url: poll.endpoint.to_string(),
        headers: vec![
            ("User-Agent".into(), config.user_agent.clone()),
            ("Accept".into(), "application/json".into()),
            ("Content-Type".into(), "application/x-www-form-urlencoded".into()),
        ],
        body,
    };
    let call = Call::new(request, poll.server.origin(), config.limits);
    Box::new(Poll { server: poll.server.clone(), config: config.clone(), state: PollState::Poll(call) })
}

enum PollState {
    Poll(Call),
    User(Call, Credentials),
    Finished,
}

struct Poll {
    server: Endpoint,
    config: ClientConfig,
    state: PollState,
}

impl Operation for Poll {
    type Output = Option<Connection>;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<Option<Connection>>, CloudError> {
        match std::mem::replace(&mut self.state, PollState::Finished) {
            PollState::Poll(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = PollState::Poll(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => match response.status {
                    404 => Ok(Step::Done(Done::value(None))),
                    200 => {
                        let credentials: Credentials = json(&response)?;
                        same_origin(&self.server, &credentials.server)?;
                        let connection = Connection::nextcloud(
                            self.server.clone(),
                            self.server.clone(),
                            credentials.login_name.clone(),
                            credentials.app_password.clone(),
                        );
                        let url = self.server.join("ocs/v2.php/cloud/user?format=json")?;
                        let request = HttpRequest {
                            method: Method::Get,
                            url: url.into(),
                            headers: vec![
                                ("Authorization".into(), connection.basic_authorization().to_string()),
                                ("User-Agent".into(), self.config.user_agent.clone()),
                                ("Accept".into(), "application/json".into()),
                                ("OCS-APIRequest".into(), "true".into()),
                            ],
                            body: Vec::new(),
                        };
                        let mut call = Call::new(request, self.server.origin(), self.config.limits);
                        let CallStep::Send(request) = call.advance(None)? else { return Err(CloudError::OutOfOrder) };
                        self.state = PollState::User(call, credentials);
                        Ok(Step::Send(request))
                    }
                    _ => Err(status_error(&response)),
                },
            },
            PollState::User(mut call, credentials) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = PollState::User(call, credentials);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    if response.status != 200 {
                        return Err(status_error(&response));
                    }
                    let ocs: Ocs = json(&response)?;
                    let user = RemotePath::from_segments([ocs.ocs.data.id]).map_err(|_| CloudError::InvalidResponse("user id"))?;
                    let files = Endpoint::parse(self.server.join("remote.php/dav/files/")?.as_str(), Transport::AllowInsecureHttp)?;
                    let endpoint = Endpoint::parse(files.resolve(&user, true)?.as_str(), Transport::AllowInsecureHttp)?;
                    let password = Zeroizing::new(credentials.app_password);
                    let connection = Connection::nextcloud(self.server.clone(), endpoint, credentials.login_name, password.to_string());
                    Ok(Step::Done(Done::value(Some(connection))))
                }
            },
            PollState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

/// Deletes the current app password; a 401 counts as already revoked.
pub(crate) fn revoke(connection: &Connection, config: &ClientConfig) -> BoxOperation<()> {
    let Some(server) = connection.server() else { return Box::new(Ready::ok(())) };
    let url = match server.join("ocs/v2.php/core/apppassword") {
        Ok(url) => url,
        Err(error) => return Box::new(Ready::err(error)),
    };
    let request = HttpRequest {
        method: Method::Delete,
        url: url.into(),
        headers: vec![
            ("Authorization".into(), connection.basic_authorization().to_string()),
            ("User-Agent".into(), config.user_agent.clone()),
            ("OCS-APIRequest".into(), "true".into()),
        ],
        body: Vec::new(),
    };
    Box::new(Single::new(Call::new(request, server.origin(), config.limits), |response| match response.status {
        200 | 204 | 401 => Ok(()),
        _ => Err(status_error(&response)),
    }))
}
