//! List search, account name masking, monogram badges, and badge colors.

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// Insensitive to case, diacritics, and full-/half-width forms, keeping only letters and digits (equivalent to
/// Foundation's `folding([.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`). Case uses full Unicode case
/// folding (`ß` -> `ss`), matching Foundation; `to_lowercase` cannot do that.
pub fn normalized_search_text(value: &str) -> String {
    let stripped: String = value.nfkd().filter(|c| !is_combining_mark(*c)).collect();
    caseless::default_case_fold_str(&stripped).chars().flat_map(char::to_lowercase).filter(|c| c.is_alphanumeric()).collect()
}

/// Substring or in-order fuzzy match; an empty query matches every account. Only the issuer and account name are matched.
pub fn matches_search(issuer: &str, username: &str, query: &str) -> bool {
    let query = normalized_search_text(query);
    if query.is_empty() {
        return true;
    }
    [issuer, username].iter().any(|value| {
        let value = normalized_search_text(value);
        value.contains(&query) || fuzzy_contains(&value, &query)
    })
}

fn fuzzy_contains(value: &str, query: &str) -> bool {
    let mut remaining = value.chars();
    query.chars().all(|wanted| remaining.any(|c| c == wanted))
}

/// Masking for display: emails keep the first 1-2 characters of the local part and the full domain; all-digit names of 7
/// or more digits keep the first 3 and last 2; anything else keeps the first 1-2 characters.
pub fn mask_username(username: &str) -> String {
    if username.is_empty() {
        return String::new();
    }
    let characters: Vec<char> = username.chars().collect();
    if let Some(at) = characters.iter().position(|c| *c == '@') {
        let local = &characters[..at];
        let domain: String = characters[at + 1..].iter().collect();
        let visible: String = local.iter().take(2).collect();
        return format!("{visible}***@{domain}");
    }
    if characters.len() >= 7 && characters.iter().all(|c| c.is_numeric()) {
        let prefix: String = characters[..3].iter().collect();
        let suffix: String = characters[characters.len() - 2..].iter().collect();
        return format!("{prefix}****{suffix}");
    }
    let visible: String = characters.iter().take(2).collect();
    if characters.len() <= 2 { username.to_owned() } else { format!("{visible}***") }
}

/// Initials of the first two words when there are several words, otherwise the first 3 characters; always uppercase.
pub fn monogram(issuer: &str) -> String {
    let words: Vec<&str> = issuer.split(' ').filter(|word| !word.is_empty()).collect();
    if words.len() > 1 {
        return words.iter().take(2).filter_map(|word| word.chars().next()).collect::<String>().to_uppercase();
    }
    issuer.chars().take(3).collect::<String>().to_uppercase()
}

/// Badge color index (0..8); each platform maps it to its own palette in the same order:
/// blue, purple, orange, green, indigo, pink, teal, brown. FNV-1a keeps a given issuer stable across launches and devices.
pub fn palette_index(issuer: &str) -> u32 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in issuer.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    (hash % 8) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_is_case_diacritic_and_width_insensitive() {
        assert!(matches_search("Café Übersicht", "", "cafe"));
        assert!(matches_search("ＧｉｔＨｕｂ", "", "github"));
        assert!(matches_search("GitHub", "alex@example.com", "ALEX EXAMPLE"));
        assert!(matches_search("Google", "", "ggl"));
        assert!(!matches_search("Google", "", "lgg"));
        assert!(matches_search("x", "y", " "));
    }

    #[test]
    fn masks_usernames() {
        assert_eq!(mask_username("alex@example.com"), "al***@example.com");
        assert_eq!(mask_username("k@x.io"), "k***@x.io");
        assert_eq!(mask_username("13800138000"), "138****00");
        assert_eq!(mask_username("alex"), "al***");
        assert_eq!(mask_username("ka"), "ka");
    }

    #[test]
    fn monograms_and_palette() {
        assert_eq!(monogram("Google Cloud Platform"), "GC");
        assert_eq!(monogram("github"), "GIT");
        assert_eq!(monogram("X"), "X");
        assert!(palette_index("GitHub") < 8);
        assert_eq!(palette_index("GitHub"), palette_index("GitHub"));
    }
}
