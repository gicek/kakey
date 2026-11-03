//! OAuth 2.0 authorization code flow (public client + PKCE, RFC 6749 / 7636 / 8252).
//!
//! 1. [`begin`]: builds the PKCE verifier and `state` from 64 random bytes supplied by the caller and assembles the
//!    authorization page URL; the caller opens it in the system browser (`ASWebAuthenticationSession` / Custom Tabs)
//!    and waits for the callback URL.
//! 2. [`Authorization::complete`]: validates the callback (`state` compared in constant time; any `error` fails),
//!    exchanges the authorization code and verifier for tokens, then looks up the account name, yielding a
//!    [`Connection`].
//!
//! 3. Dropbox can also authorize through its official Android app ([`Authorization::dropbox_app_request`] /
//!    [`Authorization::complete_dropbox_app`]): the same verifier, with the authorization code returned by the app via
//!    an intent and `state` in the app protocol's format.
//!
//! No client secret is built in: the authorization code can only be redeemed with the verifier, so an app that hijacks
//! the callback URL still cannot get tokens. Refreshing ([`refresh_request`] / [`apply_refresh`]) happens automatically
//! in [`crate::authorized`] when the token expires or a 401 comes back.

use std::fmt;
use std::time::{Duration, SystemTime};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use url::Url;
use zeroize::Zeroizing;

use crate::client::ClientConfig;
use crate::connection::{AccessScope, Connection, OAuthCredential, ProviderKind};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse, Method, Origin, status_error};
use crate::operation::{BoxOperation, Call, CallStep, Done, Operation, Step};

/// The caller's OAuth app configuration (public client, no secret).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OAuthClient {
    pub client_id: String,
    /// Callback URL registered in the provider's console, such as `com.example.app.oauth://callback`.
    pub redirect_uri: String,
    /// Name of the app folder on providers that have none of their own: Google Drive with [`AccessScope::AppFolder`]
    /// uses a visible folder with this name in the drive root, created on first access. Required there (otherwise
    /// [`begin`] reports [`CloudError::InvalidConnection`]); ignored by every other provider and scope, whose app folder
    /// is named by the app registration.
    pub folder_name: Option<String>,
}

impl OAuthClient {
    pub fn new(client_id: impl Into<String>, redirect_uri: impl Into<String>) -> Self {
        Self { client_id: client_id.into(), redirect_uri: redirect_uri.into(), folder_name: None }
    }

    pub fn with_folder_name(mut self, name: impl Into<String>) -> Self {
        self.folder_name = Some(name.into());
        self
    }
}

/// An access token counts as expired this long before it actually expires, so it does not lapse mid-request.
const EXPIRY_MARGIN: Duration = Duration::from_secs(60);

pub(crate) struct Endpoints {
    pub authorize: &'static str,
    pub token: &'static str,
}

pub(crate) fn endpoints(provider: ProviderKind) -> Result<Endpoints, CloudError> {
    match provider {
        ProviderKind::Dropbox => {
            Ok(Endpoints { authorize: "https://www.dropbox.com/oauth2/authorize", token: "https://api.dropboxapi.com/oauth2/token" })
        }
        ProviderKind::OneDrive => Ok(Endpoints {
            authorize: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            token: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        }),
        ProviderKind::GoogleDrive => {
            Ok(Endpoints { authorize: "https://accounts.google.com/o/oauth2/v2/auth", token: "https://oauth2.googleapis.com/token" })
        }
        ProviderKind::WebDav | ProviderKind::Nextcloud => Err(CloudError::InvalidConnection),
    }
}

/// Scope requested on the authorization page. Dropbox permissions are set by the app type (App folder / Full Dropbox).
/// Microsoft: `User.Read` is only for showing the account (with app folder access, `/me/drive` returns 403 and the drive
/// owner is unavailable; verified against the live API). Google: `drive.file` only reaches files the app created, which
/// is what makes the app folder private to it; `drive` (any folder) is a restricted scope. Drive's `about` works with
/// either, so no profile scope is needed for the account name.
fn scope(provider: ProviderKind, access: AccessScope) -> Option<&'static str> {
    match (provider, access) {
        (ProviderKind::OneDrive, AccessScope::AppFolder) => Some("offline_access User.Read Files.ReadWrite.AppFolder"),
        (ProviderKind::OneDrive, AccessScope::Full) => Some("offline_access User.Read Files.ReadWrite"),
        (ProviderKind::GoogleDrive, AccessScope::AppFolder) => Some(GOOGLE_DRIVE_FILE),
        (ProviderKind::GoogleDrive, AccessScope::Full) => Some(GOOGLE_DRIVE),
        _ => None,
    }
}

const GOOGLE_DRIVE_FILE: &str = "https://www.googleapis.com/auth/drive.file";
const GOOGLE_DRIVE: &str = "https://www.googleapis.com/auth/drive";

/// Scope sent to the token endpoint: only the Microsoft identity platform wants it again (on both code redemption and
/// refresh); Google keeps the scope of the grant.
fn token_scope(provider: ProviderKind, access: AccessScope) -> Option<&'static str> {
    if provider == ProviderKind::OneDrive { scope(provider, access) } else { None }
}

/// Google lets the user untick individual scopes on the consent page (granular consent), and the token response lists
/// what was actually granted. Without the Drive scope every request would fail with 403, so the sign-in counts as
/// denied. Scopes are compared as whole, case-sensitive words.
fn granted_enough(provider: ProviderKind, access: AccessScope, granted: Option<&str>) -> bool {
    if provider != ProviderKind::GoogleDrive {
        return true;
    }
    let Some(required) = scope(provider, access) else { return false };
    granted.is_some_and(|granted| granted.split(' ').any(|scope| scope == required))
}

