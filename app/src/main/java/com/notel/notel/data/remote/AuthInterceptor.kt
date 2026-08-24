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
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthInterceptor @Inject constructor(
    private val preferences: NotelPreferences
) : Interceptor {

    // Refresh endpoint path — must not trigger another refresh attempt
    private val refreshPath = "api/auth/refresh-token"
    private val logoutPath = "api/auth/logout"

    // Mutex flag to avoid concurrent refresh storms
    @Volatile private var isRefreshing = false
    private val refreshLock = Object()

    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()

        // Attach current access token
        val accessToken = runBlocking { preferences.authToken.first() }
        val authedRequest = originalRequest.withBearerToken(accessToken)
        val response = chain.proceed(authedRequest)

        // Only attempt refresh on 401, and not for the refresh or logout endpoints themselves
        val requestPath = originalRequest.url.encodedPath
        if (response.code != 401 || requestPath.contains(refreshPath) || requestPath.contains(logoutPath)) {
            return response
        }

        // Close the failed response body before retrying
        response.close()

        // Synchronize so only one thread refreshes at a time
        synchronized(refreshLock) {
            // Double-check: if another thread already refreshed while we waited,
            // the stored access token will now differ from the one that got the 401
            val currentToken = runBlocking { preferences.authToken.first() }
            if (currentToken != accessToken && currentToken.isNotBlank()) {
                // Token was already refreshed by another thread — just retry with the new one
                return chain.proceed(originalRequest.withBearerToken(currentToken))
            }

            // Attempt to refresh
            val refreshToken = runBlocking { preferences.refreshToken.first() }
            if (refreshToken.isBlank()) {
                // No refresh token — cannot recover; caller will handle the 401
                return chain.proceed(originalRequest.withBearerToken(""))
            }

            val newTokens = performRefresh(chain.request().url.toString(), refreshToken)

            return if (newTokens != null) {
                runBlocking {
                    preferences.setAuthToken(newTokens.first)
                    preferences.setRefreshToken(newTokens.second)
                }
                chain.proceed(originalRequest.withBearerToken(newTokens.first))
            } else {
                // Refresh failed — clear local session so the app shows the login screen
                runBlocking {
                    preferences.clearRefreshToken()
                    preferences.setAuthToken("")
                    preferences.setLoggedIn(false)
                }
                chain.proceed(originalRequest.withBearerToken(""))
            }
        }
    }

    /**
     * Performs the token refresh synchronously using a bare OkHttpClient
     * (separate from Retrofit to avoid circular interceptor dependency).
     * Returns Pair(newAccessToken, newRefreshToken) on success, null on failure.
     */
    private fun performRefresh(originalUrl: String, refreshToken: String): Pair<String, String>? {
        return try {
            // Derive base URL from original request URL
            val uri = okhttp3.HttpUrl.get(originalUrl)
            val baseUrl = "${uri.scheme}://${uri.host}${if (uri.port != -1 && uri.port != 80 && uri.port != 443) ":${uri.port}" else ""}/"
            val refreshUrl = "${baseUrl}${refreshPath}"

            val json = """{"refreshToken":"$refreshToken"}"""
            val body = json.toRequestBody("application/json".toMediaType())
            val request = Request.Builder()
                .url(refreshUrl)
                .post(body)
                .build()

            val client = OkHttpClient()
            val response = client.newCall(request).execute()
            if (!response.isSuccessful) return null

            val responseBody = response.body?.string() ?: return null
            val parsed = Json { ignoreUnknownKeys = true }
                .decodeFromString(RefreshTokenResponse.serializer(), responseBody)

            val newAccess = parsed.token
            val newRefresh = parsed.refreshToken
            if (newAccess.isNullOrBlank() || newRefresh.isNullOrBlank()) null
            else Pair(newAccess, newRefresh)
        } catch (e: Exception) {
            null
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
