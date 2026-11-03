//! Master password strength hints, acceptance rules for master and export passwords, and the wait policy after repeated
//! failed attempts.

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PasswordStrength {
    Empty = 0,
    Weak = 1,
    Fair = 2,
    Good = 3,
    Strong = 4,
}

/// Master password strength uses zxcvbn as the only standard: it scores 0-4 by roughly how many guesses are needed and
/// recognizes common passwords, English words, keyboard patterns, sequences, dates, repeats, and l33t substitutions.
/// 0 and 1 are `Weak` (within about 10^6 guesses), 2 is `Fair`, 3 is `Good`, and 4 is `Strong` (about 10^10 guesses or
/// more). Fewer than [`MIN_PASSWORD_LENGTH`] characters or a disallowed character fails the input requirements and is
/// `Weak` outright. The product name counts as a user-related word, so passwords like `Kakey2026!` are treated as easy
/// to guess; zxcvbn only looks at the first 100 characters.
pub fn evaluate(password: &str) -> PasswordStrength {
    if password.is_empty() {
        return PasswordStrength::Empty;
    }
    if password.chars().count() < MIN_PASSWORD_LENGTH || !password.chars().all(is_allowed_password_char) {
        return PasswordStrength::Weak;
    }
    match u8::from(zxcvbn::zxcvbn(password, &["kakey"]).score()) {
        0 | 1 => PasswordStrength::Weak,
        2 => PasswordStrength::Fair,
        3 => PasswordStrength::Good,
        _ => PasswordStrength::Strong,
    }
}

/// Characters allowed in master and export passwords: digits, English letters, and ASCII symbols (0x21-0x7E, no space).
/// The fields for setting a new master password and an export password filter by this; passwords typed to unlock or
/// import are not filtered (existing passwords keep working).
pub fn is_allowed_password_char(c: char) -> bool {
    c.is_ascii_graphic()
}

/// Removes disallowed characters and truncates to [`MAX_PASSWORD_LENGTH`] characters, for filtering input fields (pasted
/// full-width characters, CJK text, emoji, and so on are removed too).
pub fn filter_password_input(input: &str) -> String {
    input.chars().filter(|&c| is_allowed_password_char(c)).take(MAX_PASSWORD_LENGTH).collect()
}

/// Minimum characters in master and export passwords (counted in Unicode scalar values). The "8" in UI text matches this.
pub const MIN_PASSWORD_LENGTH: usize = 8;

/// Maximum characters when setting a new master password or an export password. The KDF does not care about length; the
/// cap only stops a whole block of text from being pasted in as a password that can never be typed again. Passwords
/// typed to unlock or import have no length limit, so existing passwords keep working.
pub const MAX_PASSWORD_LENGTH: usize = 128;

fn within_length(password: &str) -> bool {
    let count = password.chars().count();
    !password.trim().is_empty() && (MIN_PASSWORD_LENGTH..=MAX_PASSWORD_LENGTH).contains(&count)
}

/// Acceptable when creating a vault or changing the master password: [`MIN_PASSWORD_LENGTH`] to [`MAX_PASSWORD_LENGTH`]
/// allowed characters with strength of at least `Fair`. Rationale: backups sit in cloud storage and in export files,
/// so anyone holding a file can brute-force it offline, where the wait after failed attempts does not help; `Weak`
/// falls within about 10^6 guesses, minutes on a single GPU. `Fair` is still allowed, and the UI asks the user to confirm
/// before submitting.
pub fn is_acceptable_master_password(password: &str) -> bool {
    within_length(password) && password.chars().all(is_allowed_password_char) && evaluate(password) >= PasswordStrength::Fair
}

/// Acceptable for an encrypted export: the same rule as the master password. Export files are the easiest to forward or
/// copy and face the same offline brute force; for `Fair`, the UI warns about the risk before exporting.
pub fn is_acceptable_export_password(password: &str) -> bool {
    is_acceptable_master_password(password)
}

pub const FREE_ATTEMPTS: u32 = 5;
pub const BASE_DELAY_SECONDS: f64 = 30.0;
pub const MAX_DELAY_SECONDS: f64 = 300.0;

