package com.notel.notel

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.*
import dagger.hilt.android.HiltAndroidApp
import com.notel.notel.worker.BiometricsSyncWorker
import com.notel.notel.worker.HrSpikeBackfillWorker
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
        // One-shot daily chain pinned to 7 PM (replaces the old drifting periodic work).
        HabitReminderWorker.schedule(this)
        WorkManager.getInstance(this).cancelUniqueWork("habit_reminder")
        WorkManager.getInstance(this).cancelUniqueWork("cup_reminder")
        // Body Load feature removed: stop the deleted worker's periodic refresh.
        WorkManager.getInstance(this).cancelUniqueWork("BODY_LOAD_REFRESH")
        scheduleProjectReminder()
        BiometricsSyncWorker.schedule(this)
        // One-time 180-day HR spike history backfill (no-op once complete).
        // (The Fitbit Web API backfill was retired with the API on Oct 30, 2026.)
        HrSpikeBackfillWorker.schedule(this)

        // Tabs Lab: re-arm the daily check-in reminder alarm on every app start.
        // Idempotent (same PendingIntent); covers force-stops, which cancel
        // alarms without a later BOOT_COMPLETED to restore them.
        CoroutineScope(Dispatchers.IO).launch {
            try {
                if (preferences.checkInReminderEnabled.first()) {
                    com.notel.notel.notifications.EnergyCheckInReminderScheduler.schedule(this@NotelApp)
                }
                // Progress Reports: re-arm the appointment day-before nudge on every app
                // start (idempotent; covers force-stops which cancel alarms).
                preferences.appointmentDate.first()?.let { dateIso ->
                    com.notel.notel.notifications.AppointmentReminderScheduler.schedule(this@NotelApp, dateIso)
                }
                // Phase 2 (WS-H): re-arm scheduled report-prep alarms on
                // every app start (idempotent; covers force-stops).
                try {
                    val raw = preferences.reportEvents.first()
                    if (raw.isNotBlank()) {
                        val events = kotlinx.serialization.json.Json.decodeFromString(
                            kotlinx.serialization.builtins.ListSerializer(
                                com.notel.notel.data.model.ScheduledReportEvent.serializer()
                            ),
                            raw
                        )
                        com.notel.notel.notifications.ReportPrepScheduler.scheduleAll(this@NotelApp, events)
                    }
                } catch (e: Exception) {
                    android.util.Log.w("NotelApp", "rearmReportPrep failed: ${e.javaClass.simpleName}")
                }
                // Progress Reports: if the event linked to the saved appointment was
                // deleted (Events tab) or dropped by a sync merge, clear the stale
                // appointment instead of resurrecting the event.
                com.notel.notel.appointments.AppointmentEventLink.reconcileAppointmentLink(preferences, this@NotelApp)
            } catch (e: Exception) {
                android.util.Log.e("NotelApp", "Failed to re-arm check-in reminder", e)
            }
        }
        
        // Start HR Monitor Service safely when app enters foreground
        CoroutineScope(Dispatchers.IO).launch {
            lifecycleTracker.isAppInForeground.collectLatest { isForeground ->
                try {
                    if (isForeground && preferences.hrSpikeAlertsEnabled.first()) {
                        try {
                            HrSpikeMonitorService.startService(this@NotelApp)
                        } catch (e: Throwable) {
                            android.util.Log.e("NotelApp", "Failed to start HrSpikeMonitorService foreground service", e)
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("NotelApp", "Health Connect startup check failed", e)
                }
            }
        }
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
