package com.notel.notel.notifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

/**
 * Tabs Lab: schedules the daily "How are you feeling?" check-in reminder.
 *
 * Fires once a day at a fixed 4:00 AM local — the same moment the energy day
 * resets — so the reminder always lands at the start of a fresh check-in
 * window. Uses exact alarms like the other reminder schedulers in this
 * package; no-ops when the user has revoked exact-alarm scheduling.
 *
 * The receiver ([EnergyCheckInReminderReceiver]) skips posting when today's
 * feeling entry already exists and re-arms the next day's alarm, so this
 * scheduler only needs to be called on toggle-on, toggle-off (cancel), and
 * device boot.
 */
object EnergyCheckInReminderScheduler {

    const val FIRE_HOUR = 4
    const val FIRE_MINUTE = 0

    /** Unique request code; far from the reminder-id*1000 range used elsewhere. */
    private const val REQUEST_CODE = 770001

    /** Returns true if the app can schedule exact alarms (Android 12+ gating). */
    fun canScheduleExactAlarms(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else true
    }

    /** Schedule (or reschedule) the next 4:00 AM firing. */
    fun schedule(context: Context) {
        if (!canScheduleExactAlarms(context)) return
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, nextFourAm(), buildPendingIntent(context))
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, nextFourAm(), buildPendingIntent(context))
        }
    }

    /** Cancel the scheduled firing (toggle off). */
    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(buildPendingIntent(context))
    }

    /** Next 4:00 AM local wall-clock time; today if not yet passed, else tomorrow. */
    private fun nextFourAm(): Long {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, FIRE_HOUR)
            set(Calendar.MINUTE, FIRE_MINUTE)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        return cal.timeInMillis
    }

    private fun buildPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, EnergyCheckInReminderReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
