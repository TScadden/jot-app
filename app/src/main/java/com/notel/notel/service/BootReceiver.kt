package com.notel.notel.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.ReminderRepository
import com.notel.notel.notifications.EventScheduler
import com.notel.notel.ui.viewmodel.EventCounterDto
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.inject.Inject

@AndroidEntryPoint
class BootReceiver : BroadcastReceiver() {

    @Inject lateinit var preferences: NotelPreferences
    @Inject lateinit var reminderRepository: ReminderRepository

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            CoroutineScope(Dispatchers.IO).launch {
                // Restart HR spike monitor if enabled
                if (preferences.hrSpikeAlertsEnabled.first()) {
                    HrSpikeMonitorService.startService(context)
                }
                // Reschedule all active reminders (alarms don't survive reboots)
                reminderRepository.rescheduleAll()
                // Reschedule event-counter day-of alarms (one-shot exact alarms don't survive reboots either)
                rescheduleEventCounters(context)
                // Tabs Lab: re-arm the daily check-in reminder (alarms don't survive reboots)
                if (preferences.checkInReminderEnabled.first()) {
                    com.notel.notel.notifications.EnergyCheckInReminderScheduler.schedule(context)
                }
                // Tabs Lab: re-arm the appointment day-before nudge (one-shot alarms don't survive reboots)
                preferences.appointmentDate.first()?.let { dateIso ->
                    com.notel.notel.notifications.AppointmentReminderScheduler.schedule(context, dateIso)
                }
                // Phase 2 (WS-H): re-arm scheduled report-prep alarms.
                rearmReportPrep(context)
            }
        }
    }

    private suspend fun rescheduleEventCounters(context: Context) {
        val json = preferences.eventCounters.first()
        val counters = try {
            if (json.isNotBlank()) Json.decodeFromString(ListSerializer(EventCounterDto.serializer()), json)
            else emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        // scheduleEventNotification no-ops for past dates; skip archived and count-up events.
        counters.filter { !it.isArchived && !it.isUp }.forEach { counter ->
            EventScheduler.scheduleEventNotification(context, counter.id, counter.name, counter.targetDate)
        }
    }

    /**
     * Phase 2 (WS-H): re-arm scheduled report-prep alarms after boot.
     * Idempotent; no-ops for reminder-only events and past fire times.
     */
    private suspend fun rearmReportPrep(context: Context) {
        try {
            val raw = preferences.reportEvents.first()
            if (raw.isBlank()) return
            val events = Json.decodeFromString(
                kotlinx.serialization.builtins.ListSerializer(
                    com.notel.notel.data.model.ScheduledReportEvent.serializer()
                ),
                raw
            )
            com.notel.notel.notifications.ReportPrepScheduler.scheduleAll(context, events)
        } catch (e: Exception) {
            android.util.Log.w("BootReceiver", "rearmReportPrep failed: ${e.javaClass.simpleName}")
        }
    }
}
