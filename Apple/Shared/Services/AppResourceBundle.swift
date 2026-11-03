import Foundation

/// Single entry point for app resources. All resources (.lproj, Assets.car, etc.) are compiled into the main bundle; this
/// indirection keeps callers such as `L10n` off `Bundle.main`, so moving resources later (e.g. into a framework) only
/// changes this file.
enum AppResourceBundle {
    static let bundle: Bundle = .main
}
