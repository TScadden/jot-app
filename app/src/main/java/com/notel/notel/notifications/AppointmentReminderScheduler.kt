package com.notel.notel.notifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * Tabs Lab: day-before nudge for a saved Progress Reports appointment.
 *
 * When the user saves an appointment date on the Progress Reports screen,
 * this schedules a one-shot exact alarm for 9:00 AM local on the day before
 * the visit, reminding them to export the report. One-shot: it does not
 * re-arm itself. Re-armed on boot and on app start while the saved date is
 * still in the future.
 *
 * Follows the same exact-alarm pattern as EnergyCheckInReminderScheduler;
 * no-ops when the user has revoked exact-alarm scheduling or when 9 AM the
 * day before has already passed.
 */
object AppointmentReminderScheduler {

    /** Unique request code; far from the other reminder ranges. */
    private const val REQUEST_CODE = 770002

    /** Returns true if the app can schedule exact alarms (Android 12+ gating). */
    fun canScheduleExactAlarms(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else true
    }

    /**
     * Schedule (or reschedule) the day-before nudge for an appointment.
     * [dateIso] is "yyyy-MM-dd" (UTC), as stored by the Progress Reports
     * appointment card. No-ops when the fire time has already passed.
     */
    fun schedule(context: Context, dateIso: String) {
        if (!canScheduleExactAlarms(context)) return
        val fireAt = dayBeforeNineAm(dateIso) ?: return
        if (fireAt <= System.currentTimeMillis()) return
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, buildPendingIntent(context))
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, fireAt, buildPendingIntent(context))
        }
    }

    /** Cancel the scheduled nudge (appointment cleared). */
    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(buildPendingIntent(context))
    }

    /**
     * 9:00 AM local on the day before [dateIso]. Returns null when the ISO
     * date cannot be parsed.
     */
    fun dayBeforeNineAm(dateIso: String): Long? {
        val parsed = try {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.parse(dateIso)
        } catch (_: Exception) {
            null
        } ?: return null
        val cal = Calendar.getInstance().apply {
            timeInMillis = parsed.time
            add(Calendar.DAY_OF_YEAR, -1)
            set(Calendar.HOUR_OF_DAY, 9)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return cal.timeInMillis
    }

    private fun buildPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, AppointmentReminderReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
