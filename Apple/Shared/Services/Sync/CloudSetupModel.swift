import Foundation
import Observation

/// The steps for connecting cloud storage, shared by Mac and iOS (each draws its own UI): form (for OAuth, choosing the
/// access scope) → sign in → choose remote folder → done.
///
/// A plaintext `http://` address stops for user confirmation first (docs/SECURITY.md); the connection is created
/// only after that. The connection blob stays in memory, and `finish` hands it to the caller to save. With OAuth "Kakey app
/// folder" access there is no folder step: the app folder is the backup folder, so sign-in completes directly (`submit`
/// returns the result).
@MainActor
@Observable
final class CloudSetupModel {
    enum Step: Equatable {
        case form
        /// Nextcloud: the sign-in page is open in the browser, waiting for the user to authorize.
        case waitingForBrowser(URL)
        case chooseFolder
    }

    /// OAuth connection progress: sign in and authorize → connect account → check for backup. The UI draws the three step
    /// descriptions as progress items. Getting from the browser redirect to a working connection takes a few seconds (token
    /// exchange, folder listing, link check), so every step must be visible rather than looking stuck.
    enum ConnectPhase: Int, Comparable, CaseIterable {
        case signingIn
        case connecting
        case checkingBackup

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How one of the three steps looks: before sign-in, all are plain descriptions (upcoming); once started, finished steps
    /// get a checkmark, the current one a spinner, and later ones are dimmed.
    enum ConnectStepState: Equatable {
        case upcoming, done, active, pending

        init(step index: Int, phase: ConnectPhase?) {
            guard let phase else {
                self = .upcoming
                return
            }
            self = index < phase.rawValue ? .done : index == phase.rawValue ? .active : .pending
        }
    }

    /// Whether the connection is for backup (setting or changing the location) or first-time restore; the title, text,
    /// third step and folder rules differ accordingly. Restore is read-only: no suggested or new folders, and only folders
    /// that already hold a backup can be chosen.
    enum Purpose {
        case backup
        case restore
    }

    /// The form submitted for a WebDAV / Nextcloud connection. During first-time restore it is kept in memory with the
    /// authorization (`RestoreCloudConnections`) and prefilled when chosen again, so falling back to the form after a
    /// transient network or server error needs no retyping. The plaintext HTTP confirmation and trusted certificate are
    /// carried along.
    struct FormInput: Equatable {
        var address: String
        var username = ""
        var password = ""
        var insecureConfirmed = false
        var trustedCertificate: Data?
    }

    /// Handed to the caller when done: the connection blob and the location to save.
    struct Result: Equatable {
        var connection: Data
        var location: CloudLocation
    }

    let provider: CloudProvider
    let purpose: Purpose
    var address = ""
    var username = ""
    var password = ""
    /// OAuth access scope (docs/TECHNICAL.md); defaults to the app folder only.
    var access: CoreCloudAccess = .appFolder
    private(set) var step: Step = .form
    private(set) var isWorking = false
    /// The current OAuth step; nil before starting or after returning to the form.
    private(set) var phase: ConnectPhase?
    var errorMessage: String?
    /// The address is `http://` and needs user confirmation before continuing.
    private(set) var needsInsecureConfirmation = false
    private var insecureConfirmed = false
    /// The system does not trust the server certificate (docs/SECURITY.md): the leaf certificate fingerprint for
    /// the user to verify. Once confirmed, the connection is retried with it and only this certificate is trusted from then
    /// on.
    private(set) var untrustedCertificate: Data?
    private var trustedCertificate: Data?

