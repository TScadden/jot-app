package com.notel.notel.data.remote

import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.Response
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthInterceptor @Inject constructor(
    private val preferences: NotelPreferences
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()

        // Sync fetch JWT from preferences
        val token = runBlocking { preferences.authToken.first() } 
        // We now use the dedicated authToken field in preferences to store the JWT.

        val requestBuilder = originalRequest.newBuilder()
        if (token.isNotEmpty()) {
            requestBuilder.header("Authorization", "Bearer $token")
        }

        return chain.proceed(requestBuilder.build())
    }
}
