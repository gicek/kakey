//! Deduplication and the single insertion path shared by manual add, QR codes, text import, and encrypted import.

use std::collections::HashSet;
use std::time::SystemTime;

use uuid::Uuid;

use crate::canonical::{self, clean_text, standardized_secret};
use crate::category::{self, Category};
use crate::model::{Account, Placeholders, TotpAlgorithm, redacted_secret};
use crate::vault::{self, VaultContents, VaultError};

/// Two accounts are duplicates when issuer, username (both case-insensitive), normalized secret, algorithm, digits, and
/// period all match.
pub fn deduplication_key(
    issuer: &str,
    username: &str,
    secret: &str,
    algorithm: TotpAlgorithm,
    digits: u32,
    period: u32,
    placeholders: &Placeholders,
) -> String {
    let issuer = canonical::normalized_issuer(issuer, placeholders).to_lowercase();
    let username = canonical::normalized_username(username, placeholders).to_lowercase();
    let secret = standardized_secret(secret).unwrap_or_else(|| clean_text(secret).to_uppercase());
    [issuer, username, secret, algorithm.raw_value().to_owned(), digits.to_string(), period.to_string()].join("|")
}

pub fn account_deduplication_key(account: &Account, placeholders: &Placeholders) -> String {
    deduplication_key(&account.issuer, &account.username, &account.secret, account.algorithm, account.digits, account.period, placeholders)
}

/// Account fields to insert (not yet standardized).
#[derive(Clone, PartialEq, Eq)]
pub struct Candidate {
    pub issuer: String,
    pub username: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
    /// Categories to add the account to once inserted (matched by name case-insensitively, created if missing). A
    /// candidate skipped as a duplicate changes no category.
    pub category_names: Vec<String>,
    /// `None` means the insertion time.
    pub created_at: Option<SystemTime>,
}

