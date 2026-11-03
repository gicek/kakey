import XCTest

@testable import Kakey

/// Regression guard: static resources that view bodies read frequently must be cached singletons.
/// Creating a new LAContext (synchronous XPC) and re-reading the icon from disk on every body evaluation pumped the run loop and
/// caused an endless rebuild loop on the main thread (CPU pegged, memory growing).
final class AssetCacheTests: XCTestCase {
    @MainActor
    func testAppIconIsCachedSingleton() {
        XCTAssertTrue(KakeyAssets.appIcon === KakeyAssets.appIcon)
    }

    @MainActor
    func testMenuBarIconIsCachedSingleton() {
        XCTAssertTrue(KakeyAssets.menuBarIcon === KakeyAssets.menuBarIcon)
    }
}
