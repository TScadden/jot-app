package com.notel.notel.notifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.notel.notel.data.model.ScheduledReportEvent
import com.notel.notel.data.model.prepFireTimeMs

/**
 * Tabs Lab: preparation-step scheduler for scheduled report events
 * (Phase 2, WS-H).
 *
 * Follows the existing exact-alarm pattern (AppointmentReminderScheduler):
 * a one-shot exact alarm at the event's prep moment (day before / day of
 * at the chosen time, in the event's timezone) fires ReportPrepReceiver,
 * which enqueues the generation WorkManager job. The alarm is the timing
 * mechanism; WorkManager is the execution mechanism (survives process
 * death, dedups by unique work name, retries with backoff).
 *
 * No-ops when exact alarms are revoked, the event is reminder-only, or
 * the fire time has passed. Re-armed on boot, app start, and timezone
 * change (BootReceiver / NotelApp / TimezoneChangeReceiver).
 */
object ReportPrepScheduler {

    const val EXTRA_EVENT_ID = "notel.report_prep_event_id"

    /** Unique request code per event, derived from the event id. */
    private fun requestCodeFor(eventId: String): Int =
        780000 + (eventId.hashCode() and 0x7FFF)

    fun canScheduleExactAlarms(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else true
    }

    /** Schedule (or reschedule) the prep alarm for one event. */
    fun schedule(context: Context, event: ScheduledReportEvent) {
        if (!canScheduleExactAlarms(context)) return
        val fireAt = prepFireTimeMs(event) ?: return
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = buildPendingIntent(context, event.id)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, fireAt, pi)
        }
    }

    /** Cancel the prep alarm for one event (edited to reminder-only / deleted). */
    fun cancel(context: Context, eventId: String) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(buildPendingIntent(context, eventId))
    }

    /** Re-arm every auto-prepare event (boot / app start / timezone change). */
    fun scheduleAll(context: Context, events: List<ScheduledReportEvent>) {
        events.forEach { schedule(context, it) }
    }

    private fun buildPendingIntent(context: Context, eventId: String): PendingIntent {
        val intent = Intent(context, ReportPrepReceiver::class.java).apply {
            putExtra(EXTRA_EVENT_ID, eventId)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCodeFor(eventId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