/// Authorization parameters handed to the official Dropbox Android app (the same protocol as `AuthActivity` in the
/// official `dropbox-sdk-java` SDK). The platform puts them into a `com.dropbox.android.AUTHENTICATE_V2` intent; the app
/// returns the authorization code and `auth_state` unchanged.
#[derive(Clone, PartialEq, Eq)]
pub struct DropboxAppRequest {
    pub app_key: String,
    /// `oauth2code:<code_challenge>:S256:offline`: tells the app to run the PKCE authorization code flow, and comes back
    /// unchanged as `state`.
    pub auth_state: String,
    /// Query parameters read by older app versions; same content as `auth_state`.
    pub query_params: String,
}

impl fmt::Debug for DropboxAppRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DropboxAppRequest").field("app_key", &self.app_key).finish_non_exhaustive()
    }
}

/// Token type returned by the app for the PKCE authorization code flow: `oauth2code:` in the `ACCESS_TOKEN` field (with
/// the colon, matching `TokenType.OAUTH2CODE` in the official SDK; verified on a device), with the authorization code in
/// the `ACCESS_SECRET` field.
pub const DROPBOX_APP_CODE_TOKEN_TYPE: &str = "oauth2code:";

/// An authorization in progress: holds the verifier and `state`; `Debug` does not print them.
pub struct Authorization {
    provider: ProviderKind,
    access: AccessScope,
    client: OAuthClient,
    verifier: Zeroizing<String>,
    state: Zeroizing<String>,
    url: String,
}

impl fmt::Debug for Authorization {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Authorization").field("provider", &self.provider).field("access", &self.access).finish_non_exhaustive()
    }
}

/// Starts authorization. `random` must come from the system CSPRNG: the first 32 bytes become the PKCE verifier, the last
/// 32 bytes the `state`.
pub fn begin(provider: ProviderKind, access: AccessScope, client: OAuthClient, random: &[u8; 64]) -> Result<Authorization, CloudError> {
    let endpoints = endpoints(provider)?;
    if provider == ProviderKind::GoogleDrive
        && access == AccessScope::AppFolder
        && !client.folder_name.as_deref().is_some_and(|name| crate::path::RemotePath::root().join(name).is_ok())
    {
        return Err(CloudError::InvalidConnection);
    }
    let verifier = Zeroizing::new(URL_SAFE_NO_PAD.encode(&random[..32]));
    let state = Zeroizing::new(URL_SAFE_NO_PAD.encode(&random[32..]));
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut url = Url::parse(endpoints.authorize).map_err(|_| CloudError::InvalidConnection)?;
    {
        let mut query = url.query_pairs_mut();
        query
            .append_pair("client_id", &client.client_id)
            .append_pair("response_type", "code")
            .append_pair("redirect_uri", &client.redirect_uri)
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &state);
        match provider {
            ProviderKind::Dropbox => {
                query.append_pair("token_access_type", "offline");
            }
            ProviderKind::OneDrive => {
                query.append_pair("response_mode", "query");
                if let Some(scope) = scope(provider, access) {
                    query.append_pair("scope", scope);
                }
            }
            // Installed apps always receive a refresh token; `access_type` is a web-server parameter.
            ProviderKind::GoogleDrive => {
                if let Some(scope) = scope(provider, access) {
                    query.append_pair("scope", scope);
                }
            }
            ProviderKind::WebDav | ProviderKind::Nextcloud => {}
        }
    }
    Ok(Authorization { provider, access, client, verifier, state, url: url.into() })
}

impl Authorization {
    /// Authorization page to open in the system browser.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// Scheme of the callback URL (required by `ASWebAuthenticationSession`).
    pub fn callback_scheme(&self) -> String {
        Url::parse(&self.client.redirect_uri).map(|url| url.scheme().to_owned()).unwrap_or_default()
    }

    /// Whether a callback belongs to this authorization (URL matches the registered one, `state` matches), without
    /// consuming it. Android's callback activity uses this to forward only the callback it is waiting for.
    pub fn accepts(&self, callback_url: &str) -> bool {
        !matches!(self.code_from(callback_url), Err(CloudError::StateMismatch | CloudError::InvalidResponse("callback url")))
    }

    /// Validates the callback, exchanges the authorization code for tokens, and looks up the account name. A callback that
    /// does not match the registered URL, a mismatched `state`, or an `error` fails immediately without any request.
    pub fn complete(&self, callback_url: &str, config: &ClientConfig) -> Result<BoxOperation<Connection>, CloudError> {
        let code = self.code_from(callback_url)?;
        self.exchange(&code, Some(&self.client.redirect_uri), config)
    }

    /// Parameters for authorizing through the official Dropbox Android app; `None` if the provider is not Dropbox.
    pub fn dropbox_app_request(&self) -> Option<DropboxAppRequest> {
        (self.provider == ProviderKind::Dropbox).then(|| {
            let challenge = self.challenge();
            DropboxAppRequest {
                app_key: self.client.client_id.clone(),
                auth_state: self.dropbox_app_state(),
                query_params: format!("code_challenge={challenge}&code_challenge_method=S256&token_access_type=offline&response_type=code"),
            }
        })
    }

    /// Whether a result returned by the app belongs to this authorization (`state` compared in constant time), without
    /// consuming it.
    pub fn accepts_dropbox_app(&self, state: &str) -> bool {
        self.provider == ProviderKind::Dropbox && constant_time_eq(state.as_bytes(), self.dropbox_app_state().as_bytes())
    }

