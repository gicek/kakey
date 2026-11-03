#if DEBUG
    import Foundation

    /// Demo vault for screenshots and UI acceptance checks (Debug builds only).
    ///
    /// With the launch argument `-KakeyDemoVault YES`, uses a separate vault in a temporary directory (real data is never touched),
    /// writes sample accounts, and unlocks automatically with a fixed demo password; `-KakeyDemoLocked YES` stops at the lock screen.
    enum DemoVault {
        static let password = "demo-password-2026"

        static var isRequested: Bool {
            UserDefaults.standard.bool(forKey: "KakeyDemoVault")
        }

        /// otpauth links for the confirmation screen demo (including one line that cannot be parsed).
        static let sampleLinks = """
            otpauth://totp/Notion:alex@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Notion
            otpauth://totp/Figma:design@kakey.app?secret=GEZDGNBVGY3TQOJQ&issuer=Figma
            otpauth://hotp/Legacy:old?secret=MZXW6YTBOI&counter=3
            """

        static func prepareIfRequested() {
            guard isRequested else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KakeyDemo", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            VaultPersistenceService.vaultURLOverride = directory.appendingPathComponent("vault.json")
            let created = Date().addingTimeInterval(-86_400 * 12)
            // -KakeyDemoEmpty YES: empty directory, stops at first-run onboarding
            if UserDefaults.standard.bool(forKey: "KakeyDemoEmpty") { return }
            let accounts = [
                Account(issuer: "GitHub", username: "alex@example.com", secret: "JBSWY3DPEHPK3PXP", createdAt: created),
                Account(issuer: "Google", username: "alex.chen@gmail.com", secret: "GEZDGNBVGY3TQOJQ", createdAt: created),
                Account(issuer: "Apple", username: "alex@icloud.com", secret: "MZXW6YTBOI", createdAt: created),
                Account(
                    issuer: "Cloudflare", username: "ops@kakey.app", secret: "KRSXG5CTMVRXEZLU", algorithm: .sha256, createdAt: created),
                Account(issuer: "Amazon Web Services", username: "root", secret: "NBSWY3DPO5XXE3DE", digits: 8, createdAt: created),
                Account(issuer: "Microsoft", username: "alex@outlook.com", secret: "ORSXG5BAOJSWG33S", createdAt: created),
                Account(issuer: "Dropbox", username: "alex@example.com", secret: "MFRGGZDFMZTWQ2LK", createdAt: created),
                Account(issuer: "Stripe", username: "billing@kakey.app", secret: "GAYTEMZUGU3DOOBZ", period: 60, createdAt: Date()),
            ]
            let categories = [
                AccountCategory(id: UUID(), name: L10n.tr("Favorites"), accountIDs: [accounts[0].id, accounts[1].id]),
                AccountCategory(
                    id: UUID(), name: L10n.tr("Work"), accountIDs: [accounts[3].id, accounts[4].id, accounts[7].id, accounts[0].id]),
                AccountCategory(id: UUID(), name: L10n.tr("Personal"), accountIDs: [accounts[2].id, accounts[5].id, accounts[6].id]),
            ]
            _ = try? VaultPersistenceService.save(VaultContents(accounts: accounts, categories: categories), password: password)
        }

        @MainActor
        static func unlockIfRequested(_ store: MobileVaultStore) async {
            guard isRequested, !UserDefaults.standard.bool(forKey: "KakeyDemoLocked"), store.phase == .locked else { return }
            await store.unlock(password: password)
        }
    }
#endif