/// Starting at 5 consecutive failures, wait 30 seconds, doubling with each further failure up to 5 minutes; returns `None`
/// when no wait is needed.
pub fn lockout_seconds(consecutive_failures: u32) -> Option<f64> {
    if consecutive_failures < FREE_ATTEMPTS {
        return None;
    }
    let exponent = (consecutive_failures - FREE_ATTEMPTS).min(8);
    Some((BASE_DELAY_SECONDS * 2f64.powi(exponent as i32)).min(MAX_DELAY_SECONDS))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scores_passwords() {
        assert_eq!(evaluate(""), PasswordStrength::Empty);
        // Input requirements: fewer than 8 characters, disallowed characters
        assert_eq!(evaluate("Ab1!xY"), PasswordStrength::Weak);
        assert_eq!(evaluate("密码密码密码密码"), PasswordStrength::Weak);
        assert_eq!(evaluate("pässwörd1234"), PasswordStrength::Weak);
        // Easy to guess: common passwords, keyboard patterns, sequences, repeats, digits only
        for weak in ["Password1!", "Qwerty123!@#", "abcd1234efgh", "aaaabbbb", "333333222", "abcdabcd", "12345678"] {
            assert_eq!(evaluate(weak), PasswordStrength::Weak, "{weak}");
        }
        assert!(evaluate("Kakey2026!") <= PasswordStrength::Fair, "product name plus year");
        // Hard to guess: random strings and long phrases
        assert!(evaluate("q7#Lm2$Vx9") >= PasswordStrength::Good);
        assert_eq!(evaluate("vT8#qL2!mZ5@"), PasswordStrength::Strong);
        assert_eq!(evaluate("correcthorsebatterystaple"), PasswordStrength::Strong);
    }

    #[test]
    fn filters_password_input() {
        assert_eq!(filter_password_input("Ab1!~"), "Ab1!~");
        assert_eq!(filter_password_input("Ab 1"), "Ab1", "spaces are removed");
        assert_eq!(filter_password_input("密码abc１２３！"), "abc", "CJK and full-width characters are removed");
        assert_eq!(filter_password_input("a\tb\nc😀"), "abc", "control characters and emoji are removed");
        assert!((0x21u8..=0x7e).all(|b| is_allowed_password_char(char::from(b))));
        assert!(!is_allowed_password_char(' '));
        assert!(!is_allowed_password_char('\u{7f}'));
        assert_eq!(filter_password_input(&"a".repeat(129)), "a".repeat(128), "truncated to 128 characters");
        assert_eq!(
            filter_password_input(&format!("{} {}", "b".repeat(127), "cd")),
            format!("{}c", "b".repeat(127)),
            "filter first, then truncate"
        );
    }

    #[test]
    fn accepts_master_and_export_passwords() {
        assert!(!is_acceptable_master_password("12345678"), "weak passwords are rejected");
        assert!(!is_acceptable_master_password("aaaaaaaa"));
        assert!(!is_acceptable_master_password("Password1!"), "common passwords are weak");
        assert_eq!(evaluate("Abcdefgh1"), PasswordStrength::Good);
        assert!(is_acceptable_master_password("Abcdefgh1"));
        assert!(!is_acceptable_master_password("Abc1!"), "fewer than 8 characters");
        assert!(!is_acceptable_master_password("        "), "all whitespace");
        assert!(!is_acceptable_master_password("密码密码密码密码"), "contains disallowed characters");
        let long = "kx7Qm2vR".repeat(16);
        assert!(is_acceptable_master_password(&long), "128 characters is the maximum");
        assert!(!is_acceptable_master_password(&format!("{long}k")), "more than 128 characters");
        assert!(!is_acceptable_export_password(&format!("{long}k")), "export passwords have the same length cap");
        assert!(!is_acceptable_export_password("aaaaaaaa"), "export passwords have the same strength requirement as master passwords");
        assert!(!is_acceptable_export_password("12345678"));
        assert!(is_acceptable_export_password("Abcdefgh1"));
        assert!(!is_acceptable_export_password("aaaaaaa"));
        assert!(!is_acceptable_export_password(" \t      "));
        assert!(!is_acceptable_export_password("密码密码密码密码"), "same character restrictions as master passwords");
        assert!(!is_acceptable_export_password("abcd efgh"), "spaces are not allowed");
    }

    #[test]
    fn throttles_after_five_failures() {
        assert_eq!(lockout_seconds(4), None);
        assert_eq!(lockout_seconds(5), Some(30.0));
        assert_eq!(lockout_seconds(6), Some(60.0));
        assert_eq!(lockout_seconds(8), Some(240.0));
        assert_eq!(lockout_seconds(9), Some(300.0));
        assert_eq!(lockout_seconds(100), Some(300.0));
    }
}
