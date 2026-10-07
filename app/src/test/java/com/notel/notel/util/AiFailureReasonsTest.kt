package com.notel.notel.util

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Retry/backoff mapping for the AI-summary attempt loop: connection-class
 * failures are retried with exponential backoff, HTTP 5xx gets one extra
 * retry, HTTP 4xx (auth/rate-limit/bad request) fails fast.
 */
class AiFailureReasonsTest {

    @Test
    fun `connection errors are CONNECTION class`() {
        listOf(
            UnknownHostException("dns"),
            ConnectException("refused"),
            NoRouteToHostException("no route"),
            SocketTimeoutException("timed out"),
            IOException("plain io")
        ).forEach { ex ->
            assertEquals(
                "expected CONNECTION for ${ex.javaClass.simpleName}",
                AiFailureReasons.RetryClass.CONNECTION,
                AiFailureReasons.retryClass(ex)
            )
        }
    }

    @Test
    fun `coroutine timeout (null error) is CONNECTION class`() {
        assertEquals(
            AiFailureReasons.RetryClass.CONNECTION,
            AiFailureReasons.retryClass(null)
        )
    }

    @Test
    fun `http 5xx is SERVER_ERROR class`() {
        assertEquals(
            AiFailureReasons.RetryClass.SERVER_ERROR,
            AiFailureReasons.retryClass(RuntimeException("HTTP 500: boom"))
        )
        assertEquals(
            AiFailureReasons.RetryClass.SERVER_ERROR,
            AiFailureReasons.retryClass(RuntimeException("HTTP 503: unavailable"))
        )
    }

    @Test
    fun `http 4xx failures are FATAL (fail fast, no retry)`() {
        listOf("HTTP 400: bad", "HTTP 401: auth", "HTTP 403: forbidden", "HTTP 429: slow down", "HTTP 404: gone")
            .forEach { message ->
                assertEquals(
                    "expected FATAL for $message",
                    AiFailureReasons.RetryClass.FATAL,
                    AiFailureReasons.retryClass(RuntimeException(message))
                )
            }
    }

    @Test
    fun `non-network unknown errors are FATAL`() {
        assertEquals(
            AiFailureReasons.RetryClass.FATAL,
            AiFailureReasons.retryClass(IllegalStateException("weird"))
        )
    }

    @Test
    fun `max attempts per class`() {
        assertEquals(4, AiFailureReasons.maxAttempts(AiFailureReasons.RetryClass.CONNECTION))
        assertEquals(2, AiFailureReasons.maxAttempts(AiFailureReasons.RetryClass.SERVER_ERROR))
        assertEquals(1, AiFailureReasons.maxAttempts(AiFailureReasons.RetryClass.FATAL))
    }

    @Test
    fun `connection backoff is exponential 2s 4s 8s`() {
        assertEquals(2000L, AiFailureReasons.backoffDelayMs(AiFailureReasons.RetryClass.CONNECTION, 1))
        assertEquals(4000L, AiFailureReasons.backoffDelayMs(AiFailureReasons.RetryClass.CONNECTION, 2))
        assertEquals(8000L, AiFailureReasons.backoffDelayMs(AiFailureReasons.RetryClass.CONNECTION, 3))
    }

    @Test
    fun `server error backoff is flat 2s, fatal is zero`() {
        assertEquals(2000L, AiFailureReasons.backoffDelayMs(AiFailureReasons.RetryClass.SERVER_ERROR, 1))
        assertEquals(2000L, AiFailureReasons.backoffDelayMs(AiFailureReasons.RetryClass.SERVER_ERROR, 2))
        assertEquals(0L, AiFailureReasons.backoffDelayMs(AiFailureReasons.RetryClass.FATAL, 1))
    }

    @Test
    fun `plain reasons unchanged by retry mapping`() {
        assertEquals("no connection", AiFailureReasons.plainReason(UnknownHostException("x")))
        assertEquals("network timeout after 60s", AiFailureReasons.plainReason(null))
        assertEquals("HTTP 401 (signed out?)", AiFailureReasons.plainReason(RuntimeException("HTTP 401: nope")))
        assertEquals("HTTP 500 (server error)", AiFailureReasons.plainReason(RuntimeException("HTTP 500: nope")))
    }
}
