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
        const val NOTIFICATION_ID = 1001
        const val SPIKE_NOTIFICATION_ID = 1002
        const val HABIT_NOTIFICATION_ID = 1003
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
            .setSmallIcon(R.drawable.ic_noti_j) 
            .setContentTitle("Cup Reminder 🧪")
            .setContentText("You haven't checked it today. Check to plan better.")
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
                "Cup Reminders",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Daily nudge to check your updated Cup level"
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_j) 
            .setContentTitle("Cup Status Refreshed 🧪")
            .setContentText("Your score has updated. Check it now to plan the rest of your day better.")
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

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_noti_j)
            .setContentTitle("Daily Cup Finalized: $score/100")
            .setContentText("Your Cup level for today was $score/100. Plan for tomorrow with your level in mind.")
            .setStyle(NotificationCompat.BigTextStyle().bigText("Your Cup level for today was $score/100. Plan for tomorrow with your level in mind."))
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
            .setSmallIcon(R.drawable.ic_noti_j)
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
            .setSmallIcon(R.drawable.ic_noti_j)
            .setContentTitle("Finish your habits! ✅")
            .setContentText("You still have some daily habits to check off. Keep your streak alive!")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        manager.notify(HABIT_NOTIFICATION_ID, notification)
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
            .setSmallIcon(R.drawable.ic_noti_j)
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
}
