package com.gicek.kakey.android.data

import com.gicek.kakey.android.domain.AppearanceMode
import com.gicek.kakey.android.domain.AutoLockMode
import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.BackupHistoryStore
import com.gicek.kakey.android.domain.CloudProvider
import com.gicek.kakey.android.domain.Preferences
import com.gicek.kakey.android.domain.SyncLocation
import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/**
 * JSON codecs for settings and backup history (pure Kotlin with no Context dependency, covered directly by JVM unit tests).
 * Decoding is lenient: missing fields, unknown enum values and malformed JSON all fall back to defaults so startup never fails.
 */
object PreferencesCodec {
    fun encode(value: Preferences): String = JSONObject().apply {
        put("appearance", value.appearance.name)
        put("autoLock", value.autoLock.name)
        put("biometricsEnabled", value.biometricsEnabled)
        putOpt("syncLocation", value.syncLocation?.let(::encodeLocation))
        putOpt("lastSyncLocalUpdatedAt", value.lastSyncLocalUpdatedAt?.toString())
        putOpt("lastSyncRemoteVersion", value.lastSyncRemoteVersion)
        put("consecutiveUnlockFailures", value.consecutiveUnlockFailures)
        putOpt("lockoutSeconds", value.lockoutSeconds)
        putOpt("lockoutStartedElapsedMillis", value.lockoutStartedElapsedMillis)
    }.toString()

    fun decode(text: String): Preferences = runCatching {
        val json = JSONObject(text)
        Preferences(
            appearance = enumOr(json.optString("appearance"), AppearanceMode.SYSTEM),
            autoLock = enumOr(json.optString("autoLock"), AutoLockMode.FIVE_MINUTES),
            biometricsEnabled = json.optBoolean("biometricsEnabled"),
            syncLocation = json.optJSONObject("syncLocation")?.let(::decodeLocation),
            lastSyncLocalUpdatedAt = json.optStringOrNull("lastSyncLocalUpdatedAt")?.let(Instant::parse),
            lastSyncRemoteVersion = json.optStringOrNull("lastSyncRemoteVersion"),
            consecutiveUnlockFailures = json.optInt("consecutiveUnlockFailures"),
            lockoutSeconds = json.optLongOrNull("lockoutSeconds"),
            lockoutStartedElapsedMillis = json.optLongOrNull("lockoutStartedElapsedMillis"),
        )
    }.getOrDefault(Preferences())

    private fun encodeLocation(location: SyncLocation): JSONObject = when (location) {
        is SyncLocation.Folder -> JSONObject().put("kind", "folder").put("uri", location.uri)
        is SyncLocation.Cloud -> JSONObject()
            .put("kind", "cloud")
            .put("provider", location.provider.name)
            .put("host", location.host)
            .put("username", location.username)
            .put("isSecure", location.isSecure)
            .put("folder", location.folder)
            .put("isAppFolder", location.isAppFolder)
            .put("isCertificatePinned", location.isCertificatePinned)
    }

    /** Anything unreadable (unknown kind, missing field) is treated as not configured; no older formats are kept. */
    private fun decodeLocation(json: JSONObject): SyncLocation? = runCatching {
        when (json.getString("kind")) {
            "folder" -> SyncLocation.Folder(json.getString("uri"))
            "cloud" -> SyncLocation.Cloud(
                provider = CloudProvider.valueOf(json.getString("provider")),
                host = json.getString("host"),
                username = json.getString("username"),
                isSecure = json.getBoolean("isSecure"),
                folder = json.getString("folder"),
                // Optional, defaults to false: only meaningful for OAuth, so saved WebDAV / Nextcloud locations still decode
                isAppFolder = json.optBoolean("isAppFolder", false),
                // Optional, defaults to false, for the same reason as isAppFolder
                isCertificatePinned = json.optBoolean("isCertificatePinned", false),
            )
            else -> null
        }
    }.getOrNull()
}

object BackupHistoryCodec {
    fun encode(items: List<BackupHistoryItem>): String {
        val array = JSONArray()
        items.take(BackupHistoryStore.MAX_ENTRIES).forEach { item ->
            array.put(
                JSONObject()
                    .put("date", item.date.toString())
                    .put("device", item.device)
                    .put("size", item.sizeBytes)
                    .put("source", item.source.name)
                    .put("failure", item.isFailure)
                    .putOpt("direction", item.direction?.name)
                    .putOpt("location", item.location),
            )
        }
        return array.toString()
    }

    /** Malformed JSON throws as a whole and the caller falls back to an empty list; single records missing `date` are skipped. */
    fun decode(text: String): List<BackupHistoryItem> {
        val array = JSONArray(text)
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val date = item.optStringOrNull("date")?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return@mapNotNull null
            BackupHistoryItem(
                date = date,
                device = item.optString("device"),
                sizeBytes = item.optLong("size"),
                source = enumOr(item.optString("source"), BackupHistoryItem.Source.AUTO),
                isFailure = item.optBoolean("failure"),
                // Optional: when missing or unreadable, no direction is shown
                direction = item.optStringOrNull("direction")?.let { name ->
                    BackupHistoryItem.Direction.entries.firstOrNull { it.name == name }
                },
                location = item.optStringOrNull("location"),
            )
        }
    }
}

private inline fun <reified T : Enum<T>> enumOr(name: String?, default: T): T = enumValues<T>().firstOrNull { it.name == name } ?: default

private fun JSONObject.optStringOrNull(name: String): String? = if (has(name) && !isNull(name)) getString(name) else null

/** Null when missing, explicitly null, or not an integer (`decodeIfPresent` semantics). */
private fun JSONObject.optLongOrNull(name: String): Long? = if (has(name) &&
    !isNull(name)
) {
    runCatching { getLong(name) }.getOrNull()
} else {
    null
}
