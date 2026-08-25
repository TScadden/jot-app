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

@Singleton
class AuthInterceptor @Inject constructor(
    private val preferences: NotelPreferences
) : Interceptor {

    private val refreshPath = "api/auth/refresh-token"
    private val logoutPath = "api/auth/logout"

    // Use ReentrantLock for structured, professional concurrent request holding
    private val refreshLock = ReentrantLock()

    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()

        // Attach current access token
        val accessToken = runBlocking { preferences.authToken.first() }
        val authedRequest = originalRequest.withBearerToken(accessToken)
        val response = chain.proceed(authedRequest)

        // Only attempt refresh on 401, and not for refresh/logout endpoints
        val requestPath = originalRequest.url.encodedPath
        if (response.code != 401 || requestPath.contains(refreshPath) || requestPath.contains(logoutPath)) {
            return response
        }

        // Close the failed response body before retrying
        response.close()

        // Structured shared concurrency: lock and check if token changed while waiting
        refreshLock.lock()
        try {
            val currentToken = runBlocking { preferences.authToken.first() }
            if (currentToken != accessToken && currentToken.isNotBlank()) {
                // Another request already completed the refresh successfully
                return chain.proceed(originalRequest.withBearerToken(currentToken))
            }

            // Attempt to refresh
            val refreshToken = runBlocking { preferences.refreshToken.first() }
            if (refreshToken.isBlank()) {
                return chain.proceed(originalRequest.withBearerToken(""))
            }

            val newTokens = performRefresh(originalRequest.url, refreshToken)

            return if (newTokens != null) {
                runBlocking {
                    preferences.setAuthToken(newTokens.first)
                    preferences.setRefreshToken(newTokens.second)
                }
                chain.proceed(originalRequest.withBearerToken(newTokens.first))
            } else {
                // Refresh failed — clear local session completely
                runBlocking {
                    preferences.clearRefreshToken()
                    preferences.setAuthToken("")
                    preferences.setLoggedIn(false)
                }
                chain.proceed(originalRequest.withBearerToken(""))
            }
        } finally {
            refreshLock.unlock()
        }
    }

    /**
     * Performs the token refresh synchronously using a bare OkHttpClient.
     */
    private fun performRefresh(originalUrl: okhttp3.HttpUrl, refreshToken: String): Pair<String, String>? {
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
                if (!response.isSuccessful) return null

                val responseBody = response.body?.string() ?: return null
                val parsed = Json { ignoreUnknownKeys = true }
                    .decodeFromString(RefreshTokenResponse.serializer(), responseBody)

                val newAccess = parsed.token
                val newRefresh = parsed.refreshToken
                if (newAccess.isNullOrBlank() || newRefresh.isNullOrBlank()) null
                else Pair(newAccess, newRefresh)
            }
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
