package com.notel.notel.playground.flutter.health_connect_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// Refresh keep-alive foreground service (founder-directed
/// Oct 20, 2026).
///
/// This service runs NO health logic and reads NO health data.
/// The device-proven Dart Daily Score refresh pipeline keeps
/// running in the same process / isolate; this service only
/// keeps that process alive across a Recents swipe (its manifest
/// declaration carries android:stopWithTask="false") and carries
/// the mandatory ongoing notification Android requires of a
/// foreground service.
///
/// Copy / channel / visibility are Juno-ruled verbatim (Rulings
/// 1-2, Oct 20, 2026): title "Tabs", body "Refreshing your Daily
/// Score…" (single-character ellipsis, never updated into a
/// result), channel id/name/description exactly as below,
/// importance LOW (no sound / vibration / heads-up), ongoing +
/// non-dismissible while running, onlyAlertOnce, lock-screen
/// visibility PRIVATE with NO custom public version (the system
/// generic redaction is the approved public form). No score, no
/// health values, and no qualitative health language appear in
/// any notification string — the notification carries nothing but
/// the fixed strings below and, in its tap intent, the date.
///
/// Lifecycle: Dart (RefreshKeepAlive) asks the plugin to start
/// this service when a manual refresh flight is claimed and to
/// stop it when that refresh settles; stopping the service is
/// what dismisses the notification — it is never updated into a
/// result. START_NOT_STICKY: if the process dies anyway (force-
/// stop, memory pressure), there is no refresh left to protect,
/// so the service must not resurrect a dangling notification on
/// its own.
class RefreshKeepAliveService : Service() {

    companion object {
        const val CHANNEL_ID = "daily_score_refresh_progress"
        const val CHANNEL_NAME = "Daily Score refresh"
        const val CHANNEL_DESCRIPTION =
            "Shown while a Daily Score refresh you started is finishing."
        const val NOTIFICATION_TITLE = "Tabs"
        const val NOTIFICATION_BODY = "Refreshing your Daily Score…"
        // Distinct from the score-ready notification id (7301).
        const val NOTIFICATION_ID = 7302
        const val ACTION_START =
            "com.notel.notel.playground.flutter.health_connect_bridge.START_REFRESH_KEEP_ALIVE"
        const val ACTION_STOP =
            "com.notel.notel.playground.flutter.health_connect_bridge.STOP_REFRESH_KEEP_ALIVE"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        // A second start while running lands here too: rebuilding
        // with the newest date extra and re-calling startForeground
        // with the SAME notification id keeps exactly one service
        // and exactly one notification (idempotent start).
        val date = intent?.getStringExtra(
            HealthConnectBridgePlugin.SCORE_TAP_DATE_EXTRA
        )
        val notification = buildNotification(date)
        // startForeground MUST land within the platform deadline
        // after ContextCompat.startForegroundService — it is the
        // first thing this command does after building the
        // notification (the channel is created inside the build).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // Stopping the service dismisses the notification — the
        // only way it ever leaves the shade (never updated into
        // a result).
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun createChannel(manager: NotificationManager) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = CHANNEL_DESCRIPTION
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(date: String?): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        createChannel(manager)

        // Tap target: the host app's launch intent (its singleTop
        // MainActivity), reused — never stacked — carrying the
        // refresh date under the plugin's namespaced extra key.
        // MainActivity forwards that extra to the plugin from
        // onCreate / onNewIntent; Dart consumes it through the
        // plugin's takePendingScoreTap channel method.
        val launchIntent =
            packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent()
        val tapIntent = Intent(launchIntent).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
            if (date != null) {
                putExtra(HealthConnectBridgePlugin.SCORE_TAP_DATE_EXTRA, date)
            }
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Small icon: the host app's own icon (its applicationInfo
        // icon resource — the launcher icon), so the keep-alive
        // notification carries the app's identity, not a stock
        // glyph. Falls back to a system icon only if the host
        // somehow declares none.
        val iconRes = applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_dialog_info

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(NOTIFICATION_TITLE)
            .setContentText(NOTIFICATION_BODY)
            .setSmallIcon(iconRes)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
    }
}
