//! RFC 4648 Base32 (output without padding).
//!
//! Hand-written on purpose instead of using `data-encoding`: the Mac decoder accepts any length and drops trailing bits
//! that do not fill a byte (a single character decodes to an empty byte string, for example). Mature libraries reject
//! those lengths per the spec, and that mismatch would make the same secret valid on one platform and invalid on another.
//! The decoding semantics are pinned by `golden/base32.json`.

const ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn encode(data: &[u8]) -> String {
    let mut output = String::with_capacity(data.len().div_ceil(5) * 8);
    let mut buffer: u32 = 0;
    let mut bits_left = 0;
    for &byte in data {
        buffer = (buffer << 8) | u32::from(byte);
        bits_left += 8;
        while bits_left >= 5 {
            let index = (buffer >> (bits_left - 5)) & 0x1f;
            output.push(ALPHABET[index as usize] as char);
            bits_left -= 5;
        }
        buffer &= (1 << bits_left) - 1;
    }
    if bits_left > 0 {
        let index = (buffer << (5 - bits_left)) & 0x1f;
        output.push(ALPHABET[index as usize] as char);
    }
    output
}

/// Uppercases, then strips whitespace, `-`, and every `=`. Returns `None` if nothing is left or if any character is
/// outside the alphabet.
pub fn decode(value: &str) -> Option<Vec<u8>> {
    let cleaned: String = value.to_uppercase().chars().filter(|c| !c.is_whitespace() && *c != '-' && *c != '=').collect();
    if cleaned.is_empty() {
        return None;
    }
    let mut buffer: u32 = 0;
    let mut bits_left = 0;
    let mut bytes = Vec::with_capacity(cleaned.len() * 5 / 8);
    for character in cleaned.chars() {
        let value = ALPHABET.iter().position(|&symbol| symbol as char == character)? as u32;
        buffer = (buffer << 5) | value;
        bits_left += 5;
        if bits_left >= 8 {
            bytes.push(((buffer >> (bits_left - 8)) & 0xff) as u8);
            bits_left -= 8;
        }
        buffer &= (1 << bits_left) - 1;
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_rfc4648_vectors() {
        let vectors =
            [("", ""), ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"), ("foob", "MZXW6YQ"), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI")];
        for (plain, encoded) in vectors {
            assert_eq!(encode(plain.as_bytes()), encoded);
            if !encoded.is_empty() {
                assert_eq!(decode(encoded).unwrap(), plain.as_bytes());
            }
        }
    }

    #[test]
    fn decode_is_lenient_like_mac() {
        assert_eq!(decode("mzxw 6ytb-oi").unwrap(), b"foobar");
        assert_eq!(decode("MZXW6YTBOI======").unwrap(), b"foobar");
        assert_eq!(decode("A").unwrap(), Vec::<u8>::new());
        assert_eq!(decode("  -= "), None);
        assert_eq!(decode("MZXW1"), None);
    }
}