    /// Validates the result returned by the Dropbox app, exchanges the authorization code for tokens, and looks up the
    /// account name. A mismatched `state` reports `StateMismatch`; a token type other than the authorization code, or an
    /// empty code (the user cancelled), reports `AuthorizationDenied`; neither sends a request. The app opens the
    /// authorization page and there is no callback URL, so the token exchange omits `redirect_uri` (RFC 6749 §4.1.3: it
    /// is only required when the authorization request included it).
    pub fn complete_dropbox_app(
        &self,
        token_type: &str,
        code: &str,
        state: &str,
        config: &ClientConfig,
    ) -> Result<BoxOperation<Connection>, CloudError> {
        if self.provider != ProviderKind::Dropbox {
            return Err(CloudError::InvalidConnection);
        }
        if !self.accepts_dropbox_app(state) {
            return Err(CloudError::StateMismatch);
        }
        if token_type != DROPBOX_APP_CODE_TOKEN_TYPE || code.is_empty() {
            return Err(CloudError::AuthorizationDenied);
        }
        self.exchange(code, None, config)
    }

    /// iOS: URL that launches the Dropbox app (the same protocol as `DropboxMobileOAuthManager` in the official
    /// SwiftyDropbox SDK). `scheme` is `dbapi-2` (App Store build) or `dbapi-8-emm` (enterprise build), chosen by the
    /// platform based on which one can be opened; `None` if the provider is not Dropbox.
    pub fn dropbox_app_url(&self, scheme: &str) -> Option<String> {
        let request = self.dropbox_app_request()?;
        let mut url = Url::parse(&format!("{scheme}://1/connect")).ok()?;
        url.query_pairs_mut()
            .append_pair("k", &request.app_key)
            .append_pair("s", "")
            .append_pair("state", &request.auth_state)
            .append_pair("extra_query_params", &request.query_params);
        Some(url.into())
    }

    /// iOS: whether the app's return URL (`db-<app key>://1/connect?...`) belongs to this authorization, without consuming
    /// it. A path other than `/connect` means the user cancelled in the app; it is still accepted (and reported as denied
    /// by [`Self::complete_dropbox_app_callback`]), otherwise the user would be stuck on "Signing in" forever.
    pub fn accepts_dropbox_app_callback(&self, callback_url: &str) -> bool {
        match self.dropbox_app_callback(callback_url) {
            Ok(Some((state, _, _))) => self.accepts_dropbox_app(&state),
            Ok(None) => true,
            Err(_) => false,
        }
    }

    /// iOS: validates the app's return URL and exchanges tokens. Newer app versions send `oauth_code`, older ones
    /// `oauth_token=oauth2code:` and `oauth_token_secret`; the rules are the same as [`Self::complete_dropbox_app`].
    pub fn complete_dropbox_app_callback(&self, callback_url: &str, config: &ClientConfig) -> Result<BoxOperation<Connection>, CloudError> {
        match self.dropbox_app_callback(callback_url)? {
            Some((state, token_type, code)) => self.complete_dropbox_app(&token_type, &code, &state, config),
            None => Err(CloudError::AuthorizationDenied),
        }
    }

    /// Parses the return URL: the scheme must match the registered callback and the host must be `1`; a `/connect` path
    /// yields (`state`, token type, authorization code), anything else is a cancellation.
    #[allow(clippy::type_complexity)]
    fn dropbox_app_callback(&self, callback_url: &str) -> Result<Option<(String, String, Zeroizing<String>)>, CloudError> {
        let callback = Url::parse(callback_url).map_err(|_| CloudError::InvalidResponse("callback url"))?;
        let registered = Url::parse(&self.client.redirect_uri).map_err(|_| CloudError::InvalidResponse("redirect uri"))?;
        if self.provider != ProviderKind::Dropbox || callback.scheme() != registered.scheme() || callback.host_str() != Some("1") {
            return Err(CloudError::InvalidResponse("callback url"));
        }
        if callback.path() != "/connect" {
            return Ok(None);
        }
        let mut state = String::new();
        let mut code = None;
        let mut token = None;
        let mut secret = None;
        for (key, value) in callback.query_pairs() {
            match key.as_ref() {
                "state" => state = value.into_owned(),
                "oauth_code" => code = Some(Zeroizing::new(value.into_owned())),
                "oauth_token" => token = Some(value.into_owned()),
                "oauth_token_secret" => secret = Some(Zeroizing::new(value.into_owned())),
                _ => {}
            }
        }
        Ok(Some(match (code, token, secret) {
            (Some(code), _, _) => (state, DROPBOX_APP_CODE_TOKEN_TYPE.to_owned(), code),
            (None, Some(token), Some(secret)) => (state, token, secret),
            _ => (state, String::new(), Zeroizing::new(String::new())),
        }))
    }

    fn challenge(&self) -> String {
        URL_SAFE_NO_PAD.encode(Sha256::digest(self.verifier.as_bytes()))
    }

    /// `state` for the app protocol: carries the PKCE challenge and is only handed to the official app; the verifier is
    /// random, so other apps cannot guess it.
    fn dropbox_app_state(&self) -> String {
        format!("oauth2code:{}:S256:offline", self.challenge())
    }

