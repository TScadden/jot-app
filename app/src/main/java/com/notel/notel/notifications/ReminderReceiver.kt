package com.notel.notel.notifications

import android.app.AlarmManager
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
import com.notel.notel.data.local.entity.Reminder
import java.util.Calendar

class ReminderReceiver : BroadcastReceiver() {

    companion object {
        const val CHANNEL_ID = "user_reminders"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val reminderId    = intent.getIntExtra(ReminderScheduler.EXTRA_REMINDER_ID, -1)
        val title         = intent.getStringExtra(ReminderScheduler.EXTRA_REMINDER_TITLE) ?: return
        val type          = intent.getStringExtra(ReminderScheduler.EXTRA_REMINDER_TYPE) ?: return
        val fixedHour     = intent.getIntExtra(ReminderScheduler.EXTRA_FIXED_HOUR, 12)
        val fixedMinute   = intent.getIntExtra(ReminderScheduler.EXTRA_FIXED_MINUTE, 0)
        val intervalHours = intent.getIntExtra(ReminderScheduler.EXTRA_INTERVAL_HOURS, 2)
        val startHour     = intent.getIntExtra(ReminderScheduler.EXTRA_START_HOUR, 8)
        val startMinute   = intent.getIntExtra(ReminderScheduler.EXTRA_START_MINUTE, 0)
        val endHour       = intent.getIntExtra(ReminderScheduler.EXTRA_END_HOUR, 21)
        val endMinute     = intent.getIntExtra(ReminderScheduler.EXTRA_END_MINUTE, 0)
        val slotIndex     = intent.getIntExtra(ReminderScheduler.EXTRA_SLOT_INDEX, 0)

        // Show the notification
        showNotification(context, reminderId, title)

        // Reschedule next occurrence
        val reminder = Reminder(
            id            = reminderId,
            title         = title,
            type          = type,
            fixedHour     = fixedHour,
            fixedMinute   = fixedMinute,
            intervalHours = intervalHours,
            startHour     = startHour,
            startMinute   = startMinute,
            endHour       = endHour,
            endMinute     = endMinute,
            isEnabled     = true
        )

        when (type) {
            "FIXED" -> {
                // Reschedule for same time tomorrow
                val tomorrow = Calendar.getInstance().apply {
                    set(Calendar.HOUR_OF_DAY, fixedHour)
                    set(Calendar.MINUTE, fixedMinute)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                    add(Calendar.DAY_OF_YEAR, 1)
                }
                setExact(context, tomorrow.timeInMillis, buildPendingIntent(context, reminder, slotIndex = 0))
            }
            "INTERVAL" -> {
                // Find next slot after the current one; if none left today, schedule all for tomorrow
                val slots = ReminderScheduler.computeSlots(reminder)
                val now = System.currentTimeMillis()
                val nextSlot = slots.drop(slotIndex + 1).firstOrNull { it > now }
                if (nextSlot != null) {
                    val nextIndex = slots.indexOf(nextSlot)
                    setExact(context, nextSlot, buildPendingIntent(context, reminder, slotIndex = nextIndex))
                } else {
                    // No more slots today — schedule all slots for tomorrow
                    slots.forEachIndexed { idx, slotMs ->
                        setExact(
                            context,
                            slotMs + AlarmManager.INTERVAL_DAY,
                            buildPendingIntent(context, reminder, slotIndex = idx)
                        )
                    }
                }
            }
        }
    }

    private fun showNotification(context: Context, reminderId: Int, title: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Reminders",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Personal reminder notifications"
            }
            manager.createNotificationChannel(channel)
        }

        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            putExtra("navigate_to", "habits") // Open the Daily Routine screen
        }
        val pendingIntent = PendingIntent.getActivity(
            context, reminderId, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_j)
            .setContentTitle("Reminder 🔔")
            .setContentText(title)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(reminderId + 3000, notification)
    }

    private fun setExact(context: Context, triggerMs: Long, pi: PendingIntent) {
        if (!ReminderScheduler.canScheduleExactAlarms(context)) return
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerMs, pi)
        } else {
            am.setExact(AlarmManager.RTC_WAKEUP, triggerMs, pi)
        }
    }

    private fun buildPendingIntent(context: Context, reminder: Reminder, slotIndex: Int): PendingIntent {
        val requestCode = reminder.id * 1000 + slotIndex
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            putExtra(ReminderScheduler.EXTRA_REMINDER_ID, reminder.id)
            putExtra(ReminderScheduler.EXTRA_REMINDER_TITLE, reminder.title)
            putExtra(ReminderScheduler.EXTRA_REMINDER_TYPE, reminder.type)
            putExtra(ReminderScheduler.EXTRA_FIXED_HOUR, reminder.fixedHour)
            putExtra(ReminderScheduler.EXTRA_FIXED_MINUTE, reminder.fixedMinute)
            putExtra(ReminderScheduler.EXTRA_INTERVAL_HOURS, reminder.intervalHours)
            putExtra(ReminderScheduler.EXTRA_START_HOUR, reminder.startHour)
            putExtra(ReminderScheduler.EXTRA_START_MINUTE, reminder.startMinute)
            putExtra(ReminderScheduler.EXTRA_END_HOUR, reminder.endHour)
            putExtra(ReminderScheduler.EXTRA_END_MINUTE, reminder.endMinute)
            putExtra(ReminderScheduler.EXTRA_SLOT_INDEX, slotIndex)
        }
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
