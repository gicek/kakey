//! User categories (rules in docs/DESIGN.md, data format in docs/TECHNICAL.md).
//!
//! - Categories live only in the encrypted payload; array order is the sidebar order, and `account_ids` order is the
//!   order within the category and also defines membership.
//! - An account can belong to several categories; deleting a category does not delete its accounts.
//! - Names must not be empty after trimming surrounding whitespace, have at most [`MAX_NAME_CHARS`] characters, and must
//!   be unique case-insensitively.
//! - Every operation returns a new list and leaves its input untouched; the platform writes the result back to the vault
//!   as a whole.

use std::collections::HashSet;

use uuid::Uuid;

/// Maximum characters in a category name (counted in Unicode scalar values).
pub const MAX_NAME_CHARS: usize = 40;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Category {
    pub id: Uuid,
    pub name: String,
    pub account_ids: Vec<Uuid>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CategoryError {
    #[error("category name is empty")]
    EmptyName,
    #[error("category name is too long")]
    NameTooLong,
    #[error("a category with this name already exists")]
    DuplicateName,
    #[error("category not found")]
    NotFound,
}

impl CategoryError {
    pub fn l10n_key(self) -> &'static str {
        match self {
            CategoryError::EmptyName => "err.category.empty_name",
            CategoryError::NameTooLong => "err.category.name_too_long",
            CategoryError::DuplicateName => "err.category.duplicate_name",
            CategoryError::NotFound => "err.category.not_found",
        }
    }
}

fn name_key(name: &str) -> String {
    name.trim().to_lowercase()
}

/// Validates a name and returns it trimmed. `except` is the category being renamed, which does not clash with itself.
pub fn validated_name(categories: &[Category], raw: &str, except: Option<Uuid>) -> Result<String, CategoryError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(CategoryError::EmptyName);
    }
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(CategoryError::NameTooLong);
    }
    let key = name_key(name);
    if categories.iter().any(|category| Some(category.id) != except && name_key(&category.name) == key) {
        return Err(CategoryError::DuplicateName);
    }
    Ok(name.to_owned())
}

/// Creates an empty category at the end.
pub fn create(categories: &[Category], raw_name: &str, id: Uuid) -> Result<Vec<Category>, CategoryError> {
    let name = validated_name(categories, raw_name, None)?;
    let mut result = categories.to_vec();
    result.push(Category { id, name, account_ids: Vec::new() });
    Ok(result)
}

fn index_of(categories: &[Category], id: Uuid) -> Result<usize, CategoryError> {
    categories.iter().position(|category| category.id == id).ok_or(CategoryError::NotFound)
}

pub fn rename(categories: &[Category], id: Uuid, raw_name: &str) -> Result<Vec<Category>, CategoryError> {
    let index = index_of(categories, id)?;
    let name = validated_name(categories, raw_name, Some(id))?;
    let mut result = categories.to_vec();
    result[index].name = name;
    Ok(result)
}

/// Deletes the category itself; its accounts are unaffected. Returns the input unchanged if it does not exist.
pub fn delete(categories: &[Category], id: Uuid) -> Vec<Category> {
    categories.iter().filter(|category| category.id != id).cloned().collect()
}

/// Reorders categories by the given IDs; unlisted categories follow in their original relative order, and unknown IDs are
/// ignored.
pub fn reorder(categories: &[Category], ordered_ids: &[Uuid]) -> Vec<Category> {
    let mut seen = HashSet::new();
    let mut result: Vec<Category> = ordered_ids
        .iter()
        .filter(|id| seen.insert(**id))
        .filter_map(|id| categories.iter().find(|category| category.id == *id).cloned())
        .collect();
    result.extend(categories.iter().filter(|category| !seen.contains(&category.id)).cloned());
    result
}

/// Appends an account to a category; no change if it is already there.
pub fn add_account(categories: &[Category], id: Uuid, account_id: Uuid) -> Result<Vec<Category>, CategoryError> {
    let index = index_of(categories, id)?;
    let mut result = categories.to_vec();
    if !result[index].account_ids.contains(&account_id) {
        result[index].account_ids.push(account_id);
    }
    Ok(result)
}