    private(set) var currentPath = ""
    private(set) var folders: [CoreCloudEntry] = []
    /// Whether the current folder can be the backup folder: empty (ignoring hidden files) or already holding a Kakey backup.
    /// The rules live in the core.
    private(set) var canUseCurrentFolder = false
    /// Whether the current folder holds a Kakey backup (rules in the core); restore can only choose such folders.
    private(set) var currentFolderHasBackup = false
    /// The folder holds only a backup and no subfolders: the folder screen shows "backup found" in the middle instead of a
    /// single row (same on all three platforms).
    var currentFolderHasOnlyBackup: Bool { currentFolderHasBackup && folders.isEmpty }
    /// The connection blob after sign-in (in memory); tokens refreshed while browsing are written back here.
    private let connections = InMemoryCloudConnectionStore()
    private var pollTask: Task<Void, Never>?
    private var pollLogin: CoreNextcloudLogin?
    private var pollDeadline: ContinuousClock.Instant?
    /// The form at the start of Nextcloud sign-in, passed to `onConnected` when authorization completes and folder selection
    /// begins (no password).
    private var pollForm: FormInput?
    /// Operations started by the screen (`perform`), cancelled when the connection screen closes.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Nextcloud browser authorization: true while the immediate check after returning to the app is running, so the UI
    /// shows "finishing sign-in" instead of still waiting.
    private(set) var isCheckingSignIn = false
    /// The connection already authorized for the chosen access scope during first-time restore (set by
    /// `RestoreCloudConnections.prepare`); "Sign In" uses it to go straight to folder selection.
    var savedConnection: ((CoreCloudAccess) -> (location: CloudLocation, connection: Data)?)?
    /// Called when a connection is obtained and folder selection begins (set by `RestoreCloudConnections.track`), so the
    /// authorization is recorded right away instead of only when a folder with a backup is chosen. The third argument is
    /// the form used for this connection; nil when reusing a connection or for OAuth.
    var onConnected: ((CloudLocation, Data, FormInput?) -> Void)?

    private let service: CloudSetupService
    private let openURL: (URL) -> Void

    /// Sign-in polling interval and maximum wait.
    static let pollInterval: Duration = .seconds(2)
    static let pollTimeout: Duration = .seconds(600)

    init(provider: CloudProvider, purpose: Purpose = .backup, service: CloudSetupService, openURL: @escaping (URL) -> Void) {
        self.provider = provider
        self.purpose = purpose
        self.service = service
        self.openURL = openURL
    }

    var canSubmit: Bool {
        let hasAddress = !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch provider {
        case .webDAV: return hasAddress && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isWorking
        case .nextcloud: return hasAddress && !isWorking
        case .dropbox, .oneDrive, .googleDrive: return !isWorking
        }
    }

    /// Whether full-drive access is offered: the matching developer key is configured.
    var offersFullAccess: Bool { provider.fullAccessAvailable }

    /// The address with a scheme filled in (rules in the core): without `scheme://`, an IP gets `http://` and a domain
    /// gets `https://`.
    private var completedAddress: String {
        coreCloudCompleteAddress(input: address)
    }

    /// Whether the completed address is plaintext HTTP (scheme check only; full validation is in the core), so entering
    /// just an IP also requires confirmation.
    private var addressIsInsecure: Bool {
        completedAddress.lowercased().hasPrefix("http://")
    }

