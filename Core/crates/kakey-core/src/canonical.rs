//! Account field standardization: cleans whitespace and percent-encoding, normalizes Base32 secrets, strips redundant
//! `issuer:` prefixes, and builds standard otpauth URIs. Adding, importing, and QR code export all share these rules
//! (see docs/SECURITY.md).

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};

use crate::base32;
use crate::model::{Account, Placeholders, TotpAlgorithm, redacted_secret};

/// Strict percent-decoding: returns `None` on an incomplete `%XX` or when the result is not valid UTF-8 (matching
/// Foundation's `removingPercentEncoding`; the `percent-encoding` crate passes invalid sequences through unchanged).
fn strict_percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = bytes.get(index + 1).and_then(|b| (*b as char).to_digit(16))?;
            let low = bytes.get(index + 2).and_then(|b| (*b as char).to_digit(16))?;
            output.push((high * 16 + low) as u8);
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output).ok()
}

/// Decodes at most two layers of percent-encoding, removes every `\r` `\n` `\t`, then trims surrounding whitespace.
pub fn clean_text(value: &str) -> String {
    let mut current = value.to_owned();
    for _ in 0..2 {
        match strict_percent_decode(&current) {
            Some(decoded) if decoded != current => current = decoded,
            _ => break,
        }
    }
    current.chars().filter(|c| !matches!(c, '\r' | '\n' | '\t')).collect::<String>().trim().to_owned()
}

pub fn normalized_issuer(value: &str, placeholders: &Placeholders) -> String {
    let clean = clean_text(value);
    if clean.is_empty() { placeholders.unknown_issuer.clone() } else { clean }
}

pub fn normalized_username(value: &str, placeholders: &Placeholders) -> String {
    let clean = clean_text(value);
    if clean.is_empty() { placeholders.empty_username.clone() } else { clean }
}

/// Strips a redundant `issuer:` prefix from the username (case-insensitive, and something must follow the prefix).
pub fn stripping_issuer_prefix(username: &str, issuer: &str) -> String {
    let clean_issuer = clean_text(issuer);
    let clean_username = clean_text(username);
    if clean_issuer.is_empty() {
        return clean_username;
    }
    let prefix = format!("{clean_issuer}:");
    let prefix_length = prefix.chars().count();
    if clean_username.chars().count() <= prefix_length || !clean_username.to_lowercase().starts_with(&prefix.to_lowercase()) {
        return clean_username;
    }
    clean_text(&clean_username.chars().skip(prefix_length).collect::<String>())
}

/// Cleans, decodes as Base32, and re-encodes as uppercase without separators; returns `None` if it cannot be decoded or
/// decodes to empty bytes.
pub fn standardized_secret(value: &str) -> Option<String> {
    let data = base32::decode(&clean_text(value))?;
    if data.is_empty() {
        return None;
    }
    Some(base32::encode(&data))
}

#[derive(Clone, PartialEq, Eq)]
pub struct Fields {
    pub issuer: String,
    pub username: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
}

impl std::fmt::Debug for Fields {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Fields")
            .field("issuer", &self.issuer)
            .field("username", &self.username)
            .field("secret", &redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .finish()
    }
}

/// Standardization applied before saving; returns `None` when digits is not 6 / 8 or the secret is invalid.
pub fn fields(
    issuer: &str,
    username: &str,
    secret: &str,
    algorithm: TotpAlgorithm,
    digits: u32,
    period: u32,
    placeholders: &Placeholders,
) -> Option<Fields> {
    if digits != 6 && digits != 8 {
        return None;
    }
    let secret = standardized_secret(secret)?;
    Some(Fields {
        issuer: normalized_issuer(issuer, placeholders),
        username: normalized_username(&stripping_issuer_prefix(username, issuer), placeholders),
        secret,
        algorithm,
        digits,
        period: period.max(1),
    })
}

/// Each label segment keeps only RFC 3986 unreserved characters (exactly what Foundation's `urlPathAllowed` leaves after
/// removing `:/?#[]@!$&'()*+,;=`).
const LABEL_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');

/// How `URLComponents.queryItems` encodes values: characters allowed in a query are kept, but characters that would
/// break the structure, such as `&` `=` `+` `#`, must be encoded. The exact set is pinned by the otpauth URI cases in
/// `golden/canonical.json`.
const QUERY_VALUE_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~')
    .remove(b'!')
    .remove(b'$')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')')
    .remove(b'*')
    .remove(b'+')
    .remove(b',')
    .remove(b';')
    .remove(b':')
    .remove(b'@')
    .remove(b'/')
    .remove(b'?');

/// Standard otpauth URI for single-account QR code export.
pub fn otpauth_url(account: &Account, placeholders: &Placeholders) -> String {
    let fields =
        fields(&account.issuer, &account.username, &account.secret, account.algorithm, account.digits, account.period, placeholders)
            .unwrap_or_else(|| Fields {
                issuer: normalized_issuer(&account.issuer, placeholders),
                username: normalized_username(&account.username, placeholders),
                secret: clean_text(&account.secret).to_uppercase(),
                algorithm: account.algorithm,
                digits: account.digits,
                period: account.period.max(1),
            });

    let label =
        format!("{}:{}", utf8_percent_encode(&fields.issuer, LABEL_ENCODE_SET), utf8_percent_encode(&fields.username, LABEL_ENCODE_SET));
    let query = |value: &str| utf8_percent_encode(value, QUERY_VALUE_ENCODE_SET).to_string();
    format!(
        "otpauth://totp/{label}?secret={}&issuer={}&algorithm={}&digits={}&period={}",
        query(&fields.secret),
        query(&fields.issuer),
        fields.algorithm.raw_value(),
        fields.digits,
        fields.period
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn placeholders() -> Placeholders {
        Placeholders { unknown_issuer: "Unknown service".into(), empty_username: "No account".into() }
    }

    #[test]
    fn clean_text_decodes_twice_and_trims() {
        assert_eq!(clean_text(" GitHub%20Inc%0A "), "GitHub Inc");
        assert_eq!(clean_text("a%2520b"), "a b");
        assert_eq!(clean_text("a%252520b"), "a%20b");
        assert_eq!(clean_text("100%"), "100%");
        assert_eq!(clean_text("\tx\ry\n"), "xy");
    }

    #[test]
    fn strips_redundant_issuer_prefix() {
        assert_eq!(stripping_issuer_prefix("GitHub:alex@example.com", "github"), "alex@example.com");
        assert_eq!(stripping_issuer_prefix("GitHub%3Aalex", "GitHub"), "alex");
        assert_eq!(stripping_issuer_prefix("GitHub:", "GitHub"), "GitHub:");
        assert_eq!(stripping_issuer_prefix("alex", ""), "alex");
    }

    #[test]
    fn fields_standardize_and_validate() {
        let result = fields(" ", "", "mzxw 6ytb-oi", TotpAlgorithm::Sha1, 6, 0, &placeholders()).unwrap();
        assert_eq!(result.issuer, "Unknown service");
        assert_eq!(result.username, "No account");
        assert_eq!(result.secret, "MZXW6YTBOI");
        assert_eq!(result.period, 1);
        assert!(fields("a", "b", "MZXW6YTBOI", TotpAlgorithm::Sha1, 7, 30, &placeholders()).is_none());
        assert!(fields("a", "b", "A", TotpAlgorithm::Sha1, 6, 30, &placeholders()).is_none());
    }
}
