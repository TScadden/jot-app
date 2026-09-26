package com.notel.notel.worker

import android.content.Context
import android.util.Log
import androidx.hilt.work.HiltWorker
import androidx.work.*
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.preferences.NotelPreferences
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * One-time background backfill of the 180-day HR spike history cache from the
 * Fitbit Web API intraday series.
 *
 * The HrSpikeBackfillWorker (commit c0d9cff) searched the phone's Health Connect
 * for raw HR samples, but Health Connect only retains ~14 days. Watch data since
 * December lives in Fitbit's cloud, so this worker pulls intraday heart rate
 * (1-minute resolution) per day from
 * `GET /1/user/-/activities/heart/date/{date}/1d/1min.json` and runs the SAME
 * spike-counting logic ([HealthConnectManager.computeDailyHeartRateSummary]:
 * readings >= 100 bpm, day 7am-10pm / night 10pm-7am splits, 10th-percentile
 * baseline, maxDelta, awakeAvg), merging each day into the durable
 * `historicalHrSpikes` DataStore cache keyed by date.
 *
 * Auth: reuses the app's existing Fitbit OAuth token management — the stored
 * access token from [NotelPreferences.fitbitToken], exactly as
 * FitbitViewModel.fetchFromFitbitApi does. The app has no refresh-token
 * rotation (token exchange happens once at login via the server proxy), so a
 * 401 is treated as "user must re-link Fitbit": the run succeeds WITHOUT
 * setting the completion flag, and schedule() re-triggers on app start /
 * background sync. No new auth flow, no new permissions, no UI blocking.
 *
 * Rate limiting: Fitbit allows 150 requests/hour/user. This worker issues at
 * most [DAYS_PER_RUN] requests per run spaced [REQUEST_DELAY_MS] apart
 * (~100 req/hr), then chains the next run via schedule() with a delay, so
 * 180 days pace through in the background without ever approaching the limit.
 *
 * Behavior:
 * - Resumable: per-day progress is persisted in the
 *   `fitbit_spike_backfill_done_days` DataStore set as each day is attempted
 *   (with or without data); a killed run continues with the first unattempted
 *   day. Days with no intraday data are skipped gracefully (marked done, no
 *   cache entry) so empty days can never wedge the backfill.
 * - Idempotent: short-circuits when the FITBIT_SPIKE_BACKFILL_COMPLETE flag is
 *   set or the cache already covers 180 days; safe to schedule on every app
 *   start and every background sync.
 * - Transient per-day failures (network/5xx) leave the day unattempted so the
 *   next run retries it; they never abort the run or mark it complete.
 *
 * Done-detection: logcat tag "FitbitSpikeBackfill" (see [TAG] and the bracketed
 * markers below — dates and counts only, never health values or tokens), plus
 * the DataStore keys "fitbit_spike_backfill_complete" (boolean) and
 * "fitbit_spike_backfill_completed_at" (epoch millis).
 */
