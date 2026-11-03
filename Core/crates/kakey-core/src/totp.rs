//! RFC 6238 TOTP. HMAC uses RustCrypto `hmac` + `sha1` / `sha2`.

use std::time::{SystemTime, UNIX_EPOCH};

use hmac::{Hmac, KeyInit, Mac};

use crate::base32;
use crate::model::{Account, TotpAlgorithm};

/// The HOTP truncated value has only 31 bits, so at most 10 decimal digits. The digit count comes from files or callers;
/// anything larger is treated as 10 so an abnormal value cannot turn the zero-padding width and placeholder length into
/// a huge allocation (real accounts use 6 or 8 digits).
const MAX_DIGITS: u32 = 10;

/// Placeholder shown when the secret cannot be decoded (matches Mac: at least 6 dashes).
fn placeholder(digits: u32) -> String {
    "—".repeat(digits.max(6) as usize)
}

fn unix_seconds(date: SystemTime) -> f64 {
    match date.duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs_f64(),
        Err(error) => -error.duration().as_secs_f64(),
    }
}

pub fn code(secret: &str, algorithm: TotpAlgorithm, digits: u32, period: u32, date: SystemTime) -> String {
    let digits = digits.min(MAX_DIGITS);
    let period = period.max(1);
    let Some(key) = base32::decode(secret) else {
        return placeholder(digits);
    };
    let counter = (unix_seconds(date) / f64::from(period)).floor().max(0.0) as u64;
    let value = hotp(&key, counter, algorithm);
    let modulus = 10u64.pow(digits);
    format!("{:0width$}", u64::from(value) % modulus, width = digits as usize)
}

pub fn account_code(account: &Account, date: SystemTime) -> String {
    code(&account.secret, account.algorithm, account.digits, account.period, date)
}

/// Inserts a space in the middle when longer than 4 digits (`123 456`, `1234 5678`).
pub fn formatted(code: &str) -> String {
    let characters: Vec<char> = code.chars().collect();
    if characters.len() <= 4 {
        return code.to_owned();
    }
    let split = characters.len() / 2;
    let (left, right) = characters.split_at(split);
    format!("{} {}", left.iter().collect::<String>(), right.iter().collect::<String>())
}

pub fn seconds_remaining(period: u32, date: SystemTime) -> u32 {
    let period = i64::from(period.max(1));
    let now = unix_seconds(date).trunc() as i64;
    (period - now.rem_euclid(period)) as u32
}

pub fn progress(period: u32, date: SystemTime) -> f64 {
    f64::from(seconds_remaining(period, date)) / f64::from(period.max(1))
}

pub fn is_valid_secret(secret: &str) -> bool {
    base32::decode(secret).is_some()
}

fn hotp(key: &[u8], counter: u64, algorithm: TotpAlgorithm) -> u32 {
    let message = counter.to_be_bytes();
    let digest: Vec<u8> = match algorithm {
        TotpAlgorithm::Sha1 => mac::<Hmac<sha1::Sha1>>(key, &message),
        TotpAlgorithm::Sha256 => mac::<Hmac<sha2::Sha256>>(key, &message),
        TotpAlgorithm::Sha512 => mac::<Hmac<sha2::Sha512>>(key, &message),
    };
    let offset = usize::from(digest.last().copied().unwrap_or(0) & 0x0f);
    if offset + 3 >= digest.len() {
        return 0;
    }
    (u32::from(digest[offset]) & 0x7f) << 24
        | u32::from(digest[offset + 1]) << 16
        | u32::from(digest[offset + 2]) << 8
        | u32::from(digest[offset + 3])
}

fn mac<M: Mac + KeyInit>(key: &[u8], message: &[u8]) -> Vec<u8> {
    let mut mac = <M as KeyInit>::new_from_slice(key).expect("HMAC accepts keys of any length");
    mac.update(message);
    mac.finalize().into_bytes().to_vec()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    /// RFC 6238 Appendix B (separate ASCII seeds for SHA1 / SHA256 / SHA512).
    #[test]
    fn rfc6238_vectors() {
        let sha1 = base32::encode(b"12345678901234567890");
        let sha256 = base32::encode(b"12345678901234567890123456789012");
        let sha512 = base32::encode(b"1234567890123456789012345678901234567890123456789012345678901234");
        let cases = [
            (59, "94287082", "46119246", "90693936"),
            (1_111_111_109, "07081804", "68084774", "25091201"),
            (1_111_111_111, "14050471", "67062674", "99943326"),
            (1_234_567_890, "89005924", "91819424", "93441116"),
            (2_000_000_000, "69279037", "90698825", "38618901"),
            (20_000_000_000, "65353130", "77737706", "47863826"),
        ];
        for (time, expected1, expected256, expected512) in cases {
            assert_eq!(code(&sha1, TotpAlgorithm::Sha1, 8, 30, at(time)), expected1);
            assert_eq!(code(&sha256, TotpAlgorithm::Sha256, 8, 30, at(time)), expected256);
            assert_eq!(code(&sha512, TotpAlgorithm::Sha512, 8, 30, at(time)), expected512);
        }
    }

    #[test]
    fn invalid_secret_shows_placeholder() {
        assert_eq!(code("not base32!", TotpAlgorithm::Sha1, 6, 30, at(0)), "——————");
        assert_eq!(code("1", TotpAlgorithm::Sha1, 8, 30, at(0)), "————————");
    }

    #[test]
    fn oversized_digits_are_capped() {
        let secret = base32::encode(b"12345678901234567890");
        assert_eq!(code(&secret, TotpAlgorithm::Sha1, u32::MAX, 30, at(59)).len(), 10);
        assert_eq!(code("bad!", TotpAlgorithm::Sha1, u32::MAX, 30, at(59)).chars().count(), 10);
    }

    #[test]
    fn formatting_and_countdown() {
        assert_eq!(formatted("123456"), "123 456");
        assert_eq!(formatted("12345678"), "1234 5678");
        assert_eq!(formatted("1234"), "1234");
        assert_eq!(seconds_remaining(30, at(59)), 1);
        assert_eq!(seconds_remaining(30, at(60)), 30);
        assert!((progress(30, at(45)) - 0.5).abs() < f64::EPSILON);
    }
}
