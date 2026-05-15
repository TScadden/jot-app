package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.*
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import java.util.concurrent.TimeUnit

@HiltWorker
class BodyLoadWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository
) : CoroutineWorker(context, params) {

    private val weatherApi = com.notel.notel.data.remote.WeatherApi()

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()

        val lastRefresh = preferences.lastBodyLoadRefresh.first()
        val now = System.currentTimeMillis()
        
        // Random notification logic: 12 PM - 5 PM
        val currentHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
        val todayStr = java.time.LocalDate.now().toString()
        val lastNotifDate = preferences.lastDynamicNotificationDate.first()
        val remindersEnabled = preferences.bodyLoadRemindersEnabled.first()
        
        if (remindersEnabled && lastNotifDate != todayStr && currentHour in 12..17) {
             // We roll a 50% chance to send it now, but if it's already after 3pm we just send it 
             // to ensure it happens before the window closes.
             val roll = (0..100).random()
             if (roll > 50 || currentHour >= 15) {
                com.notel.notel.util.NotificationHelper(applicationContext).showMidDayBodyLoadRefresh()
                preferences.setLastDynamicNotificationDate(todayStr)
             }
        }

        try {
            // Update weather using persistent location
            val lat = preferences.lastKnownLat.first().takeIf { it != 0.0 }
            val lon = preferences.lastKnownLon.first().takeIf { it != 0.0 }
            val city = preferences.lastKnownCity.first()
            
            if (lat != null && lon != null) {
                weatherApi.getDetailedWeather(lat, lon, city)
            }

            // Sync Health Connect Data (Every 30 minutes)
            try {
                logRepository.getDailyStatsSummary(todayStr, forceRefresh = true)
            } catch (e: Exception) {
                // Ignore health connect sync error
            }

            // Safety check: Don't run AI fetch if refreshed within last 2.5 hours
            if ((now - lastRefresh) < (2.5 * 60 * 60 * 1000L)) {
                return Result.success()
            }

            val categories = categoryRepository.getAllCategories().first()
            if (categories.isEmpty()) return Result.success()

            val result = logRepository.getBodyLoad(categories)
            result.onSuccess { res ->
                preferences.setLastBodyLoadRefresh(System.currentTimeMillis())
                preferences.setLastBodyLoadData(
                    res.score,
                    res.factors.joinToString(", "),
                    res.advice ?: ""
                )
            }
        } catch (e: Exception) {
            return Result.retry()
        }

        return Result.success()
    }

    companion object {
        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<BodyLoadWorker>(30, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .addTag("BODY_LOAD_REFRESH")
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "BODY_LOAD_REFRESH",
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }
    }
}