pub fn remove_account(categories: &[Category], id: Uuid, account_id: Uuid) -> Result<Vec<Category>, CategoryError> {
    let index = index_of(categories, id)?;
    let mut result = categories.to_vec();
    result[index].account_ids.retain(|existing| *existing != account_id);
    Ok(result)
}

/// Sets the order within a category (committing a drag reorder): existing members are arranged in the given order,
/// members missing from it follow in their original relative order, and IDs not in the category are ignored.
pub fn set_account_order(categories: &[Category], id: Uuid, ordered_ids: &[Uuid]) -> Result<Vec<Category>, CategoryError> {
    let index = index_of(categories, id)?;
    let mut result = categories.to_vec();
    let members: HashSet<Uuid> = result[index].account_ids.iter().copied().collect();
    let mut seen = HashSet::new();
    let mut ordered: Vec<Uuid> = ordered_ids.iter().copied().filter(|id| members.contains(id) && seen.insert(*id)).collect();
    ordered.extend(result[index].account_ids.iter().copied().filter(|id| !seen.contains(id)));
    result[index].account_ids = ordered;
    Ok(result)
}

/// Removes deleted accounts from every category.
pub fn removing_accounts(categories: &[Category], account_ids: &[Uuid]) -> Vec<Category> {
    let removed: HashSet<Uuid> = account_ids.iter().copied().collect();
    categories
        .iter()
        .map(|category| Category {
            account_ids: category.account_ids.iter().copied().filter(|id| !removed.contains(id)).collect(),
            ..category.clone()
        })
        .collect()
}

/// Cleanup when reading or writing the vault: drops categories with duplicate IDs (keeping the first), IDs that point to
/// missing accounts, and duplicate IDs within a category.
pub fn sanitized(categories: &[Category], existing_account_ids: &HashSet<Uuid>) -> Vec<Category> {
    let mut seen_categories = HashSet::new();
    categories
        .iter()
        .filter(|category| seen_categories.insert(category.id))
        .map(|category| {
            let mut seen = HashSet::new();
            Category {
                account_ids: category
                    .account_ids
                    .iter()
                    .copied()
                    .filter(|id| existing_account_ids.contains(id) && seen.insert(*id))
                    .collect(),
                ..category.clone()
            }
        })
        .collect()
}

