package com.notel.notel.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.notel.notel.MainActivity
import com.notel.notel.R
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.state.ReportGenerationState
import com.notel.notel.util.FriendlyErrors
import com.notel.notel.util.NotificationHelper
import com.notel.notel.util.ReportGenerator
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Pure-Kotlin mapping of pipeline state → foreground-notification stage text.
 * Kept outside the Service class so it stays unit-testable on the JVM.
 */
object ReportStageText {
    fun text(state: ReportGenerationState): String = when (state) {
        is ReportGenerationState.CollectingData -> "Collecting your health data…"
        is ReportGenerationState.RefreshingHealthData -> "Syncing health metrics…"
        is ReportGenerationState.BuildingSummary -> "Generating AI clinical summary…"
        is ReportGenerationState.RenderingPdf -> "Rendering your PDF…"
        is ReportGenerationState.SavingFile -> "Saving your report…"
        else -> "Generating your report…"
    }
}

/**
 * Runs clinical report generation (data collection, AI summary, PDF render)
 * in a foreground service so Android Doze can't suspend the app's network
 * mid-generation when the founder leaves the app after tapping Generate.
 *
 * The persistent "Generating your report…" notification is required by
 * Android for foreground services; tapping it returns to the app. The
 * existing "report ready" notification (NotificationHelper) remains the
 * completion signal. Progress is published to
 * [LogRepository.reportGenerationState], which the UI observes, so the
 * screen still reflects live progress when the app is in the foreground.
 *
 * Foreground-service type is dataSync (network fetch + local processing).
 */
@AndroidEntryPoint
class ReportGenerationService : Service() {

    @Inject
    lateinit var logRepository: LogRepository

    @Inject
    lateinit var reportGenerator: ReportGenerator

    @Inject
    lateinit var categoryRepository: CategoryRepository

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var generationJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        private const val CHANNEL_ID = "report_generation"
        private const val NOTIFICATION_ID = 5002
        private const val ACTION_START = "com.notel.notel.action.GENERATE_REPORT"
        private const val EXTRA_LAST_30_DAYS = "last_30_days"
        private const val EXTRA_FORCE_RAW = "force_raw"
        private const val EXTRA_CATEGORY_IDS = "category_ids"

        fun start(
            context: Context,
            last30DaysOnly: Boolean,
            forceRawFallback: Boolean,
            categoryIds: IntArray?
        ) {
            val intent = Intent(context, ReportGenerationService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_LAST_30_DAYS, last30DaysOnly)
                putExtra(EXTRA_FORCE_RAW, forceRawFallback)
                if (categoryIds != null) putExtra(EXTRA_CATEGORY_IDS, categoryIds)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun cancel(context: Context) {
            context.stopService(Intent(context, ReportGenerationService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForegroundWithType(buildNotification("Generating your report…"))
        // Keep the CPU on for the duration: Doze must not pause us mid-call.
        // 10-minute safety cap; released in onDestroy.
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Tabs:ReportGeneration")
            .apply { acquire(10 * 60 * 1000L) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val startIntent = intent?.takeIf { it.action == ACTION_START } ?: return START_NOT_STICKY
        // A new request supersedes any in-flight generation (matches the old
        // viewModelScope behavior of cancelling the previous reportJob).
        generationJob?.cancel()
        val last30DaysOnly = startIntent.getBooleanExtra(EXTRA_LAST_30_DAYS, false)
        val forceRawFallback = startIntent.getBooleanExtra(EXTRA_FORCE_RAW, false)
        val categoryIds = startIntent.getIntArrayExtra(EXTRA_CATEGORY_IDS)
        val myStartId = startId
        generationJob = serviceScope.launch {
            try {
                runGeneration(last30DaysOnly, forceRawFallback, categoryIds)
            } catch (e: CancellationException) {
                logRepository.updateReportGenerationState(ReportGenerationState.Cancelled)
            } catch (e: Exception) {
                logRepository.updateReportGenerationState(
                    ReportGenerationState.Failed(
                        FriendlyErrors.forBackendError(
                            "ReportGenerationService", e, FriendlyErrors.Kind.EXPORT
                        ).banner,
                        allowRawFallback = true
                    )
                )
            } finally {
                // Only stop if no newer start superseded us; a cancelled old
                // job must not kill the service out from under the new one.
                stopSelfResult(myStartId)
            }
        }
        return START_NOT_STICKY
    }

    private suspend fun runGeneration(
        last30DaysOnly: Boolean,
        forceRawFallback: Boolean,
        categoryIds: IntArray?
    ) {
        val allCats = categoryRepository.getAllCategories().first()
        val idSet = categoryIds?.toSet()
        val cats = if (idSet != null) allCats.filter { it.id in idSet } else allCats

        val onStateUpdate: (ReportGenerationState) -> Unit = { state ->
            logRepository.updateReportGenerationState(state)
            updateNotification(ReportStageText.text(state))
            if (state is ReportGenerationState.Ready) {
                NotificationHelper(this).showReportReady(state.file)
            }
        }

        if (forceRawFallback) {
            onStateUpdate(ReportGenerationState.CollectingData("Collecting patient data for Raw Data report..."))
            val snapshot = logRepository.clinicalReportDataCollector.collectReportData(cats, last30DaysOnly)
            onStateUpdate(ReportGenerationState.RenderingPdf("Rendering Raw Data PDF..."))
            val file = reportGenerator.generateReport(snapshot, aiSummary = null, isRawFallback = true)
            if (file != null) {
                onStateUpdate(ReportGenerationState.Ready(file, isRawFallback = true))
            } else {
                onStateUpdate(ReportGenerationState.Failed("Failed generating Raw Data report file."))
            }
        } else {
            logRepository.generateProfessionalReportWithSnapshot(
                categories = cats,
                reportGenerator = reportGenerator,
                last30DaysOnly = last30DaysOnly,
                onStateUpdate = onStateUpdate
            )
        }
    }

    override fun onDestroy() {
        // If the system kills us mid-generation, don't leave the UI stuck on a spinner.
        if (generationJob?.isActive == true) {
            generationJob?.cancel()
            logRepository.updateReportGenerationState(ReportGenerationState.Cancelled)
        }
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Report generation",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Shows while your clinical report is being generated" }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val mainIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, mainIntent, PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Tabs")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_noti_note)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun startForegroundWithType(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            android.util.Log.e("ReportGenerationService", "startForeground failed", e)
        }
    }
}
