package com.notel.notel.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileWriter
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.notel.notel.R
import com.notel.notel.MainActivity
import com.notel.notel.data.BleManager
import com.notel.notel.data.BleDevice
import com.notel.notel.data.ConnectionState
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.data.TelemetryPoint
import kotlinx.coroutines.flow.first
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

private const val TAG = "HeartRateLoggingService"
private const val CHANNEL_ID = "HeartRateLoggingChannel"
private const val NOTIFICATION_ID = 101

@AndroidEntryPoint
class HeartRateLoggingService : Service() {

    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(Dispatchers.Main + serviceJob)

    @Inject
    lateinit var preferences: NotelPreferences

    @Inject
    lateinit var syncManager: SyncManager

    private lateinit var bleManager: BleManager
    private var isRecording = false
    private var wakeLock: android.os.PowerManager.WakeLock? = null
    private var csvFile: File? = null
    private val hrAccumulator = mutableListOf<Int>()
    private var sessionStartMs = 0L
    private var windowStartMs = 0L
    private var windowStartHr = 0

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val EXTRA_DEVICE_ADDRESS = "EXTRA_DEVICE_ADDRESS"
        const val EXTRA_DEVICE_NAME = "EXTRA_DEVICE_NAME"

        private val _isServiceRunning = MutableStateFlow(false)
        val isServiceRunning: StateFlow<Boolean> = _isServiceRunning.asStateFlow()

        private val _activeFileName = MutableStateFlow<String?>(null)
        val activeFileName: StateFlow<String?> = _activeFileName.asStateFlow()

        private val _sessionMinHr = MutableStateFlow<Int?>(null)
        val sessionMinHr: StateFlow<Int?> = _sessionMinHr.asStateFlow()

        private val _sessionMaxHr = MutableStateFlow<Int?>(null)
        val sessionMaxHr: StateFlow<Int?> = _sessionMaxHr.asStateFlow()