/// Adds accounts to the category named `name` (matched case-insensitively), creating it if missing; `new_id` is only
/// called when creating (usually `vault::random_uuid`; if it fails, that error is returned for the whole call).
/// An invalid name returns the input unchanged (names from import files must not make an import fail).
pub fn adding_to_named<E>(
    categories: &[Category],
    name: &str,
    account_ids: &[Uuid],
    new_id: impl FnOnce() -> Result<Uuid, E>,
) -> Result<Vec<Category>, E> {
    let key = name_key(name);
    let mut result = categories.to_vec();
    let index = match result.iter().position(|category| name_key(&category.name) == key) {
        Some(index) => index,
        None => {
            let Ok(name) = validated_name(&result, name, None) else { return Ok(result) };
            result.push(Category { id: new_id()?, name, account_ids: Vec::new() });
            result.len() - 1
        }
    };
    for account_id in account_ids {
        if !result[index].account_ids.contains(account_id) {
            result[index].account_ids.push(*account_id);
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn sample() -> Vec<Category> {
        vec![
            Category { id: id(1), name: "工作".into(), account_ids: vec![id(10), id(11)] },
            Category { id: id(2), name: "Crypto".into(), account_ids: vec![id(11)] },
        ]
    }

    #[test]
    fn names_are_trimmed_bounded_and_unique_ignoring_case() {
        let categories = sample();
        assert_eq!(create(&categories, "  ", id(3)), Err(CategoryError::EmptyName));
        assert_eq!(create(&categories, &"字".repeat(41), id(3)), Err(CategoryError::NameTooLong));
        assert!(create(&categories, &"字".repeat(40), id(3)).is_ok());
        assert_eq!(create(&categories, " crypto ", id(3)), Err(CategoryError::DuplicateName));
        let created = create(&categories, "  个人 ", id(3)).unwrap();
        assert_eq!(created[2], Category { id: id(3), name: "个人".into(), account_ids: vec![] });
    }

    #[test]
    fn rename_allows_own_name_and_rejects_others() {
        let categories = sample();
        assert_eq!(rename(&categories, id(2), "CRYPTO").unwrap()[1].name, "CRYPTO");
        assert_eq!(rename(&categories, id(2), "工作"), Err(CategoryError::DuplicateName));
        assert_eq!(rename(&categories, id(9), "x"), Err(CategoryError::NotFound));
    }

    #[test]
    fn membership_and_ordering() {
        let categories = sample();
        let added = add_account(&categories, id(2), id(12)).unwrap();
        assert_eq!(added[1].account_ids, vec![id(11), id(12)]);
        assert_eq!(add_account(&added, id(2), id(12)).unwrap(), added, "adding again changes nothing");
        assert_eq!(remove_account(&added, id(2), id(11)).unwrap()[1].account_ids, vec![id(12)]);
        let ordered = set_account_order(&categories, id(1), &[id(11), id(99), id(11)]).unwrap();
        assert_eq!(ordered[0].account_ids, vec![id(11), id(10)], "unlisted members stay at the end; foreign and duplicate IDs are ignored");
        assert_eq!(reorder(&categories, &[id(2), id(7)]).iter().map(|c| c.id).collect::<Vec<_>>(), vec![id(2), id(1)]);
    }

    #[test]
    fn deleting_category_keeps_accounts_and_deleting_accounts_cleans_categories() {
        let categories = sample();
        assert_eq!(delete(&categories, id(1)), vec![categories[1].clone()]);
        let cleaned = removing_accounts(&categories, &[id(11)]);
        assert_eq!(cleaned[0].account_ids, vec![id(10)]);
        assert!(cleaned[1].account_ids.is_empty());
    }

    #[test]
    fn sanitize_drops_unknown_and_duplicate_ids() {
        let categories = vec![Category { id: id(1), name: "a".into(), account_ids: vec![id(10), id(99), id(10)] }];
        let existing: HashSet<Uuid> = [id(10)].into();
        assert_eq!(sanitized(&categories, &existing)[0].account_ids, vec![id(10)]);
    }

    /// When the same category ID appears twice (corrupt file or a bad sync merge), only the first is kept and later ones
    /// are dropped entirely.
    #[test]
    fn sanitize_drops_categories_with_repeated_ids() {
        let categories = vec![
            Category { id: id(1), name: "a".into(), account_ids: vec![id(10)] },
            Category { id: id(2), name: "b".into(), account_ids: vec![id(11)] },
            Category { id: id(1), name: "a again".into(), account_ids: vec![id(11)] },
        ];
        let existing: HashSet<Uuid> = [id(10), id(11)].into();
        assert_eq!(sanitized(&categories, &existing), categories[..2].to_vec());
    }

    #[test]
    fn adding_to_named_matches_case_insensitively_or_creates() {
        let categories = sample();
        let new_id = || Ok::<_, ()>(id(5));
        let merged = adding_to_named(&categories, "CRYPTO", &[id(12), id(11)], new_id).unwrap();
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[1].account_ids, vec![id(11), id(12)]);
        let created = adding_to_named(&categories, " 常用 ", &[id(10)], new_id).unwrap();
        assert_eq!(created[2], Category { id: id(5), name: "常用".into(), account_ids: vec![id(10)] });
        assert_eq!(adding_to_named(&categories, "  ", &[id(10)], new_id).unwrap(), categories, "an invalid name creates nothing");
        assert_eq!(
            adding_to_named(&categories, "CRYPTO", &[id(12)], || Err("rng")).unwrap(),
            merged,
            "joining an existing category needs no new ID"
        );
        assert_eq!(
            adding_to_named(&categories, "新", &[id(12)], || Err("rng")).unwrap_err(),
            "rng",
            "an ID generation failure while creating a category fails the whole call"
        );
    }
}
