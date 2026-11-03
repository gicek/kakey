//! Golden samples: responses in the style of real servers and the results the component should produce.
//! - `golden/multistatus.json`: WebDAV PROPFIND responses through `Client::list`.
//! - `golden/oauth.json`: Dropbox / OneDrive / Google Drive metadata, listing, download, upload, and error responses
//!   through the matching operations.

use std::collections::VecDeque;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cloudset::oauth::begin;
use cloudset::testing::oauth::{FakeProvider, GOOGLE_APP_FOLDER, MemoryCloud};
use cloudset::{
    AccessScope, Client, ClientConfig, Connection, Endpoint, Entry, HttpResponse, Method, OAuthClient, Precondition, ProviderKind,
    RemotePath, Revision, Transport, drive,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct Golden {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    endpoint: String,
    dir: String,
    body: String,
    expected: Vec<Expected>,
}

#[derive(Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Expected {
    path: String,
    is_dir: bool,
    size: Option<u64>,
    modified_at: Option<u64>,
    revision: Option<String>,
}

fn seconds(at: Option<SystemTime>) -> Option<u64> {
    at.map(|at| at.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO).as_secs())
}

impl From<Entry> for Expected {
    fn from(entry: Entry) -> Self {
        Self {
            path: entry.path.to_string(),
            is_dir: entry.is_dir,
            size: entry.size,
            modified_at: seconds(entry.modified_at),
            revision: entry.revision.map(|r| r.as_str().to_owned()),
        }
    }
}

#[test]
fn multistatus_golden() {
    let golden: Golden = serde_json::from_str(include_str!("../golden/multistatus.json")).unwrap();
    for case in golden.cases {
        let endpoint = Endpoint::parse(&case.endpoint, Transport::RequireHttps).unwrap();
        let client = Client::new(Connection::webdav(endpoint, "u".into(), "p".into()), ClientConfig::new("t"));
        let mut operation = client.list(RemotePath::parse(&case.dir).unwrap());
        let listed = drive(operation.as_mut(), |request| {
            assert_eq!((request.method, request.header("Depth")), (Method::Propfind, Some("1")), "{}", case.name);
            HttpResponse { status: 207, headers: Vec::new(), body: case.body.clone().into_bytes() }
        })
        .unwrap()
        .value;
        let actual: Vec<Expected> = listed.into_iter().map(Expected::from).collect();
        assert_eq!(actual, case.expected, "{}", case.name);
    }
}

#[derive(Deserialize)]
struct OAuthGolden {
    cases: Vec<OAuthCase>,
}

#[derive(Deserialize)]
struct OAuthCase {
    name: String,
    provider: String,
    operation: String,
    path: String,
    #[serde(default)]
    precondition: Option<serde_json::Value>,
    responses: Vec<Recorded>,
    expected: serde_json::Value,
}

#[derive(Deserialize)]
struct Recorded {
    status: u16,
    #[serde(default)]
    headers: Vec<(String, String)>,
    body: String,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Outcome {
    Entry(Option<Expected>),
    Entries(Vec<Expected>),
    File(ExpectedFile),
    Error(String),
}

#[derive(Debug, PartialEq, Deserialize)]
struct ExpectedFile {
    entry: Expected,
    data: String,
}

/// Signs in once against the in-memory server to get a real OAuth connection (the golden file only replaces the API
/// responses that follow).
fn oauth_connection(provider: FakeProvider) -> Connection {
    let kind = match provider {
        FakeProvider::Dropbox => ProviderKind::Dropbox,
        FakeProvider::OneDrive => ProviderKind::OneDrive,
        FakeProvider::GoogleDrive => ProviderKind::GoogleDrive,
    };
    let mut server = MemoryCloud::new(provider);
    let client = OAuthClient::new("client", "com.example.app.oauth://callback").with_folder_name(GOOGLE_APP_FOLDER);
    let authorization = begin(kind, AccessScope::AppFolder, client, &[7; 64]).unwrap();
    let callback = server.authorize(authorization.url());
    let mut operation = authorization.complete(&callback, &ClientConfig::new("t")).unwrap();
    drive(operation.as_mut(), |request| server.handle(request)).unwrap().value
}

fn precondition(value: Option<&serde_json::Value>) -> Precondition {
    match value {
        Some(serde_json::Value::String(text)) if text == "absent" => Precondition::Absent,
        Some(serde_json::Value::Object(map)) => Precondition::Matches(Revision::new(map["matches"].as_str().unwrap())),
        _ => Precondition::None,
    }
}

#[test]
fn oauth_golden() {
    let golden: OAuthGolden = serde_json::from_str(include_str!("../golden/oauth.json")).unwrap();
    let dropbox = oauth_connection(FakeProvider::Dropbox);
    let onedrive = oauth_connection(FakeProvider::OneDrive);
    let googledrive = oauth_connection(FakeProvider::GoogleDrive);
    for case in golden.cases {
        let connection = match case.provider.as_str() {
            "dropbox" => dropbox.clone(),
            "onedrive" => onedrive.clone(),
            "googledrive" => googledrive.clone(),
            other => panic!("unknown provider {other}"),
        };
        let client = Client::new(connection, ClientConfig::new("t"));
        let path = RemotePath::parse(&case.path).unwrap();
        let mut responses: VecDeque<HttpResponse> = case
            .responses
            .into_iter()
            .map(|recorded| HttpResponse { status: recorded.status, headers: recorded.headers, body: recorded.body.into_bytes() })
            .collect();
        let mut replay = |_| responses.pop_front().unwrap_or_else(|| panic!("{}: more requests than recorded responses", case.name));
        let actual = match case.operation.as_str() {
            "stat" => drive(client.stat(path).as_mut(), &mut replay).map(|done| Outcome::Entry(done.value.map(Expected::from))),
            "list" => drive(client.list(path).as_mut(), &mut replay)
                .map(|done| Outcome::Entries(done.value.into_iter().map(Expected::from).collect())),
            "read" => drive(client.read(path).as_mut(), &mut replay).map(|done| {
                let file = done.value.expect("file");
                Outcome::File(ExpectedFile { entry: file.entry.into(), data: String::from_utf8(file.data).unwrap() })
            }),
            "write" => drive(client.write(path, b"ciphertext".to_vec(), precondition(case.precondition.as_ref())).as_mut(), &mut replay)
                .map(|done| Outcome::Entry(Some(done.value.into()))),
            other => panic!("unknown operation {other}"),
        }
        .unwrap_or_else(|error| Outcome::Error(format!("{error:?}")));
        let expected: Outcome = serde_json::from_value(case.expected).unwrap_or_else(|error| panic!("{}: {error}", case.name));
        assert_eq!(actual, expected, "{}", case.name);
        assert!(responses.is_empty(), "{}: recorded responses were not all used", case.name);
    }
}
