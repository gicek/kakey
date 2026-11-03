//! Compares and merges two sets of vault contents on a sync conflict (see docs/TECHNICAL.md).
//!
//! Only decrypted contents in memory are compared; the platform shows the differences and merges according to the user's
//! choices. Pairing rules:
//! - Accounts pair by ID first, then the rest by dedup key ([`crate::dedup::account_deduplication_key`]), so the same
//!   account added separately on two devices is not a difference.
//! - Categories pair by ID, then by name (ignoring case and surrounding whitespace).
//!
//! Differences in order alone do not count. A merge keeps every account from both sides, and for accounts changed on
//! both sides the caller picks which version to keep, one by one. There are no deletion records, so an account deleted on
//! one side comes back.

use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use crate::canonical::standardized_secret;
use crate::category::Category;
use crate::dedup::account_deduplication_key;
use crate::model::{Account, Placeholders};
use crate::vault::VaultContents;

/// Ways the same account differs between the two sides (possibly several).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AccountChange {
    /// Issuer.
    Issuer,
    Username,
    /// Different secrets (the UI only says the secret differs and never shows the value).
    Secret,
    /// Algorithm, digits, or period.
    Parameters,
    /// Category membership (compared by category name).
    Categories,
}

/// An account that was paired but differs between the two sides.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChangedAccount {
    pub local: Account,
    pub remote: Account,
    pub changes: Vec<AccountChange>,
}

/// Differences between two sets of contents; accounts are in the order of the side they come from.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VaultDiff {
    pub only_local: Vec<Account>,
    pub only_remote: Vec<Account>,
    pub changed: Vec<ChangedAccount>,
    /// Category names that exist on only one side.
    pub categories_only_local: Vec<String>,
    pub categories_only_remote: Vec<String>,
    /// The same category (same ID) named differently on each side: (local, backup).
    pub categories_renamed: Vec<(String, String)>,
}

impl VaultDiff {
    pub fn is_empty(&self) -> bool {
        self.only_local.is_empty()
            && self.only_remote.is_empty()
            && self.changed.is_empty()
            && self.categories_only_local.is_empty()
            && self.categories_only_remote.is_empty()
            && self.categories_renamed.is_empty()
    }
}

/// Account pairing: backup account ID -> local account ID.
fn pair_accounts(local: &VaultContents, remote: &VaultContents, placeholders: &Placeholders) -> HashMap<Uuid, Uuid> {
    let local_ids: HashSet<Uuid> = local.accounts.iter().map(|account| account.id).collect();
    let mut pairs: HashMap<Uuid, Uuid> =
        remote.accounts.iter().filter(|account| local_ids.contains(&account.id)).map(|account| (account.id, account.id)).collect();
    let paired_local: HashSet<Uuid> = pairs.values().copied().collect();
    let mut by_key: HashMap<String, Uuid> = HashMap::new();
    for account in local.accounts.iter().filter(|account| !paired_local.contains(&account.id)) {
        by_key.entry(account_deduplication_key(account, placeholders)).or_insert(account.id);
    }
    for account in remote.accounts.iter().filter(|account| !local_ids.contains(&account.id)) {
        if let Some(local_id) = by_key.remove(&account_deduplication_key(account, placeholders)) {
            pairs.insert(account.id, local_id);
        }
    }
    pairs
}

/// Category pairing: backup category ID -> local category ID.
fn pair_categories(local: &[Category], remote: &[Category]) -> HashMap<Uuid, Uuid> {
    let local_ids: HashSet<Uuid> = local.iter().map(|category| category.id).collect();
    let mut pairs: HashMap<Uuid, Uuid> =
        remote.iter().filter(|category| local_ids.contains(&category.id)).map(|category| (category.id, category.id)).collect();
    let paired_local: HashSet<Uuid> = pairs.values().copied().collect();
    let mut by_name: HashMap<String, Uuid> = local
        .iter()
        .filter(|category| !paired_local.contains(&category.id))
        .map(|category| (name_key(&category.name), category.id))
        .collect();
    for category in remote.iter().filter(|category| !local_ids.contains(&category.id)) {
        if let Some(local_id) = by_name.remove(&name_key(&category.name)) {
            pairs.insert(category.id, local_id);
        }
    }
    pairs
}

