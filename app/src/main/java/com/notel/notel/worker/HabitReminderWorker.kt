package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import java.util.Calendar
import java.util.concurrent.TimeUnit

@HiltWorker
class HabitReminderWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val habitRepository: HabitRepository
) : CoroutineWorker(context, params) {

    companion object {
        /**
         * Unique name for the one-shot daily chain. Deliberately different from the legacy
         * "habit_reminder" periodic work (cancelled in NotelApp on upgrade).
         */
        const val UNIQUE_WORK_NAME = "habit_reminder_daily"

        /**
         * Schedules a one-time run at the next 7:00 PM local time. KEEP policy: if a run is
         * already pending (or currently executing), leave it alone so the daily chain is
         * never duplicated or cancelled mid-flight.
         */
        fun schedule(context: Context) {
            val calendar = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 19)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }

            if (calendar.timeInMillis <= System.currentTimeMillis()) {
                calendar.add(Calendar.DAY_OF_YEAR, 1)
            }

            val delay = calendar.timeInMillis - System.currentTimeMillis()

            val workRequest = OneTimeWorkRequestBuilder<HabitReminderWorker>()
                .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                .addTag("habit_reminder")
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_WORK_NAME,
                ExistingWorkPolicy.KEEP,
                workRequest
            )
        }
    }

    override suspend fun doWork(): Result {
        try {
            if (!preferences.loggedIn.first()) return Result.success()
            if (!preferences.habitReminderEnabled.first()) return Result.success()

            // Sync habits first to get latest state
            habitRepository.fetchHabits()

            val habits = habitRepository.habits.value
            val today = habitRepository.todayDateString()

            val anyUnchecked = habits.any { today !in it.logs }

            if (anyUnchecked) {
                NotificationHelper(applicationContext).showHabitReminder()
            }

            return Result.success()
        } finally {
            // Chain the next day's 7 PM run regardless of early returns above, so the
            // schedule stays pinned to wall-clock time instead of drifting.
            schedule(applicationContext)
        }
    }
}
