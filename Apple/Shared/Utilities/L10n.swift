import Foundation

/// In-app language preference. Display names follow Apple HIG
/// (each language is shown in its own orthography).
enum LanguageMode: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    /// BCP-47 code used for `.lproj` lookup; `nil` means follow system.
    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        }
    }

    /// Title shown in the language picker (not re-translated into other languages).
    var pickerTitle: String {
        switch self {
        case .system:
            L10n.tr("System")
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"  // i18n-guard: allow language names are written in their own language
        case .traditionalChinese:
            "繁體中文"  // i18n-guard: allow language names are written in their own language
        }
    }
}

/// Runtime localization: English source strings are the keys (`Localizable.xcstrings`, source language `en`);
/// the catalog compiles into per-language `.lproj` folders, and the selected one is passed explicitly as the bundle.
enum L10n {
    /// Languages shipped with the app. Order is not preference order.
    static let supportedLanguageCodes = ["en", "zh-Hans", "zh-Hant"]
    /// Used when the preference is “System” but none of the supported languages match.
    static let fallbackLanguageCode = "en"

    /// Bundle and locale for the current language. Read from any thread (error text in background tasks), so lock-protected.
    private static let current = Locked<(bundle: Bundle, locale: Locale)>(
        (AppResourceBundle.bundle, Locale(identifier: fallbackLanguageCode))
    )

    static var bundle: Bundle {
        current.value.bundle
    }

    static var locale: Locale {
        current.value.locale
    }

    static func apply(languageMode: LanguageMode) {
        let resolvedCode = resolvedLanguageCode(for: languageMode)
        let languageBundle =
            localizationBundle(for: resolvedCode)
            ?? localizationBundle(for: fallbackLanguageCode)
            ?? AppResourceBundle.bundle
        current.value = (languageBundle, Locale(identifier: resolvedCode))
    }

    /// Resolves the language code for the given mode.
    /// - System: best match among supported codes from `Locale.preferredLanguages`.
    /// - No match: falls back to English.
    static func resolvedLanguageCode(for languageMode: LanguageMode) -> String {
        if let code = languageMode.localeIdentifier {
            return code
        }

        let matched = Bundle.preferredLocalizations(
            from: supportedLanguageCodes,
            forPreferences: Locale.preferredLanguages
        )
        return matched.first ?? fallbackLanguageCode
    }

    /// Resolves `.lproj` even when SwiftPM lowercases folder names (e.g. `zh-hans`).
    private static func localizationBundle(for code: String) -> Bundle? {
        let resourceBundle = AppResourceBundle.bundle
        if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
            let bundle = Bundle(path: path)
        {
            return bundle
        }

        let needle = "\(code).lproj".lowercased()
        guard let resourceURL = resourceBundle.resourceURL,
            let contents = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }

        return
            contents
            .first { $0.lastPathComponent.lowercased() == needle }
            .flatMap { Bundle(url: $0) }
    }

    static func tr(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: bundle)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, bundle: bundle, locale: locale, arguments: arguments)
    }

    /// Plural variations and positional placeholders come from the compiled String Catalog; the template is taken
    /// straight from the bundle so its plural rules survive into `String(format:)`.
    static func format(_ key: String, bundle: Bundle, locale: Locale, arguments: [CVarArg]) -> String {
        let template = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: template, locale: locale, arguments: arguments)
    }
}
