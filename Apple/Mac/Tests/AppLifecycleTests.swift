import AppKit
import XCTest

@testable import Kakey

final class AppLifecycleTests: XCTestCase {
    @MainActor
    func testApplicationQuitIsImmediateEvenWithPresentedSheets() {
        let delegate = KakeyAppDelegate()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
