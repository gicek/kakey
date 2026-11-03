//! Parsing of `otpauth://totp/...` and Google Authenticator `otpauth-migration://offline?data=...`.
//!
//! URL structure is parsed with `url`, the migration protobuf with `prost`. The query is split by hand: `URLComponents`
//! does not treat `+` as a space but `url::Url::query_pairs` does, so a `+` in the issuer would differ between platforms.

use base64::Engine;
use prost::Message;
use url::Url;

use crate::canonical::{clean_text, normalized_issuer, normalized_username, standardized_secret, stripping_issuer_prefix};
use crate::model::{Placeholders, TotpAlgorithm, redacted_secret};
use crate::{base32, totp};

/// Why parsing failed; each platform looks up localized text by `l10n_key` (keys match Mac).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseFailure {
    BadUrl,
    NotOtpauth,
    NotTotp,
    MissingSecret,
    BadBase32,
    Digits,
    Period,
    BadMigration,
    UnsupportedAlgorithm,
}

impl ParseFailure {
    pub fn l10n_key(self) -> &'static str {
        match self {
            ParseFailure::BadUrl => "otp.err.bad_url",
            ParseFailure::NotOtpauth => "otp.err.not_otpauth",
            ParseFailure::NotTotp => "otp.err.not_totp",
            ParseFailure::MissingSecret => "otp.err.missing_secret",
            ParseFailure::BadBase32 => "otp.err.bad_base32",
            ParseFailure::Digits => "otp.err.digits",
            ParseFailure::Period => "otp.err.period",
            ParseFailure::BadMigration => "otp.err.bad_migration",
            ParseFailure::UnsupportedAlgorithm => "otp.err.unsupported_algorithm",
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ParsedOtpAuth {
    pub failure: Option<ParseFailure>,
    pub issuer: String,
    pub account: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
}

impl std::fmt::Debug for ParsedOtpAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ParsedOtpAuth")
            .field("failure", &self.failure)
            .field("issuer", &self.issuer)
            .field("account", &self.account)
            .field("secret", &redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .finish()
    }
}

impl ParsedOtpAuth {
    pub fn is_valid(&self) -> bool {
        self.failure.is_none()
    }

