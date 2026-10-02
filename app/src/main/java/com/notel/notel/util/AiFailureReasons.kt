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

    fun plainReason(error: Throwable?): String {
        if (error == null) return "network timeout after 60s"

        // PR #15 prefixes Gemini API failures with "HTTP <status>: ...".
        // Read only the 3-digit code; never surface the raw message.
        val httpCode = error.message
            ?.let { httpCodeRegex.find(it)?.groupValues?.getOrNull(1) }

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
