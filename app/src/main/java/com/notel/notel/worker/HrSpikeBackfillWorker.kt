package com.notel.notel.worker

import android.content.Context
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.hilt.work.HiltWorker
import androidx.work.*
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.healthconnect.HealthConnectCoordinator
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.preferences.NotelPreferences
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.util.concurrent.TimeUnit

/**
 * One-time background backfill of the 180-day HR spike history cache.
 *
 * The incremental refresh in LogRepository only ever reads the most recent
 * 14 days (30 on cold start) from Health Connect and merges them into the
 * durable `historicalHrSpikes` DataStore cache, so spike history plateaus.
 * This worker walks back through Health Connect in 30-day chunks — a 180-day
 * raw read times out, but 30-day chunked reads succeed — reusing the existing
 * spike-detection logic in [HealthConnectManager.readHistoricalHeartRateWithSpikes].
 *
 * Behavior:
 * - Merges EACH chunk into the cache as it goes (read-modify-write, keyed by
 *   date), so a killed run resumes from the cache instead of restarting.
 * - Per-chunk timeout (~45s): partial progress is kept and the run is retried
 *   by WorkManager, resuming at the first uncached chunk.
 * - Idempotent: short-circuits when the HR_SPIKE_BACKFILL_COMPLETE flag is set
 *   or the cache already covers 180 days, so re-enqueueing (e.g. on app start)
 *   can never restart a finished backfill.
 * - No network, no new permissions, no UI/report-generation blocking.
 *
 * Done-detection: logcat tag "HrSpikeBackfill" (see [TAG] and the bracketed
 * markers below — dates and counts only, never health values), plus the
 * DataStore keys "hr_spike_backfill_complete" (boolean) and
 * "hr_spike_backfill_completed_at" (epoch millis).
 */
