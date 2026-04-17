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
        val notification = createNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            // If foreground start fails, the service will likely be killed by the system,
            // but at least it won't crash the entire app process.
        }
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

                checkSpikes()
                delay(30000L) // 30 seconds check for near real-time response
            }
        }
    }

    private suspend fun checkSpikes() {
        val staticThreshold = preferences.spikeThreshold.first()
        val deltaEnabled = preferences.hrDeltaEnabled.first()
        val deltaThreshold = preferences.spikeDeltaThreshold.first()
        val previousBpm = preferences.hrLastPokedBpm.first()
        val lastProcessedTime = preferences.hrLastSampleTime.first()

        try {
            // Read records from the last 15 minutes + any since last processed for efficiency
            val fifteenMinsAgo = java.time.Instant.now().minus(15, java.time.temporal.ChronoUnit.MINUTES)
            val intraday = healthConnectManager.readLatestHeartRate(fifteenMinsAgo)
            
            if (intraday.isNotEmpty()) {
                val latest = intraday.last()
                val latestTime = latest.first
                val latestBpm = latest.second
                
                // Track this BPM for real-time Home screen update
                preferences.setLatestBpm(latestBpm)
                
                // 1. Only process if this is a NEW sample we haven't seen yet
                // 2. Only alert if the sample is RECENT (within last 10 minutes)
                val currentTime = System.currentTimeMillis()
                val isNewSample = latestTime > lastProcessedTime
                val isRecent = (currentTime - latestTime) < 600000L // 10 minutes

                if (isNewSample && isRecent) {
                    val currentDelta = if (previousBpm > 0) latestBpm - previousBpm else 0
                    
                    val isStaticSpike = latestBpm >= staticThreshold
                    val isDeltaSpike = deltaEnabled && currentDelta >= deltaThreshold
                    
                    if (isStaticSpike || isDeltaSpike) {
                        val lastAlertTime = preferences.hrLastAlertTime.first()
                        
                        // Cooldown check for notifications - 30 second gap between alerts
                        if (currentTime - lastAlertTime > 30000L) { 
                            withContext(Dispatchers.Main) {
                                if (isDeltaSpike && previousBpm > 0) {
                                    NotificationHelper(this@HrSpikeMonitorService).showSpikeAlert(latestBpm, previousBpm, currentDelta)
                                } else {
                                    NotificationHelper(this@HrSpikeMonitorService).showSpikeAlert(latestBpm)
                                }
                            }
                            preferences.setHrLastAlertTime(currentTime)
                        }
                    }
                    
                    // Track this BPM even if we didn't notify, to calculate delta on the NEXT record
                    preferences.setHrLastPokedBpm(latestBpm)
                }
                
                // Track this sample to avoid re-alerts
                preferences.setHrLastSampleTime(latestTime)
            }

            // Optimization: Only fetch a full 7-day week if our cache is missing or incomplete
            val currentSpikesStr = preferences.historicalHrSpikes.first()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            val existingList = try {
                if (currentSpikesStr.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(currentSpikesStr) else emptyList()
            } catch(e: Exception) { emptyList() }
            
            val todayStr = java.time.LocalDate.now().toString()
            val needsFullSync = existingList.size < 7 || existingList.none { it.date == todayStr }
            
            val fetchDays = if (needsFullSync) 7 else 1
            val history = healthConnectManager.readHistoricalHeartRateWithSpikes(fetchDays)
            
            val todaySummary = history.find { it.date == todayStr }
            todaySummary?.let {
                preferences.setTodaySpikeCount(it.spikeCount)
            }
            
            // Merge or replace: if we fetched 7, replace. If we fetched 1, merge with existing.
            if (history.isNotEmpty()) {
                val newList = if (fetchDays == 7) {
                    history
                } else {
                    val updatedToday = history.first()
                    // Filter out old version of today, add new one, and keep history (sort by date desc)
                    (existingList.filter { it.date != todayStr } + updatedToday).sortedByDescending { it.date }
                }

                preferences.setHistoricalHrSpikes(
                    json.encodeToString(
                        kotlinx.serialization.serializer<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(), 
                        newList
                    )
                )
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
