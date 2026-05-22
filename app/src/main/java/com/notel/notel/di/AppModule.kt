package com.notel.notel.di

import android.content.Context
import com.notel.notel.data.local.NotelDatabase
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import java.util.concurrent.TimeUnit
import javax.inject.Singleton
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.remote.AuthInterceptor
import com.notel.notel.data.remote.JotApi

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): NotelDatabase =
        NotelDatabase.getInstance(context)

    @Provides
    @Singleton
    fun provideLogEntryDao(db: NotelDatabase): LogEntryDao = db.logEntryDao()

    @Provides
    @Singleton
    fun provideCategoryDao(db: NotelDatabase): CategoryDao = db.categoryDao()

    @Provides
    @Singleton
    fun provideKnowledgeDocumentDao(db: NotelDatabase): com.notel.notel.data.local.dao.KnowledgeDocumentDao = 
        db.knowledgeDocumentDao()

    @Provides
    @Singleton
    fun provideReminderDao(db: NotelDatabase): com.notel.notel.data.local.dao.ReminderDao =
        db.reminderDao()

    @Provides
    @Singleton
    fun provideCoachSessionDao(db: NotelDatabase): com.notel.notel.data.local.dao.CoachSessionDao =
        db.coachSessionDao()

    @Provides
    @Singleton
    fun provideCoachMessageDao(db: NotelDatabase): com.notel.notel.data.local.dao.CoachMessageDao =
        db.coachMessageDao()

    @Provides
    @Singleton
    fun provideUserListDao(db: NotelDatabase): com.notel.notel.data.local.dao.UserListDao =
        db.userListDao()

    @Provides
    @Singleton
    fun provideOkHttpClient(authInterceptor: AuthInterceptor): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .addInterceptor(authInterceptor)
        .addInterceptor { chain ->
            // Global rate-limit retry interceptor: retries 429s with exponential backoff
            // Skip auth endpoints — retrying login/register makes rate limiting worse
            val request = chain.request()
            var response = chain.proceed(request)
            val path = request.url.encodedPath
            val isAuthEndpoint = path.contains("/api/auth/")
            
            if (!isAuthEndpoint) {
                var retryCount = 0
                val maxRetries = 2
                var backoffMs = 2000L
                
                while (response.code == 429 && retryCount < maxRetries) {
                    response.close()
                    Thread.sleep(backoffMs)
                    backoffMs *= 2
                    retryCount++
                    response = chain.proceed(request)
                }
            }
            response
        }
        .addInterceptor(HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
        })
        .build()

    @Provides
    @Singleton
    fun provideJotApi(okHttpClient: OkHttpClient): JotApi {
        val json = Json { ignoreUnknownKeys = true }
        return Retrofit.Builder()
            .baseUrl("http://3.138.56.92:3000/")
            .client(okHttpClient)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(JotApi::class.java)
    }

    @Provides
    @Singleton
    fun provideHealthConnectManager(@ApplicationContext context: Context): HealthConnectManager =
        HealthConnectManager(context)
}
