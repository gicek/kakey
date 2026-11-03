//! Shared parts of the OAuth providers: API origin allowlist, account name lookup, JSON requests, and time parsing.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use url::Url;

use crate::client::ClientConfig;
use crate::connection::{OAuthCredential, ProviderKind};
use crate::error::CloudError;
use crate::http::{HttpRequest, HttpResponse, Method};

/// Requests that carry credentials may only go to these origins (HTTPS, default port).
pub(crate) fn is_api_url(provider: ProviderKind, url: &str) -> bool {
    let Ok(url) = Url::parse(url) else { return false };
    if url.scheme() != "https" || url.port().is_some() {
        return false;
    }
    let host = url.host_str().unwrap_or_default();
    match provider {
        ProviderKind::Dropbox => matches!(host, "api.dropboxapi.com" | "content.dropboxapi.com"),
        ProviderKind::OneDrive => host == "graph.microsoft.com",
        // Metadata and uploads share this host (`/drive/v3`, `/upload/drive/v3`).
        ProviderKind::GoogleDrive => host == "www.googleapis.com",
        ProviderKind::WebDav | ProviderKind::Nextcloud => false,
    }
}

pub(crate) fn json_request(method: Method, url: &str, body: Option<&serde_json::Value>) -> HttpRequest {
    let mut headers = vec![("Accept".to_owned(), "application/json".to_owned())];
    let body = match body {
        Some(value) => {
            headers.push(("Content-Type".into(), "application/json".into()));
            value.to_string().into_bytes()
        }
        None => Vec::new(),
    };
    HttpRequest { method, url: url.to_owned(), headers, body }
}

/// Request for the account name (sent right after sign-in with the fresh access token, bypassing the refresh driver).
pub(crate) fn account_request(credential: &OAuthCredential, config: &ClientConfig) -> Result<HttpRequest, CloudError> {
    let mut request = match credential.provider {
        // RPC endpoint without arguments: the request body is JSON null.
        ProviderKind::Dropbox => {
            json_request(Method::Post, "https://api.dropboxapi.com/2/users/get_current_account", Some(&serde_json::Value::Null))
        }
        ProviderKind::OneDrive => {
            json_request(Method::Get, "https://graph.microsoft.com/v1.0/me?$select=displayName,mail,userPrincipalName", None)
        }
        // Allowed with `drive.file`, so no profile scope is requested.
        ProviderKind::GoogleDrive => {
            json_request(Method::Get, "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)", None)
        }
        ProviderKind::WebDav | ProviderKind::Nextcloud => return Err(CloudError::InvalidConnection),
    };
    request.headers.push(("Authorization".into(), format!("Bearer {}", credential.access_token.as_str())));
    request.headers.push(("User-Agent".into(), config.user_agent.clone()));
    Ok(request)
}

/// Display name of the account: the email on Dropbox, the email from `/me` on OneDrive (`User.Read`), the email from
/// Drive's `about` on Google Drive.
pub(crate) fn parse_account(provider: ProviderKind, response: &HttpResponse) -> Option<String> {
    if response.status != 200 {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&response.body).ok()?;
    let name = match provider {
        ProviderKind::Dropbox => json.get("email")?.as_str()?,
        // `mail` is often null on personal accounts, and `userPrincipalName` is the sign-in email; fall back to the display
        // name only when neither exists.
        ProviderKind::OneDrive => ["mail", "userPrincipalName", "displayName"]
            .iter()
            .find_map(|key| json.get(*key).and_then(serde_json::Value::as_str).filter(|value| !value.is_empty()))?,
        ProviderKind::GoogleDrive => ["emailAddress", "displayName"]
            .iter()
            .find_map(|key| json.pointer(&format!("/user/{key}")).and_then(serde_json::Value::as_str).filter(|value| !value.is_empty()))?,
        ProviderKind::WebDav | ProviderKind::Nextcloud => return None,
    };
    Some(name.to_owned())
}

