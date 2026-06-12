package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.ui.viewmodel.FocusStateDto
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.time.ZonedDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

@HiltWorker
class ProjectReminderWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences
) : CoroutineWorker(context, params) {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()
        // Default to true if not set, or read from preference
        val enabled = preferences.projectReminderEnabled.first()
        if (!enabled) return Result.success()

        val focusStateJson = preferences.focusState.first()
        if (focusStateJson.isBlank() || focusStateJson == "{}") return Result.success()

        val parsed = try {
            json.decodeFromString<FocusStateDto>(focusStateJson)
        } catch (e: Exception) {
            null
        }

        if (parsed == null || parsed.activeTests.isEmpty()) return Result.success()

        val todayStr = LocalDate.now().toString()
        val todayToDateString = DateTimeFormatter.ofPattern("EEE MMM dd yyyy", Locale.US)
            .format(ZonedDateTime.now(ZoneId.systemDefault()))

        val anyActiveNeedsCheckIn = parsed.activeTests.any { test ->
            val startMs = test.startTimestamp
            val durationMs = test.durationDays.toLong() * 24L * 60L * 60L * 1000L
            val elapsedMs = System.currentTimeMillis() - startMs
            val isCompleted = elapsedMs >= durationMs

            val isFirstDay = test.lockDayStr == todayToDateString
            val checkedInToday = test.logs.containsKey(todayStr) || isFirstDay

            !isCompleted && !checkedInToday
        }

        if (anyActiveNeedsCheckIn) {
            NotificationHelper(applicationContext).showProjectReminder()
        }

        return Result.success()
    }
}