@HiltWorker
class FitbitSpikeBackfillWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val healthConnectManager: HealthConnectManager
) : CoroutineWorker(context, params) {

    private val json = Json { ignoreUnknownKeys = true }

    private sealed interface DayResult {
        data class Data(val samples: List<Pair<Long, Int>>) : DayResult
        data object NoData : DayResult
        data object Unauthorized : DayResult
        data class RateLimited(val retryAfterSeconds: Long) : DayResult
        data object TransientError : DayResult
    }

    override suspend fun doWork(): Result {
        Log.d(TAG, "[BACKFILL_START] one-time Fitbit intraday HR spike backfill check")

        // 1. Already done? Never run twice per install.
        if (preferences.fitbitSpikeBackfillComplete.first()) {
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

        // 3. Fitbit token available? If not, succeed WITHOUT setting the flag —
        //    schedule() re-enqueues on app start / background sync, so the run
        //    resumes on the next trigger once the user links Fitbit.
        val token = preferences.fitbitToken.first()
        if (token.isBlank()) {
            Log.w(TAG, "[BACKFILL_NO_TOKEN] no Fitbit token stored; will retry on next trigger")
            return Result.success()
        }

        // 4. Process up to DAYS_PER_RUN unattempted days, oldest first, pacing
        //    requests to stay well under Fitbit's 150/hour limit.
        val doneDays = preferences.fitbitSpikeBackfillDoneDays.first()
        val cachedDates = cached.map { it.date }.toSet()
        val allDates = (0 until BACKFILL_DAYS).map { targetStart.plusDays(it.toLong()).toString() }
        val missing = allDates.filter { it !in cachedDates && it !in doneDays }

        if (missing.isEmpty()) {
            Log.d(TAG, "[BACKFILL_ALL_ATTEMPTED] all $BACKFILL_DAYS days attempted (cached=${cached.size}); marking complete")
            markComplete()
            return Result.success()
        }

        val client = OkHttpClient()
        var processed = 0
        var currentToken = token
        for (date in missing) {
            if (processed >= DAYS_PER_RUN) break
            if (isStopped) {
                Log.d(TAG, "[BACKFILL_STOPPED] worker stopped after $processed days; progress persisted, will resume")
                return Result.success()
            }

            when (val result = fetchDayIntraday(client, currentToken, date)) {
                is DayResult.Data -> {
                    val summary = healthConnectManager.computeDailyHeartRateSummary(date, result.samples)
                    if (summary != null) {
                        cached = mergeAndPersist(summary)
                        Log.d(TAG, "[BACKFILL_DAY_OK] date=$date samples=${result.samples.size} spikes=${summary.spikeCount} cachedTotal=${cached.size}")
                    } else {
                        Log.d(TAG, "[BACKFILL_DAY_EMPTY] date=$date parsed 0 usable samples; skipping")
                    }
                    preferences.addFitbitSpikeBackfillDoneDay(date)
                }
                DayResult.NoData -> {
                    Log.d(TAG, "[BACKFILL_DAY_EMPTY] date=$date no intraday data in Fitbit; skipping")
                    preferences.addFitbitSpikeBackfillDoneDay(date)
                }
                DayResult.Unauthorized -> {
                    // The app has no refresh-token rotation; re-read the stored
                    // token once in case the user re-linked Fitbit concurrently,
                    // then give up gracefully so a later trigger can retry.
                    val freshToken = preferences.fitbitToken.first()
                    if (freshToken.isNotBlank() && freshToken != currentToken) {
                        currentToken = freshToken
                        Log.d(TAG, "[BACKFILL_TOKEN_REFRESHED] stored token changed; retrying day $date")
                        when (val retry = fetchDayIntraday(client, currentToken, date)) {
                            is DayResult.Data -> {
                                val summary = healthConnectManager.computeDailyHeartRateSummary(date, retry.samples)
                                if (summary != null) {
                                    cached = mergeAndPersist(summary)
                                    Log.d(TAG, "[BACKFILL_DAY_OK] date=$date samples=${retry.samples.size} spikes=${summary.spikeCount} cachedTotal=${cached.size}")
                                }
                                preferences.addFitbitSpikeBackfillDoneDay(date)
                            }
                            else -> {
                                Log.w(TAG, "[BACKFILL_UNAUTHORIZED] day=$date still unauthorized after token re-read; will retry on next trigger")
                                return Result.success()
                            }
                        }
                    } else {
                        Log.w(TAG, "[BACKFILL_UNAUTHORIZED] day=$date Fitbit token rejected (401); user must re-link Fitbit; will retry on next trigger")
                        return Result.success()
                    }
                }
                is DayResult.RateLimited -> {
                    val delayMin = ((result.retryAfterSeconds / 60) + 2).coerceIn(2, 60)
                    Log.w(TAG, "[BACKFILL_RATE_LIMITED] Fitbit 429; chaining continuation in ${delayMin}min")
                    schedule(applicationContext, delayMin)
                    return Result.success()
                }
                DayResult.TransientError -> {
                    // Leave the day unattempted so the next run retries it;
                    // keep going with the rest of the chunk.
                    Log.w(TAG, "[BACKFILL_DAY_ERROR] date=$date transient failure; leaving for next run")
                }
            }

            processed++
            if (processed < DAYS_PER_RUN && processed < missing.size) {
                delay(REQUEST_DELAY_MS)
            }
        }

        // 5. More days remain? Chain the next run; otherwise mark complete.
        val remaining = missing.size - processed
        if (remaining > 0) {
            Log.d(TAG, "[BACKFILL_CHUNK_DONE] processed=$processed remaining=$remaining cachedTotal=${cached.size}; chaining continuation in ${CONTINUATION_DELAY_MIN}min")
            schedule(applicationContext, CONTINUATION_DELAY_MIN)
        } else {
            markComplete()
            Log.d(TAG, "[BACKFILL_COMPLETE] covered ${cached.size} days $targetStart..$today; completion timestamp stored in DataStore")
        }
        return Result.success()
    }

    /**
     * Fetches one day of 1-minute intraday HR from the Fitbit Web API.
     * Returns the parsed (epochMs, bpm) samples; intraday "time" values are in
     * the user's local timezone, matching the Health Connect-side assumption.
     */
    private suspend fun fetchDayIntraday(
        client: OkHttpClient,
        token: String,
        date: String
    ): DayResult = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("https://api.fitbit.com/1/user/-/activities/heart/date/$date/1d/1min.json")
            .header("Authorization", "Bearer $token")
            .build()
        try {
            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> {
                        val body = response.body?.string().orEmpty()
                        parseIntraday(body, date)
                    }
                    response.code == 401 || response.code == 403 -> DayResult.Unauthorized
                    response.code == 429 -> {
                        val retryAfter = response.header("Retry-After")?.toLongOrNull() ?: 3600L
                        DayResult.RateLimited(retryAfter.coerceAtLeast(60L))
                    }
                    else -> DayResult.TransientError
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "[BACKFILL_DAY_ERROR] date=$date ${e::class.java.simpleName}; leaving for next run")
            DayResult.TransientError
        }
    }

    private fun parseIntraday(body: String, date: String): DayResult {
        return try {
            val root = json.parseToJsonElement(body).jsonObject
            val dataset = root["activities-heart-intraday"]
                ?.jsonObject?.get("dataset")?.jsonArray
                ?: return DayResult.NoData
            if (dataset.isEmpty()) return DayResult.NoData

            val localDate = LocalDate.parse(date)
            val zoneId = ZoneId.systemDefault()
            val samples = dataset.mapNotNull { el ->
                val obj = el.jsonObject
                val timeStr = obj["time"]?.jsonPrimitive?.content ?: return@mapNotNull null
                val bpm = obj["value"]?.jsonPrimitive?.intOrNull ?: return@mapNotNull null
                if (bpm <= 0) return@mapNotNull null
                val epochMs = try {
                    localDate.atTime(LocalTime.parse(timeStr)).atZone(zoneId).toInstant().toEpochMilli()
                } catch (e: Exception) {
                    return@mapNotNull null
                }
                epochMs to bpm
            }
            if (samples.isEmpty()) DayResult.NoData else DayResult.Data(samples)
        } catch (e: Exception) {
            DayResult.TransientError
        }
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
     * Read-modify-write merge of a day into the durable cache, keyed by date
     * (fresh Fitbit intraday summaries win over cached entries). Re-reads the
     * cache immediately before writing so a concurrent LogRepository refresh
     * cannot be clobbered.
     */
    private suspend fun mergeAndPersist(fresh: DailyHeartRateSummary): List<DailyHeartRateSummary> {
        val latest = readCachedSpikes()
        val merged = (latest + fresh).associateBy { it.date }.values
            .sortedBy { it.date }
            .takeLast(BACKFILL_DAYS)
        preferences.setHistoricalHrSpikes(
            json.encodeToString(ListSerializer(DailyHeartRateSummary.serializer()), merged)
        )
        return merged
    }

    private suspend fun markComplete() {
        preferences.setFitbitSpikeBackfillComplete(true)
        preferences.setFitbitSpikeBackfillCompletedAt(System.currentTimeMillis())
    }

    companion object {
        const val TAG = "FitbitSpikeBackfill"
        private const val WORK_NAME = "FITBIT_SPIKE_HISTORY_BACKFILL"
        private const val BACKFILL_DAYS = 180

        // Fitbit allows 150 requests/hour/user; 12 requests per run spaced
        // 35s apart paces at ~100 req/hr and keeps each run under ~8 minutes.
        private const val DAYS_PER_RUN = 12
        private const val REQUEST_DELAY_MS = 35_000L
        private const val CONTINUATION_DELAY_MIN = 15L

        /**
         * Schedules the one-time Fitbit intraday backfill. Safe to call on every
         * app start and every background sync: REPLACE is used (not KEEP) so an
         * interrupted run resumes on the next trigger, and doWork() short-circuits
         * in milliseconds when the backfill is complete or the cache already
         * covers 180 days — a finished backfill is never restarted.
         */
        fun schedule(context: Context, initialDelayMinutes: Long = 0L) {
            val request = OneTimeWorkRequestBuilder<FitbitSpikeBackfillWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.MINUTES)
                .addTag(WORK_NAME)
                .apply {
                    if (initialDelayMinutes > 0) {
                        setInitialDelay(initialDelayMinutes, TimeUnit.MINUTES)
                    }
                }
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request
            )
        }
    }
}
