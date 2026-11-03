use std::time::SystemTime;

use crate::path::RemotePath;

/// A version identifier from the remote (ETag / rev), stored and sent back verbatim and only compared for equality.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Revision(String);

impl Revision {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// A weak ETag (`W/"…"`) cannot be used for the strong comparison of conditional requests.
    pub(crate) fn is_weak(&self) -> bool {
        self.0.starts_with("W/")
    }
}

/// Metadata of a file or directory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub path: RemotePath,
    pub is_dir: bool,
    pub size: Option<u64>,
    pub modified_at: Option<SystemTime>,
    pub revision: Option<Revision>,
}

/// File contents together with the metadata at read time (same version).
#[derive(Clone, PartialEq, Eq)]
pub struct File {
    pub data: Vec<u8>,
    pub entry: Entry,
}

impl std::fmt::Debug for File {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("File").field("len", &self.data.len()).field("entry", &self.entry).finish()
    }
}

/// Precondition for a write; if it does not hold, the write fails with [`crate::CloudError::PreconditionFailed`] and the
/// remote is unchanged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Precondition {
    /// Overwrite unconditionally.
    None,
    /// Create only if the file does not exist.
    Absent,
    /// Overwrite only if the remote version is still this one.
    Matches(Revision),
}