    fn exchange(&self, code: &str, redirect_uri: Option<&str>, config: &ClientConfig) -> Result<BoxOperation<Connection>, CloudError> {
        let endpoints = endpoints(self.provider)?;
        let mut form = vec![
            ("grant_type", "authorization_code".to_owned()),
            ("code", code.to_owned()),
            ("code_verifier", self.verifier.to_string()),
            ("client_id", self.client.client_id.clone()),
        ];
        if let Some(redirect_uri) = redirect_uri {
            form.push(("redirect_uri", redirect_uri.to_owned()));
        }
        if let Some(scope) = token_scope(self.provider, self.access) {
            form.push(("scope", scope.to_owned()));
        }
        let request = form_request(endpoints.token, &form, config)?;
        let call = Call::new(request, origin_of(endpoints.token)?, config.limits);
        let folder_name = (self.provider == ProviderKind::GoogleDrive && self.access == AccessScope::AppFolder)
            .then(|| self.client.folder_name.clone())
            .flatten();
        Ok(Box::new(Exchange {
            provider: self.provider,
            access: self.access,
            client_id: self.client.client_id.clone(),
            folder_name,
            config: config.clone(),
            state: ExchangeState::Token(call),
        }))
    }

    fn code_from(&self, callback_url: &str) -> Result<Zeroizing<String>, CloudError> {
        let callback = Url::parse(callback_url).map_err(|_| CloudError::InvalidResponse("callback url"))?;
        let registered = Url::parse(&self.client.redirect_uri).map_err(|_| CloudError::InvalidResponse("redirect uri"))?;
        if callback.scheme() != registered.scheme() || callback.host_str() != registered.host_str() || path(&callback) != path(&registered)
        {
            return Err(CloudError::InvalidResponse("callback url"));
        }
        let mut code = None;
        let mut state = None;
        let mut error = false;
        for (key, value) in callback.query_pairs() {
            match key.as_ref() {
                "code" => code = Some(Zeroizing::new(value.into_owned())),
                "state" => state = Some(Zeroizing::new(value.into_owned())),
                "error" => error = true,
                _ => {}
            }
        }
        if !state.is_some_and(|state| constant_time_eq(state.as_bytes(), self.state.as_bytes())) {
            return Err(CloudError::StateMismatch);
        }
        if error {
            return Err(CloudError::AuthorizationDenied);
        }
        code.filter(|code| !code.is_empty()).ok_or(CloudError::InvalidResponse("missing code"))
    }
}

/// Path of a callback URL: with a host, an empty path equals `/` (RFC 3986 §6.2.3). Microsoft turns `msal<id>://auth`
/// into `auth/` when redirecting back.
fn path(url: &Url) -> &str {
    if url.path().is_empty() { "/" } else { url.path() }
}

/// Different lengths are unequal right away; for equal lengths, XOR bytes into an accumulator without returning early at
/// the first difference.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub(crate) fn origin_of(url: &str) -> Result<Origin, CloudError> {
    Url::parse(url).map(|url| Origin::of(&url)).map_err(|_| CloudError::InvalidConnection)
}

fn form_request(url: &str, form: &[(&str, String)], config: &ClientConfig) -> Result<HttpRequest, CloudError> {
    let body = url::form_urlencoded::Serializer::new(String::new()).extend_pairs(form.iter().map(|(k, v)| (*k, v.as_str()))).finish();
    Ok(HttpRequest {
        method: Method::Post,
        url: url.to_owned(),
        headers: vec![
            ("Content-Type".into(), "application/x-www-form-urlencoded".into()),
            ("Accept".into(), "application/json".into()),
            ("User-Agent".into(), config.user_agent.clone()),
        ],
        body: Zeroizing::new(body).as_bytes().to_vec(),
    })
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    /// Space-separated scopes actually granted (Google, Microsoft); absent on Dropbox.
    #[serde(default)]
    scope: Option<String>,
}

fn parse_token(response: &HttpResponse) -> Result<TokenResponse, CloudError> {
    match response.status {
        200 => serde_json::from_slice(&response.body).map_err(|_| CloudError::InvalidResponse("token json")),
        // invalid_grant (refresh token revoked or expired), invalid_client, etc.: the only way out is signing in again.
        400 | 401 => Err(CloudError::ReauthRequired),
        _ => Err(status_error(response)),
    }
}

fn expires_at(expires_in: Option<u64>, config: &ClientConfig) -> Option<SystemTime> {
    Some(config.now? + Duration::from_secs(expires_in?))
}

/// Request that exchanges the refresh token for a new access token.
pub(crate) fn refresh_request(credential: &OAuthCredential, config: &ClientConfig) -> Result<HttpRequest, CloudError> {
    let endpoints = endpoints(credential.provider)?;
    let mut form = vec![
        ("grant_type", "refresh_token".to_owned()),
        ("refresh_token", credential.refresh_token.to_string()),
        ("client_id", credential.client_id.clone()),
    ];
    if let Some(scope) = token_scope(credential.provider, credential.access) {
        form.push(("scope", scope.to_owned()));
    }
    form_request(endpoints.token, &form, config)
}

/// Applies a refresh result. If the provider rotated the refresh token (Microsoft does), it is replaced too; otherwise the
/// old one is kept.
pub(crate) fn apply_refresh(credential: &mut OAuthCredential, response: &HttpResponse, config: &ClientConfig) -> Result<(), CloudError> {
    let token = parse_token(response)?;
    credential.access_token = Zeroizing::new(token.access_token);
    if let Some(refresh) = token.refresh_token.filter(|token| !token.is_empty()) {
        credential.refresh_token = Zeroizing::new(refresh);
    }
    credential.expires_at = expires_at(token.expires_in, config);
    Ok(())
}

/// Whether to refresh first: when both the current time and the expiry are known and the early-refresh margin has been
/// reached. Without a known time, refresh only after a 401.
pub(crate) fn needs_refresh(credential: &OAuthCredential, config: &ClientConfig) -> bool {
    match (config.now, credential.expires_at) {
        (Some(now), Some(expires_at)) => now + EXPIRY_MARGIN >= expires_at,
        _ => false,
    }
}

enum ExchangeState {
    Token(Call),
    Account(Call, OAuthCredential),
    Finished,
}

