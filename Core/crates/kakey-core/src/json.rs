//! Field encoding for JSON written to disk, interoperable with `JSONEncoder.kakey` / `JSONDecoder.kakey` on Mac:
//! - Byte strings: standard base64 (with padding)
//! - Dates: ISO-8601 / RFC 3339, written to whole seconds in UTC with a `Z` suffix (Foundation's `.iso8601`
//!   decoder rejects fractional seconds)
//! - UUIDs: uppercase with hyphens
//! - Output is sorted by key with two-space indentation, so files diff cleanly.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

pub fn to_offset(date: SystemTime) -> OffsetDateTime {
    let seconds = match date.duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as i64,
        Err(error) => -(error.duration().as_secs_f64().ceil() as i64),
    };
    OffsetDateTime::from_unix_timestamp(seconds).unwrap_or(OffsetDateTime::UNIX_EPOCH)
}

pub fn from_offset(date: OffsetDateTime) -> SystemTime {
    let seconds = date.unix_timestamp();
    if seconds >= 0 { UNIX_EPOCH + Duration::from_secs(seconds as u64) } else { UNIX_EPOCH - Duration::from_secs(seconds.unsigned_abs()) }
}

/// Truncates to whole seconds so a value read back after writing equals the one in memory.
pub fn truncate_to_seconds(date: SystemTime) -> SystemTime {
    from_offset(to_offset(date))
}

pub fn format_date(date: SystemTime) -> String {
    to_offset(date).format(&Rfc3339).unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

pub fn parse_date(value: &str) -> Option<SystemTime> {
    OffsetDateTime::parse(value, &Rfc3339).ok().map(from_offset)
}

pub mod date {
    use super::*;

    pub fn serialize<S: Serializer>(date: &SystemTime, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format_date(*date))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<SystemTime, D::Error> {
        let value = String::deserialize(deserializer)?;
        parse_date(&value).ok_or_else(|| serde::de::Error::custom("invalid ISO-8601 date"))
    }
}

pub mod bytes {
    use super::*;

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let value = String::deserialize(deserializer)?;
        base64::engine::general_purpose::STANDARD.decode(value).map_err(serde::de::Error::custom)
    }
}

pub mod uuid_upper {
    use super::*;

    pub fn serialize<S: Serializer>(id: &Uuid, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(id.hyphenated().encode_upper(&mut Uuid::encode_buffer()))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
        let value = String::deserialize(deserializer)?;
        Uuid::parse_str(&value).map_err(serde::de::Error::custom)
    }
}

pub mod uuid_upper_vec {
    use super::*;

    #[derive(Serialize, Deserialize)]
    struct Wrapped(#[serde(with = "super::uuid_upper")] Uuid);

    pub fn serialize<S: Serializer>(ids: &[Uuid], serializer: S) -> Result<S::Ok, S::Error> {
        ids.iter().map(|id| Wrapped(*id)).collect::<Vec<_>>().serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<Uuid>, D::Error> {
        Ok(Vec::<Wrapped>::deserialize(deserializer)?.into_iter().map(|Wrapped(id)| id).collect())
    }
}

/// A JSON value sorted by key. Uses BTreeMap explicitly: if any crate in the dependency graph enables serde_json's
/// `preserve_order`, `serde_json::Map` switches to insertion order.
enum Sorted {
    Object(std::collections::BTreeMap<String, Sorted>),
    Array(Vec<Sorted>),
    Scalar(serde_json::Value),
}

impl From<serde_json::Value> for Sorted {
    fn from(value: serde_json::Value) -> Self {
        match value {
            serde_json::Value::Object(map) => Sorted::Object(map.into_iter().map(|(k, v)| (k, v.into())).collect()),
            serde_json::Value::Array(items) => Sorted::Array(items.into_iter().map(Into::into).collect()),
            scalar => Sorted::Scalar(scalar),
        }
    }
}

impl Serialize for Sorted {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Sorted::Object(map) => map.serialize(serializer),
            Sorted::Array(items) => items.serialize(serializer),
            Sorted::Scalar(value) => value.serialize(serializer),
        }
    }
}

/// Serializes to JSON sorted by key with two-space indentation.
pub fn to_sorted_pretty<T: Serialize>(value: &T) -> Vec<u8> {
    let value = serde_json::to_value(value).expect("in-memory structs always serialize");
    serde_json::to_vec_pretty(&Sorted::from(value)).expect("sorted JSON always serializes")
}
