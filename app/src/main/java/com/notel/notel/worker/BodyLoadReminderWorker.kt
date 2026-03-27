package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.local.entity.AiInsight
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@HiltWorker
class BodyLoadReminderWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val logRepository: com.notel.notel.data.repository.LogRepository,
    private val categoryRepository: com.notel.notel.data.repository.CategoryRepository
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()

        val insightsStr = preferences.aiInsights.first()
        val insights: List<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<List<AiInsight>>(insightsStr) else emptyList()
        } catch(e: Exception) { emptyList() }

        val today = System.currentTimeMillis()
        val hasCheckedToday = insights.any { 
            it.type == "BodyLoad" && isSameDay(it.timestamp, today)
        }

        if (hasCheckedToday) return Result.success()

        // Background Auto-Analysis
        val categories = categoryRepository.getAllCategories().first()
        val helper = NotificationHelper(applicationContext)

        logRepository.getBodyLoad(categories).fold(
            onSuccess = { res ->
                if (preferences.dailyCupUpdatesEnabled.first()) {
                    helper.showBodyLoadUpdate(res.score)
                }
            },
            onFailure = {
                if (preferences.bodyLoadRemindersEnabled.first()) {
                    helper.showBodyLoadReminder()
                }
            }
        )

        return Result.success()
    }

    private fun isSameDay(t1: Long, t2: Long): Boolean {
        val d1 = java.time.Instant.ofEpochMilli(t1).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        val d2 = java.time.Instant.ofEpochMilli(t2).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        return d1 == d2
    }
}