fn name_key(name: &str) -> String {
    name.trim().to_lowercase()
}

/// Case-insensitive set of names of the categories an account belongs to, used to compare membership across sides.
fn category_names_of(account_id: Uuid, categories: &[Category]) -> HashSet<String> {
    categories.iter().filter(|category| category.account_ids.contains(&account_id)).map(|category| name_key(&category.name)).collect()
}

fn changes_between(local: &Account, remote: &Account, local_categories: &[Category], remote_categories: &[Category]) -> Vec<AccountChange> {
    let mut changes = Vec::new();
    if local.issuer != remote.issuer {
        changes.push(AccountChange::Issuer);
    }
    if local.username != remote.username {
        changes.push(AccountChange::Username);
    }
    let secret = |account: &Account| standardized_secret(&account.secret).unwrap_or_else(|| account.secret.clone());
    if secret(local) != secret(remote) {
        changes.push(AccountChange::Secret);
    }
    if (local.algorithm, local.digits, local.period) != (remote.algorithm, remote.digits, remote.period) {
        changes.push(AccountChange::Parameters);
    }
    if category_names_of(local.id, local_categories) != category_names_of(remote.id, remote_categories) {
        changes.push(AccountChange::Categories);
    }
    changes
}

pub fn diff(local: &VaultContents, remote: &VaultContents, placeholders: &Placeholders) -> VaultDiff {
    let account_pairs = pair_accounts(local, remote, placeholders);
    let paired_local: HashSet<Uuid> = account_pairs.values().copied().collect();
    let remote_by_local: HashMap<Uuid, &Account> =
        remote.accounts.iter().filter_map(|account| account_pairs.get(&account.id).map(|local_id| (*local_id, account))).collect();

    let mut result = VaultDiff {
        only_local: local.accounts.iter().filter(|account| !paired_local.contains(&account.id)).cloned().collect(),
        only_remote: remote.accounts.iter().filter(|account| !account_pairs.contains_key(&account.id)).cloned().collect(),
        ..VaultDiff::default()
    };
    for local_account in &local.accounts {
        if let Some(remote_account) = remote_by_local.get(&local_account.id) {
            let changes = changes_between(local_account, remote_account, &local.categories, &remote.categories);
            if !changes.is_empty() {
                result.changed.push(ChangedAccount { local: local_account.clone(), remote: (*remote_account).clone(), changes });
            }
        }
    }

    let category_pairs = pair_categories(&local.categories, &remote.categories);
    let paired_local_categories: HashSet<Uuid> = category_pairs.values().copied().collect();
    result.categories_only_local = local
        .categories
        .iter()
        .filter(|category| !paired_local_categories.contains(&category.id))
        .map(|category| category.name.clone())
        .collect();
    result.categories_only_remote = remote
        .categories
        .iter()
        .filter(|category| !category_pairs.contains_key(&category.id))
        .map(|category| category.name.clone())
        .collect();
    for remote_category in &remote.categories {
        if let Some(local_category) =
            category_pairs.get(&remote_category.id).and_then(|local_id| local.categories.iter().find(|category| category.id == *local_id))
            && name_key(&local_category.name) != name_key(&remote_category.name)
        {
            result.categories_renamed.push((local_category.name.clone(), remote_category.name.clone()));
        }
    }
    result
}

