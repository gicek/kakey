package com.gicek.kakey.android

import com.gicek.kakey.android.data.BackupHistoryCodec
import com.gicek.kakey.android.data.PreferencesCodec
import com.gicek.kakey.android.domain.AppearanceMode
import com.gicek.kakey.android.domain.AutoLockMode
import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.BackupHistoryStore
import com.gicek.kakey.android.domain.CloudProvider
import com.gicek.kakey.android.domain.FileLimits.readAtMost
import com.gicek.kakey.android.domain.Preferences
import com.gicek.kakey.android.domain.SyncLocation
import java.io.ByteArrayInputStream
import java.time.Instant
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure Kotlin parts of `data/`: JSON codecs for settings and backup history, and the size limit for external files. */
class CodecsTest {
    @Test
    fun syncLocationsRoundTripAndUnknownKindsAreDropped() {
        val cloud = Preferences(syncLocation = SyncLocation.Cloud(CloudProvider.NEXTCLOUD, "cloud.example.com", "alice", false, "Kakey/备份"))
        assertEquals(cloud, PreferencesCodec.decode(PreferencesCodec.encode(cloud)))
        val dropbox = Preferences(
            syncLocation = SyncLocation.Cloud(CloudProvider.DROPBOX, "dropbox.com", "alice@example.com", true, "", isAppFolder = true),
        )
        assertEquals(dropbox, PreferencesCodec.decode(PreferencesCodec.encode(dropbox)))
        val google = Preferences(
            syncLocation = SyncLocation.Cloud(
                CloudProvider.GOOGLE_DRIVE,
                "drive.google.com",
                "alice@gmail.com",
                true,
                "",
                isAppFolder = true,
            ),
        )
        assertEquals(google, PreferencesCodec.decode(PreferencesCodec.encode(google)))
        assertEquals(CloudProvider.GOOGLE_DRIVE, CloudProvider.of(CloudProvider.GOOGLE_DRIVE.core))
        assertEquals(
            "Location without isAppFolder still decodes, as a non-app folder",
            cloud,
            PreferencesCodec.decode(
                """{"syncLocation":{"kind":"cloud","provider":"NEXTCLOUD","host":"cloud.example.com","username":"alice",""" +
                    """"isSecure":false,"folder":"Kakey/备份"}}""",
            ),
        )
        assertEquals("Unknown kind means not configured", Preferences(), PreferencesCodec.decode("""{"syncLocation":{"kind":"ftp"}}"""))
        assertEquals(
            "Missing fields mean not configured",
            Preferences(),
            PreferencesCodec.decode("""{"syncLocation":{"kind":"cloud","provider":"WEBDAV"}}"""),
        )
        assertEquals("syncFolderUri is not read", Preferences(), PreferencesCodec.decode("""{"syncFolderUri":"content://x"}"""))
    }

    @Test
    fun preferencesRoundTripAndTolerantDecoding() {
        val value = Preferences(
            appearance = AppearanceMode.DARK,
            autoLock = AutoLockMode.FIVE_MINUTES,
            biometricsEnabled = true,
            syncLocation = SyncLocation.Folder("content://com.android.externalstorage.documents/tree/primary%3Akakey"),
            lastSyncLocalUpdatedAt = Instant.parse("2026-10-27T08:00:00Z"),
            lastSyncRemoteVersion = "t:1792915260000",
            consecutiveUnlockFailures = 3,
            lockoutSeconds = 30,
            lockoutStartedElapsedMillis = 1_234_567,
        )
        assertEquals(value, PreferencesCodec.decode(PreferencesCodec.encode(value)))
        assertEquals("Null fields not written as \"null\"", Preferences(), PreferencesCodec.decode(PreferencesCodec.encode(Preferences())))

        assertEquals("Malformed JSON falls back to defaults", Preferences(), PreferencesCodec.decode("{not json"))
        assertEquals(
            "Unknown enum value falls back to the default; other fields still decode",
            Preferences(autoLock = AutoLockMode.FIVE_MINUTES, biometricsEnabled = true),
            PreferencesCodec.decode("""{"autoLock":"TEN_MINUTES","biometricsEnabled":true}"""),
        )
        assertEquals(
            "Explicit null is treated as absent",
            Preferences(),
            PreferencesCodec.decode("""{"syncLocation":null,"lockoutSeconds":null,"lockoutStartedElapsedMillis":null}"""),
        )
        assertEquals(
            "Wall-clock lockoutUntil is not read; the failure count is kept",
            Preferences(consecutiveUnlockFailures = 5),
            PreferencesCodec.decode("""{"consecutiveUnlockFailures":5,"lockoutUntil":"2099-01-01T00:00:00Z","lockoutSeconds":"x"}"""),
        )
    }

    @Test
    fun backupHistoryRoundTripSkipsBrokenEntriesAndCapsLength() {
        val base = Instant.parse("2026-10-27T08:00:00Z")
        val items = (0 until BackupHistoryStore.MAX_ENTRIES + 5).map { index ->
            BackupHistoryItem(
                base.plusSeconds(index.toLong()),
                "Pixel",
                1_024L + index,
                BackupHistoryItem.Source.entries[index % 4],
                isFailure =
                    index % 7 == 0,
                direction = BackupHistoryItem.Direction.entries.getOrNull(index % 4),
                location = listOf("OneDrive", "Dropbox", null)[index % 3],
            )
        }
        val decoded = BackupHistoryCodec.decode(BackupHistoryCodec.encode(items))
        assertEquals("Keeps at most MAX_ENTRIES entries", BackupHistoryStore.MAX_ENTRIES, decoded.size)
        assertEquals(items.take(BackupHistoryStore.MAX_ENTRIES), decoded)

        val mixed = """[{"date":"2026-10-27T08:00:00Z","device":"Mac","size":10,"source":"SYNC"},""" +
            """{"device":"no date"},{"date":"garbage"},7]"""
        val survivors = BackupHistoryCodec.decode(mixed)
        assertEquals(1, survivors.size)
        assertEquals(
            "Entry without a direction still decodes",
            BackupHistoryItem(base, "Mac", 10, BackupHistoryItem.Source.SYNC),
            survivors.single(),
        )
        assertTrue(BackupHistoryCodec.decode("[]").isEmpty())
    }

    @Test
    fun readAtMostStopsAtTheLimit() {
        val bytes = ByteArray(1000) { it.toByte() }
        assertArrayEquals(bytes, ByteArrayInputStream(bytes).readAtMost(1000))
        assertNull("Over the limit returns null instead of truncated content", ByteArrayInputStream(bytes).readAtMost(999))
        assertArrayEquals(ByteArray(0), ByteArrayInputStream(ByteArray(0)).readAtMost(0))
    }
}
