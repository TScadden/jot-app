package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first

@HiltWorker
class HrSpikeAlertWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val healthConnectManager: HealthConnectManager
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()
        if (!preferences.hrSpikeAlertsEnabled.first()) {
            // If disabled, stop the recursion
            return Result.success()
        }
        
        val threshold = preferences.spikeThreshold.first()
        
        try {
            // Read intraday samples for today to check the most recent one
            val intraday = healthConnectManager.readHeartRateIntraday("today")
            if (intraday.isNotEmpty()) {
                val latest = intraday.last()
                val latestTime = latest.first
                val latestBpm = latest.second
                
                val lastProcessedTime = preferences.hrLastSampleTime.first()
                val currentTime = System.currentTimeMillis()
                
                val isNewSample = latestTime > lastProcessedTime
                val isRecent = (currentTime - latestTime) < 600000L // 10 mins
                
                if (isNewSample && isRecent && latestBpm >= threshold) {
                    val lastAlertTime = preferences.hrLastAlertTime.first()
                    
                    if (currentTime - lastAlertTime > 30000L) { // 30 second alert cooldown
                        NotificationHelper(applicationContext).showSpikeAlert(latestBpm)
                        preferences.setHrLastAlertTime(currentTime)
                    }
                }
                
                // Track this sample to avoid re-alerting on it if it's stale
                preferences.setHrLastSampleTime(latestTime)
            }
        } catch (e: Exception) {
            // Log and continue recursion unless critical
        } finally {
            // Schedule the next check in 5 minutes for "near real-time" monitoring
            scheduleNextCheck(applicationContext)
        }

        return Result.success()
    }

    private fun scheduleNextCheck(context: Context) {
        val nextRequest = androidx.work.OneTimeWorkRequestBuilder<HrSpikeAlertWorker>()
            .setInitialDelay(30, java.util.concurrent.TimeUnit.SECONDS)
            .addTag("hr_spike_alert_recursive")
            .build()
            
        androidx.work.WorkManager.getInstance(context).enqueueUniqueWork(
            "hr_spike_alert_loop",
            androidx.work.ExistingWorkPolicy.REPLACE,
            nextRequest
        )
    }
}