/// Merges two sets of contents. `prefer_remote` holds the accounts changed on both sides for which the backup version wins
/// (as local account IDs); all others keep the local version.
///
/// Accounts: the local order comes first (accounts taking the backup version get its fields but keep the local ID), and
/// accounts only in the backup follow in backup order.
/// Categories: merged by pairing, using the local name; members are the union (local order first), and categories only in
/// the backup follow.
pub fn merge(local: &VaultContents, remote: &VaultContents, prefer_remote: &HashSet<Uuid>, placeholders: &Placeholders) -> VaultContents {
    let account_pairs = pair_accounts(local, remote, placeholders);
    let remote_by_local: HashMap<Uuid, &Account> =
        remote.accounts.iter().filter_map(|account| account_pairs.get(&account.id).map(|local_id| (*local_id, account))).collect();

    let mut accounts: Vec<Account> = local
        .accounts
        .iter()
        .map(|account| match remote_by_local.get(&account.id) {
            Some(remote_account) if prefer_remote.contains(&account.id) => Account { id: account.id, ..(*remote_account).clone() },
            _ => account.clone(),
        })
        .collect();
    accounts.extend(remote.accounts.iter().filter(|account| !account_pairs.contains_key(&account.id)).cloned());
    let merged_ids: HashSet<Uuid> = accounts.iter().map(|account| account.id).collect();
    let mapped = |remote_id: &Uuid| account_pairs.get(remote_id).copied().unwrap_or(*remote_id);

    let category_pairs = pair_categories(&local.categories, &remote.categories);
    let remote_by_local_category: HashMap<Uuid, &Category> =
        remote.categories.iter().filter_map(|category| category_pairs.get(&category.id).map(|local_id| (*local_id, category))).collect();
    let mut categories: Vec<Category> = local
        .categories
        .iter()
        .map(|category| {
            let mut account_ids = category.account_ids.clone();
            if let Some(remote_category) = remote_by_local_category.get(&category.id) {
                for id in remote_category.account_ids.iter().map(mapped) {
                    if !account_ids.contains(&id) {
                        account_ids.push(id);
                    }
                }
            }
            Category { id: category.id, name: category.name.clone(), account_ids }
        })
        .collect();
    categories.extend(remote.categories.iter().filter(|category| !category_pairs.contains_key(&category.id)).map(|category| {
        let mut account_ids: Vec<Uuid> = Vec::new();
        for id in category.account_ids.iter().map(mapped) {
            if !account_ids.contains(&id) {
                account_ids.push(id);
            }
        }
        Category { id: category.id, name: category.name.clone(), account_ids }
    }));
    for category in &mut categories {
        category.account_ids.retain(|id| merged_ids.contains(id));
    }
    VaultContents { accounts, categories, pinned_ids: Vec::new() }
}

#[cfg(test)]
mod tests {
    use std::time::UNIX_EPOCH;

    use super::*;
    use crate::model::TotpAlgorithm;

    fn placeholders() -> Placeholders {
        Placeholders { unknown_issuer: "Unknown".into(), empty_username: "None".into() }
    }

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn account(n: u128, issuer: &str, secret: &str) -> Account {
        Account {
            id: id(n),
            issuer: issuer.into(),
            username: "alex".into(),
            secret: secret.into(),
            algorithm: TotpAlgorithm::Sha1,
            digits: 6,
            period: 30,
            created_at: UNIX_EPOCH,
            added_by: "manual".into(),
        }
    }

    fn category(n: u128, name: &str, members: &[u128]) -> Category {
        Category { id: id(n), name: name.into(), account_ids: members.iter().map(|m| id(*m)).collect() }
    }

    fn contents(accounts: Vec<Account>, categories: Vec<Category>) -> VaultContents {
        VaultContents { accounts, categories, pinned_ids: Vec::new() }
    }

    #[test]
    fn identical_contents_in_another_order_have_no_differences() {
        let a = account(1, "GitHub", "JBSWY3DPEHPK3PXP");
        let b = account(2, "Google", "GEZDGNBVGY3TQOJQ");
        let local = contents(vec![a.clone(), b.clone()], vec![category(10, "Work", &[1, 2])]);
        let remote = contents(vec![b, a], vec![category(10, "Work", &[2, 1])]);
        assert!(diff(&local, &remote, &placeholders()).is_empty());
    }

    #[test]
    fn same_account_added_separately_on_two_devices_pairs_by_identity() {
        let local = contents(vec![account(1, "GitHub", "JBSWY3DPEHPK3PXP")], vec![]);
        let remote = contents(vec![account(9, "github", "jbsw y3dp ehpk 3pxp")], vec![]);
        let result = diff(&local, &remote, &placeholders());
        assert!(
            result.only_local.is_empty() && result.only_remote.is_empty(),
            "differences in case and secret spacing still pair as one account"
        );
        assert_eq!(
            result.changed[0].changes,
            [AccountChange::Issuer],
            "a display name differing in case is listed; secrets equal after normalization are not a difference"
        );
        let merged = merge(&local, &remote, &HashSet::new(), &placeholders());
        assert_eq!(merged.accounts.len(), 1, "merging creates no duplicates");
    }

