package com.notel.notel.util

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Maps an AI-summary failure into a short, plain-language one-liner for the
 * founder to see (PDF raw-fallback banner + export UI). Deliberately emits
 * only FIXED strings: never the exception message, so no server-provided
 * text or health/snapshot data can leak into the report.
 *
 * A null [error] means the attempt timed out (withTimeoutOrNull returned
 * null) rather than throwing.
 */
object AiFailureReasons {

    private val httpCodeRegex = Regex("""HTTP\s+(\d{3})""")

    /**
     * Retry class for an AI-summary failure. Drives the backoff policy in
     * LogRepository: transient connection failures get several attempts with
     * exponential backoff; HTTP 5xx gets one extra retry; everything else
     * (HTTP 4xx auth/rate-limit/bad-request, unknown) fails fast because
     * retrying is pointless.
     */
    enum class RetryClass { CONNECTION, SERVER_ERROR, FATAL }

    private fun httpCodeOf(error: Throwable?): String? =
        error?.message?.let { httpCodeRegex.find(it)?.groupValues?.getOrNull(1) }

    fun retryClass(error: Throwable?): RetryClass {
        // A null error means the attempt hit the 60s coroutine timeout rather
        // than throwing: treat it as a transient connection problem.
        if (error == null) return RetryClass.CONNECTION
        val httpCode = httpCodeOf(error)
        if (httpCode != null) {
            return if (httpCode.startsWith("5")) RetryClass.SERVER_ERROR
            else RetryClass.FATAL
        }
        return when (error) {
            is UnknownHostException,
            is ConnectException,
            is NoRouteToHostException,
            is SocketTimeoutException,
            is IOException -> RetryClass.CONNECTION
            else -> RetryClass.FATAL
        }
    }

    /**
     * Backoff delay before the next attempt. [completedAttempt] is the
     * 1-based number of the attempt that just failed. Connection failures
     * back off exponentially (2s, 4s, 8s, ...); server errors wait a flat 2s.
     */
    fun backoffDelayMs(retryClass: RetryClass, completedAttempt: Int): Long =
        when (retryClass) {
            RetryClass.CONNECTION -> 2000L * (1L shl (completedAttempt - 1).coerceIn(0, 10))
            RetryClass.SERVER_ERROR -> 2000L
            RetryClass.FATAL -> 0L
        }

    /** Maximum attempts for a failure class: connection 4, server error 2, fatal 1. */
    fun maxAttempts(retryClass: RetryClass): Int = when (retryClass) {
        RetryClass.CONNECTION -> 4
        RetryClass.SERVER_ERROR -> 2
        RetryClass.FATAL -> 1
    }

    fun plainReason(error: Throwable?): String {
        if (error == null) return "network timeout after 60s"

        // PR #15 prefixes Gemini API failures with "HTTP <status>: ...".
        // Read only the 3-digit code; never surface the raw message.
        val httpCode = httpCodeOf(error)

        return when {
            httpCode == "401" -> "HTTP 401 (signed out?)"
            httpCode == "429" -> "HTTP 429 (try again later)"
            httpCode != null && httpCode.startsWith("5") -> "HTTP $httpCode (server error)"
            httpCode != null -> "HTTP $httpCode (request failed)"
            error is UnknownHostException ||
                error is ConnectException ||
                error is NoRouteToHostException ||
                error is SocketTimeoutException -> "no connection"
            error is IOException -> "network error"
            else -> "unknown error"
        }
    }
}
