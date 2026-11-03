package com.gicek.kakey.android.domain

import com.gicek.kakey.core.CoreCloudProvider
import com.gicek.kakey.core.coreCloudOauthProviders
import java.time.Instant

enum class AppearanceMode { SYSTEM, LIGHT, DARK }

/** In-app language; `SYSTEM` follows the system, others are written as the system per-app language (Android 13+). */
enum class LanguageMode(val tag: String?) {
    SYSTEM(null),
    ENGLISH("en"),
    SIMPLIFIED_CHINESE("zh-Hans"),
    TRADITIONAL_CHINESE("zh-Hant"),
}

/**
 * Auto-lock: locks once the app has been idle for the chosen duration since the last interaction, whether in the foreground
 * or background. The same three options as on Apple, defaulting to 5 minutes like the Mac (see docs/DESIGN.md); unreadable
 * stored values fall back to the default without migration.
 */
enum class AutoLockMode(val delaySeconds: Long) {
    ONE_MINUTE(60),
    FIVE_MINUTES(5 * 60),
    THIRTY_MINUTES(30 * 60),
}

/**
 * Non-sensitive settings. Accounts, secrets and the master password are not here. Persisted by [PreferencesStore] (DataStore);
 * tests inject an in-memory implementation.
 */
data class Preferences(
    val appearance: AppearanceMode = AppearanceMode.SYSTEM,
    val autoLock: AutoLockMode = AutoLockMode.FIVE_MINUTES,
    val biometricsEnabled: Boolean = false,
    /**
     * Backup location (a sync folder or cloud storage); null when sync is off. Cloud storage credentials are kept separately
     * in [CloudConnectionStore].
     */
    val syncLocation: SyncLocation? = null,
    val lastSyncLocalUpdatedAt: Instant? = null,
    /** Persisted text of the remote version (`coreEncodeRemoteVersion`); unreadable means never synced. */
    val lastSyncRemoteVersion: String? = null,
    val consecutiveUnlockFailures: Int = 0,
    /**
     * Wait after repeated wrong passwords: the total seconds to wait and the monotonic clock reading when the wait began
     * (`SystemClock.elapsedRealtime`, milliseconds). No deadline is stored, so changing the system time can't skip the wait.
     * The monotonic clock restarts from zero after a reboot; a start timestamp in the future means a reboot, and the full wait
     * restarts from the new origin.
     */
    val lockoutSeconds: Long? = null,
    val lockoutStartedElapsedMillis: Long? = null,
)

/**
 * [load] reads once at startup (suspending, without blocking the main thread); implementations move [save] / [clear] to the
 * background themselves.
 */
interface PreferencesStore {
    suspend fun load(): Preferences
    fun save(preferences: Preferences)
    fun clear()
}

class InMemoryPreferencesStore(private var value: Preferences = Preferences()) : PreferencesStore {
    override suspend fun load() = value
    override fun save(preferences: Preferences) {
        value = preferences
    }

    override fun clear() {
        value = Preferences()
    }
}

/** The backup location chosen by the user (docs/TECHNICAL.md): non-sensitive, and only one at a time. */
sealed interface SyncLocation {
    /** A folder granted through the system file picker (SAF), with a persisted permission. */
    data class Folder(val uri: String) : SyncLocation

    /**
     * Cloud storage: the connection blob is in [CloudConnectionStore]; this holds only display info and the remote folder
     * (relative to the storage root; an empty string is the root).
     * [isAppFolder]: the OAuth provider can only access the app folder ("Apps › Kakey", docs/TECHNICAL.md), and the
     * backup sits at its root.
     */
    data class Cloud(
        val provider: CloudProvider,
        val host: String,
        val username: String,
        val isSecure: Boolean,
        val folder: String,
        val isAppFolder: Boolean = false,
        /** A user-confirmed server certificate is pinned: the UI keeps showing "Certificate not verified". */
        val isCertificatePinned: Boolean = false,
    ) : SyncLocation {
        /**
         * Second display line: "account · host › folder". The app folder's "account · Apps › Kakey" needs localization, so the
         * UI builds it.
         */
        val detail: String get() = if (folder.isEmpty()) "$username · $host" else "$username · $host › $folder"
    }
}

/**
 * Cloud storage backend kinds; OAuth providers appear only when the build has developer keys configured (`cloud-keys.toml`,
 * see [available]).
 */
enum class CloudProvider(val displayName: String, val core: CoreCloudProvider) {
    DROPBOX("Dropbox", CoreCloudProvider.DROPBOX),
    ONEDRIVE("OneDrive", CoreCloudProvider.ONE_DRIVE),
    GOOGLE_DRIVE("Google Drive", CoreCloudProvider.GOOGLE_DRIVE),
    NEXTCLOUD("Nextcloud", CoreCloudProvider.NEXTCLOUD),
    WEBDAV("WebDAV", CoreCloudProvider.WEB_DAV),
    ;

    /** Signs in with OAuth (browser) instead of entering a server address. */
    val usesOAuth: Boolean get() = this == DROPBOX || this == ONEDRIVE || this == GOOGLE_DRIVE

    /** Whether "entire drive" access can be chosen (the matching key is configured). */
    val fullAccessAvailable: Boolean
        get() = coreCloudOauthProviders().firstOrNull { it.provider == core }?.fullAccessAvailable ?: false

    /**
     * Whether the user can choose the backup folder: always for WebDAV / Nextcloud; OAuth providers need a build configured
     * with an "any folder" key.
     */
    val canChooseFolder: Boolean get() = !usesOAuth || fullAccessAvailable

    companion object {
        fun of(provider: CoreCloudProvider): CloudProvider = entries.first { it.core == provider }

        /** Backends selectable in this build: WebDAV and Nextcloud are always available. */
        val available: List<CloudProvider>
            get() {
                val configured = coreCloudOauthProviders().map { it.provider }.toSet()
                return entries.filter { !it.usesOAuth || it.core in configured }
            }
    }
}
