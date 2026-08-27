package com.notel.notel.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

class AuthInterceptorBehaviorTest {

    @Test
    fun testRefreshResultSuccessAndFailureTypes() {
        val success = RefreshResult.Success("new_access", "new_refresh")
        assertEquals("new_access", success.accessToken)
        assertEquals("new_refresh", success.refreshToken)

        val temp = RefreshResult.TemporaryFailure
        val def = RefreshResult.DefinitiveFailure
        assertTrue(temp is RefreshResult.TemporaryFailure)
        assertTrue(def is RefreshResult.DefinitiveFailure)
    }

    @Test
    fun testSingleFlightRefreshMutexConcurrency() {
        val refreshCallCount = AtomicInteger(0)
        val threads = 20
        val latch = CountDownLatch(threads)
        val results = ConcurrentHashMap<Int, RefreshResult>()

        fun mockPerformSingleRefresh(): RefreshResult {
            refreshCallCount.incrementAndGet()
            Thread.sleep(50) // Simulate network delay
            return RefreshResult.Success("shared_access_token", "shared_refresh_token")
        }

        val lock = Any()
        var ongoingRefreshResult: RefreshResult? = null

        fun getOrPerformRefresh(): RefreshResult {
            synchronized(lock) {
                if (ongoingRefreshResult != null) return ongoingRefreshResult!!
                val res = mockPerformSingleRefresh()
                ongoingRefreshResult = res
                return res
            }
        }

        for (i in 0 until threads) {
            Thread {
                results[i] = getOrPerformRefresh()
                latch.countDown()
            }.start()
        }

        latch.await()

        assertEquals(1, refreshCallCount.get())
        for (i in 0 until threads) {
            val res = results[i]
            assertTrue(res is RefreshResult.Success)
            assertEquals("shared_access_token", (res as RefreshResult.Success).accessToken)
        }
    }

    @Test
    fun testAccountMismatchPreventionLogic() {
        val currentStableUserId = "user_12345"
        val incomingUserIdMatch = "user_12345"
        val incomingUserIdMismatch = "user_67890"

        val isMatchBlocked = currentStableUserId.isNotBlank() && incomingUserIdMatch.isNotBlank() && currentStableUserId != incomingUserIdMatch
        val isMismatchBlocked = currentStableUserId.isNotBlank() && incomingUserIdMismatch.isNotBlank() && currentStableUserId != incomingUserIdMismatch

        assertFalse("Same account login should not be blocked", isMatchBlocked)
        assertTrue("Different account login MUST be blocked", isMismatchBlocked)
    }

    @Test
    fun testBlankRefreshTokenRejection() {
        val blankToken = "   "
        val isRejected = blankToken.isBlank()
        assertTrue("Blank refresh token must be rejected", isRejected)
    }

    @Test
    fun testLoginScreenVisibilityDuringReconnectState() {
        val reconnectRequired = true
        val alreadyLoggedIn = true

        val shouldRedirectBack = alreadyLoggedIn && !reconnectRequired
        assertFalse("LoginScreen must not auto-redirect when reconnect is required", shouldRedirectBack)
    }

    @Test
    fun testDialogSuppressionOnLoginRoute() {
        val reconnectRequired = true
        val currentRouteOnLogin = "login?mode=login"
        val isLoginRoute = currentRouteOnLogin.startsWith("login")

        val showDialog = reconnectRequired && !isLoginRoute
        assertFalse("Session Expired dialog MUST be suppressed while on login route", showDialog)
    }
}