    /// Submits the form. WebDAV verifies the connection and moves to folder selection; Nextcloud opens the browser and
    /// starts polling; OAuth opens the system sign-in page, then completes and returns the result for app-folder access or
    /// moves to folder selection for full-drive access.
    @discardableResult
    func submit() async -> Result? {
        errorMessage = nil
        if provider.usesOAuth {
            if let saved = savedConnection?(access) {
                // App folder already authorized: return it and look for the backup directly, as on first sign-in, without
                // listing folders.
                if saved.location.isAppFolder { return Result(connection: saved.connection, location: saved.location) }
                await resume(with: saved.location, connection: saved.connection)
                return nil
            }
            return await signIn()
        }
        if addressIsInsecure, !insecureConfirmed {
            needsInsecureConfirmation = true
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        let url = completedAddress
        do {
            switch provider {
            case .webDAV:
                let connection = try await service.webDAVConnection(
                    url: url, username: username.trimmingCharacters(in: .whitespaces), password: password,
                    allowInsecureHTTP: insecureConfirmed, trustedCertificate: trustedCertificate)
                let form = formInput
                password = ""
                await enterFolderStep(with: connection, form: form)
            case .nextcloud:
                let (loginURL, login) = try await service.beginNextcloudLogin(
                    server: url, allowInsecureHTTP: insecureConfirmed, trustedCertificate: trustedCertificate)
                step = .waitingForBrowser(loginURL)
                openURL(loginURL)
                pollForm = formInput
                startPolling(login)
            case .dropbox, .oneDrive, .googleDrive:
                break  // Already routed to signIn() above.
            }
        } catch CloudCertificateError.untrusted(let fingerprint) {
            untrustedCertificate = fingerprint
        } catch {
            errorMessage = Self.message(for: error)
        }
        return nil
    }

    private func signIn() async -> Result? {
        isWorking = true
        phase = .signingIn
        defer { isWorking = false }
        do {
            let connection = try await service.signIn(to: provider, access: access) { [weak self] in self?.phase = .connecting }
            guard access == .appFolder else {
                await enterFolderStep(with: connection)
                return nil
            }
            // The app folder belongs to Kakey alone, so use its root directly; if it unexpectedly holds other files, fall
            // back to folder selection, with the same rules as other backends.
            try connections.save(connection)
            await load("")
            guard errorMessage == nil else {
                phase = nil
                return nil
            }
            if canUseCurrentFolder { return try finish() }
            phase = nil
            step = .chooseFolder
            return nil
        } catch is CancellationError {
            phase = nil
            return nil
        } catch {
            phase = nil
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Hands the result to the caller to activate (link check + first sync, or the first-time restore download). Meanwhile
    /// shows "checking for backup" and disables actions; on failure, stays on this screen with the reason. Returns whether
    /// it succeeded (on success, the caller leaves this screen).
    func complete(_ result: Result, using configure: @escaping (Result) async -> String?) async -> Bool {
        errorMessage = nil
        isWorking = true
        if provider.usesOAuth { phase = .checkingBackup }
        defer { isWorking = false }
        // Activation / restore is not cancelled when the connection screen closes: cancelling midway would leave a
        // half-finished state, so the caller finishes it and shows the result.
        let configured = Task { await configure(result) }
        if let message = await configured.value {
            errorMessage = message
            phase = nil
            return false
        }
        return true
    }

    func confirmInsecure() async {
        insecureConfirmed = true
        needsInsecureConfirmation = false
        _ = await submit()
    }

    func declineInsecure() {
        needsInsecureConfirmation = false
    }

    /// The user verified the fingerprint and chose to trust this certificate (docs/SECURITY.md): reconnect with
    /// it. The fingerprint is passed in by the confirmation UI rather than read from `untrustedCertificate`, because an iOS
    /// alert clears that when it dismisses, before the button's async task runs.
    func confirmCertificate(_ fingerprint: Data) async {
        trustedCertificate = fingerprint
        untrustedCertificate = nil
        _ = await submit()
    }

    func declineCertificate() {
        untrustedCertificate = nil
    }

    private var formInput: FormInput {
        FormInput(
            address: address, username: username, password: password,
            insecureConfirmed: insecureConfirmed, trustedCertificate: trustedCertificate)
    }

    /// Prefills the form from the previous connection during first-time restore (called by
    /// `RestoreCloudConnections.prepare`).
    func prefill(_ form: FormInput) {
        address = form.address
        username = form.username
        password = form.password
        insecureConfirmed = form.insecureConfirmed
        trustedCertificate = form.trustedCertificate
    }

    /// A changed address requires confirming plaintext HTTP and the server certificate again.
    func addressDidChange() {
        insecureConfirmed = false
        trustedCertificate = nil
    }

    /// Display form of a certificate fingerprint: uppercase hex with colon-separated bytes, matching how NAS admin pages and
    /// browser certificate details show it.
    static func formattedFingerprint(_ fingerprint: Data) -> String {
        fingerprint.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Returns to the form (cancelling browser sign-in or switching accounts).
    func backToForm() {
        stopPolling()
        connections.remove()
        folders = []
        currentPath = ""
        phase = nil
        step = .form
    }

    /// Runs an operation started by the screen (connecting, listing folders, etc.). Closing the screen (`cancel`) cancels
    /// it, which makes URLSession abort the request instead of running in the background until timeout (with Wi-Fi off, iOS
    /// keeps trying to connect and takes 30 seconds to report an error).
    func perform(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    /// Closes the connection screen: stops Nextcloud polling and cancels running operations.
    func cancel() {
        stopPolling()
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }

    /// Called when returning to the app: the user has most likely authorized in the browser, so check immediately instead of
    /// waiting for the next poll.
    func checkSignInNow() {
        guard case .waitingForBrowser = step else { return }
        runPolling(immediately: true)
    }

    // MARK: - Choosing the remote folder

    /// Choosing an already authorized provider again during first-time restore: reuses that connection and goes straight to
    /// folder selection (the previously chosen folder, or the root for the app folder) without signing in again. If the
    /// connection is no longer valid (e.g. authorization revoked on the web) or there is a transient network or server
    /// error, returns to the form with the reason; `prefill` has already filled in the previous values, and the new
    /// connection replaces the old one.
    func resume(with location: CloudLocation, connection: Data) async {
        access = location.isAppFolder ? .appFolder : .full
        await enterFolderStep(with: connection, at: location.folder)
        if errorMessage != nil { backToForm() }
    }

    /// The chosen location has no backup during first-time restore and the user taps "Choose Folder". A connection with
    /// folder choice goes straight back to folder selection, starting at the parent of the previous folder, without signing
    /// in again; with only app-folder authorization, "any folder" is preselected and the form waits for a new sign-in.
    func chooseAnotherFolder(after location: CloudLocation, connection: Data) async {
        guard !location.isAppFolder else {
            access = .full
            return
        }
        await enterFolderStep(with: connection, at: (location.folder as NSString).deletingLastPathComponent)
    }

    /// Full path of the current folder (`home › Kakey`); the root shows "Root Folder".
    var currentFolderTitle: String {
        currentPath.isEmpty ? L10n.tr("Root Folder") : currentPath.split(separator: "/").joined(separator: " › ")
    }

    var canGoUp: Bool { !currentPath.isEmpty }

    /// Whether the folder screen's primary button is enabled: backup needs an empty folder or an existing backup; restore
    /// needs an existing backup.
    var canFinish: Bool {
        purpose == .restore ? currentFolderHasBackup : canUseCurrentFolder
    }

    /// Explains why the current folder cannot be chosen for backup; nil when it can, or during restore (where the disabled
    /// primary button is enough).
    var folderHint: String? {
        purpose == .backup && !canFinish ? Self.folderNotEmptyMessage : nil
    }

    func open(_ entry: CoreCloudEntry) async {
        await load(entry.path)
    }

    /// Lists the current folder again (the user changed the drive contents elsewhere).
    func refresh() async {
        await load(currentPath)
    }

    func goUp() async {
        await load((currentPath as NSString).deletingLastPathComponent)
    }

    /// Creates a folder in the current folder and enters it.
    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = currentPath.isEmpty ? trimmed : "\(currentPath)/\(trimmed)"
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.createFolder(path, connections: connections)
            await load(path)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Uses the current folder; refuses if it holds other files.
    func finish() throws -> Result {
        guard let connection = try connections.load() else { throw CloudSyncError.service(.ReauthRequired) }
        guard canUseCurrentFolder else { throw CloudSetupError(message: Self.folderNotEmptyMessage) }
        return Result(connection: connection, location: try CloudSetupService.location(for: connection, folder: currentPath))
    }

    /// The suggested default folder: `Kakey` inside the current folder (the current folder itself if it is `Kakey`;
    /// created if missing). It is created here rather than at the root because many servers (e.g. Synology) do not allow
    /// creating folders at the root. On failure, stays put and shows the reason.
    func useDefaultFolder() async throws -> Result {
        errorMessage = nil
        if (currentPath as NSString).lastPathComponent != Self.defaultFolder {
            if let existing = folders.first(where: { $0.name == Self.defaultFolder }) {
                await load(existing.path)
            } else {
                await createFolder(named: Self.defaultFolder)
            }
        }
        if let errorMessage { throw CloudSetupError(message: errorMessage) }
        do {
            return try finish()
        } catch {
            errorMessage = Self.message(for: error)
            throw error
        }
    }

    // MARK: - Text (shared by Mac and iOS; differs between backup and restore)

    /// Connection screen title: "Connect to X" for backup, "Restore from X" for restore.
    var title: String {
        purpose == .restore
            ? L10n.format("Restore from %@", provider.displayName) : L10n.format("Connect to %@", provider.displayName)
    }

    /// First line to the right of the pairing illustration.
    var headline: String {
        provider == .webDAV ? L10n.tr("Connect to your own server or NAS") : provider.pickerSubtitle
    }

    /// Second line to the right of the pairing illustration: for backup, only the encrypted vault is stored; for restore,
    /// only the encrypted backup is read.
    var storedNote: String {
        switch (purpose, provider) {
        case (.backup, .webDAV): L10n.tr("Only the encrypted vault is stored on your server.")
        case (.restore, .webDAV): L10n.tr("Kakey only reads your encrypted backup from your server.")
        case (.backup, _): L10n.format("Only the encrypted vault is stored in %@.", provider.displayName)
        case (.restore, _): L10n.format("Kakey only reads your encrypted backup from %@.", provider.displayName)
        }
    }

    /// Hint below the server address field (the field has a label, so no placeholder).
    var addressHint: String {
        provider == .webDAV
            ? L10n.tr("The WebDAV address of the folder, for example https://example.com/remote.php/webdav/")
            : L10n.tr("For example https://cloud.example.com. You’ll sign in and allow Kakey in your browser.")
    }

    /// The three step descriptions, which double as progress items (in `ConnectPhase` order). With full-drive access, the
    /// third step is choosing a folder.
    var connectSteps: [String] {
        let last =
            switch (purpose, access) {
            case (.backup, .appFolder): L10n.tr("Look for an existing backup, then back up")
            case (.backup, .full): L10n.tr("Choose a folder for the backup")
            case (.restore, .appFolder): L10n.tr("Find your backup")
            case (.restore, .full): L10n.tr("Open the folder with your backup")
            }
        return [
            L10n.format("Sign in to %@ and allow Kakey", provider.displayName),
            L10n.format("Connect to your %@ account", provider.displayName),
            last,
        ]
    }

    static func accessTitle(_ access: CoreCloudAccess) -> String {
        switch access {
        case .appFolder: L10n.tr("Kakey Folder Only")
        case .full: L10n.tr("Any Folder")
        }
    }

    func accessDetail(_ access: CoreCloudAccess) -> String {
        switch access {
        case .appFolder:
            L10n.format("Kakey can only see its own folder, %1$@, in your %2$@.", provider.appFolderPath, provider.displayName)
        case .full: L10n.format("Kakey can read and change every file in your %@. You choose the folder next.", provider.displayName)
        }
    }

    var submitTitle: String {
        provider.usesOAuth ? L10n.tr("Sign In") : L10n.tr("Connect")
    }

    static var folderNotEmptyMessage: String {
        L10n.tr("Choose an empty folder or one that already has a Kakey backup. Hidden files are ignored.")
    }

    static let defaultFolder = "Kakey"

    // MARK: - Internals

    private func enterFolderStep(with connection: Data, at path: String = "", form: FormInput? = nil) async {
        do {
            try connections.save(connection)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        if let onConnected, let location = try? CloudSetupService.location(for: connection, folder: path) {
            onConnected(location, connection, form)
        }
        // Sign-in progress ends here: Back and Cancel must both work during folder selection.
        phase = nil
        isCheckingSignIn = false
        step = .chooseFolder
        await load(path)
    }

    private func load(_ path: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let entries = try await service.entries(in: path, connections: connections)
            folders = entries.filter(\.isDir)
            canUseCurrentFolder = coreCloudIsUsableFolder(names: entries.map(\.name))
            currentFolderHasBackup = coreCloudFolderHasBackup(names: entries.map(\.name))
            currentPath = path
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func startPolling(_ login: CoreNextcloudLogin) {
        pollLogin = login
        pollDeadline = ContinuousClock.now.advanced(by: Self.pollTimeout)
        runPolling(immediately: false)
    }

    /// Polls until authorization completes or times out. With `immediately`, the first poll skips the interval and
    /// `isCheckingSignIn` is true while it runs.
    private func runPolling(immediately: Bool) {
        guard let login = pollLogin, let deadline = pollDeadline else { return }
        pollTask?.cancel()
        isCheckingSignIn = immediately
        pollTask = Task { [weak self, service] in
            var immediate = immediately
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if !immediate { try? await Task.sleep(for: Self.pollInterval) }
                guard !Task.isCancelled else { return }
                do {
                    if let connection = try await service.pollNextcloudLogin(login) {
                        await self?.enterFolderStep(with: connection, form: self?.pollForm)
                        return
                    }
                } catch let error as URLError where error.code != .serverCertificateUntrusted && error.code != .secureConnectionFailed {
                    // Treat network-level failures as transient and keep waiting until timeout: the app is suspended in
                    // the background while the user authorizes in the browser, and polls sent then fail with "connection
                    // lost". Ending sign-in on those would greet the user with an error on returning to the app.
                } catch {
                    self?.failSignIn(Self.message(for: error))
                    return
                }
                guard !Task.isCancelled else { return }
                if immediate {
                    immediate = false
                    self?.isCheckingSignIn = false
                }
            }
            if !Task.isCancelled { self?.failSignIn(L10n.tr("Sign-in timed out. Try again")) }
        }
    }

    private func failSignIn(_ message: String) {
        errorMessage = message
        isCheckingSignIn = false
        step = .form
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollLogin = nil
        pollDeadline = nil
        pollForm = nil
        isCheckingSignIn = false
    }

    static func message(for error: Error) -> String {
        SyncErrorText.message(for: error)
    }
}

/// Compared by object identity: the UI uses it as a sheet / navigation target (each connection gets a new model object).
extension CloudSetupModel: Identifiable, Hashable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    nonisolated static func == (lhs: CloudSetupModel, rhs: CloudSetupModel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct CloudSetupError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