/// RFC 3339 UTC time (`2026-10-28T09:12:40Z`, fractional seconds allowed). Only a `Z` suffix is accepted; returns `None`
/// on anything unreadable.
pub(crate) fn parse_utc(text: &str) -> Option<SystemTime> {
    let text = text.strip_suffix('Z')?;
    let (date, time) = text.split_once('T')?;
    let mut date = date.split('-').map(|part| part.parse::<i64>().ok());
    let (year, month, day) = (date.next()??, date.next()??, date.next()??);
    let mut time = time.split(':');
    let hour: i64 = time.next()?.parse().ok()?;
    let minute: i64 = time.next()?.parse().ok()?;
    let seconds = time.next()?;
    let (whole, fraction) = seconds.split_once('.').unwrap_or((seconds, ""));
    let second: i64 = whole.parse().ok()?;
    let nanos: u32 = if fraction.is_empty() { 0 } else { format!("{fraction:0<9}").get(..9)?.parse().ok()? };
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    // Howard Hinnant's days_from_civil
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = u64::try_from(days * 86_400 + hour * 3_600 + minute * 60 + second).ok()?;
    Some(UNIX_EPOCH + Duration::new(secs, nanos))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rfc3339_utc() {
        assert_eq!(parse_utc("1970-01-01T00:00:00Z"), Some(UNIX_EPOCH));
        assert_eq!(parse_utc("2026-10-28T09:12:40Z"), Some(UNIX_EPOCH + Duration::from_secs(1_793_178_760)));
        assert_eq!(parse_utc("2024-02-29T12:00:00.5Z"), Some(UNIX_EPOCH + Duration::new(1_709_208_000, 500_000_000)));
        for bad in ["2026-10-28T09:12:40", "2026-13-01T00:00:00Z", "yesterday", "2026-10-28 09:12:40Z"] {
            assert_eq!(parse_utc(bad), None, "{bad}");
        }
    }

    #[test]
    fn onedrive_account_prefers_an_email() {
        let me = |body: &str| HttpResponse { status: 200, headers: Vec::new(), body: body.as_bytes().to_vec() };
        let parse = |body: &str| parse_account(ProviderKind::OneDrive, &me(body));
        assert_eq!(
            parse(r#"{"displayName":"A","mail":"a@work.com","userPrincipalName":"a@corp.onmicrosoft.com"}"#).as_deref(),
            Some("a@work.com")
        );
        assert_eq!(parse(r#"{"displayName":"A","mail":null,"userPrincipalName":"a@outlook.com"}"#).as_deref(), Some("a@outlook.com"));
        assert_eq!(parse(r#"{"displayName":"A","mail":""}"#).as_deref(), Some("A"));
        assert_eq!(parse("{}"), None);
        assert_eq!(parse_account(ProviderKind::OneDrive, &HttpResponse { status: 403, headers: Vec::new(), body: Vec::new() }), None);
    }

    #[test]
    fn google_account_prefers_the_email() {
        let about = |body: &str| HttpResponse { status: 200, headers: Vec::new(), body: body.as_bytes().to_vec() };
        let parse = |body: &str| parse_account(ProviderKind::GoogleDrive, &about(body));
        assert_eq!(parse(r#"{"user":{"displayName":"Alice","emailAddress":"alice@gmail.com"}}"#).as_deref(), Some("alice@gmail.com"));
        assert_eq!(parse(r#"{"user":{"displayName":"Alice"}}"#).as_deref(), Some("Alice"));
        assert_eq!(parse(r#"{"kind":"drive#about"}"#), None);
    }

    #[test]
    fn api_url_whitelist() {
        assert!(is_api_url(ProviderKind::Dropbox, "https://api.dropboxapi.com/2/files/get_metadata"));
        assert!(is_api_url(ProviderKind::Dropbox, "https://content.dropboxapi.com/2/files/download"));
        assert!(!is_api_url(ProviderKind::Dropbox, "https://evil.com/2/files"));
        assert!(!is_api_url(ProviderKind::Dropbox, "http://api.dropboxapi.com/2/files"));
        assert!(!is_api_url(ProviderKind::Dropbox, "https://api.dropboxapi.com:8443/2/files"));
        assert!(is_api_url(ProviderKind::OneDrive, "https://graph.microsoft.com/v1.0/me/drive"));
        assert!(!is_api_url(ProviderKind::OneDrive, "https://public.bn.files.1drv.com/x"));
        assert!(is_api_url(ProviderKind::GoogleDrive, "https://www.googleapis.com/upload/drive/v3/files"));
        assert!(!is_api_url(ProviderKind::GoogleDrive, "https://oauth2.googleapis.com/revoke"), "revocation carries no bearer token");
        assert!(!is_api_url(ProviderKind::GoogleDrive, "https://graph.microsoft.com/v1.0/me"));
    }
}
