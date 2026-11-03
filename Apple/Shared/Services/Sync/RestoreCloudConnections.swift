import Foundation

/// Cloud storage connections authorized during first-time restore, one per provider and access scope, so choosing the
/// provider again needs no new sign-in. For Dropbox / OneDrive, "Kakey app folder only" and "any folder" are two developer
/// keys with separate authorizations and must be stored separately; otherwise choosing the other scope would reuse the
/// wrong one. For WebDAV / Nextcloud the submitted form is also kept (including the WebDAV password, the same one that is
/// in the connection blob): it prefills the form when chosen again, so falling back to the form after a transient network
/// or server error does not leave it empty.
/// Memory only, never in the Keychain or on disk: owned by onboarding and released with it after a successful restore or
/// a new vault, and gone when the app quits. The connection to keep after a successful restore is saved separately by the
/// store into `CloudConnectionStoring`.
@MainActor
final class RestoreCloudConnections {
    private struct Key: Hashable {
        var provider: CloudProvider
        var isAppFolder: Bool
    }

    private var saved: [Key: (location: CloudLocation, connection: Data)] = [:]
    private var forms: [CloudProvider: CloudSetupModel.FormInput] = [:]

    /// Records the connection returned by the connection screen (whether or not a backup is then found); tokens refreshed
    /// while browsing update it too. A nil `form` (reused connection, OAuth) keeps the previous form.
    func remember(_ location: CloudLocation, connection: Data, form: CloudSetupModel.FormInput? = nil) {
        saved[Key(provider: location.provider, isAppFolder: location.isAppFolder)] = (location, connection)
        if let form { forms[location.provider] = form }
    }

    /// Makes the connection screen record the authorization as soon as it has one (on entering folder selection). After an
    /// "any folder" sign-in the user picks a folder first, and closing the screen without finding a backup never returns
    /// the connection, so without this the user would have to sign in again. Also prefills the provider's previous form.
    func track(_ model: CloudSetupModel) {
        if let form = forms[model.provider] { model.prefill(form) }
        model.onConnected = { [weak self] location, connection, form in
            self?.remember(location, connection: connection, form: form)
        }
    }

    enum Preparation {
        /// Restore directly with this connection, without opening the connection screen.
        case restore(location: CloudLocation, connection: Data)
        /// Open the connection screen; a non-nil `resume` opens it in the previous folder (`CloudSetupModel.resume`).
        case open(resume: (location: CloudLocation, connection: Data)?)
    }

    /// Reuses existing authorization before opening the connection screen. This only decides and never touches the network,
    /// so the screen appears immediately even on a slow connection. For a provider limited to the Kakey app folder that is
    /// already authorized, it looks for the backup directly, as on first sign-in, instead of listing the app folder's
    /// contents (that list looks too much like "any folder"). Providers offering both scopes stop at the form, and "Sign In"
    /// reuses the authorization for the chosen scope if there is one (the app folder again looks for the backup directly).
    /// WebDAV and Nextcloud open in the previous folder with the form prefilled.
    func prepare(_ model: CloudSetupModel) -> Preparation {
        track(model)
        let provider = model.provider
        if model.offersFullAccess {
            model.savedConnection = { [weak self] access in
                self?.saved[Key(provider: provider, isAppFolder: access == .appFolder)]
            }
            return .open(resume: nil)
        }
        guard let existing = saved.first(where: { $0.key.provider == provider })?.value else { return .open(resume: nil) }
        if existing.location.isAppFolder { return .restore(location: existing.location, connection: existing.connection) }
        return .open(resume: existing)
    }
}
