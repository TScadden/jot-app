package com.notel.notel.notifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

object EventScheduler {
    fun scheduleEventNotification(context: Context, eventId: String, eventName: String, targetDateMs: Long) {
        if (!ReminderScheduler.canScheduleExactAlarms(context)) return

        val cal = Calendar.getInstance().apply {
            timeInMillis = targetDateMs
            set(Calendar.HOUR_OF_DAY, 9)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }

        val triggerTime = cal.timeInMillis
        val now = System.currentTimeMillis()

        // If target date 9:00 AM has already passed today, do not schedule
        if (triggerTime <= now) return

        val intent = Intent(context, EventReceiver::class.java).apply {
            putExtra(EventReceiver.EXTRA_EVENT_NAME, eventName)
        }

        val requestCode = (eventId.hashCode() and 0x7FFFFFFF)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
        }
    }

    /**
     * Cancel a previously scheduled day-of event notification. Matches the
     * PendingIntent built in [scheduleEventNotification]: extras are ignored
     * for intent matching, so the name extra is not needed here.
     */
    fun cancelEventNotification(context: Context, eventId: String) {
        val intent = Intent(context, EventReceiver::class.java)
        val requestCode = (eventId.hashCode() and 0x7FFFFFFF)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent)
        pendingIntent.cancel()
    }
}