@HiltWorker
class HrSpikeBackfillWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val healthConnectManager: HealthConnectManager,
    private val healthConnectCoordinator: HealthConnectCoordinator
) : CoroutineWorker(context, params) {

    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun doWork(): Result {
        Log.d(TAG, "[BACKFILL_START] one-time HR spike history backfill check")

        // 1. Already done? Never run twice per install.
        if (preferences.hrSpikeBackfillComplete.first()) {
            Log.d(TAG, "[BACKFILL_SKIP_COMPLETE] flag already set; nothing to do")
            return Result.success()
        }

        val today = LocalDate.now()
        val targetStart = today.minusDays((BACKFILL_DAYS - 1).toLong())
        var cached = readCachedSpikes()

        // 2. Cache already covers the full window? Mark complete and skip.
        if (coversRange(cached, targetStart, today)) {
            Log.d(TAG, "[BACKFILL_SKIP_CACHE_COVERED] cache covers $targetStart..$today (${cached.size} days); marking complete")
            markComplete()
            return Result.success()
        }

        // 3. Health Connect available? If not, succeed WITHOUT setting the flag —
        //    schedule() re-enqueues on app start / background sync, so the run
        //    resumes on the next trigger once Health Connect is available.
        if (healthConnectManager.checkAvailability() != HealthConnectClient.SDK_AVAILABLE) {
            Log.w(TAG, "[BACKFILL_HC_UNAVAILABLE] Health Connect not available; will retry on next trigger")
            return Result.success()
        }

        // 4. Walk back in 30-day chunks, oldest first, merging each chunk into
        //    the cache as it goes so a killed run resumes rather than restarts.
        val chunkEndDates = (0 until BACKFILL_DAYS / CHUNK_DAYS).map { i ->
            today.minusDays(((BACKFILL_DAYS / CHUNK_DAYS - 1 - i) * CHUNK_DAYS).toLong())
        }
        for (chunkEnd in chunkEndDates) {
            val chunkStart = chunkEnd.minusDays((CHUNK_DAYS - 1).toLong())
            val cachedDates = cached.map { it.date }.toSet()
            val missingCount = (0 until CHUNK_DAYS).count { offset ->
                chunkStart.plusDays(offset.toLong()).toString() !in cachedDates
            }
            if (missingCount == 0) {
                Log.d(TAG, "[BACKFILL_SKIP_CHUNK] chunk=$chunkStart..$chunkEnd already cached")
                continue
            }

            Log.d(TAG, "[BACKFILL_CHUNK] chunk=$chunkStart..$chunkEnd missing=$missingCount days")
            val fresh = try {
                withTimeout(CHUNK_TIMEOUT_MS) {
                    healthConnectCoordinator.getHrSpikesHistory(
                        days = CHUNK_DAYS,
                        targetToday = chunkEnd,
                        anchorDate = chunkEnd
                    )
                }
            } catch (e: Exception) {
                // Partial progress is already persisted; retry resumes at the
                // first uncached chunk on the next trigger.
                Log.w(TAG, "[BACKFILL_CHUNK_RETRY] chunk=$chunkStart..$chunkEnd failed (${e::class.java.simpleName}); progress kept, will resume")
                return Result.retry()
            }

            if (fresh.isEmpty()) {
                // Health Connect returned no data for this window (e.g. no HR
                // samples that far back). Treat as data-absent, not a failure.
                Log.d(TAG, "[BACKFILL_CHUNK_EMPTY] chunk=$chunkStart..$chunkEnd no data returned")
                continue
            }

            cached = mergeAndPersist(fresh)
            Log.d(TAG, "[BACKFILL_CHUNK_OK] chunk=$chunkStart..$chunkEnd days=${fresh.size} cachedTotal=${cached.size}")
        }

        markComplete()
        Log.d(TAG, "[BACKFILL_COMPLETE] covered ${cached.size} days $targetStart..$today; completion timestamp stored in DataStore")
        return Result.success()
    }

    private suspend fun readCachedSpikes(): List<DailyHeartRateSummary> {
        return try {
            val str = preferences.historicalHrSpikes.first()
            if (str.isBlank()) emptyList() else json.decodeFromString(str)
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun coversRange(cached: List<DailyHeartRateSummary>, start: LocalDate, end: LocalDate): Boolean {
        val dates = cached.map { it.date }.toSet()
        var d = start
        while (!d.isAfter(end)) {
            if (d.toString() !in dates) return false
            d = d.plusDays(1)
        }
        return true
    }

    /**
     * Read-modify-write merge of a chunk into the durable cache, keyed by
     * date (fresh Health Connect reads win over cached entries). Re-reads the
     * cache immediately before writing so a concurrent LogRepository refresh
     * cannot be clobbered.
     */
    private suspend fun mergeAndPersist(
        fresh: List<DailyHeartRateSummary>
    ): List<DailyHeartRateSummary> {
        val latest = readCachedSpikes()
        val merged = (latest + fresh).associateBy { it.date }.values
            .sortedBy { it.date }
            .takeLast(BACKFILL_DAYS)
        preferences.setHistoricalHrSpikes(json.encodeToString(merged))
        return merged
    }

    private suspend fun markComplete() {
        preferences.setHrSpikeBackfillComplete(true)
        preferences.setHrSpikeBackfillCompletedAt(System.currentTimeMillis())
    }

    companion object {
        const val TAG = "HrSpikeBackfill"
        private const val WORK_NAME = "HR_SPIKE_HISTORY_BACKFILL"
        private const val BACKFILL_DAYS = 180
        private const val CHUNK_DAYS = 30
        private const val CHUNK_TIMEOUT_MS = 45_000L

        /**
         * Schedules the one-time backfill. Safe to call on every app start and
         * every background sync: REPLACE is used (not KEEP) so an interrupted
         * run resumes on the next trigger, and doWork() short-circuits in
         * milliseconds when the backfill is complete or the cache already
         * covers 180 days — a finished backfill is never restarted.
         */
        fun schedule(context: Context) {
            val request = OneTimeWorkRequestBuilder<HrSpikeBackfillWorker>()
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.MINUTES)
                .addTag(WORK_NAME)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request
            )
        }
    }
}