    fn invalid(failure: ParseFailure) -> Self {
        ParsedOtpAuth {
            failure: Some(failure),
            issuer: String::new(),
            account: String::new(),
            secret: String::new(),
            algorithm: TotpAlgorithm::Sha1,
            digits: 6,
            period: 30,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanResult {
    pub accounts: Vec<ParsedOtpAuth>,
    pub batch_index: Option<i64>,
    pub batch_size: Option<i64>,
    pub batch_id: Option<i64>,
    pub is_google_migration: bool,
}

impl ScanResult {
    fn single(account: ParsedOtpAuth) -> Self {
        ScanResult { accounts: vec![account], batch_index: None, batch_size: None, batch_id: None, is_google_migration: false }
    }

    fn invalid_migration() -> Self {
        ScanResult {
            accounts: vec![ParsedOtpAuth::invalid(ParseFailure::BadMigration)],
            batch_index: None,
            batch_size: None,
            batch_id: None,
            is_google_migration: true,
        }
    }

    pub fn valid_accounts(&self) -> Vec<ParsedOtpAuth> {
        self.accounts.iter().filter(|account| account.is_valid()).cloned().collect()
    }

    /// Distinguishes batches when merging several migration QR codes; `None` for non-migration codes or when the batch
    /// index is missing.
    pub fn batch_key(&self) -> Option<String> {
        if !self.is_google_migration {
            return None;
        }
        let index = self.batch_index?;
        Some(format!("{}-{}-{}", self.batch_id.unwrap_or(0), self.batch_size.unwrap_or(0), index))
    }
}

/// Parses line by line (newline-separated, blank lines skipped); migration codes expand into several entries.
pub fn parse_lines(text: &str, placeholders: &Placeholders) -> Vec<ParsedOtpAuth> {
    text.split(is_newline).filter(|line| !line.is_empty()).flat_map(|line| parse_scan_result(line, placeholders).accounts).collect()
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

pub fn parse_scan_result(line: &str, placeholders: &Placeholders) -> ScanResult {
    let url = match parse_url(line) {
        Ok(url) => url,
        Err(failure) => return ScanResult::single(ParsedOtpAuth::invalid(failure)),
    };
    if url.scheme() == "otpauth-migration" {
        return parse_migration(&url, placeholders);
    }
    ScanResult::single(parse_otpauth(&url, placeholders))
}

/// Parses a single entry; for a migration code, the first valid account is taken.
pub fn parse(line: &str, placeholders: &Placeholders) -> ParsedOtpAuth {
    let url = match parse_url(line) {
        Ok(url) => url,
        Err(failure) => return ParsedOtpAuth::invalid(failure),
    };
    if url.scheme() == "otpauth-migration" {
        let result = parse_migration(&url, placeholders);
        return result
            .accounts
            .iter()
            .find(|account| account.is_valid())
            .or(result.accounts.first())
            .cloned()
            .unwrap_or_else(|| ParsedOtpAuth::invalid(ParseFailure::BadMigration));
    }
    parse_otpauth(&url, placeholders)
}

fn parse_url(line: &str) -> Result<Url, ParseFailure> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Err(ParseFailure::BadUrl);
    }
    match Url::parse(trimmed) {
        Ok(url) => Ok(url),
        // Foundation accepts text without a scheme as a relative URL, then rejects it because the scheme is not otpauth.
        Err(url::ParseError::RelativeUrlWithoutBase) => Err(ParseFailure::NotOtpauth),
        Err(_) => Err(ParseFailure::BadUrl),
    }
}

/// `URLComponents.queryItems` semantics: split on `&`, split name and value at the first `=`, percent-decode each, and keep
/// `+`.
fn query_items(url: &Url) -> Vec<(String, Option<String>)> {
    let Some(query) = url.query() else { return Vec::new() };
    query
        .split('&')
        .map(|item| {
            let decode = |value: &str| percent_encoding::percent_decode_str(value).decode_utf8_lossy().into_owned();
            match item.split_once('=') {
                Some((name, value)) => (decode(name), Some(decode(value))),
                None => (decode(item), None),
            }
        })
        .collect()
}

fn query_value(items: &[(String, Option<String>)], name: &str) -> Option<String> {
    items.iter().find(|(key, _)| key.to_lowercase() == name).and_then(|(_, value)| value.clone())
}

/// Equivalent of Swift `split(separator: ":", maxSplits: 1)` (which drops empty pieces by default).
fn split_label(label: &str) -> Vec<String> {
    let trimmed = label.trim_start_matches(':');
    if trimmed.is_empty() {
        return Vec::new();
    }
    match trimmed.split_once(':') {
        Some((first, rest)) if !rest.is_empty() => vec![first.to_owned(), rest.to_owned()],
        Some((first, _)) => vec![first.to_owned()],
        None => vec![trimmed.to_owned()],
    }
}

fn parse_otpauth(url: &Url, placeholders: &Placeholders) -> ParsedOtpAuth {
    if url.scheme() != "otpauth" {
        return ParsedOtpAuth::invalid(ParseFailure::NotOtpauth);
    }
    let otp_type = url.host_str().unwrap_or("").to_lowercase();
    if otp_type != "totp" && otp_type != "1" {
        return ParsedOtpAuth::invalid(ParseFailure::NotTotp);
    }
    let items = query_items(url);
    let secret = query_value(&items, "secret").unwrap_or_default();
    if clean_text(&secret).is_empty() {
        return ParsedOtpAuth::invalid(ParseFailure::MissingSecret);
    }
    let Some(secret) = standardized_secret(&secret) else {
        return ParsedOtpAuth::invalid(ParseFailure::BadBase32);
    };

    let issuer_query = clean_text(&query_value(&items, "issuer").unwrap_or_default());
    // Decode first, then split the label (issuer:account) at the first colon: some QR codes encode the colon as %3A.
    let label = clean_text(url.path().trim_matches('/'));
    let label_parts: Vec<String> = split_label(&label).iter().map(|part| clean_text(part)).collect();
    let issuer_from_label = label_parts.first().cloned().unwrap_or_default();
    let issuer = if issuer_query.is_empty() { issuer_from_label } else { issuer_query };
    let account_part = if label_parts.len() > 1 { label_parts[1].clone() } else { label.clone() };
    let account = stripping_issuer_prefix(&account_part, &issuer);

    let algorithm = query_value(&items, "algorithm")
        .and_then(|value| TotpAlgorithm::from_raw_value(&value.to_uppercase()))
        .unwrap_or(TotpAlgorithm::Sha1);
    let digits = query_value(&items, "digits").and_then(|value| value.parse::<i64>().ok()).unwrap_or(6);
    let period = query_value(&items, "period").and_then(|value| value.parse::<i64>().ok()).unwrap_or(30);
    if digits != 6 && digits != 8 {
        return ParsedOtpAuth::invalid(ParseFailure::Digits);
    }
    if period <= 0 || period > i64::from(u32::MAX) {
        return ParsedOtpAuth::invalid(ParseFailure::Period);
    }

    ParsedOtpAuth {
        failure: None,
        issuer: normalized_issuer(&issuer, placeholders),
        account: normalized_username(&account, placeholders),
        secret,
        algorithm,
        digits: digits as u32,
        period: period as u32,
    }
}

// Google Authenticator migration payload. Enums and omittable fields are declared optional: the fallback when absent
// (totp / SHA1 / 6 digits) means something different from an explicit 0 (unspecified), so the two must be told apart.
#[derive(Clone, PartialEq, Message)]
struct MigrationPayload {
    #[prost(message, repeated, tag = "1")]
    otp_parameters: Vec<OtpParameters>,
    #[prost(int32, optional, tag = "3")]
    batch_size: Option<i32>,
    #[prost(int32, optional, tag = "4")]
    batch_index: Option<i32>,
    #[prost(int32, optional, tag = "5")]
    batch_id: Option<i32>,
}

#[derive(Clone, PartialEq, Message)]
struct OtpParameters {
    #[prost(bytes = "vec", tag = "1")]
    secret: Vec<u8>,
    // Names are read as bytes: invalid UTF-8 becomes an empty string on Mac instead of failing the whole migration code.
    #[prost(bytes = "vec", tag = "2")]
    name: Vec<u8>,
    #[prost(bytes = "vec", tag = "3")]
    issuer: Vec<u8>,
    #[prost(int32, optional, tag = "4")]
    algorithm: Option<i32>,
    #[prost(int32, optional, tag = "5")]
    digits: Option<i32>,
    #[prost(int32, optional, tag = "6")]
    otp_type: Option<i32>,
}

fn decode_migration_data(value: &str) -> Option<Vec<u8>> {
    let mut normalized = value.replace('-', "+").replace('_', "/");
    let remainder = normalized.chars().count() % 4;
    if remainder > 0 {
        normalized.push_str(&"=".repeat(4 - remainder));
    }
    base64::engine::general_purpose::STANDARD.decode(normalized).ok()
}

fn parse_migration(url: &Url, placeholders: &Placeholders) -> ScanResult {
    if url.host_str().map(str::to_lowercase).as_deref() != Some("offline") {
        return ScanResult::invalid_migration();
    }
    let items = query_items(url);
    let Some(data) = items.iter().find(|(name, _)| name == "data").and_then(|(_, value)| value.as_deref()) else {
        return ScanResult::invalid_migration();
    };
    let Some(bytes) = decode_migration_data(data) else {
        return ScanResult::invalid_migration();
    };
    let Ok(payload) = MigrationPayload::decode(bytes.as_slice()) else {
        return ScanResult::invalid_migration();
    };

    let accounts: Vec<ParsedOtpAuth> = payload
        .otp_parameters
        .iter()
        .map(|parameter| {
            // Defaults to totp(2); an explicit unspecified(0), hotp(1), or unknown value is not TOTP.
            if parameter.otp_type.unwrap_or(2) != 2 {
                return ParsedOtpAuth::invalid(ParseFailure::NotTotp);
            }
            let secret = base32::encode(&parameter.secret);
            if secret.is_empty() || !totp::is_valid_secret(&secret) {
                return ParsedOtpAuth::invalid(ParseFailure::BadBase32);
            }
            let algorithm = match parameter.algorithm.unwrap_or(1) {
                2 => TotpAlgorithm::Sha256,
                3 => TotpAlgorithm::Sha512,
                4 => return ParsedOtpAuth::invalid(ParseFailure::UnsupportedAlgorithm),
                _ => TotpAlgorithm::Sha1,
            };
            let digits = if parameter.digits == Some(2) { 8 } else { 6 };
            let issuer = String::from_utf8(parameter.issuer.clone()).unwrap_or_default();
            let name = String::from_utf8(parameter.name.clone()).unwrap_or_default();
            ParsedOtpAuth {
                failure: None,
                issuer: normalized_issuer(&issuer, placeholders),
                account: normalized_username(&stripping_issuer_prefix(&name, &issuer), placeholders),
                secret,
                algorithm,
                digits,
                period: 30,
            }
        })
        .collect();

    ScanResult {
        accounts: if accounts.is_empty() { vec![ParsedOtpAuth::invalid(ParseFailure::BadMigration)] } else { accounts },
        batch_index: payload.batch_index.map(i64::from),
        batch_size: payload.batch_size.map(i64::from),
        batch_id: payload.batch_id.map(i64::from),
        is_google_migration: true,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn placeholders() -> Placeholders {
        Placeholders { unknown_issuer: "Unknown service".into(), empty_username: "No account".into() }
    }

    /// (secret, name, issuer, algorithm, digits, type)
    type Parameter<'a> = (&'a [u8], &'a str, &'a str, i32, i32, i32);

    /// Test helper: encodes a migration payload in Google Authenticator's format.
    pub(crate) fn migration_url(parameters: &[Parameter<'_>], batch: Option<(i32, i32, i32)>) -> String {
        let payload = MigrationPayload {
            otp_parameters: parameters
                .iter()
                .map(|(secret, name, issuer, algorithm, digits, otp_type)| OtpParameters {
                    secret: secret.to_vec(),
                    name: name.as_bytes().to_vec(),
                    issuer: issuer.as_bytes().to_vec(),
                    algorithm: Some(*algorithm),
                    digits: Some(*digits),
                    otp_type: Some(*otp_type),
                })
                .collect(),
            batch_size: batch.map(|b| b.0),
            batch_index: batch.map(|b| b.1),
            batch_id: batch.map(|b| b.2),
        };
        let data = base64::engine::general_purpose::STANDARD.encode(payload.encode_to_vec());
        let encoded = percent_encoding::utf8_percent_encode(&data, percent_encoding::NON_ALPHANUMERIC);
        format!("otpauth-migration://offline?data={encoded}")
    }

    #[test]
    fn parses_standard_uri() {
        let result = parse(
            "otpauth://totp/GitHub%3Aalex%40example.com?secret=mzxw6ytboi&issuer=GitHub&algorithm=sha256&digits=8&period=60",
            &placeholders(),
        );
        assert!(result.is_valid());
        assert_eq!(result.issuer, "GitHub");
        assert_eq!(result.account, "alex@example.com");
        assert_eq!(result.secret, "MZXW6YTBOI");
        assert_eq!(result.algorithm, TotpAlgorithm::Sha256);
        assert_eq!((result.digits, result.period), (8, 60));
    }

    #[test]
    fn plus_in_issuer_is_not_a_space() {
        let result = parse("otpauth://totp/A+B:me?secret=MZXW6YTBOI&issuer=A+B", &placeholders());
        assert_eq!(result.issuer, "A+B");
    }

    #[test]
    fn rejects_invalid_inputs() {
        let cases = [
            ("", ParseFailure::BadUrl),
            ("hello", ParseFailure::NotOtpauth),
            ("https://example.com", ParseFailure::NotOtpauth),
            ("otpauth://hotp/x?secret=MZXW6YTBOI", ParseFailure::NotTotp),
            ("otpauth://totp/x", ParseFailure::MissingSecret),
            ("otpauth://totp/x?secret=1111", ParseFailure::BadBase32),
            ("otpauth://totp/x?secret=MZXW6YTBOI&digits=7", ParseFailure::Digits),
            ("otpauth://totp/x?secret=MZXW6YTBOI&period=0", ParseFailure::Period),
        ];
        for (line, failure) in cases {
            assert_eq!(parse(line, &placeholders()).failure, Some(failure), "{line}");
        }
    }

    #[test]
    fn parses_google_migration_batch() {
        let url = migration_url(
            &[(b"foobar", "GitHub:alex", "GitHub", 1, 1, 2), (b"foobar", "hotp", "X", 1, 1, 1), (b"foobar", "md5", "Y", 4, 1, 2)],
            Some((2, 1, 7)),
        );
        let result = parse_scan_result(&url, &placeholders());
        assert!(result.is_google_migration);
        assert_eq!(result.batch_key().as_deref(), Some("7-2-1"));
        assert_eq!(result.accounts.len(), 3);
        assert_eq!(result.accounts[0].account, "alex");
        assert_eq!(result.accounts[1].failure, Some(ParseFailure::NotTotp));
        assert_eq!(result.accounts[2].failure, Some(ParseFailure::UnsupportedAlgorithm));
    }

    #[test]
    fn parse_lines_expands_every_line() {
        let text = "otpauth://totp/A:a?secret=MZXW6YTBOI\n\r\notpauth://totp/B:b?secret=MZXW6YTBOI\n";
        let parsed = parse_lines(text, &placeholders());
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[1].issuer, "B");
    }
}