        private val _max15sJump = MutableStateFlow<Int?>(null)
        val max15sJump: StateFlow<Int?> = _max15sJump.asStateFlow()
    }

    override fun onCreate() {
        super.onCreate()
        bleManager = BleManager.getInstance(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // Service was killed and restarted by the system: try to reconnect using stored preferences
            serviceScope.launch {
                val address = preferences.lastConnectedDeviceAddress.first()
                val name = preferences.lastConnectedDeviceName.first()
                if (address.isNotBlank() && !isRecording) {
                    startLogging(address, name)
                }
            }
        } else {
            when (intent.action) {
                ACTION_START -> {
                    val address = intent.getStringExtra(EXTRA_DEVICE_ADDRESS)
                    val name = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "Band"
                    if (address != null && !isRecording) {
                        startLogging(address, name)
                    }
                }
                ACTION_STOP -> {
                    stopLogging()
                }
            }
        }
        return START_STICKY
    }

    private fun startLogging(address: String, name: String) {
        isRecording = true
        _isServiceRunning.value = true
        sessionStartMs = System.currentTimeMillis()

        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            wakeLock = powerManager.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "Notel:HeartRateLoggingWakeLock").apply {
                acquire()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire wake lock", e)
        }

        serviceScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            preferences.setLastConnectedDeviceAddress(address)
            preferences.setLastConnectedDeviceName(name)
        }

        // Create log file in application's local directory
        val fileName = "heart_rate_session_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(Date())}.csv"
        csvFile = File(filesDir, fileName)
        _activeFileName.value = fileName

        // Write header
        try {
            val writer = FileWriter(csvFile, true)
            writer.append("Timestamp,BPM\n")
            writer.flush()
            writer.close()
        } catch (e: IOException) {
            Log.e(TAG, "Error writing CSV header", e)
        }

        // Start Foreground Service with notification specifying type for Android 10+ (needed for background BLE access)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification("Connecting to $name..."),
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Connecting to $name..."))
        }

        _sessionMinHr.value = null
        _sessionMaxHr.value = null
        _max15sJump.value = null
        windowStartMs = 0L
        windowStartHr = 0

        // Connect to BLE Device
        bleManager.startScanning() // Ensure adapter initialized
        val bluetoothAdapter = (getSystemService(Context.BLUETOOTH_SERVICE) as android.bluetooth.BluetoothManager).adapter
        val device = bluetoothAdapter.getRemoteDevice(address)
        bleManager.connectToDevice(BleDevice(name, address, device))

        hrAccumulator.clear()

        // Collect Heart Rate Flow
        serviceScope.launch {
            bleManager.liveHeartRate.collect { hr ->
                if (hr != null && hr > 0) {
                    // Update session min and max
                    _sessionMinHr.value = _sessionMinHr.value?.let { Math.min(it, hr) } ?: hr
                    _sessionMaxHr.value = _sessionMaxHr.value?.let { Math.max(it, hr) } ?: hr

                    // 15s window jump calculation
                    val now = System.currentTimeMillis()
                    if (now - sessionStartMs >= 15000) {
                        if (windowStartMs == 0L) {
                            windowStartMs = now
                            windowStartHr = hr
                        } else if (now - windowStartMs >= 15000) {
                            val jump = hr - windowStartHr
                            if (jump > 0) {
                                _max15sJump.value = _max15sJump.value?.let { Math.max(it, jump) } ?: jump
                            }
                            windowStartMs = now
                            windowStartHr = hr
                        }
                    }

                    hrAccumulator.add(hr)
                    if (hrAccumulator.size >= 10) {
                        val avgHr = hrAccumulator.average().toInt()
                        logHeartRate(avgHr)
                        hrAccumulator.clear()

                        serviceScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                            try {
                                val currentHistory = preferences.heartRateHistory.first()
                                val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                                val points = try {
                                    if (currentHistory.isNotBlank() && currentHistory != "[]") {
                                        json.decodeFromString<List<com.notel.notel.data.TelemetryPoint>>(currentHistory).toMutableList()
                                    } else {
                                        mutableListOf()
                                    }
                                } catch (e: Exception) {
                                    mutableListOf()
                                }
                                points.add(com.notel.notel.data.TelemetryPoint(System.currentTimeMillis(), avgHr))
                                val trimmedPoints = if (points.size > 1500) points.takeLast(1500) else points
                                val serialized = json.encodeToString(kotlinx.serialization.builtins.ListSerializer(com.notel.notel.data.TelemetryPoint.serializer()), trimmedPoints)
                                preferences.setHeartRateHistory(serialized)
                                syncManager.pushProfileData()
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to sync heart rate telemetry to server", e)
                            }
                        }
                    }
                    updateNotification("Current Heart Rate: $hr BPM")
                }
            }
        }

        // Collect Connection State Flow to stop logging if disconnected
        serviceScope.launch {
            bleManager.connectionState.collect { state ->
                if (state is ConnectionState.Error) {
                    updateNotification("Error: ${state.message}")
                }
            }
        }
    }

    private fun logHeartRate(bpm: Int) {
        val timestamp = SimpleDateFormat("yyyy-MM-dd hh:mm:ss a", Locale.getDefault()).format(Date())
        try {
            csvFile?.let { file ->
                val writer = FileWriter(file, true)
                writer.append("$timestamp,[$bpm BPM]\n")
                writer.flush()
                writer.close()
                Log.d(TAG, "Logged to CSV: $timestamp, [$bpm BPM]")
            }
        } catch (e: IOException) {
            Log.e(TAG, "Failed to log heart rate to CSV", e)
        }
    }

    private fun stopLogging() {
        val file = csvFile
        if (file != null && file.exists()) {
            try {
                val lines = file.readLines()
                val dataRows = lines.drop(1).filter { line ->
                    val parts = line.split(",")
                    if (parts.size >= 2) {
                        val bpmClean = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                        bpmClean.toIntOrNull() != null && parts[0].contains(":")
                    } else false
                }
                
                val heartRates = dataRows.mapNotNull { line ->
                    val bpmClean = line.split(",")[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                    bpmClean.toIntOrNull()
                }
                
                if (heartRates.isNotEmpty()) {
                    val minHr = heartRates.minOrNull() ?: 0
                    val maxHr = heartRates.maxOrNull() ?: 0
                    val avgHr = heartRates.average().toInt()
                    
                    val spikesOver100 = dataRows.mapNotNull { line ->
                        val parts = line.split(",")
                        if (parts.size >= 2) {
                            val timeStr = parts[0].trim()
                            val bpmClean = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                            val bpmVal = bpmClean.toIntOrNull()
                            if (bpmVal != null && bpmVal >= 100) timeStr to bpmVal else null
                        } else null
                    }
                    
                    val spikesText = if (spikesOver100.isEmpty()) {
                        "  [ SPIKES ],None detected\n"
                    } else {
                        val spikesLines = spikesOver100.map { (time, bpm) ->
                            val timeOnly = if (time.contains(" ")) time.substringAfter(" ") else time
                            "  [ SPIKE ],$timeOnly ([$bpm BPM])\n"
                        }
                        "  [ SPIKES ],${spikesOver100.size} detected:\n" + spikesLines.joinToString("")
                    }
                    
                    val firstRow = dataRows.first()
                    val lastRow = dataRows.last()
                    val firstTimestamp = firstRow.split(",")[0].trim()
                    val lastTimestamp = lastRow.split(",")[0].trim()
                    
                    val dateStr = if (firstTimestamp.contains(" ")) firstTimestamp.split(" ")[0] else "N/A"
                    val startTimeStr = if (firstTimestamp.contains(" ")) firstTimestamp.substringAfter(" ") else firstTimestamp
                    val endTimeStr = if (lastTimestamp.contains(" ")) lastTimestamp.substringAfter(" ") else lastTimestamp
                    
                    val durationText = {
                        val diffMs = System.currentTimeMillis() - sessionStartMs
                        val totalSeconds = diffMs / 1000
                        val hrs = totalSeconds / 3600
                        val mins = (totalSeconds % 3600) / 60
                        val secs = totalSeconds % 60
                        when {
                            hrs > 0 -> "${hrs}h ${mins}m ${secs}s"
                            mins > 0 -> "${mins}m ${secs}s"
                            else -> "${secs}s"
                        }
                    }()
                    
                    val minHrVal = _sessionMinHr.value ?: minHr
                    val maxHrVal = _sessionMaxHr.value ?: maxHr
                    val max15sJumpVal = _max15sJump.value ?: 0
                    
                    file.bufferedWriter().use { writer ->
                        writer.write("-----------------------------------------------------,\n")
                        writer.write("               JOT LIVE SESSION LOG,\n")
                        writer.write("-----------------------------------------------------,\n")
                        writer.write("  Date:,$dateStr\n")
                        writer.write("  Start Time:,$startTimeStr\n")
                        writer.write("  End Time:,$endTimeStr\n")
                        writer.write("  Duration:,$durationText\n")
                        writer.write("-----------------------------------------------------,\n")
                        writer.write("  STATISTICS:,\n")
                        writer.write("  [ MIN HR ],$minHrVal BPM\n")
                        writer.write("  [ AVG HR ],$avgHr BPM\n")
                        writer.write("  [ MAX HR ],$maxHrVal BPM\n")
                        writer.write("  [ 15S MAX JUMP ],$max15sJumpVal BPM\n")
                        writer.write(spikesText)
                        writer.write("-----------------------------------------------------,\n\n")
                        writer.write("Timestamp,Heart Rate\n")
                        
                        dataRows.forEach { line ->
                            writer.write("$line\n")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to prepend dashboard to CSV", e)
            }
        }
        isRecording = false
        _isServiceRunning.value = false
        _activeFileName.value = null
        bleManager.disconnect(explicit = true)

        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock in stopLogging", e)
        }

        serviceJob.cancelChildren()
        stopForeground(true)
        stopSelf()
    }

    private fun updateNotification(contentText: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, buildNotification(contentText))
    }

    private fun buildNotification(contentText: String): Notification {
        val stopIntent = Intent(this, HeartRateLoggingService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val openAppIntent = Intent(this, MainActivity::class.java)
        val openAppPendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Jot Live Active Log")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification_heart_lock)
            .setContentIntent(openAppPendingIntent)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop Recording", stopPendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Heart Rate Logging Service Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock in onDestroy", e)
        }
        serviceJob.cancel()
        _isServiceRunning.value = false
        _activeFileName.value = null
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
}
