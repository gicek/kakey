import XCTest

@testable import Kakey

final class AppResourceBundleTests: XCTestCase {
    func testResourceBundleResolvesLocalizationsWithoutBundleModule() {
        let bundle = AppResourceBundle.bundle

        XCTAssertNotNil(bundle.resourceURL)
        XCTAssertNotNil(
            bundle.path(forResource: "en", ofType: "lproj")
                ?? bundle.resourceURL.flatMap { resourceURL in
                    try? FileManager.default.contentsOfDirectory(
                        at: resourceURL,
                        includingPropertiesForKeys: nil
                    )
                    .first { $0.lastPathComponent.lowercased() == "en.lproj" }?
                    .path
                }
        )
    }
}
