//! Sync conflict detection (shared by the folder and cloud storage backends).
//!
//! The platform reads and writes the remote and remembers the local time and remote version of the last sync; this
//! module only decides from snapshots whether to upload, download, do nothing, or report a conflict. When both sides
//! changed, it is always a conflict for the user to resolve by picking a direction; nothing is merged automatically.
//!
//! Only the local key is trusted: a remote that changed since the last sync and cannot be opened with the current local
//! vault key (a different vault, or another device changed the master password) yields [`SyncDecision::Unreadable`]: no
//! upload, no download, no conflict choice; the platform reports an error and only an explicit "restore from backup" by
//! the user is allowed. An unchanged remote is not checked: after the master password is changed on this device, the
//! remote is still the copy encrypted with the old key and is uploaded as usual.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Time comparison tolerance: file systems and metadata differ in time precision, so times within 0.5 s count as equal.
const TOLERANCE: Duration = Duration::from_millis(500);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalSnapshot {
    pub data: Vec<u8>,
    /// `updatedAt` from the local vault envelope.
    pub vault_updated_at: SystemTime,
}

/// Version identifier of the remote file. The folder backend only has a modification time (compared with tolerance); cloud
/// storage backends have an ETag / rev (compared exactly). The two kinds are not comparable and count as changed (see
/// docs/TECHNICAL.md).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemoteVersion {
    ModifiedAt { at: SystemTime },
    Revision { value: String },
}

impl RemoteVersion {
    fn changed_since(&self, last: &Self) -> bool {
        match (self, last) {
            (Self::ModifiedAt { at }, Self::ModifiedAt { at: last }) => differs(*at, *last),
            (Self::Revision { value }, Self::Revision { value: last }) => value != last,
            _ => true,
        }
    }

    /// Text form the platform persists as the sync marker: `t:<Unix milliseconds>` or `r:<version>`.
    pub fn encode(&self) -> String {
        match self {
            Self::ModifiedAt { at } => format!("t:{}", unix_millis(*at)),
            Self::Revision { value } => format!("r:{value}"),
        }
    }

    /// Returns `None` if unreadable (empty, unknown prefix, time out of range); the caller treats that as never synced.
    pub fn decode(text: &str) -> Option<Self> {
        if let Some(millis) = text.strip_prefix("t:") {
            let millis: i64 = millis.parse().ok()?;
            let magnitude = Duration::from_millis(millis.unsigned_abs());
            let at = if millis >= 0 { UNIX_EPOCH.checked_add(magnitude) } else { UNIX_EPOCH.checked_sub(magnitude) }?;
            return Some(Self::ModifiedAt { at });
        }
        text.strip_prefix("r:").filter(|value| !value.is_empty()).map(|value| Self::Revision { value: value.to_owned() })
    }
}

