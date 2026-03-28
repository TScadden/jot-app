package com.notel.notel.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.notel.notel.MainActivity
import com.notel.notel.R
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.util.NotificationHelper
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import javax.inject.Inject

@AndroidEntryPoint
class HrSpikeMonitorService : Service() {

    @Inject
    lateinit var preferences: NotelPreferences

    @Inject
    lateinit var healthConnectManager: HealthConnectManager

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var monitorJob: Job? = null

    companion object {
        private const val NOTIFICATION_ID = 5001
        private const val CHANNEL_ID = "hr_monitor_service"
        
        fun startService(context: Context) {
            val intent = Intent(context, HrSpikeMonitorService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(context: Context) {
            val intent = Intent(context, HrSpikeMonitorService::class.java)
            context.stopService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (monitorJob == null || !monitorJob!!.isActive) {
            startMonitoring()
        }
        return START_STICKY
    }

    private fun startMonitoring() {
        monitorJob = serviceScope.launch {
            while (isActive) {
                val enabled = preferences.hrSpikeAlertsEnabled.first()
                if (!enabled) {
                    stopSelf()
                    break
                }

                val lastAlertTime = preferences.hrLastAlertTime.first()
                val currentTime = System.currentTimeMillis()
                val cooldownRemaining = 300000L - (currentTime - lastAlertTime)

                if (cooldownRemaining > 0) {
                    // We are in a 10-minute cooldown, so wait the remaining time
                    delay(cooldownRemaining + 5000L) // +5s buffer
                } else {
                    checkSpikes()
                    delay(120000L) // 2 minutes normal check
                }
            }
        }
    }

    private suspend fun checkSpikes() {
        val staticThreshold = preferences.spikeThreshold.first()
        val deltaEnabled = preferences.hrDeltaEnabled.first()
        val deltaThreshold = preferences.spikeDeltaThreshold.first()

        try {
            val intraday = healthConnectManager.readHeartRateIntraday("today")
            if (intraday.isNotEmpty()) {
                val bpmList = intraday.map { it.second }.sorted()
                val latestBpm = intraday.last().second
                
                // Calculate daily baseline (10th percentile) for delta comparison
                val p10Index = (bpmList.size * 0.10).toInt().coerceAtLeast(0)
                val baseline = bpmList[p10Index]
                val currentDelta = latestBpm - baseline

                val isStaticSpike = latestBpm >= staticThreshold
                val isDeltaSpike = deltaEnabled && currentDelta >= deltaThreshold
                
                if (isStaticSpike || isDeltaSpike) {
                    val lastAlertTime = preferences.hrLastAlertTime.first()
                    val currentTime = System.currentTimeMillis()
                    
                    if (currentTime - lastAlertTime > 300000L) { // 5 minute cooldown
                        withContext(Dispatchers.Main) {
                            NotificationHelper(this@HrSpikeMonitorService).showSpikeAlert(latestBpm, baseline, currentDelta)
                        }
                        preferences.setHrLastAlertTime(currentTime)
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun createNotification(): android.app.Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Spike Monitor Active")
            .setContentText("Jot is monitoring your heart rate for spikes.")
            .setSmallIcon(R.drawable.ic_noti_j)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Heart Rate Monitor",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }
}
