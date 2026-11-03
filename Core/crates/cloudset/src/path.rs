use std::fmt;

use crate::error::CloudError;

/// A path relative to the storage root, stored as segments. The root is the empty path.
///
/// Segments may not be empty, `.`, or `..`, and may not contain `/`, `\`, or control characters: paths come from the UI
/// or from remote listings, so traversal must be ruled out before they are joined into a URL.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RemotePath {
    segments: Vec<String>,
}

impl RemotePath {
    pub fn root() -> Self {
        Self::default()
    }

    /// Parses `a/b/c`; leading and trailing `/` are ignored, empty inner segments (`a//b`) are rejected.
    pub fn parse(text: &str) -> Result<Self, CloudError> {
        let trimmed = text.trim_matches('/');
        if trimmed.is_empty() {
            return Ok(Self::root());
        }
        Self::from_segments(trimmed.split('/').map(str::to_owned))
    }

    pub fn from_segments(segments: impl IntoIterator<Item = String>) -> Result<Self, CloudError> {
        let segments: Vec<String> = segments.into_iter().collect();
        if segments.iter().all(|segment| valid_segment(segment)) { Ok(Self { segments }) } else { Err(CloudError::InvalidPath) }
    }

    pub fn join(&self, name: &str) -> Result<Self, CloudError> {
        if !valid_segment(name) {
            return Err(CloudError::InvalidPath);
        }
        let mut segments = self.segments.clone();
        segments.push(name.to_owned());
        Ok(Self { segments })
    }

    pub fn parent(&self) -> Option<Self> {
        let (_, parent) = self.segments.split_last()?;
        Some(Self { segments: parent.to_vec() })
    }

    pub fn name(&self) -> Option<&str> {
        self.segments.last().map(String::as_str)
    }

    pub fn segments(&self) -> &[String] {
        &self.segments
    }

    pub fn is_root(&self) -> bool {
        self.segments.is_empty()
    }
}

fn valid_segment(segment: &str) -> bool {
    !segment.is_empty() && segment != "." && segment != ".." && !segment.chars().any(|c| c == '/' || c == '\\' || c.is_control())
}

impl fmt::Display for RemotePath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.segments.join("/"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_rejects_traversal() {
        assert_eq!(RemotePath::parse("/").unwrap(), RemotePath::root());
        let path = RemotePath::parse("/Backups/vault.bin").unwrap();
        assert_eq!(path.segments(), ["Backups", "vault.bin"]);
        assert_eq!(path.to_string(), "Backups/vault.bin");
        assert_eq!(path.parent().unwrap().to_string(), "Backups");
        assert_eq!(path.name(), Some("vault.bin"));
        assert_eq!(RemotePath::parse("备份/文件 1").unwrap().segments(), ["备份", "文件 1"]);
        for bad in ["a//b", "a/../b", "./a", "a\\b", "a/\u{0}b", "a/\nb"] {
            assert_eq!(RemotePath::parse(bad), Err(CloudError::InvalidPath), "{bad:?}");
        }
        assert_eq!(RemotePath::root().join(".."), Err(CloudError::InvalidPath));
        assert_eq!(RemotePath::root().parent(), None);
    }
}