/// Exchange tokens -> look up the account name -> yield the connection.
struct Exchange {
    provider: ProviderKind,
    access: AccessScope,
    client_id: String,
    folder_name: Option<String>,
    config: ClientConfig,
    state: ExchangeState,
}

impl Operation for Exchange {
    type Output = Connection;

    fn advance(&mut self, response: Option<HttpResponse>) -> Result<Step<Connection>, CloudError> {
        match std::mem::replace(&mut self.state, ExchangeState::Finished) {
            ExchangeState::Token(mut call) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = ExchangeState::Token(call);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    let token = parse_token(&response)?;
                    if !granted_enough(self.provider, self.access, token.scope.as_deref()) {
                        return Err(CloudError::AuthorizationDenied);
                    }
                    let refresh_token =
                        token.refresh_token.filter(|token| !token.is_empty()).ok_or(CloudError::InvalidResponse("no refresh token"))?;
                    let credential = OAuthCredential {
                        provider: self.provider,
                        access: self.access,
                        client_id: self.client_id.clone(),
                        access_token: Zeroizing::new(token.access_token),
                        refresh_token: Zeroizing::new(refresh_token),
                        expires_at: expires_at(token.expires_in, &self.config),
                        account: String::new(),
                        folder_name: self.folder_name.clone(),
                    };
                    let request = crate::providers::account_request(&credential, &self.config)?;
                    let mut call = Call::new(request.clone(), origin_of(&request.url)?, self.config.limits);
                    let CallStep::Send(request) = call.advance(None)? else { return Err(CloudError::OutOfOrder) };
                    self.state = ExchangeState::Account(call, credential);
                    Ok(Step::Send(request))
                }
            },
            ExchangeState::Account(mut call, mut credential) => match call.advance(response)? {
                CallStep::Send(request) => {
                    self.state = ExchangeState::Account(call, credential);
                    Ok(Step::Send(request))
                }
                CallStep::Response(response) => {
                    // The account name is for display only: failing to look it up does not affect the connection.
                    credential.account = crate::providers::parse_account(credential.provider, &response).unwrap_or_default();
                    Ok(Step::Done(Done::value(Connection::oauth(credential))))
                }
            },
            ExchangeState::Finished => Err(CloudError::OutOfOrder),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::UNIX_EPOCH;

    use super::*;

    fn client() -> OAuthClient {
        OAuthClient::new("app-key", "com.example.app.oauth://callback")
    }

