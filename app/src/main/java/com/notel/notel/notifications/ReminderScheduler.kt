package com.notel.notel.notifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.notel.notel.data.local.entity.Reminder
import java.util.Calendar

object ReminderScheduler {

    const val EXTRA_REMINDER_ID    = "reminder_id"
    const val EXTRA_REMINDER_TITLE = "reminder_title"
    const val EXTRA_REMINDER_TYPE  = "reminder_type"
    const val EXTRA_FIXED_HOUR     = "fixed_hour"
    const val EXTRA_FIXED_MINUTE   = "fixed_minute"
    const val EXTRA_INTERVAL_HOURS   = "interval_hours"
    const val EXTRA_INTERVAL_MINUTES = "interval_minutes"
    const val EXTRA_START_HOUR       = "start_hour"
    const val EXTRA_START_MINUTE     = "start_minute"
    const val EXTRA_END_HOUR         = "end_hour"
    const val EXTRA_END_MINUTE       = "end_minute"
    const val EXTRA_SLOT_INDEX       = "slot_index"
    const val EXTRA_DAYS_CONFIG      = "days_config"

    /** Returns true if the app can schedule exact alarms (Android 12+ gating). */
    fun canScheduleExactAlarms(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else true
    }

    /** Schedule (or reschedule) all alarms for the given reminder. */
    fun schedule(context: Context, reminder: Reminder) {
        if (!reminder.isEnabled) {
            cancel(context, reminder)
            return
        }
        if (!canScheduleExactAlarms(context)) return

        when (reminder.type) {
            "FIXED"    -> scheduleFixed(context, reminder)
            "INTERVAL" -> scheduleInterval(context, reminder)
        }
    }

    /** Cancel all alarms for the given reminder. */
    fun cancel(context: Context, reminder: Reminder) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // Cancel the single FIXED legacy alarm
        am.cancel(buildPendingIntent(context, reminder, slotIndex = 0))
        // Cancel weekday specific alarms (1 to 7 corresponding to Calendar.SUNDAY to Calendar.SATURDAY)
        for (i in 1..7) {
            am.cancel(buildPendingIntent(context, reminder, slotIndex = i))
        }
        // Cancel up to 48 INTERVAL slots
        for (i in 0..47) {
            am.cancel(buildPendingIntent(context, reminder, slotIndex = i))
        }
    }

    // ── Fixed ─────────────────────────────────────────────────────────────

    private fun scheduleFixed(context: Context, reminder: Reminder) {
        if (reminder.daysOfWeekConfig.isNotBlank()) {
            try {
                val configs = kotlinx.serialization.json.Json.decodeFromString<List<com.notel.notel.data.local.entity.DayTimeConfig>>(reminder.daysOfWeekConfig)
                val enabledConfigs = configs.filter { it.isEnabled }
                if (enabledConfigs.isNotEmpty()) {
                    for (config in enabledConfigs) {
                        val trigger = nextWeekdayOccurrence(config.dayOfWeek, config.hour, config.minute)
                        setExact(context, trigger, buildPendingIntent(context, reminder, slotIndex = config.dayOfWeek))
                    }
                    return
                }
            } catch (e: Exception) {
                // Fallback to legacy daily if parsing fails
            }
        }
        val trigger = nextOccurrence(reminder.fixedHour, reminder.fixedMinute)
        setExact(context, trigger, buildPendingIntent(context, reminder, slotIndex = 0))
    }

    // ── Interval ──────────────────────────────────────────────────────────

    private fun scheduleInterval(context: Context, reminder: Reminder) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val slots = computeSlots(reminder)
        val now = System.currentTimeMillis()

        slots.forEachIndexed { index, triggerMs ->
            val adjustedTrigger = if (triggerMs <= now) {
                // Already passed today — schedule for tomorrow
                triggerMs + AlarmManager.INTERVAL_DAY
            } else {
                triggerMs
            }
            setExact(context, adjustedTrigger, buildPendingIntent(context, reminder, slotIndex = index))
        }
    }

    /** Compute all wall-clock trigger times for today for an INTERVAL reminder. */
    fun computeSlots(reminder: Reminder): List<Long> {
        val slots = mutableListOf<Long>()
        val addHours = reminder.intervalHours
        val addMinutes = reminder.intervalMinutes
        if (addHours == 0 && addMinutes == 0) {
            return slots // Prevent infinite loop
        }

        val cal = Calendar.getInstance().apply {
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            set(Calendar.HOUR_OF_DAY, reminder.startHour)
            set(Calendar.MINUTE, reminder.startMinute)
        }
        val endMs = Calendar.getInstance().apply {
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            set(Calendar.HOUR_OF_DAY, reminder.endHour)
            set(Calendar.MINUTE, reminder.endMinute)
        }.timeInMillis

        while (cal.timeInMillis <= endMs) {
            slots.add(cal.timeInMillis)
            cal.add(Calendar.HOUR_OF_DAY, addHours)
            cal.add(Calendar.MINUTE, addMinutes)
        }
        return slots
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /** Returns the next wall-clock time for hour:minute (today if not yet passed, else tomorrow). */
    private fun nextOccurrence(hour: Int, minute: Int): Long {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        return cal.timeInMillis
    }

    private fun nextWeekdayOccurrence(dayOfWeek: Int, hour: Int, minute: Int): Long {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val now = Calendar.getInstance()
        while (cal.get(Calendar.DAY_OF_WEEK) != dayOfWeek || cal.timeInMillis <= now.timeInMillis) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        return cal.timeInMillis
    }

    private fun setExact(context: Context, triggerMs: Long, pi: PendingIntent) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerMs, pi)
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, triggerMs, pi)
        }
    }

    private fun buildPendingIntent(context: Context, reminder: Reminder, slotIndex: Int): PendingIntent {
        // Unique request code: FIXED uses id*1000, INTERVAL uses id*1000+slot
        val requestCode = reminder.id * 1000 + slotIndex
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            putExtra(EXTRA_REMINDER_ID, reminder.id)
            putExtra(EXTRA_REMINDER_TITLE, reminder.title)
            putExtra(EXTRA_REMINDER_TYPE, reminder.type)
            putExtra(EXTRA_FIXED_HOUR, reminder.fixedHour)
            putExtra(EXTRA_FIXED_MINUTE, reminder.fixedMinute)
            putExtra(EXTRA_INTERVAL_HOURS, reminder.intervalHours)
            putExtra(EXTRA_INTERVAL_MINUTES, reminder.intervalMinutes)
            putExtra(EXTRA_START_HOUR, reminder.startHour)
            putExtra(EXTRA_START_MINUTE, reminder.startMinute)
            putExtra(EXTRA_END_HOUR, reminder.endHour)
            putExtra(EXTRA_END_MINUTE, reminder.endMinute)
            putExtra(EXTRA_SLOT_INDEX, slotIndex)
            putExtra(EXTRA_DAYS_CONFIG, reminder.daysOfWeekConfig)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
