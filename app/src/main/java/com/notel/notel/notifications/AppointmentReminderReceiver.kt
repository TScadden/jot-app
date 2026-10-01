package com.notel.notel.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.preferences.NotelPreferences
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.inject.Inject

/**
 * Tabs Lab: fires the Progress Reports appointment nudge at 9:00 AM local
 * the day before a saved appointment.
 *
 * Posts the notification only when the saved appointment date is today or
 * in the future (a stale alarm firing late stays silent). One-shot: it does
 * not re-arm itself; the saved appointment card keeps the date until the
 * user clears it or saves a new one.
 */
@AndroidEntryPoint
class AppointmentReminderReceiver : BroadcastReceiver() {

    @Inject lateinit var preferences: NotelPreferences

    override fun onReceive(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val dateIso = preferences.appointmentDate.first()
                if (dateIso.isNullOrBlank()) return@launch
                if (!preferences.loggedIn.first()) return@launch
                if (isPast(dateIso)) return@launch

                val typeKey = preferences.appointmentReportType.first()
                val typeLabel = when (typeKey) {
                    "training" -> "Training"
                    "custom" -> "Custom"
                    else -> "Health"
                }
                val dateLabel = try {
                    val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                        timeZone = TimeZone.getTimeZone("UTC")
                    }.parse(dateIso)
                    if (parsed != null) SimpleDateFormat("MMM d", Locale.US).format(parsed) else dateIso
                } catch (_: Exception) {
                    dateIso
                }
                com.notel.notel.util.NotificationHelper(context)
                    .showAppointmentReminder(typeLabel, dateLabel)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private fun isPast(dateIso: String): Boolean {
        val todayIso = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())
        return dateIso < todayIso
    }
}
