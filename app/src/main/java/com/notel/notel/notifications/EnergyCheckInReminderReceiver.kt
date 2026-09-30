package com.notel.notel.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.notel.notel.MainActivity
import com.notel.notel.R
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.ui.viewmodel.ENERGY_CATEGORY_FALLBACK_ID
import com.notel.notel.ui.viewmodel.ENERGY_CATEGORY_SLUG
import com.notel.notel.ui.viewmodel.ENERGY_CHECKIN_SOURCE
import com.notel.notel.ui.viewmodel.energyDayStart
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Tabs Lab: fires the daily check-in reminder at 4:00 AM local.
 *
 * Posts the notification ONLY when no "Energy check-in" entry exists in the
 * current energy-day window (the same 4am-boundary rule the Home card uses):
 * if the user already logged today's feeling, the day stays silent. While the
 * toggle is still on, the next day's alarm is re-armed every firing so the
 * daily chain survives without a boot receiver dependency (boot is also
 * handled separately since alarms do not survive reboots).
 */
@AndroidEntryPoint
class EnergyCheckInReminderReceiver : BroadcastReceiver() {

    @Inject lateinit var preferences: NotelPreferences
    @Inject lateinit var categoryRepository: CategoryRepository
    @Inject lateinit var logEntryDao: LogEntryDao

    companion object {
        const val CHANNEL_ID = "check_in_reminder"
        private const val NOTIFICATION_ID = 770001
    }

    override fun onReceive(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val enabled = preferences.checkInReminderEnabled.first()
                if (!enabled) return@launch

                if (preferences.loggedIn.first() && !hasLoggedTodaysCheckIn()) {
                    showNotification(context)
                }

                // Re-arm tomorrow's firing while the toggle is on.
                EnergyCheckInReminderScheduler.schedule(context)
            } finally {
                pendingResult.finish()
            }
        }
    }

    /**
     * True when an entry with source "Energy check-in" exists inside the
     * current energy-day window (starts at 4am local). Mirrors the visibility
     * rule in EnergyCheckInViewModel; deleting the entry restores eligibility.
     */
    private suspend fun hasLoggedTodaysCheckIn(): Boolean {
        val categoryId = try {
            categoryRepository.findCategoryIdBySlug(ENERGY_CATEGORY_SLUG, ENERGY_CATEGORY_FALLBACK_ID)
        } catch (e: Exception) {
            ENERGY_CATEGORY_FALLBACK_ID
        }
        val windowStart = energyDayStart()
        val startMillis = windowStart.toInstant().toEpochMilli()
        val endMillis = windowStart.plusDays(1).toInstant().toEpochMilli()
        return try {
            logEntryDao.getEntriesByCategory(categoryId).first().any { entry ->
                entry.source == ENERGY_CHECKIN_SOURCE &&
                    entry.timestamp in startMillis until endMillis
            }
        } catch (e: Exception) {
            // If the database cannot be read, do not notify: a silent day is
            // safer than a wrong one. The alarm chain is still re-armed.
            true
        }
    }

    private fun showNotification(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Check in reminders",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Daily morning check in reminder"
            }
            manager.createNotificationChannel(channel)
        }

        // Opens the app to the Home screen: MainActivity's splash routes
        // logged-in users straight to the body_load route.
        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("How are you feeling?")
            .setContentText("Tap to log today's check in.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(NOTIFICATION_ID, notification)
    }
}
