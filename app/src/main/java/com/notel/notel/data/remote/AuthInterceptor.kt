package com.notel.notel.data.remote

import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject
import javax.inject.Singleton

sealed class RefreshResult {
    data class Success(val accessToken: String, val refreshToken: String) : RefreshResult()
    object TemporaryFailure : RefreshResult()
    object DefinitiveFailure : RefreshResult()
}

@Singleton
class AuthInterceptor @Inject constructor(
    private val preferences: NotelPreferences
) : Interceptor {

    private val refreshPath = "api/auth/refresh-token"
    private val loginPath = "api/auth/login"
    private val registerPath = "api/auth/register"
    private val googlePath = "api/auth/google"
    private val logoutPath = "api/auth/logout"

    // Structured thread lock for single-flight token refresh across concurrent requests
    private val refreshLock = ReentrantLock()

    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()
        val requestPath = originalRequest.url.encodedPath

        // Do not attach token or intercept refresh for public auth endpoints
        val isPublicAuthEndpoint = requestPath.contains(refreshPath) ||
                requestPath.contains(loginPath) ||
                requestPath.contains(registerPath) ||
                requestPath.contains(googlePath) ||
                requestPath.contains(logoutPath)

        if (isPublicAuthEndpoint) {
            return chain.proceed(originalRequest)
        }

        // Attach current access token
        val accessToken = runBlocking { preferences.authToken.first() }
        val authedRequest = originalRequest.withBearerToken(accessToken)
        val response = chain.proceed(authedRequest)

        // Only attempt refresh on HTTP 401
        if (response.code != 401) {
            return response
        }

        // Close response body of the failed request before attempting refresh & retry
        response.close()

        // Acquire lock for single-flight execution
        refreshLock.lock()
        val newAccessToken: String? = try {
            val currentAccessToken = runBlocking { preferences.authToken.first() }
            if (currentAccessToken != accessToken && currentAccessToken.isNotBlank()) {
                // Another thread already refreshed successfully while this thread was waiting
                currentAccessToken
            } else {
                val currentRefreshToken = runBlocking { preferences.refreshToken.first() }
                if (currentRefreshToken.isBlank()) {
                    // No refresh token available, mark reconnect required
                    runBlocking { preferences.markReconnectRequiredAtomically() }
                    null
                } else {
                    val result = performRefresh(originalRequest.url, currentRefreshToken)
                    when (result) {
                        is RefreshResult.Success -> {
                            runBlocking {
                                preferences.saveSessionAtomically(
                                    accessToken = result.accessToken,
                                    refreshToken = result.refreshToken
                                )
                            }
                            result.accessToken
                        }
                        is RefreshResult.DefinitiveFailure -> {
                            runBlocking { preferences.markReconnectRequiredAtomically() }
                            null
                        }
                        is RefreshResult.TemporaryFailure -> {
                            // Temporary failure (5xx, network timeout) -> preserve session, return null to complete retry without logging out
                            null
                        }
                    }
                }
            }
        } finally {
            refreshLock.unlock()
        }

        return if (!newAccessToken.isNullOrBlank()) {
            // Retry the original request once with the new access token
            chain.proceed(originalRequest.withBearerToken(newAccessToken))
        } else {
            // Return a dummy response or un-retried request without clearing local records
            chain.proceed(originalRequest.withBearerToken(accessToken))
        }
    }

    /**
     * Synchronously performs token refresh with explicit error categorization.
     */
    private fun performRefresh(originalUrl: okhttp3.HttpUrl, refreshToken: String): RefreshResult {
        return try {
            val baseUrl = "${originalUrl.scheme}://${originalUrl.host}${if (originalUrl.port != -1 && originalUrl.port != 80 && originalUrl.port != 443) ":${originalUrl.port}" else ""}/"
            val refreshUrl = "${baseUrl}${refreshPath}"

            val json = Json.encodeToString(
                RefreshTokenRequest.serializer(),
                RefreshTokenRequest(refreshToken)
            )
            val body = json.toRequestBody("application/json".toMediaType())
            val request = Request.Builder()
                .url(refreshUrl)
                .post(body)
                .build()

            OkHttpClient().newCall(request).execute().use { response ->
                val responseBodyStr = response.body?.string() ?: ""
                val code = response.code

                if (code == 401 || code == 403) {
                    return RefreshResult.DefinitiveFailure
                }

                if (code >= 500) {
                    return RefreshResult.TemporaryFailure
                }

                if (!response.isSuccessful) {
                    return RefreshResult.TemporaryFailure
                }

                val parsed = try {
                    Json { ignoreUnknownKeys = true }.decodeFromString(RefreshTokenResponse.serializer(), responseBodyStr)
                } catch (e: Exception) {
                    return RefreshResult.TemporaryFailure
                }

                if (parsed.error != null) {
                    val err = parsed.error.lowercase()
                    if (err.contains("expired") || err.contains("revoked") || err.contains("invalid") || err.contains("disabled")) {
                        return RefreshResult.DefinitiveFailure
                    }
                }

                val newAccess = parsed.token
                val newRefresh = parsed.refreshToken

                if (newAccess.isNullOrBlank() || newRefresh.isNullOrBlank()) {
                    RefreshResult.TemporaryFailure
                } else {
                    RefreshResult.Success(newAccess, newRefresh)
                }
            }
        } catch (e: Exception) {
            RefreshResult.TemporaryFailure
        }
    }

    private fun Request.withBearerToken(token: String): Request {
        val builder = newBuilder()
        if (token.isNotEmpty()) {
            builder.header("Authorization", "Bearer $token")
        }
        return builder.build()
    }
}
