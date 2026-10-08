package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.*
import com.notel.notel.data.local.NotelDatabase
import com.notel.notel.data.model.*
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.ClinicalReportDataCollector
import com.notel.notel.util.GeneratedReport
import com.notel.notel.util.ReportGenerator
import com.notel.notel.util.ReportRenderOptions
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.concurrent.TimeUnit

/**
 * Tabs Lab: generates a scheduled report draft in the background
 * (Phase 2, WS-H).
 *
 * Enqueued as one-time work under the unique name "report-prep-<eventId>"
 * with KEEP semantics (dedup: a second trigger while one is pending never
 * double-generates). Survives process death and device restart via
 * WorkManager; retries with exponential backoff on transient failure.
 *
 * Offline / AI failure policy: NEVER silently skip. When the AI summary
 * cannot be produced (offline, timeout, error), the worker falls back to
 * a raw-data draft so the user still gets a report, flagged as raw.
 *
 * On success it records a SavedReport row (new version, linked to the
 * event) and posts a notification whose tap opens the Progress Reports
 * preview. SHARING stays a separate explicit user action (Vera's confirm
 * dialog in the app).
 */
@HiltWorker
class ReportPrepWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val collector: ClinicalReportDataCollector,
    private val reportGenerator: ReportGenerator,
    private val geminiService: GeminiService,
    private val categoryRepository: CategoryRepository,
    private val preferences: NotelPreferences,
    private val database: NotelDatabase
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val eventId = inputData.getString(KEY_EVENT_ID) ?: return Result.failure()
        val events = readEvents()
        val event = events.firstOrNull { it.id == eventId } ?: return Result.failure()
        if (event.isReminderOnly) return Result.success() // nothing to generate

        updateEvent(eventId) { it.copy(lastRunStatus = "running") }

        return try {
            val categories = categoryRepository.getAllCategories().first()
            val range = resolveEventRange(event)
            val focus = resolveEventFocus(event)

            val snapshot = collector.collectReportData(
                allCategories = categories,
                range = range,
                focus = focus,
                customCategoryIds = event.customCategoryIds
            )
            if (!snapshot.hasAnyData) {
                updateEvent(eventId) {
                    it.copy(lastRunStatus = "failed", lastError = "No data in range")
                }
                // No data is a terminal state for this run, not a retryable error.
                return Result.success()
            }

            // Bounded AI attempts (same shape as the foreground path); any
            // failure -> raw fallback draft, never a silent skip.
            var aiSummary: String? = null
            var attempts = 2
            while (attempts > 0 && aiSummary == null) {
                val res = withTimeoutOrNull(60_000L) {
                    geminiService.getMedicalReportSummaryFromSnapshot(snapshot)
                }
                if (res != null && res.isSuccess) aiSummary = res.getOrNull()
                attempts--
            }
            val isRaw = aiSummary == null

            val result: GeneratedReport = reportGenerator.generateReportDetailed(
                snapshot = snapshot,
                aiSummary = aiSummary,
                isRawFallback = isRaw,
                options = ReportRenderOptions()
            ) ?: run {
                updateEvent(eventId) { it.copy(lastRunStatus = "failed", lastError = "PDF render failed") }
                return Result.retry()
            }

            // Record the draft as a new saved-report version linked to the event.
            val resolved = range.toClinicalReportRange(System.currentTimeMillis())
            val title = "${focus.label} report · ${range.label}"
            val dao = database.savedReportDao()
            val nextVersion = (dao.maxVersionFor(title, focus.key) ?: 0) + 1
            dao.insert(
                com.notel.notel.data.local.entity.SavedReport(
                    title = title,
                    focusKey = focus.key,
                    focusText = (focus as? ReportFocus.Custom)?.focusText.orEmpty(),
                    rangeType = range.prefsKey,
                    rangeStartMs = resolved.startEpochMs,
                    rangeEndMs = resolved.endEpochMs,
                    eventId = eventId,
                    pdfUri = result.downloadsUri,
                    version = nextVersion,
                    isRawFallback = isRaw,
                    customCategoryIdsCsv = event.customCategoryIds.joinToString(",")
                )
            )

            updateEvent(eventId) {
                it.copy(
                    lastRunStatus = "ready",
                    lastRunAtMs = System.currentTimeMillis(),
                    lastDataCutoffMs = snapshot.generationTimestamp,
                    lastError = null
                )
            }

            NotificationHelper(applicationContext).showReportDraftReady(
                eventName = event.name,
                eventId = eventId,
                isRawFallback = isRaw
            )
            Result.success()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "ReportPrepWorker failed: ${e.javaClass.simpleName}")
            updateEvent(eventId) { it.copy(lastRunStatus = "failed", lastError = e.javaClass.simpleName) }
            Result.retry()
        }
    }

    private suspend fun readEvents(): List<ScheduledReportEvent> {
        return try {
            val raw = preferences.reportEvents.first()
            if (raw.isBlank()) emptyList()
            else Json.decodeFromString(ListSerializer(ScheduledReportEvent.serializer()), raw)
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun updateEvent(eventId: String, transform: (ScheduledReportEvent) -> ScheduledReportEvent) {
        try {
            val updated = readEvents().map { if (it.id == eventId) transform(it) else it }
            preferences.setReportEvents(Json.encodeToString(ListSerializer(ScheduledReportEvent.serializer()), updated))
        } catch (_: Exception) { /* bookkeeping must not fail the run */ }
    }

    companion object {
        private const val TAG = "ReportPrepWorker"
        const val KEY_EVENT_ID = "eventId"
        const val WORK_TAG = "report-prep"

        fun workName(eventId: String) = "report-prep-$eventId"

        /** Enqueue (or keep) the one-time prep job for an event. Dedups by unique name. */
        fun enqueue(context: Context, eventId: String) {
            val request = OneTimeWorkRequestBuilder<ReportPrepWorker>()
                .setInputData(workDataOf(KEY_EVENT_ID to eventId))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.MINUTES)
                .addTag(WORK_TAG)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                workName(eventId),
                ExistingWorkPolicy.KEEP,
                request
            )
        }

        fun cancel(context: Context, eventId: String) {
            WorkManager.getInstance(context).cancelUniqueWork(workName(eventId))
        }
    }
}
