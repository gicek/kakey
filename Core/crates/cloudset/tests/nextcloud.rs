//! Nextcloud Login Flow v2 and app password revocation, against a server scripted with the response formats from the
//! official docs.

use cloudset::nextcloud::{begin_login, poll_login};
use cloudset::{Client, ClientConfig, CloudError, Endpoint, HttpRequest, HttpResponse, Method, ProviderKind, Transport, drive};

fn config() -> ClientConfig {
    ClientConfig::new("ExampleApp (Mac)")
}

fn server() -> Endpoint {
    Endpoint::parse("https://cloud.example.com/nextcloud", Transport::RequireHttps).unwrap()
}

fn json(status: u16, body: &str) -> HttpResponse {
    HttpResponse { status, headers: vec![("Content-Type".into(), "application/json".into())], body: body.as_bytes().to_vec() }
}

const START: &str = r#"{"poll":{"token":"mQUYQdffOSAMJYtm8pVpkOsVqXt5hglnuSpO5EMbgJMNEPFGaiDe8OUjvrJ2WcYcBSLgqynu9jaPFvZHMl83ybMvp6aDIDARjTFIBpRWod6p32fL9LIpIStvc6k8Wrs1","endpoint":"https://cloud.example.com/nextcloud/login/v2/poll"},"login":"https://cloud.example.com/nextcloud/login/v2/flow/guyjGtcKPTKCi4epIRIupIexgJ8wNInMFSfHabACRPZUkmEaWZSM54bFkFuzWksbps7jmTFQjj2"}"#;

#[test]
fn login_flow_yields_a_webdav_connection() {
    let mut requests: Vec<HttpRequest> = Vec::new();
    let flow = drive(begin_login(&server(), &config()).as_mut(), |request| {
        requests.push(request);
        json(200, START)
    })
    .unwrap()
    .value;
    assert_eq!((requests[0].method, requests[0].url.as_str()), (Method::Post, "https://cloud.example.com/nextcloud/index.php/login/v2"));
    assert_eq!(requests[0].header("User-Agent"), Some("ExampleApp (Mac)"));
    assert!(flow.login_url.starts_with("https://cloud.example.com/nextcloud/login/v2/flow/"));
    assert!(!format!("{:?}", flow.poll).contains("mQUYQ"), "Debug must not print the token");

    let pending = drive(poll_login(&flow.poll, &config()).as_mut(), |request| {
        assert_eq!(request.url, "https://cloud.example.com/nextcloud/login/v2/poll");
        assert!(String::from_utf8(request.body).unwrap().starts_with("token=mQUYQ"));
        HttpResponse::new(404)
    })
    .unwrap()
    .value;
    assert!(pending.is_none(), "the user has not authorized yet");

    let mut seen = Vec::new();
    let connection = drive(poll_login(&flow.poll, &config()).as_mut(), |request| {
        seen.push(request.clone());
        if request.url.ends_with("/login/v2/poll") {
            json(200, r#"{"server":"https://cloud.example.com/nextcloud","loginName":"alice@example.com","appPassword":"yKTVA4zgxjfivy52WqD8kW3M2pKGQr6srmUXMipRdunxjPFripJn0GMfmtNOqOolYSuJ6sCN"}"#)
        } else {
            assert_eq!(request.url, "https://cloud.example.com/nextcloud/ocs/v2.php/cloud/user?format=json");
            assert_eq!(request.header("OCS-APIRequest"), Some("true"));
            assert!(request.header("Authorization").unwrap().starts_with("Basic "));
            json(200, r#"{"ocs":{"meta":{"status":"ok","statuscode":200},"data":{"id":"alice@example.com","displayname":"Alice"}}}"#)
        }
    })
    .unwrap()
    .value
    .unwrap();
    assert_eq!(seen.len(), 2);
    assert_eq!(connection.provider(), ProviderKind::Nextcloud);
    assert_eq!(connection.username(), "alice@example.com");
    assert_eq!(connection.endpoint().unwrap().as_str(), "https://cloud.example.com/nextcloud/remote.php/dav/files/alice@example.com/");
    assert_eq!(connection.server(), Some(&server()));

    let mut revoked = Vec::new();
    drive(Client::new(connection, config()).revoke().as_mut(), |request| {
        revoked.push(request);
        HttpResponse::new(401)
    })
    .unwrap();
    assert_eq!(
        (revoked[0].method, revoked[0].url.as_str()),
        (Method::Delete, "https://cloud.example.com/nextcloud/ocs/v2.php/core/apppassword")
    );
    assert_eq!(revoked[0].header("OCS-APIRequest"), Some("true"));
}

#[test]
fn refuses_other_origins() {
    let foreign_poll = START.replace("https://cloud.example.com/nextcloud/login/v2/poll", "https://evil.example/poll");
    assert_eq!(drive(begin_login(&server(), &config()).as_mut(), |_| json(200, &foreign_poll)).err(), Some(CloudError::InsecureRedirect));
    let foreign_login = START.replace("https://cloud.example.com/nextcloud/login/v2/flow/", "http://cloud.example.com/flow/");
    assert_eq!(drive(begin_login(&server(), &config()).as_mut(), |_| json(200, &foreign_login)).err(), Some(CloudError::InsecureRedirect));

    let flow = drive(begin_login(&server(), &config()).as_mut(), |_| json(200, START)).unwrap().value;
    let result = drive(poll_login(&flow.poll, &config()).as_mut(), |_| {
        json(200, r#"{"server":"https://evil.example","loginName":"a","appPassword":"b"}"#)
    });
    assert_eq!(result.err(), Some(CloudError::InsecureRedirect));
}

#[test]
fn reports_server_errors() {
    assert_eq!(drive(begin_login(&server(), &config()).as_mut(), |_| HttpResponse::new(404)).err(), Some(CloudError::NotFound));
    assert!(matches!(
        drive(begin_login(&server(), &config()).as_mut(), |_| json(200, "<html>")).err(),
        Some(CloudError::InvalidResponse(_))
    ));
}
