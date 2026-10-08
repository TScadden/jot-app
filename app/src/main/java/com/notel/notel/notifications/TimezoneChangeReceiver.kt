package com.notel.notel.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.model.ScheduledReportEvent
import com.notel.notel.data.preferences.NotelPreferences
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.inject.Inject

/**
 * Tabs Lab (Phase 2, WS-H): re-arms exact alarms when the timezone
 * changes.
 *
 * Exact alarms fire at UTC millis, but the report prep moments are
 * defined in local wall-clock terms ("9:00 AM the day before, in the
 * event's timezone") — so a timezone change shifts what the stored fire
 * time means. Recompute and re-arm everything: report prep alarms, the
 * legacy appointment nudge, and the daily check-in reminder. Idempotent
 * (same PendingIntents); no-ops for past fire times.
 */
@AndroidEntryPoint
class TimezoneChangeReceiver : BroadcastReceiver() {

    @Inject lateinit var preferences: NotelPreferences

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_TIMEZONE_CHANGED) return
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                // Report prep alarms (the new event model).
                val events = readEvents()
                ReportPrepScheduler.scheduleAll(context, events)
                // Legacy appointment day-before nudge.
                preferences.appointmentDate.first()?.let { dateIso ->
                    AppointmentReminderScheduler.schedule(context, dateIso)
                }
                // Daily check-in reminder.
                if (preferences.checkInReminderEnabled.first()) {
                    EnergyCheckInReminderScheduler.schedule(context)
                }
            } finally {
                pendingResult.finish()
            }
        }
    }

    private suspend fun readEvents(): List<ScheduledReportEvent> {
        return try {
            val raw = preferences.reportEvents.first()
            if (raw.isBlank()) emptyList()
            else Json.decodeFromString(ListSerializer(ScheduledReportEvent.serializer()), raw)
        } catch (_: Exception) {
            emptyList()
        }
    }
}
