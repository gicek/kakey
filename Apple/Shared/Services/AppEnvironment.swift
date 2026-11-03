import Foundation

enum AppEnvironment {
    /// Whether this is the test host (`Test` configuration, bundle ID ending in `.testhost`). The test host keeps the vault in a
    /// temporary directory, installs no menu bar icon and uses in-memory key storage, so it never touches real user data.
    static let isTestHost: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".testhost") ?? false
}