    #[test]
    fn pkce_challenge_matches_rfc_7636_appendix_b() {
        // RFC 7636 Appendix B: the verifier and its S256 challenge
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        // The 32 random bytes from Appendix B encode to exactly this verifier
        let octets: [u8; 32] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88,
            83, 132, 141, 121,
        ];
        let mut random = [0u8; 64];
        random[..32].copy_from_slice(&octets);
        let authorization = begin(ProviderKind::Dropbox, AccessScope::AppFolder, client(), &random).unwrap();
        assert_eq!(authorization.verifier.as_str(), verifier);
        let url = Url::parse(authorization.url()).unwrap();
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        assert_eq!(query["code_challenge_method"], "S256");
        assert_eq!(query["token_access_type"], "offline");
        assert_eq!(query["redirect_uri"], "com.example.app.oauth://callback");
        assert_eq!(authorization.callback_scheme(), "com.example.app.oauth");
        assert!(!query.contains_key("client_secret"));
    }

    #[test]
    fn onedrive_requests_least_privilege_scope() {
        let app = begin(ProviderKind::OneDrive, AccessScope::AppFolder, client(), &[7; 64]).unwrap();
        assert!(app.url().starts_with("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"));
        assert!(app.url().contains("scope=offline_access+User.Read+Files.ReadWrite.AppFolder"));
        let full = begin(ProviderKind::OneDrive, AccessScope::Full, client(), &[7; 64]).unwrap();
        assert!(full.url().ends_with("scope=offline_access+User.Read+Files.ReadWrite"));
        assert!(begin(ProviderKind::WebDav, AccessScope::Full, client(), &[7; 64]).is_err());
    }

    fn google_client() -> OAuthClient {
        OAuthClient::new("123-abc.apps.googleusercontent.com", "com.googleusercontent.apps.123-abc:/oauth2redirect")
            .with_folder_name("My App")
    }

    #[test]
    fn google_requests_drive_file_and_needs_a_folder_name() {
        let app = begin(ProviderKind::GoogleDrive, AccessScope::AppFolder, google_client(), &[7; 64]).unwrap();
        let url = Url::parse(app.url()).unwrap();
        assert_eq!((url.host_str(), url.path()), (Some("accounts.google.com"), "/o/oauth2/v2/auth"));
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query["scope"], "https://www.googleapis.com/auth/drive.file");
        assert_eq!(query["redirect_uri"], "com.googleusercontent.apps.123-abc:/oauth2redirect");
        assert!(!query.contains_key("access_type") && !query.contains_key("client_secret"));
        assert_eq!(app.callback_scheme(), "com.googleusercontent.apps.123-abc");
        let full = begin(ProviderKind::GoogleDrive, AccessScope::Full, google_client(), &[7; 64]).unwrap();
        let full: std::collections::HashMap<_, _> = Url::parse(full.url()).unwrap().query_pairs().into_owned().collect();
        assert_eq!(full["scope"], "https://www.googleapis.com/auth/drive");

        let unnamed = OAuthClient::new("id", "com.googleusercontent.apps.id:/oauth2redirect");
        assert_eq!(
            begin(ProviderKind::GoogleDrive, AccessScope::AppFolder, unnamed.clone(), &[7; 64]).err(),
            Some(CloudError::InvalidConnection)
        );
        assert!(begin(ProviderKind::GoogleDrive, AccessScope::Full, unnamed.clone(), &[7; 64]).is_ok(), "the full scope needs no folder");
        let traversal = unnamed.with_folder_name("../x");
        assert_eq!(
            begin(ProviderKind::GoogleDrive, AccessScope::AppFolder, traversal, &[7; 64]).err(),
            Some(CloudError::InvalidConnection)
        );
    }

    /// Google's callback has no host and a single-slash path, and carries extra parameters (`scope`, `iss`).
    #[test]
    fn google_callback_without_host_is_matched_exactly() {
        let authorization = begin(ProviderKind::GoogleDrive, AccessScope::AppFolder, google_client(), &[6; 64]).unwrap();
        let state = authorization.state.to_string();
        let scheme = "com.googleusercontent.apps.123-abc";
        assert!(authorization.accepts(&format!("{scheme}:/oauth2redirect?state={state}&iss=https://accounts.google.com&code=c&scope=x")));
        assert!(!authorization.accepts(&format!("{scheme}:/other?state={state}&code=c")));
        assert!(!authorization.accepts(&format!("{scheme}://oauth2redirect?state={state}&code=c")), "a host is not the same URL");
        assert!(!authorization.accepts(&format!("com.googleusercontent.apps.evil:/oauth2redirect?state={state}&code=c")));
    }

    /// Granular consent: a grant without the Drive scope is useless, so sign-in reports denied and no account lookup is
    /// sent. Code redemption and refresh carry no scope for Google.
    #[test]
    fn google_sign_in_requires_the_drive_scope_to_be_granted() {
        let config = ClientConfig::new("t");
        let token = |scope: &str| HttpResponse {
            status: 200,
            headers: Vec::new(),
            body: format!(
                r#"{{"access_token":"ya29.a","expires_in":3599,"refresh_token":"1//r","scope":"{scope}","token_type":"Bearer"}}"#
            )
            .into_bytes(),
        };
        for (granted, ok) in [
            ("https://www.googleapis.com/auth/drive.file", true),
            ("openid https://www.googleapis.com/auth/drive.file", true),
            ("https://www.googleapis.com/auth/drive.readonly", false),
            ("https://www.googleapis.com/auth/drive.file.x", false),
            ("", false),
        ] {
            let authorization = begin(ProviderKind::GoogleDrive, AccessScope::AppFolder, google_client(), &[8; 64]).unwrap();
            let state = authorization.state.to_string();
            let callback = format!("com.googleusercontent.apps.123-abc:/oauth2redirect?code=c&state={state}");
            let mut operation = authorization.complete(&callback, &config).unwrap();
            let mut requests = 0;
            let result = crate::drive(operation.as_mut(), |request| {
                requests += 1;
                if request.url.ends_with("/token") {
                    let body = String::from_utf8(request.body).unwrap();
                    assert!(!body.contains("scope=") && !body.contains("client_secret"), "{body}");
                    token(granted)
                } else {
                    assert!(request.url.starts_with("https://www.googleapis.com/drive/v3/about?"), "{}", request.url);
                    HttpResponse { status: 200, headers: Vec::new(), body: br#"{"user":{"emailAddress":"a@gmail.com"}}"#.to_vec() }
                }
            });
            match result {
                Ok(done) => {
                    assert!(ok, "{granted}");
                    let credential = done.value.oauth_credential().cloned().unwrap();
                    assert_eq!((credential.account.as_str(), credential.folder_name.as_deref()), ("a@gmail.com", Some("My App")));
                    let refresh = String::from_utf8(refresh_request(&credential, &config).unwrap().body).unwrap();
                    assert!(refresh.contains("grant_type=refresh_token") && !refresh.contains("scope="), "{refresh}");
                }
                Err(error) => {
                    assert!(!ok, "{granted}");
                    assert_eq!((error, requests), (CloudError::AuthorizationDenied, 1), "{granted}");
                }
            }
        }
    }

    #[test]
    fn callback_is_validated_before_any_request() {
        let authorization = begin(ProviderKind::Dropbox, AccessScope::AppFolder, client(), &[9; 64]).unwrap();
        let state = authorization.state.to_string();
        let config = ClientConfig::new("t");
        let complete = |url: String| authorization.complete(&url, &config).map(|_| ());
        assert_eq!(complete("com.example.app.oauth://callback?code=abc&state=wrong".into()), Err(CloudError::StateMismatch));
        assert_eq!(complete("com.example.app.oauth://callback?code=abc".into()), Err(CloudError::StateMismatch));
        assert_eq!(
            complete(format!("com.example.app.oauth://callback?error=access_denied&state={state}")),
            Err(CloudError::AuthorizationDenied)
        );
        assert_eq!(
            complete(format!("com.example.app.oauth://evil?code=abc&state={state}")),
            Err(CloudError::InvalidResponse("callback url"))
        );
        assert_eq!(complete(format!("com.example.app.oauth://callback?state={state}")), Err(CloudError::InvalidResponse("missing code")));
        assert!(complete(format!("com.example.app.oauth://callback?code=abc&state={state}")).is_ok());
        assert!(authorization.accepts(&format!("com.example.app.oauth://callback?code=abc&state={state}")));
        assert!(
            authorization.accepts(&format!("com.example.app.oauth://callback?error=access_denied&state={state}")),
            "a callback with error is also passed to complete, which reports it"
        );
        assert!(!authorization.accepts("com.example.app.oauth://callback?code=abc&state=wrong"));
        assert!(!authorization.accepts(&format!("com.example.app.oauth://evil?code=abc&state={state}")));
        assert!(!format!("{authorization:?}").contains(&state));
    }

    #[test]
    fn callback_path_treats_empty_and_slash_alike() {
        let client = OAuthClient::new("id", "msalid://auth");
        let authorization = begin(ProviderKind::OneDrive, AccessScope::AppFolder, client, &[4; 64]).unwrap();
        let state = authorization.state.to_string();
        // Microsoft turns `msal<id>://auth` into `msal<id>://auth/` when redirecting back
        assert!(authorization.accepts(&format!("msalid://auth/?code=abc&state={state}")));
        assert!(authorization.accepts(&format!("msalid://auth?code=abc&state={state}")));
        assert!(!authorization.accepts(&format!("msalid://auth/x?code=abc&state={state}")));
        assert!(!authorization.accepts(&format!("msalid://other/?code=abc&state={state}")));
    }

    #[test]
    fn token_exchange_sends_verifier_and_builds_a_connection() {
        let authorization = begin(ProviderKind::Dropbox, AccessScope::Full, client(), &[3; 64]).unwrap();
        let state = authorization.state.to_string();
        let mut config = ClientConfig::new("cloudset-test");
        config.now = Some(UNIX_EPOCH + Duration::from_secs(1_000));
        let mut operation =
            authorization.complete(&format!("com.example.app.oauth://callback?code=the-code&state={state}"), &config).unwrap();
        let mut seen = Vec::new();
        let done = crate::drive(operation.as_mut(), |request| {
            seen.push(request.clone());
            if request.url.ends_with("/oauth2/token") {
                let body = String::from_utf8(request.body).unwrap();
                assert!(
                    body.contains("grant_type=authorization_code") && body.contains("code=the-code") && body.contains("code_verifier=")
                );
                assert!(!body.contains("client_secret"));
                HttpResponse {
                    status: 200,
                    headers: Vec::new(),
                    body: br#"{"access_token":"sl.A","expires_in":14400,"token_type":"bearer","refresh_token":"R","account_id":"x"}"#
                        .to_vec(),
                }
            } else {
                assert_eq!(request.header("Authorization"), Some("Bearer sl.A"));
                HttpResponse {
                    status: 200,
                    headers: Vec::new(),
                    body: br#"{"email":"alice@example.com","name":{"display_name":"Alice"}}"#.to_vec(),
                }
            }
        })
        .unwrap();
        let connection = done.value;
        assert_eq!(
            (connection.provider(), connection.username(), connection.access_scope()),
            (ProviderKind::Dropbox, "alice@example.com", Some(AccessScope::Full))
        );
        let credential = connection.oauth_credential().unwrap();
        assert_eq!(credential.expires_at, Some(UNIX_EPOCH + Duration::from_secs(1_000 + 14_400)));
        assert_eq!(seen.len(), 2);
    }

    /// Authorization through the official Dropbox app: parameters match the official SDK, the returned result is checked
    /// for `state` and token type first, and the token exchange uses the same verifier without `redirect_uri`.
    #[test]
    fn dropbox_app_flow_uses_the_same_verifier_without_redirect_uri() {
        // The verifier from RFC 7636 Appendix B, with a known challenge
        let octets: [u8; 32] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88,
            83, 132, 141, 121,
        ];
        let mut random = [0u8; 64];
        random[..32].copy_from_slice(&octets);
        let authorization = begin(ProviderKind::Dropbox, AccessScope::AppFolder, client(), &random).unwrap();
        let request = authorization.dropbox_app_request().unwrap();
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
        assert_eq!(request.app_key, "app-key");
        assert_eq!(request.auth_state, format!("oauth2code:{challenge}:S256:offline"));
        assert_eq!(
            request.query_params,
            format!("code_challenge={challenge}&code_challenge_method=S256&token_access_type=offline&response_type=code")
        );
        assert!(!format!("{request:?}").contains(challenge));

        let config = ClientConfig::new("t");
        let state = request.auth_state.as_str();
        let complete =
            |token_type: &str, code: &str, state: &str| authorization.complete_dropbox_app(token_type, code, state, &config).map(|_| ());
        assert_eq!(complete("oauth2code:", "c", "oauth2code:other:S256:offline"), Err(CloudError::StateMismatch));
        assert_eq!(complete("oauth2code:", "c", ""), Err(CloudError::StateMismatch));
        assert_eq!(complete("oauth2:", "c", state), Err(CloudError::AuthorizationDenied), "the legacy long-lived token flow is rejected");
        assert_eq!(
            complete("oauth2code", "c", state),
            Err(CloudError::AuthorizationDenied),
            "the type includes the colon, as in the official SDK"
        );
        assert_eq!(complete("oauth2code:", "", state), Err(CloudError::AuthorizationDenied));
        assert!(authorization.accepts_dropbox_app(state));
        assert!(!authorization.accepts_dropbox_app("oauth2code:x:S256:offline"));

        let mut operation = authorization.complete_dropbox_app("oauth2code:", "app-code", state, &config).unwrap();
        let done = crate::drive(operation.as_mut(), |request| {
            if request.url.ends_with("/oauth2/token") {
                let body = String::from_utf8(request.body).unwrap();
                assert!(body.contains("code=app-code") && body.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
                assert!(!body.contains("redirect_uri"), "app authorization has no callback URL");
                HttpResponse { status: 200, headers: Vec::new(), body: br#"{"access_token":"sl.A","refresh_token":"R"}"#.to_vec() }
            } else {
                HttpResponse { status: 200, headers: Vec::new(), body: br#"{"email":"alice@example.com"}"#.to_vec() }
            }
        })
        .unwrap();
        assert_eq!(done.value.username(), "alice@example.com");

        let onedrive = begin(ProviderKind::OneDrive, AccessScope::AppFolder, client(), &[1; 64]).unwrap();
        assert!(onedrive.dropbox_app_request().is_none());
        assert_eq!(onedrive.complete_dropbox_app("oauth2code:", "c", "s", &config).map(|_| ()), Err(CloudError::InvalidConnection));
    }

    /// App authorization on iOS: the launch URL matches the official SDK; the return URL is checked for scheme, host, and
    /// `state`; both old and new authorization code forms are accepted, and cancellations are passed back too.
    #[test]
    fn dropbox_app_urls_for_ios() {
        let dropbox = OAuthClient::new("AbC", "db-abc://2/token");
        let authorization = begin(ProviderKind::Dropbox, AccessScope::AppFolder, dropbox, &[2; 64]).unwrap();
        let request = authorization.dropbox_app_request().unwrap();
        let url = Url::parse(&authorization.dropbox_app_url("dbapi-2").unwrap()).unwrap();
        assert_eq!((url.scheme(), url.host_str(), url.path()), ("dbapi-2", Some("1"), "/connect"));
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query["k"], "AbC");
        assert_eq!(query["s"], "");
        assert_eq!(query["state"], request.auth_state);
        assert_eq!(query["extra_query_params"], request.query_params);

        let state = url::form_urlencoded::byte_serialize(request.auth_state.as_bytes()).collect::<String>();
        let new = format!("db-abc://1/connect?state={state}&oauth_code=c1");
        let legacy = format!("db-abc://1/connect?state={state}&oauth_token=oauth2code%3A&oauth_token_secret=c2");
        assert!(authorization.accepts_dropbox_app_callback(&new));
        assert!(authorization.accepts_dropbox_app_callback(&legacy));
        assert!(authorization.accepts_dropbox_app_callback("db-abc://1/cancel"), "cancellations are passed back too");
        assert!(!authorization.accepts_dropbox_app_callback("db-abc://1/connect?state=other&oauth_code=c"));
        assert!(!authorization.accepts_dropbox_app_callback(&format!("db-evil://1/connect?state={state}&oauth_code=c")));
        assert!(!authorization.accepts_dropbox_app_callback(&format!("db-abc://2/token?state={state}&code=c")));

        let config = ClientConfig::new("t");
        let complete = |url: &str| authorization.complete_dropbox_app_callback(url, &config).map(|_| ());
        assert!(complete(&new).is_ok());
        assert!(complete(&legacy).is_ok());
        assert_eq!(complete("db-abc://1/cancel"), Err(CloudError::AuthorizationDenied));
        assert_eq!(complete(&format!("db-abc://1/connect?state={state}")), Err(CloudError::AuthorizationDenied));
        assert_eq!(complete("db-abc://1/connect?state=other&oauth_code=c"), Err(CloudError::StateMismatch));
        assert!(begin(ProviderKind::OneDrive, AccessScope::AppFolder, client(), &[2; 64]).unwrap().dropbox_app_url("dbapi-2").is_none());
    }

    #[test]
    fn token_errors_need_a_new_sign_in() {
        let authorization = begin(ProviderKind::OneDrive, AccessScope::AppFolder, client(), &[5; 64]).unwrap();
        let state = authorization.state.to_string();
        let config = ClientConfig::new("t");
        let mut operation = authorization.complete(&format!("com.example.app.oauth://callback?code=c&state={state}"), &config).unwrap();
        let result = crate::drive(operation.as_mut(), |_| HttpResponse {
            status: 400,
            headers: Vec::new(),
            body: br#"{"error":"invalid_grant"}"#.to_vec(),
        });
        assert_eq!(result.err(), Some(CloudError::ReauthRequired));
    }

    #[test]
    fn refresh_rotates_tokens_and_tracks_expiry() {
        let mut credential = OAuthCredential {
            provider: ProviderKind::OneDrive,
            access: AccessScope::AppFolder,
            client_id: "id".into(),
            access_token: Zeroizing::new("old".into()),
            refresh_token: Zeroizing::new("r1".into()),
            expires_at: Some(UNIX_EPOCH + Duration::from_secs(100)),
            account: "a".into(),
            folder_name: None,
        };
        let mut config = ClientConfig::new("t");
        config.now = Some(UNIX_EPOCH + Duration::from_secs(50));
        assert!(needs_refresh(&credential, &config), "inside the 60-second early-refresh window");
        let request = refresh_request(&credential, &config).unwrap();
        let body = String::from_utf8(request.body).unwrap();
        assert!(body.contains("grant_type=refresh_token") && body.contains("refresh_token=r1") && body.contains("scope=offline_access"));
        let response = HttpResponse {
            status: 200,
            headers: Vec::new(),
            body: br#"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#.to_vec(),
        };
        apply_refresh(&mut credential, &response, &config).unwrap();
        assert_eq!((credential.access_token.as_str(), credential.refresh_token.as_str()), ("new", "r2"));
        assert!(!needs_refresh(&credential, &config));
        let without_rotation =
            HttpResponse { status: 200, headers: Vec::new(), body: br#"{"access_token":"newer","expires_in":3600}"#.to_vec() };
        apply_refresh(&mut credential, &without_rotation, &config).unwrap();
        assert_eq!(credential.refresh_token.as_str(), "r2", "keeps the old refresh token when no new one is given");
        assert!(!needs_refresh(&credential, &ClientConfig::new("t")), "no proactive refresh without the current time");
        assert!(constant_time_eq(b"abc", b"abc") && !constant_time_eq(b"abc", b"abd") && !constant_time_eq(b"ab", b"abc"));
    }
}
