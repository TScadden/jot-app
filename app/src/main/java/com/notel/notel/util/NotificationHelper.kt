package com.notel.notel.util

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.notel.notel.MainActivity
import com.notel.notel.R

class NotificationHelper(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "body_load_reminders"
        const val SPIKE_CHANNEL_ID = "hr_spike_alerts"
        const val HABIT_CHANNEL_ID = "habit_reminders"
        const val REPORT_CHANNEL_ID = "ai_graph_reports"
        const val NOTIFICATION_ID = 1001
        const val SPIKE_NOTIFICATION_ID = 1002
        const val HABIT_NOTIFICATION_ID = 1003
        const val REPORT_NOTIFICATION_ID = 1009
    }

    fun showGraphReportNotification() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                REPORT_CHANNEL_ID,
                "AI Graph Reports",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications when a new AI Biometric Graph Report is ready"
                enableVibration(true)
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            putExtra("open_route", "settings_reports")
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(context, REPORT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("📊 AI Graph Analysis Ready!")
            .setContentText("Your web biometric graph report is ready. Tap to view & download.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(REPORT_NOTIFICATION_ID, notification)
    }

    fun showBodyLoadReminder() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Cup Reminders",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Daily reminder to check your Cup level"
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            context, 
            0, 
            intent, 
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note) 
            .setContentTitle("Cup Reminder 🧪")
            .setContentText("Log in and check your score for the day so you can plan better.")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(NOTIFICATION_ID, notification)
    }

    fun showMidDayBodyLoadRefresh() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Score Reminders",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Daily nudge to check your updated Score"
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val content = "Your score has updated. Check it now to plan the rest of your day better."
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note) 
            .setContentTitle("Score Refreshed 🧪")
            .setContentText(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(content))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(NOTIFICATION_ID + 100, notification)
    }

    fun showBodyLoadUpdate(score: Int) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Body Load Updates",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val content = "Your Score for today was $score/100. Plan for tomorrow with your level in mind."
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Daily Score Finalized: $score/100")
            .setContentText(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(content))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(NOTIFICATION_ID, notification)
    }

    fun showSpikeAlert(bpm: Int, baseline: Int? = null, delta: Int? = null) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                SPIKE_CHANNEL_ID,
                "Heart Rate Spike Alerts",
                NotificationManager.IMPORTANCE_HIGH
            )
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val contentText = if (baseline != null && delta != null) {
            "BPM jumped from $baseline to $bpm (+${delta}). Take a break."
        } else {
            "You hit your threshold ($bpm BPM). You should take a break."
        }

        val notification = NotificationCompat.Builder(context, SPIKE_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Heart Rate Spike ⚠️")
            .setContentText(contentText)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(SPIKE_NOTIFICATION_ID, notification)
    }

    fun showHabitReminder() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                HABIT_CHANNEL_ID,
                "Habit Reminders",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val notification = NotificationCompat.Builder(context, HABIT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Finish your habits! ✅")
            .setContentText("You still have some daily habits to check off. Keep your streak alive!")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(HABIT_NOTIFICATION_ID, notification)
    }

    fun showTestReminder(title: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "user_reminders"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Reminders",
                NotificationManager.IMPORTANCE_HIGH
            )
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            putExtra("navigate_to", "reminders")
        }
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Reminder 🔔")
            .setContentText(title)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(3001, notification)
    }

    fun showReportReady(file: java.io.File) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "report_notifications"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Medical Reports",
                NotificationManager.IMPORTANCE_HIGH
            )
            manager.createNotificationChannel(channel)
        }

        val fileUri = androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.provider",
            file
        )

        // Activity for when they tap the notification itself (open App)
        val mainIntent = Intent(context, MainActivity::class.java)
        val mainPendingIntent = PendingIntent.getActivity(context, 0, mainIntent, PendingIntent.FLAG_IMMUTABLE)

        // Intent for the Share action button
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(Intent.EXTRA_STREAM, fileUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(shareIntent, "Share Medical Report")
        val sharePendingIntent = PendingIntent.getActivity(
            context, 
            1, 
            chooser, 
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Clinical Report Ready 📄")
            .setContentText("Your report has been saved to Downloads. Tap to share or review.")
            .setStyle(NotificationCompat.BigTextStyle().bigText("Your professional medical report has been saved to your Downloads folder. Tap this notification to share it or review the file."))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(sharePendingIntent) // Tapping now shares directly
            .addAction(android.R.drawable.ic_menu_share, "Share", sharePendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(2001, notification)
    }

    fun showCsvReady(file: java.io.File) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "csv_notifications"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Biometrics Exports",
                NotificationManager.IMPORTANCE_HIGH
            )
            manager.createNotificationChannel(channel)
        }

        val fileUri = androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.provider",
            file
        )

        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, fileUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(shareIntent, "Share Biometrics CSV")
        val sharePendingIntent = PendingIntent.getActivity(
            context, 
            2, 
            chooser, 
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Biometrics CSV Ready 📊")
            .setContentText("Your biometrics CSV has been saved to Downloads. Tap to share.")
            .setStyle(NotificationCompat.BigTextStyle().bigText("Your biometrics CSV data has been saved to your Downloads folder. Tap this notification to share it or review the file."))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(sharePendingIntent) // Tapping now shares directly
            .addAction(android.R.drawable.ic_menu_share, "Share", sharePendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(2002, notification)
    }

    fun showProjectReminder() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "project_reminders"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Project Reminders",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Daily reminder to complete your Project Focus task"
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Project Focus Nudge ⏳")
            .setContentText("Don't forget to complete your project task for the day.")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(1004, notification)
    }

    fun showEventNotification(eventName: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "event_reminders"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Event Reminders",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Reminders on the day of your scheduled events"
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val content = "Today is the day! Don't forget: $eventName. Open the app for a quick refresher."
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentTitle("Event Today: $eventName 🗓️")
            .setContentText(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(content))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify((eventName + System.currentTimeMillis()).hashCode(), notification)
    }
}
