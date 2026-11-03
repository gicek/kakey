package com.gicek.kakey.android

import com.gicek.kakey.android.platform.OAuthCallbacks
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** OAuth callback relay: only hands back a callback to a waiting sign-in, and only one the core accepts as belonging to it. */
class OAuthCallbacksTest {
    private val accepted = "db-key://2/token?code=c&state=s"

    @Test
    fun deliversOnlyTheAcceptedCallbackToTheWaitingSignIn() = runTest {
        assertFalse("Dropped when no sign-in is waiting", OAuthCallbacks.deliver(accepted))
        val opened = CompletableDeferred<Unit>()
        val result = async { OAuthCallbacks.await({ it == accepted }) { opened.complete(Unit) } }
        opened.await()
        assertFalse("Callback with a mismatched state is not delivered", OAuthCallbacks.deliver("db-key://2/token?code=c&state=forged"))
        assertTrue(OAuthCallbacks.deliver(accepted))
        assertEquals(accepted, result.await())
        assertFalse("Not accepted after completion", OAuthCallbacks.deliver(accepted))
    }

    @Test
    fun cancellingTheSignInStopsWaiting() = runTest {
        val opened = CompletableDeferred<Unit>()
        val result = async { OAuthCallbacks.await({ true }) { opened.complete(Unit) } }
        opened.await()
        result.cancel()
        yield()
        assertTrue(result.isCancelled)
        assertFalse("Callback is dropped after cancellation", OAuthCallbacks.deliver(accepted))
    }
}