impl std::fmt::Debug for Candidate {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Candidate")
            .field("issuer", &self.issuer)
            .field("username", &self.username)
            .field("secret", &redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .field("category_names", &self.category_names)
            .field("created_at", &self.created_at)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InsertResult {
    /// The full account list after insertion: new accounts come first, in candidate order (the first candidate ends up
    /// first), followed by the existing accounts.
    pub accounts: Vec<Account>,
    /// Categories after insertion: new accounts are appended to the end of their categories.
    pub categories: Vec<Category>,
    pub inserted_ids: Vec<Uuid>,
}

/// Standardizes candidates one by one, skipping invalid ones and duplicates (against existing accounts and within the
/// batch). Only fails with `CryptoFailure` when the system random number generator fails (for new account or category
/// IDs).
pub fn insert_accounts(
    existing: &[Account],
    categories: &[Category],
    candidates: &[Candidate],
    added_by: &str,
    now: SystemTime,
    placeholders: &Placeholders,
) -> Result<InsertResult, VaultError> {
    let mut keys: HashSet<String> = existing.iter().map(|account| account_deduplication_key(account, placeholders)).collect();
    let mut accounts = existing.to_vec();
    let mut categories = categories.to_vec();
    let mut inserted_ids = Vec::new();

    for candidate in candidates {
        let Some(fields) = canonical::fields(
            &candidate.issuer,
            &candidate.username,
            &candidate.secret,
            candidate.algorithm,
            candidate.digits,
            candidate.period,
            placeholders,
        ) else {
            continue;
        };
        let key = deduplication_key(
            &fields.issuer,
            &fields.username,
            &fields.secret,
            fields.algorithm,
            fields.digits,
            fields.period,
            placeholders,
        );
        if !keys.insert(key) {
            continue;
        }
        let account = Account {
            id: vault::random_uuid()?,
            issuer: fields.issuer,
            username: fields.username,
            secret: fields.secret,
            algorithm: fields.algorithm,
            digits: fields.digits,
            period: fields.period,
            created_at: candidate.created_at.unwrap_or(now),
            added_by: added_by.to_owned(),
        };
        for name in &candidate.category_names {
            categories = category::adding_to_named(&categories, name, &[account.id], vault::random_uuid)?;
        }
        // New accounts go first, in the order of the batch: importing an export file keeps the order it was exported in.
        let id = account.id;
        accounts.insert(inserted_ids.len(), account);
        inserted_ids.push(id);
    }

    Ok(InsertResult { accounts, categories, inserted_ids })
}

/// Turns contents read from an import file (Authenticator backups have already gone through
/// [`VaultContents::adopting_pinned`]) into insertion candidates: each account carries the names of the categories it
/// belongs to in the import file and keeps its original creation time.
pub fn candidates_from_import(imported: &VaultContents) -> Vec<Candidate> {
    imported
        .accounts
        .iter()
        .map(|account| Candidate {
            issuer: account.issuer.clone(),
            username: account.username.clone(),
            secret: account.secret.clone(),
            algorithm: account.algorithm,
            digits: account.digits,
            period: account.period,
            category_names: imported
                .categories
                .iter()
                .filter(|category| category.account_ids.contains(&account.id))
                .map(|category| category.name.clone())
                .collect(),
            created_at: Some(account.created_at),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::otpauth::tests::placeholders;

    fn candidate(issuer: &str, username: &str, secret: &str) -> Candidate {
        Candidate {
            issuer: issuer.into(),
            username: username.into(),
            secret: secret.into(),
            algorithm: TotpAlgorithm::Sha1,
            digits: 6,
            period: 30,
            category_names: vec![],
            created_at: None,
        }
    }

    #[test]
    fn dedup_key_ignores_case_and_secret_formatting() {
        let p = placeholders();
        assert_eq!(
            deduplication_key("GitHub", "Alex", "mzxw 6ytb-oi", TotpAlgorithm::Sha1, 6, 30, &p),
            deduplication_key(" github ", "alex", "MZXW6YTBOI", TotpAlgorithm::Sha1, 6, 30, &p)
        );
        assert_eq!(deduplication_key("", "", "x!", TotpAlgorithm::Sha1, 6, 30, &p), "unknown service|no account|X!|SHA1|6|30");
    }

    #[test]
    fn inserts_new_accounts_first_and_skips_duplicates() {
        let p = placeholders();
        let first = insert_accounts(&[], &[], &[candidate("A", "a", "MZXW6YTBOI")], "manual", SystemTime::UNIX_EPOCH, &p).unwrap();
        let existing_category = Category { id: Uuid::from_u128(1), name: "Work".into(), account_ids: vec![first.accounts[0].id] };
        let mut categorized = candidate("B", "b", "MZXW6YTBOI");
        categorized.category_names = vec!["work".into(), "常用".into()];
        let mut duplicate = candidate("a", "A", "mzxw6ytboi");
        duplicate.category_names = vec!["常用".into()];
        let second = insert_accounts(
            &first.accounts,
            &[existing_category],
            &[duplicate, categorized.clone(), categorized, candidate("C", "c", "bad!")],
            "import",
            SystemTime::UNIX_EPOCH,
            &p,
        )
        .unwrap();
        assert_eq!(second.inserted_ids.len(), 1);
        assert_eq!(second.accounts.len(), 2);
        let inserted = second.accounts[0].id;
        assert_eq!(second.accounts[0].issuer, "B");
        assert_eq!(second.accounts[0].added_by, "import");
        assert_eq!(second.categories[0].account_ids, vec![first.accounts[0].id, inserted], "merged into the existing category by name");
        assert_eq!(second.categories[1].name, "常用");
        assert_eq!(second.categories[1].account_ids, vec![inserted], "a candidate skipped as a duplicate changes no category");
    }

    /// A batch lands in front of the existing accounts in its own order (export -> import keeps the order), not reversed.
    #[test]
    fn a_batch_keeps_its_order_in_front_of_existing_accounts() {
        let p = placeholders();
        let existing = insert_accounts(&[], &[], &[candidate("Old", "o", "MZXW6YTBOI")], "manual", SystemTime::UNIX_EPOCH, &p).unwrap();
        let batch = [candidate("A", "a", "MZXW6YTBOI"), candidate("B", "b", "MZXW6YTBOI"), candidate("C", "c", "MZXW6YTBOI")];
        let result = insert_accounts(&existing.accounts, &[], &batch, "import", SystemTime::UNIX_EPOCH, &p).unwrap();
        let issuers: Vec<&str> = result.accounts.iter().map(|account| account.issuer.as_str()).collect();
        assert_eq!(issuers, ["A", "B", "C", "Old"]);
        assert_eq!(result.inserted_ids, result.accounts[..3].iter().map(|account| account.id).collect::<Vec<_>>());
    }

    #[test]
    fn candidates_carry_their_imported_category_names() {
        let account = |n: u128| Account {
            id: Uuid::from_u128(n),
            issuer: format!("S{n}"),
            username: "u".into(),
            secret: "MZXW6YTBOI".into(),
            algorithm: TotpAlgorithm::Sha1,
            digits: 6,
            period: 30,
            created_at: SystemTime::UNIX_EPOCH,
            added_by: "manual".into(),
        };
        let imported = VaultContents {
            accounts: vec![account(1), account(2)],
            categories: vec![
                Category { id: Uuid::from_u128(7), name: "A".into(), account_ids: vec![Uuid::from_u128(1)] },
                Category { id: Uuid::from_u128(8), name: "B".into(), account_ids: vec![Uuid::from_u128(1)] },
            ],
            pinned_ids: vec![],
        };
        let candidates = candidates_from_import(&imported);
        assert_eq!(candidates[0].category_names, vec!["A".to_owned(), "B".to_owned()]);
        assert!(candidates[1].category_names.is_empty());
        assert_eq!(candidates[0].created_at, Some(SystemTime::UNIX_EPOCH));
    }
}
