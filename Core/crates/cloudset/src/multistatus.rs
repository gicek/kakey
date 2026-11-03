//! WebDAV `207 Multi-Status` response parsing (RFC 4918 §13). Only `href` and four properties from 2xx `propstat` are read.
//!
//! Remote XML is always treated as untrusted: `DOCTYPE` is rejected (no custom entities are ever expanded), nesting depth
//! and entry count are capped, and only predefined entities and character references are decoded.

use std::time::SystemTime;

use quick_xml::NsReader;
use quick_xml::escape::resolve_predefined_entity;
use quick_xml::events::Event;
use quick_xml::name::{Namespace, ResolveResult};

use crate::error::CloudError;

const DAV: Namespace<'static> = Namespace("DAV:");
const MAX_DEPTH: usize = 32;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct DavEntry {
    pub href: String,
    pub is_dir: bool,
    pub size: Option<u64>,
    pub modified_at: Option<SystemTime>,
    pub etag: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tag {
    Multistatus,
    Response,
    Href,
    Propstat,
    Status,
    Prop,
    ResourceType,
    Collection,
    ContentLength,
    LastModified,
    Etag,
    Other,
}

impl Tag {
    fn of(name: &str) -> Self {
        match name {
            "multistatus" => Self::Multistatus,
            "response" => Self::Response,
            "href" => Self::Href,
            "propstat" => Self::Propstat,
            "status" => Self::Status,
            "prop" => Self::Prop,
            "resourcetype" => Self::ResourceType,
            "collection" => Self::Collection,
            "getcontentlength" => Self::ContentLength,
            "getlastmodified" => Self::LastModified,
            "getetag" => Self::Etag,
            _ => Self::Other,
        }
    }

    /// Elements whose text content is collected.
    fn has_text(self) -> bool {
        matches!(self, Self::Href | Self::Status | Self::ContentLength | Self::LastModified | Self::Etag)
    }
}

#[derive(Default)]
struct Propstat {
    status: Option<u16>,
    props: DavEntry,
}

#[derive(Default)]
struct ResponseBuilder {
    href: Option<String>,
    propstats: Vec<Propstat>,
}

impl ResponseBuilder {
    /// Merges every 2xx (or status-less) propstat; properties that only appear in failed propstats (404 etc.) count as absent.
    fn finish(self) -> Option<DavEntry> {
        let mut entry = DavEntry { href: self.href?, ..DavEntry::default() };
        for propstat in self.propstats.into_iter().filter(|p| p.status.is_none_or(|s| (200..300).contains(&s))) {
            let props = propstat.props;
            entry.is_dir |= props.is_dir;
            entry.size = entry.size.or(props.size);
            entry.modified_at = entry.modified_at.or(props.modified_at);
            entry.etag = entry.etag.or(props.etag);
        }
        Some(entry)
    }
}

pub(crate) fn parse(body: &[u8], max_entries: usize) -> Result<Vec<DavEntry>, CloudError> {
    let mut reader = NsReader::from_reader(body);
    reader.config_mut().expand_empty_elements = true;
    let mut buf = Vec::new();
    let mut stack: Vec<Tag> = Vec::new();
    let mut text = String::new();
    let mut entries = Vec::new();
    let mut response: Option<ResponseBuilder> = None;
    let mut propstat: Option<Propstat> = None;
    let mut saw_root = false;

    loop {
        let (namespace, event) = reader.read_resolved_event_into(&mut buf).map_err(|_| CloudError::InvalidResponse("malformed xml"))?;
        let in_dav = matches!(namespace, ResolveResult::Bound(ns) if ns == DAV);
        match event {
            Event::Start(start) => {
                let tag = if in_dav { Tag::of(start.local_name().as_ref()) } else { Tag::Other };
                if stack.is_empty() {
                    if tag != Tag::Multistatus {
                        return Err(CloudError::InvalidResponse("not a multistatus"));
                    }
                    saw_root = true;
                }
                if stack.len() >= MAX_DEPTH {
                    return Err(CloudError::InvalidResponse("xml too deep"));
                }
                match (stack.last(), tag) {
                    (Some(Tag::Multistatus), Tag::Response) => response = Some(ResponseBuilder::default()),
                    (Some(Tag::Response), Tag::Propstat) => propstat = Some(Propstat::default()),
                    (Some(Tag::ResourceType), Tag::Collection) => {
                        if let Some(propstat) = propstat.as_mut() {
                            propstat.props.is_dir = true;
                        }
                    }
                    _ => {}
                }
                text.clear();
                stack.push(tag);
            }
            Event::End(_) => {
                let tag = stack.pop().ok_or(CloudError::InvalidResponse("malformed xml"))?;
                let parent = stack.last().copied();
                let value = text.trim();
                match (parent, tag) {
                    (Some(Tag::Response), Tag::Href) => {
                        if let Some(response) = response.as_mut() {
                            response.href = Some(value.to_owned());
                        }
                    }
                    (Some(Tag::Propstat), Tag::Status) => {
                        if let Some(propstat) = propstat.as_mut() {
                            propstat.status = parse_status(value);
                        }
                    }
                    (Some(Tag::Prop), Tag::ContentLength | Tag::LastModified | Tag::Etag) => {
                        if let Some(propstat) = propstat.as_mut() {
                            set_prop(&mut propstat.props, tag, value);
                        }
                    }
                    (Some(Tag::Response), Tag::Propstat) => {
                        if let (Some(response), Some(propstat)) = (response.as_mut(), propstat.take()) {
                            response.propstats.push(propstat);
                        }
                    }
                    (Some(Tag::Multistatus), Tag::Response) => {
                        if let Some(entry) = response.take().and_then(ResponseBuilder::finish) {
                            if entries.len() >= max_entries {
                                return Err(CloudError::TooLarge);
                            }
                            entries.push(entry);
                        }
                    }
                    _ => {}
                }
                text.clear();
            }
            Event::Text(content) => {
                if stack.last().is_some_and(|tag| tag.has_text()) {
                    text.push_str(&content.xml10_content());
                }
            }
            Event::CData(content) => {
                if stack.last().is_some_and(|tag| tag.has_text()) {
                    text.push_str(&content.xml10_content());
                }
            }
            Event::GeneralRef(reference) => {
                let resolved =
                    if let Some(c) = reference.resolve_char_ref().map_err(|_| CloudError::InvalidResponse("bad character reference"))? {
                        c.to_string()
                    } else {
                        resolve_predefined_entity(&reference).ok_or(CloudError::InvalidResponse("unknown entity"))?.to_owned()
                    };
                if stack.last().is_some_and(|tag| tag.has_text()) {
                    text.push_str(&resolved);
                }
            }
            Event::DocType(_) => return Err(CloudError::InvalidResponse("doctype not allowed")),
            Event::Eof => break,
            Event::Empty(_) | Event::Comment(_) | Event::Decl(_) | Event::PI(_) => {}
        }
        buf.clear();
    }
    if !saw_root || !stack.is_empty() {
        return Err(CloudError::InvalidResponse("not a multistatus"));
    }
    Ok(entries)
}

fn parse_status(line: &str) -> Option<u16> {
    line.split_whitespace().nth(1)?.parse().ok()
}

fn set_prop(props: &mut DavEntry, tag: Tag, value: &str) {
    if value.is_empty() {
        return;
    }
    match tag {
        Tag::ContentLength => props.size = value.parse().ok(),
        Tag::LastModified => props.modified_at = httpdate::parse_http_date(value).ok(),
        Tag::Etag => props.etag = Some(value.to_owned()),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, UNIX_EPOCH};

    use super::*;

    #[test]
    fn parses_prefixed_and_default_namespaces() {
        let body = br#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response><d:href>/dav/Backups/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getetag>"dir1"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
    <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
  </d:response>
  <d:response><d:href>/dav/Backups/a%20b&amp;c.txt</d:href>
    <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength>
      <d:getlastmodified>Sun, 06 Nov 1994 08:49:37 GMT</d:getlastmodified><d:getetag>&quot;e1&quot;</d:getetag><oc:size>9</oc:size></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>"#;
        let entries = parse(body, 10).unwrap();
        assert_eq!(
            entries[0],
            DavEntry { href: "/dav/Backups/".into(), is_dir: true, etag: Some("\"dir1\"".into()), ..DavEntry::default() }
        );
        assert_eq!(
            entries[1],
            DavEntry {
                href: "/dav/Backups/a%20b&c.txt".into(),
                is_dir: false,
                size: Some(42),
                modified_at: Some(UNIX_EPOCH + Duration::from_secs(784_111_777)),
                etag: Some("\"e1\"".into()),
            }
        );

        let default_ns = br#"<multistatus xmlns="DAV:"><response><href>https://x/a</href><propstat><prop><getetag>W/"1"</getetag></prop></propstat></response></multistatus>"#;
        assert_eq!(parse(default_ns, 10).unwrap()[0].etag.as_deref(), Some("W/\"1\""));
    }

    #[test]
    fn ignores_foreign_namespaces_with_dav_names() {
        let body = br#"<d:multistatus xmlns:d="DAV:" xmlns:x="urn:x"><d:response><d:href>/a</d:href><d:propstat><d:prop>
            <d:resourcetype><x:collection/></d:resourcetype><x:getetag>"no"</x:getetag></d:prop></d:propstat></d:response></d:multistatus>"#;
        assert_eq!(parse(body, 10).unwrap()[0], DavEntry { href: "/a".into(), ..DavEntry::default() });
    }

    #[test]
    fn rejects_hostile_or_malformed_input() {
        let doctype = br#"<?xml version="1.0"?><!DOCTYPE d [<!ENTITY x "xxxxxxxx">]><d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>"#;
        assert_eq!(parse(doctype, 10), Err(CloudError::InvalidResponse("doctype not allowed")));
        let entity = br#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>"#;
        assert_eq!(parse(entity, 10), Err(CloudError::InvalidResponse("unknown entity")));
        let deep = format!(r#"<d:multistatus xmlns:d="DAV:">{}{}</d:multistatus>"#, "<a>".repeat(40), "</a>".repeat(40));
        assert_eq!(parse(deep.as_bytes(), 10), Err(CloudError::InvalidResponse("xml too deep")));
        let many = format!(r#"<d:multistatus xmlns:d="DAV:">{}</d:multistatus>"#, "<d:response><d:href>/a</d:href></d:response>".repeat(3));
        assert_eq!(parse(many.as_bytes(), 2), Err(CloudError::TooLarge));
        assert!(parse(b"<html><body>login</body></html>", 10).is_err());
        assert!(parse(b"", 10).is_err());
        assert!(parse(br#"<d:multistatus xmlns:d="DAV:"><d:response>"#, 10).is_err());
    }
}
