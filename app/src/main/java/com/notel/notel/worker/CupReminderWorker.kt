package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first

/**
 * Sends a Cup Reminder if the user hasn't checked their Cup level by the afternoon.
 */
@HiltWorker
class CupReminderWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()
        if (!preferences.bodyLoadRemindersEnabled.first()) return Result.success()

        // Prevent reminder from firing if user opened app today before 9:00 AM
        val today = java.time.LocalDate.now().toString()
        val lastOpen = preferences.lastOpenDate.first()
        if (lastOpen == today) {
            return Result.success()
        }

        // Send a simple reminder notification
        NotificationHelper(applicationContext).showBodyLoadReminder()

        return Result.success()
    }
}