    #[test]
    fn reports_one_sided_and_changed_accounts_and_categories() {
        let local = contents(
            vec![
                account(1, "GitHub", "JBSWY3DPEHPK3PXP"),
                account(2, "Local only", "GEZDGNBVGY3TQOJQ"),
                account(3, "Shared", "MZXW6YTBOI"),
            ],
            vec![category(10, "Work", &[1]), category(11, "Mine", &[])],
        );
        let mut renamed = account(1, "GitHub Enterprise", "JBSWY3DPEHPK3PXP");
        renamed.digits = 8;
        let remote = contents(
            vec![renamed, account(3, "Shared", "MZXW6YTBOI"), account(4, "Remote only", "KRSXG5A")],
            vec![category(10, "Office", &[1, 3]), category(12, "Theirs", &[4])],
        );
        let result = diff(&local, &remote, &placeholders());
        assert_eq!(result.only_local.iter().map(|a| a.id).collect::<Vec<_>>(), [id(2)]);
        assert_eq!(result.only_remote.iter().map(|a| a.id).collect::<Vec<_>>(), [id(4)]);
        assert_eq!(result.changed.len(), 2);
        assert_eq!(result.changed[0].changes, [AccountChange::Issuer, AccountChange::Parameters, AccountChange::Categories]);
        assert_eq!(result.changed[1].local.id, id(3));
        assert_eq!(result.changed[1].changes, [AccountChange::Categories], "Shared is in Office in the backup but in no category locally");
        assert_eq!(result.categories_only_local, ["Mine"]);
        assert_eq!(result.categories_only_remote, ["Theirs"]);
        assert_eq!(result.categories_renamed, [("Work".to_owned(), "Office".to_owned())]);
    }

    #[test]
    fn secret_changes_are_flagged() {
        let local = contents(vec![account(1, "GitHub", "JBSWY3DPEHPK3PXP")], vec![]);
        let remote = contents(vec![account(1, "GitHub", "GEZDGNBVGY3TQOJQ")], vec![]);
        assert_eq!(diff(&local, &remote, &placeholders()).changed[0].changes, [AccountChange::Secret]);
    }

    #[test]
    fn merge_keeps_both_sides_and_applies_per_account_choices() {
        let local = contents(
            vec![account(1, "GitHub", "JBSWY3DPEHPK3PXP"), account(2, "Local only", "GEZDGNBVGY3TQOJQ"), account(5, "Kept", "ORSXG5A")],
            vec![category(10, "Work", &[2, 1]), category(11, "Mine", &[5])],
        );
        let remote = contents(
            vec![
                account(1, "GitHub Enterprise", "JBSWY3DPEHPK3PXP"),
                account(5, "Kept remotely", "ORSXG5A"),
                account(4, "Remote only", "KRSXG5A"),
            ],
            vec![category(20, "work", &[4, 1]), category(12, "Theirs", &[4, 5])],
        );
        let merged = merge(&local, &remote, &[id(1)].into_iter().collect(), &placeholders());
        let issuers: Vec<&str> = merged.accounts.iter().map(|a| a.issuer.as_str()).collect();
        assert_eq!(
            issuers,
            ["GitHub Enterprise", "Local only", "Kept", "Remote only"],
            "local order first; backup fields where the backup version was chosen"
        );
        assert_eq!(merged.accounts[0].id, id(1));
        let work = &merged.categories[0];
        assert_eq!((work.id, work.name.as_str()), (id(10), "Work"), "a category paired by name keeps the local ID and name");
        assert_eq!(work.account_ids, [id(2), id(1), id(4)], "union of members, local order first");
        assert_eq!(merged.categories[2].name, "Theirs");
        assert_eq!(merged.categories[2].account_ids, [id(4), id(5)]);
        assert!(merged.pinned_ids.is_empty());
    }

    #[test]
    fn merge_maps_remote_members_paired_by_identity() {
        let local = contents(vec![account(1, "GitHub", "JBSWY3DPEHPK3PXP")], vec![]);
        let remote = contents(vec![account(9, "GitHub", "JBSWY3DPEHPK3PXP")], vec![category(12, "Theirs", &[9, 77])]);
        let merged = merge(&local, &remote, &HashSet::new(), &placeholders());
        assert_eq!(merged.categories[0].account_ids, [id(1)], "backup member 9 becomes local 1; members that do not exist are dropped");
    }
}
