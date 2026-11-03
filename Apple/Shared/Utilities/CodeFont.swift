import CoreText
import SwiftUI

/// Font for verification code digits: Atkinson Hyperlegible Mono (Braille Institute, OFL 1.1).
/// Designed for low-vision legibility, with clearly distinct glyphs for 0/O, 1/l, 3/8, 6/8; monospaced, so digits do not
/// shift as the code changes. Used only for the code itself; secrets, links, etc. use the system monospaced font. The font
/// file ships in the app and is registered with this process on first use, falling back to the system monospaced font if
/// registration fails.
enum CodeFont {
    static let familyName = "Atkinson Hyperlegible Mono"

    static let isAvailable: Bool = {
        if let url = AppResourceBundle.bundle.url(forResource: "AtkinsonHyperlegibleMono-Variable", withExtension: "ttf") {
            // Returns an error if already registered (e.g. repeated calls in the test host); availability is checked below.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let font = CTFontCreateWithName(familyName as CFString, 12, nil)
        return CTFontCopyFamilyName(font) as String == familyName
    }()

    /// - Parameter textStyle: On iOS, the text style to scale with Dynamic Type; Mac uses a fixed size.
    static func font(size: CGFloat, weight: Font.Weight = .semibold, relativeTo textStyle: Font.TextStyle? = nil) -> Font {
        guard isAvailable else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        let base = textStyle.map { Font.custom(familyName, size: size, relativeTo: $0) } ?? Font.custom(familyName, fixedSize: size)
        return base.weight(weight)
    }
}
