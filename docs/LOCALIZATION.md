# Kakey Localization

> The localization contract, writing rules, and glossary shared by all three platforms. Platform implementation details are in each platform's TECHNICAL document.

## Languages and Sources

- Supported: `en` (source), `zh-Hans`, and `zh-Hant` (Taiwan usage), matching `LANGS` in the Makefile. On first launch the app follows the system language and falls back to English; switching in the app takes effect immediately.
- Single sources: `Apple/Shared/Resources/Localizable.xcstrings` (UI strings, shared by all three platforms) and `InfoPlist.xcstrings` (Apple permission usage descriptions; Info.plist holds the English text).
- At build time, `scripts/android_strings.py` generates `strings.xml` for `values`, `values-b+zh+Hans`, and `values-b+zh+Hant` from the String Catalog into `Build/`. They aren't committed.
  - Resource names derive from keys (for example `err.vault.corrupt` → `err_vault_corrupt`, `Delete “%@”?` → `delete_x`); the rules are in the script, and `--print-names` lists every name.
  - Placeholders become Android syntax (`%@` → `%s`, `%lld` → `%d`), and English plural variations become `<plurals>`.
  - Android-only strings live in the same catalog (with `comment` set to `Android`). The app language list comes from `generateLocaleConfig`.

## Writing Rules

- **The English source string is the key**: `L10n.tr("Add Account")`, `L10n.format("Imported %lld accounts", count)`. Android uses the derived `R.string` / `R.plurals`.
- **Exceptions that keep semantic keys** (marked with a `comment` in the catalog): core error codes (`err.vault.*`, `err.import.*`, `err.category.*`, `otp.err.*`), because the core returns only the key; and source keys written into backup history (`icloud.hist.*`, `icloud.manual_backup`), because renaming them would leave existing entries unreadable.
- When the same English needs different translations in different contexts, change the English wording to tell them apart (for example, the Dock option uses `Never Show`). Don't keep two translations for one English string.
- Don't concatenate sentences. With two or more arguments, use positional placeholders (`%1$@`, `%2$lld`); numeric arguments use `%lld`. English counts use plural variations (one / other), with substitutions when two counts vary independently. Chinese has no plural forms.
- Fixed text that needs no translation (brand names, sample links, `·`, digit options) uses `Text(verbatim:)` and stays out of the catalog. In Chinese, put a space between Latin words (Face ID, iCloud, QR) and Chinese characters.
- Don't use system controls that bring their own text (`EditButton`, `ContentUnavailableView.search`, a `confirmationDialog` without an explicit cancel button). They follow the system language, so switching languages in the app would mix two languages. Format dates with `Date.FormatStyle(..., locale: L10n.locale)`. The system search bar's Cancel button and the system photo and file pickers can't be replaced.
- Reason strings for biometric or system password prompts have no ending punctuation. macOS embeds them in "Kakey is trying to …", so the English is a lowercase verb phrase without "with Touch ID". iOS shows them on their own, so the English starts with a capital letter. Each platform has its own keys.
- Strings never end with an ellipsis.

## Language Options

| Option | Stored value | Display name |
|---|---|---|
| System | `system` | Localized |
| English | `en` | English |
| Simplified Chinese | `zh-Hans` | 简体中文 |
| Traditional Chinese | `zh-Hant` | 繁體中文 |

Each language's display name is written in that language, and the matching source line is marked `// i18n-guard: allow`.

## Adding a Language

The language list isn't generated from one place yet. A new language (BCP-47 code `xx`) touches:

- **Translations**: every entry in `Localizable.xcstrings` and `InfoPlist.xcstrings`, and a column in the glossary below.
- **Build and guard**: `LANGS` in the `Makefile`; `LANG_DIRS` in `scripts/android_strings.py` (Android resource directory, such as `values-b+xx`).
- **Apple**: `CFBundleLocalizations` in `Apple/Mac/Info.plist` and in `Apple/project.yml` for iOS (then `make project`); `LanguageMode` and `supportedLanguageCodes` in `Apple/Shared/Utilities/L10n.swift`.
- **Android**: `LanguageMode` in `domain/Preferences.kt` and its display name in `ui/settings/SettingsScreen.kt`. The per-app language list comes from the generated resources.
- **Alfred workflow**: `LANGUAGES` in `Apple/Mac/scripts/build-alfred-workflow.py`, `SUPPORTED_LANGUAGES` in `scripts/alfred/search.py`, and the language match in `scripts/alfred/reveal.sh`.
- **Screenshots**: the language lists in `Apple/iOS/scripts/screenshots.sh` and `Android/scripts/screenshots.sh`.

The display name goes in the language itself with `// i18n-guard: allow`. Run `make test`; the guard reports any missing translation.

## Guard

`make test-mac`, `test-ios`, and `test-android` run `scripts/i18n-guard.py` first; any failure fails the tests. All three platforms check the same String Catalog (`--catalog`, default `Apple/Shared/Resources`):

1. **Source scan**: A CJK character or full-width punctuation in a Swift or Kotlin string literal fails the check. To allow an exception, add `// i18n-guard: allow <reason>` on the same line.
2. **Complete translations**: Every key has all three languages, no undeclared languages, and no trailing ellipsis. Strings with several arguments use positional placeholders that match across languages. No orphan keys (keys that no Swift, Kotlin, or Rust source references; Kotlin is matched by derived resource name).
3. **Keys resolve**: On Apple, every literal key in `L10n.tr` / `L10n.format` / `Text("…")` and similar calls exists in the catalog. On Android, every `R.string.*` / `R.plurals.*` maps back to a catalog key.

`--min-files` is 40 for Mac, 25 for iOS, and 25 for Android, to catch broken path resolution; adjust it when the source size changes. Not covered by the guard, so check manually: go through the UI in the language with the longest strings (English), and check that Traditional Chinese wording reads naturally.

## Glossary

| Concept | English | Simplified Chinese (zh-Hans) | Traditional Chinese (zh-Hant) |
|---|---|---|---|
| Account | account | 账户 | 帳號 |
| Category | category | 分类 | 分類 |
| Code | code / verification code | 验证码 | 驗證碼 |
| TOTP secret | secret / setup key | 密钥 | 密鑰 |
| Vault | vault | 保险库 | 保險庫 |
| Vault key (unlock material) | vault key | 保险库密钥 | 保險庫金鑰 |
| Master password | master password | 主密码 | 主密碼 |
| QR code | QR code | 二维码 | QR 碼 |
| Export / import | export / import | 导出 / 导入 | 匯出／匯入 |
| Back up / restore | back up / restore | 备份 / 恢复 | 備份／復原 |
| Camera | camera | 摄像头 for the device; 相机 for the permission (matches System Settings) | 相機 |
| Screen Recording | Screen Recording | 屏幕录制 | 螢幕錄製 |
| Settings | Settings | 设置 | 設定 |
| File | file | 文件 | 檔案 |
| Face ID | Face ID | 面容 ID | Face ID |
| Keychain | Keychain | 钥匙串 | 鑰匙圈 |
| My Drive (Google Drive root; uses Google's official translations) | My Drive | 我的云端硬盘 | 我的雲端硬碟 |
