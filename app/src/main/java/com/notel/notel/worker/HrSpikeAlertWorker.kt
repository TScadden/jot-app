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
                val bpm = latest.second
                
                if (bpm >= threshold) {
                    val lastAlertTime = preferences.hrLastAlertTime.first()
                    val currentTime = System.currentTimeMillis()
                    
                    if (currentTime - lastAlertTime > 600000L) { // 10 minute cooldown
                        NotificationHelper(applicationContext).showSpikeAlert(bpm)
                        preferences.setHrLastAlertTime(currentTime)
                    }
                }
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
            .setInitialDelay(5, java.util.concurrent.TimeUnit.MINUTES)
            .addTag("hr_spike_alert_recursive")
            .build()
            
        androidx.work.WorkManager.getInstance(context).enqueueUniqueWork(
            "hr_spike_alert_loop",
            androidx.work.ExistingWorkPolicy.REPLACE,
            nextRequest
        )
    }
}