fn unix_millis(at: SystemTime) -> i64 {
    match at.duration_since(UNIX_EPOCH) {
        Ok(after) => i64::try_from(after.as_millis()).unwrap_or(i64::MAX),
        Err(before) => i64::try_from(before.duration().as_millis()).map_or(i64::MIN, |millis| -millis),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteSnapshot {
    pub data: Vec<u8>,
    /// Version of the remote file; counts as "changed" when unavailable.
    pub version: Option<RemoteVersion>,
    /// Whether the current local vault key opens the remote envelope (the platform tries the key without running the
    /// KDF). Ignored when there is no local vault.
    pub readable: bool,
}

/// Local time and remote version recorded at the last successful sync; `None` if never synced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncMarks {
    pub last_local_updated_at: Option<SystemTime>,
    pub last_remote_version: Option<RemoteVersion>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncDecision {
    NoLocalVault,
    Upload,
    Download,
    UpToDate,
    Conflict,
    /// The remote changed since the last sync and the local key cannot open it: cannot sync.
    Unreadable,
}

fn differs(value: SystemTime, reference: SystemTime) -> bool {
    let delta = value.duration_since(reference).or_else(|_| reference.duration_since(value)).unwrap_or_default();
    delta > TOLERANCE
}

pub fn decide(local: Option<&LocalSnapshot>, remote: Option<&RemoteSnapshot>, marks: &SyncMarks) -> SyncDecision {
    match (local, remote) {
        (None, None) => SyncDecision::NoLocalVault,
        (Some(_), None) => SyncDecision::Upload,
        (None, Some(_)) => SyncDecision::Download,
        (Some(local), Some(remote)) => {
            if local.data == remote.data {
                return SyncDecision::UpToDate;
            }
            let local_changed = marks.last_local_updated_at.is_none_or(|last| differs(local.vault_updated_at, last));
            let remote_changed = match (&remote.version, &marks.last_remote_version) {
                (Some(version), Some(last)) => version.changed_since(last),
                _ => true,
            };
            if remote_changed && !remote.readable {
                return SyncDecision::Unreadable;
            }
            match (local_changed, remote_changed) {
                (true, false) => SyncDecision::Upload,
                (false, true) => SyncDecision::Download,
                _ => SyncDecision::Conflict,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: f64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs_f64(seconds)
    }

    fn time(seconds: f64) -> RemoteVersion {
        RemoteVersion::ModifiedAt { at: at(seconds) }
    }

    fn rev(value: &str) -> RemoteVersion {
        RemoteVersion::Revision { value: value.to_owned() }
    }

    fn local(data: &[u8], updated: f64) -> LocalSnapshot {
        LocalSnapshot { data: data.to_vec(), vault_updated_at: at(updated) }
    }

    fn remote(data: &[u8], version: Option<RemoteVersion>) -> RemoteSnapshot {
        RemoteSnapshot { data: data.to_vec(), version, readable: true }
    }

    fn unreadable(data: &[u8], version: Option<RemoteVersion>) -> RemoteSnapshot {
        RemoteSnapshot { readable: false, ..remote(data, version) }
    }

    fn marks(local: f64, remote: RemoteVersion) -> SyncMarks {
        SyncMarks { last_local_updated_at: Some(at(local)), last_remote_version: Some(remote) }
    }

    #[test]
    fn decides_by_presence_and_content() {
        let none = SyncMarks::default();
        assert_eq!(decide(None, None, &none), SyncDecision::NoLocalVault);
        assert_eq!(decide(Some(&local(b"a", 1.0)), None, &none), SyncDecision::Upload);
        assert_eq!(decide(None, Some(&remote(b"a", Some(time(1.0)))), &none), SyncDecision::Download);
        assert_eq!(decide(Some(&local(b"a", 1.0)), Some(&remote(b"a", Some(time(9.0)))), &none), SyncDecision::UpToDate);
    }

    #[test]
    fn decides_by_modification_time_with_tolerance() {
        let l = local(b"l", 100.0);
        let r = remote(b"r", Some(time(200.0)));
        assert_eq!(decide(Some(&l), Some(&r), &marks(50.0, time(200.3))), SyncDecision::Upload);
        assert_eq!(decide(Some(&l), Some(&r), &marks(100.2, time(150.0))), SyncDecision::Download);
        assert_eq!(decide(Some(&l), Some(&r), &marks(50.0, time(150.0))), SyncDecision::Conflict);
        assert_eq!(decide(Some(&l), Some(&r), &marks(100.0, time(200.0))), SyncDecision::Conflict);
        assert_eq!(decide(Some(&l), Some(&r), &SyncMarks::default()), SyncDecision::Conflict);
        assert_eq!(decide(Some(&l), Some(&remote(b"r", None)), &marks(100.0, time(200.0))), SyncDecision::Download);
    }

    #[test]
    fn decides_by_revision_exactly() {
        let l = local(b"l", 100.0);
        let r = remote(b"r", Some(rev("abc")));
        assert_eq!(decide(Some(&l), Some(&r), &marks(50.0, rev("abc"))), SyncDecision::Upload);
        assert_eq!(decide(Some(&l), Some(&r), &marks(100.0, rev("abd"))), SyncDecision::Download);
        assert_eq!(decide(Some(&l), Some(&r), &marks(50.0, rev("abd"))), SyncDecision::Conflict);
    }

    #[test]
    fn changed_remotes_the_local_key_cannot_open_are_unreadable() {
        let l = local(b"l", 100.0);
        let none = SyncMarks::default();
        assert_eq!(
            decide(Some(&l), Some(&unreadable(b"r", Some(rev("1")))), &none),
            SyncDecision::Unreadable,
            "first link: an unrecognized backup cannot be used"
        );
        assert_eq!(
            decide(Some(&l), Some(&remote(b"r", Some(rev("1")))), &none),
            SyncDecision::Conflict,
            "readable, different contents: pick a direction"
        );
        assert_eq!(
            decide(Some(&l), Some(&unreadable(b"r", Some(rev("2")))), &marks(100.0, rev("1"))),
            SyncDecision::Unreadable,
            "another device changed the master password"
        );
        assert_eq!(
            decide(Some(&l), Some(&unreadable(b"r", Some(rev("2")))), &marks(50.0, rev("1"))),
            SyncDecision::Unreadable,
            "changed on both sides still is not a conflict"
        );
        assert_eq!(
            decide(Some(&l), Some(&unreadable(b"r", Some(rev("1")))), &marks(50.0, rev("1"))),
            SyncDecision::Upload,
            "remote unchanged: upload as usual after a local master password change"
        );
        assert_eq!(
            decide(None, Some(&unreadable(b"r", None)), &none),
            SyncDecision::Download,
            "no local vault: first restore ignores the key"
        );
        assert_eq!(decide(Some(&local(b"same", 1.0)), Some(&unreadable(b"same", None)), &none), SyncDecision::UpToDate);
    }

    #[test]
    fn mixed_version_kinds_count_as_changed() {
        let l = local(b"l", 100.0);
        assert_eq!(decide(Some(&l), Some(&remote(b"r", Some(rev("1")))), &marks(100.0, time(1.0))), SyncDecision::Download);
        assert_eq!(decide(Some(&l), Some(&remote(b"r", Some(time(1.0)))), &marks(100.0, rev("1"))), SyncDecision::Download);
    }

    #[test]
    fn encodes_and_decodes_versions() {
        let millisecond_precise = RemoteVersion::ModifiedAt { at: UNIX_EPOCH + Duration::from_millis(1_730_000_000_123) };
        for version in [millisecond_precise, time(0.0), rev("\"etag-1\""), rev("r:nested")] {
            assert_eq!(RemoteVersion::decode(&version.encode()), Some(version));
        }
        let before_epoch = RemoteVersion::ModifiedAt { at: UNIX_EPOCH - Duration::from_millis(1500) };
        assert_eq!(before_epoch.encode(), "t:-1500");
        assert_eq!(RemoteVersion::decode("t:-1500"), Some(before_epoch));
        assert_eq!(time(1.0).encode(), "t:1000");
        for invalid in ["", "t:", "t:x", "r:", "x:1", "1000"] {
            assert_eq!(RemoteVersion::decode(invalid), None, "{invalid}");
        }
    }
}
