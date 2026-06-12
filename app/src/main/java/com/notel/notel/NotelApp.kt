package com.notel.notel

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.*
import dagger.hilt.android.HiltAndroidApp
import com.notel.notel.worker.BodyLoadReminderWorker
import com.notel.notel.worker.BiometricsSyncWorker
import com.notel.notel.worker.CupReminderWorker
import com.notel.notel.worker.HabitReminderWorker
import com.notel.notel.worker.ProjectReminderWorker
import com.notel.notel.service.HrSpikeMonitorService
import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit
import java.util.Calendar
import javax.inject.Inject

@HiltAndroidApp
class NotelApp : Application(), Configuration.Provider {

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    @Inject
    lateinit var preferences: NotelPreferences

    @Inject
    lateinit var lifecycleTracker: com.notel.notel.util.AppLifecycleTracker

    override val workManagerConfiguration: androidx.work.Configuration
        get() = androidx.work.Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()

    override fun onCreate() {
        super.onCreate()
        lifecycleTracker.startTracking()
        scheduleHabitReminder()
        scheduleCupReminder()
        scheduleProjectReminder()
        com.notel.notel.worker.RedditRefreshWorker.schedule(this)
        BiometricsSyncWorker.schedule(this)
        
        // Start HR Monitor Service safely when app enters foreground
        CoroutineScope(Dispatchers.IO).launch {
            lifecycleTracker.isAppInForeground.collectLatest { isForeground ->
                try {
                    if (isForeground && preferences.hrSpikeAlertsEnabled.first()) {
                        HrSpikeMonitorService.startService(this@NotelApp)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
    }

    private fun scheduleHabitReminder() {
        val calendar = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 19)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
        }
        
        if (calendar.timeInMillis <= System.currentTimeMillis()) {
            calendar.add(Calendar.DAY_OF_YEAR, 1)
        }

        val delay = calendar.timeInMillis - System.currentTimeMillis()

        val dailyWorkRequest = PeriodicWorkRequestBuilder<HabitReminderWorker>(24, TimeUnit.HOURS)
            .setInitialDelay(delay, TimeUnit.MILLISECONDS)
            .addTag("habit_reminder")
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "habit_reminder",
            ExistingPeriodicWorkPolicy.UPDATE,
            dailyWorkRequest
        )
    }

    private fun scheduleCupReminder() {
        val calendar = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 9) // 9:00 AM
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
        }
        
        if (calendar.timeInMillis <= System.currentTimeMillis()) {
            calendar.add(Calendar.DAY_OF_YEAR, 1)
        }

        val delay = calendar.timeInMillis - System.currentTimeMillis()

        val dailyWorkRequest = PeriodicWorkRequestBuilder<CupReminderWorker>(24, TimeUnit.HOURS)
            .setInitialDelay(delay, TimeUnit.MILLISECONDS)
            .addTag("cup_reminder")
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "cup_reminder",
            ExistingPeriodicWorkPolicy.UPDATE,
            dailyWorkRequest
        )
    }

    private fun scheduleProjectReminder() {
        val calendar = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 20) // 8:00 PM
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
        }
        
        if (calendar.timeInMillis <= System.currentTimeMillis()) {
            calendar.add(Calendar.DAY_OF_YEAR, 1)
        }

        val delay = calendar.timeInMillis - System.currentTimeMillis()

        val dailyWorkRequest = PeriodicWorkRequestBuilder<ProjectReminderWorker>(24, TimeUnit.HOURS)
            .setInitialDelay(delay, TimeUnit.MILLISECONDS)
            .addTag("project_reminder")
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "project_reminder",
            ExistingPeriodicWorkPolicy.UPDATE,
            dailyWorkRequest
        )
    }
}
