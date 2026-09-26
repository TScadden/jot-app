package com.notel.notel.data.healthconnect

import android.util.Log
import com.notel.notel.data.model.WeeklySnapshotMetric
import com.notel.notel.ui.viewmodel.SleepData
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

enum class HealthConnectMetricType(val metricKey: String) {
    SLEEP("sleep"),
    HEART_RATE("heart_rate"),
    HR_SPIKES("hr_spikes"),
    CALORIES("calories"),
    BLOOD_PRESSURE("blood_pressure"),
    INTRADAY_HR("intraday_hr"),
    ACTIVE_CALORIES("active_calories"),
    SLEEP_SESSION("sleep_session"),
    RESTING_HR("resting_hr"),
    HRV("hrv");

    companion object {
        fun fromWeeklyMetric(metric: WeeklySnapshotMetric): HealthConnectMetricType? {
            return when (metric) {
                WeeklySnapshotMetric.SLEEP_HOURS -> SLEEP
                WeeklySnapshotMetric.RESTING_HEART_RATE -> HEART_RATE
                WeeklySnapshotMetric.HR_SPIKES -> HR_SPIKES
                WeeklySnapshotMetric.CALORIES -> CALORIES
                WeeklySnapshotMetric.BLOOD_PRESSURE -> BLOOD_PRESSURE
                else -> null
            }
        }
    }
}

data class HealthConnectRequestKey(
    val metricType: HealthConnectMetricType,
    val startDate: LocalDate,
    val endDate: LocalDate,
    val extraParam: String = ""
)

class HealthConnectHistoryCache {
    private val sleepCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>() // date -> (mins, timestamp)
    private val hrCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>() // date -> (bpm, timestamp)
    private val caloriesCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>() // date -> (cals, timestamp)
    private val spikesCache = ConcurrentHashMap<LocalDate, Pair<DailyHeartRateSummary, Long>>()
    private val intradayHrCache = ConcurrentHashMap<LocalDate, Pair<List<Pair<Long, Int>>, Long>>()
    private val activeCalCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>()
    private val sleepSessionCache = ConcurrentHashMap<LocalDate, Pair<SleepData?, Long>>()
    private val restingHrCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>()
    private val hrvCache = ConcurrentHashMap<LocalDate, Pair<List<Pair<String, Double>>, Long>>()

    fun putSleep(date: LocalDate, mins: Int) {
        sleepCache[date] = mins to System.currentTimeMillis()
    }

    fun getSleep(date: LocalDate, ttlMillis: Long = Long.MAX_VALUE): Int? {
        val entry = sleepCache[date] ?: return null
        if (System.currentTimeMillis() - entry.second > ttlMillis) return null
        return entry.first
    }

    fun putHr(date: LocalDate, bpm: Int) {
        hrCache[date] = bpm to System.currentTimeMillis()
    }

    fun getHr(date: LocalDate, ttlMillis: Long = Long.MAX_VALUE): Int? {
        val entry = hrCache[date] ?: return null
        if (System.currentTimeMillis() - entry.second > ttlMillis) return null
        return entry.first
    }

    fun putCalories(date: LocalDate, cals: Int) {
        caloriesCache[date] = cals to System.currentTimeMillis()
    }

    fun getCalories(date: LocalDate, ttlMillis: Long = Long.MAX_VALUE): Int? {
        val entry = caloriesCache[date] ?: return null
        if (System.currentTimeMillis() - entry.second > ttlMillis) return null
        return entry.first
    }

    fun putSpikes(summary: DailyHeartRateSummary) {
        try {
            val date = LocalDate.parse(summary.date)
            spikesCache[date] = summary to System.currentTimeMillis()
        } catch (e: Exception) {
            // ignore
        }
    }

    fun getSpikes(date: LocalDate, ttlMillis: Long = Long.MAX_VALUE): DailyHeartRateSummary? {
        val entry = spikesCache[date] ?: return null
        if (System.currentTimeMillis() - entry.second > ttlMillis) return null
        return entry.first
    }

    fun putIntradayHr(date: LocalDate, data: List<Pair<Long, Int>>) {
        intradayHrCache[date] = data to System.currentTimeMillis()
    }

    fun getIntradayHr(date: LocalDate, ttlMillis: Long = Long.MAX_VALUE): List<Pair<Long, Int>>? {
        val entry = intradayHrCache[date] ?: return null
        if (System.currentTimeMillis() - entry.second > ttlMillis) return null
        return entry.first
    }

    fun getIntradayHrRaw(date: LocalDate): List<Pair<Long, Int>>? = intradayHrCache[date]?.first
    fun getIntradayHrTimestamp(date: LocalDate): Long? = intradayHrCache[date]?.second

    fun putActiveCalories(date: LocalDate, cals: Int) {
        activeCalCache[date] = cals to System.currentTimeMillis()
    }

    fun getActiveCalories(date: LocalDate, ttlMillis: Long = Long.MAX_VALUE): Int? {
        val entry = activeCalCache[date] ?: return null
        if (System.currentTimeMillis() - entry.second > ttlMillis) return null
        return entry.first
    }

    fun putSleepSession(date: LocalDate, session: SleepData?) {
        sleepSessionCache[date] = session to System.currentTimeMillis()
    }

    fun getSleepSession(date: LocalDate): SleepData? = sleepSessionCache[date]?.first

    fun putRestingHr(date: LocalDate, rhr: Int) {
        restingHrCache[date] = rhr to System.currentTimeMillis()
    }

    fun getRestingHr(date: LocalDate): Int? = restingHrCache[date]?.first

    fun putHrv(date: LocalDate, hrvList: List<Pair<String, Double>>) {
        hrvCache[date] = hrvList to System.currentTimeMillis()
    }

    fun getHrv(date: LocalDate): List<Pair<String, Double>>? = hrvCache[date]?.first

    fun hasRange(metricType: HealthConnectMetricType, dates: List<LocalDate>): Boolean {
        return dates.all { d ->
            when (metricType) {
                HealthConnectMetricType.SLEEP -> getSleep(d) != null
                HealthConnectMetricType.HEART_RATE -> getHr(d) != null
                HealthConnectMetricType.CALORIES -> getCalories(d) != null
                HealthConnectMetricType.HR_SPIKES -> getSpikes(d) != null
                HealthConnectMetricType.INTRADAY_HR -> getIntradayHr(d) != null
                HealthConnectMetricType.ACTIVE_CALORIES -> getActiveCalories(d) != null
                HealthConnectMetricType.SLEEP_SESSION -> sleepSessionCache.containsKey(d)
                HealthConnectMetricType.RESTING_HR -> getRestingHr(d) != null
                HealthConnectMetricType.HRV -> getHrv(d) != null
                HealthConnectMetricType.BLOOD_PRESSURE -> false
            }
        }
    }
}

@Singleton
class HealthConnectCoordinator @Inject constructor(
    private val healthConnectManager: HealthConnectManager
) {
    private val cache = HealthConnectHistoryCache()
    private val activeJobs = ConcurrentHashMap<HealthConnectRequestKey, Deferred<Any?>>()
    private val mutex = Mutex()

    fun getMemoryCache(): HealthConnectHistoryCache = cache

    private fun safeLogD(tag: String, msg: String) {
        try { Log.d(tag, msg) } catch (e: Throwable) {}
    }

    private fun safeLogE(tag: String, msg: String, tr: Throwable? = null) {
        try {
            if (tr != null) Log.e(tag, msg, tr) else Log.e(tag, msg)
        } catch (e: Throwable) {}
    }

    private fun parseLocalDate(dateStr: String): LocalDate {
        return try {
            if (dateStr == "today" || dateStr.isBlank()) LocalDate.now() else LocalDate.parse(dateStr)
        } catch (e: Exception) {
            LocalDate.now()
        }
    }

    suspend fun getIntradayHeartRate(
        dateStr: String,
        forceRefresh: Boolean = false
    ): List<Pair<Long, Int>> = withContext(Dispatchers.IO) {
        val date = parseLocalDate(dateStr)
        val isToday = date == LocalDate.now()
        val ttlMillis = if (isToday) 3 * 60 * 1000L else Long.MAX_VALUE

        val existingCached = cache.getIntradayHrRaw(date)
        val cacheTimestamp = cache.getIntradayHrTimestamp(date) ?: 0L
        val cacheAgeMs = if (cacheTimestamp > 0) System.currentTimeMillis() - cacheTimestamp else -1L

        if (!forceRefresh) {
            val cached = cache.getIntradayHr(date, ttlMillis = ttlMillis)
            if (cached != null) {
                val newestSampleTime = cached.lastOrNull()?.first ?: 0L
                val newestSampleStr = if (newestSampleTime > 0) {
                    java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(newestSampleTime), java.time.ZoneId.systemDefault()).toLocalTime().toString()
                } else "none"
                safeLogD(
                    "HealthConnectTiming",
                    "[MEMORY_CACHE_HIT] Intraday HR date=$date points=${cached.size} newestSample=$newestSampleStr cacheAgeMs=$cacheAgeMs forceRefresh=$forceRefresh"
                )
                return@withContext cached
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.INTRADAY_HR, date, date)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs[requestKey]
            if (existing != null && existing.isActive) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight Intraday HR request for $date")
                @Suppress("UNCHECKED_CAST")
                existing as Deferred<List<Pair<Long, Int>>>
            } else {
                val newestCachedMs = existingCached?.lastOrNull()?.first ?: 0L
                val newestCachedStr = if (newestCachedMs > 0) {
                    java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(newestCachedMs), java.time.ZoneId.systemDefault()).toLocalTime().toString()
                } else "none"
                safeLogD(
                    "HealthConnectTiming",
                    "[IPC_START] Reading Intraday HR date=$date newestCached=$newestCachedStr cacheAgeMs=$cacheAgeMs forceRefresh=$forceRefresh"
                )
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHeartRateIntraday(dateStr)
                        val duration = System.currentTimeMillis() - startTimeMs
                        
                        val merged = if (existingCached != null && isToday) {
                            (existingCached + raw).distinctBy { it.first }.sortedBy { it.first }
                        } else {
                            raw
                        }
                        
                        val newestHcMs = merged.lastOrNull()?.first ?: 0L
                        val newestHcStr = if (newestHcMs > 0) {
                            java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(newestHcMs), java.time.ZoneId.systemDefault()).toLocalTime().toString()
                        } else "none"

                        safeLogD(
                            "HealthConnectTiming",
                            "[IPC_SUCCESS] Intraday HR date=$date durationMs=$duration rawSamples=${raw.size} mergedSamples=${merged.size} newestHcSample=$newestHcStr"
                        )
                        cache.putIntradayHr(date, merged)
                        merged
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] Intraday HR date=$date durationMs=$duration err=${e.message}", e)
                        if (existingCached != null) {
                            safeLogD("HealthConnectTiming", "[FALLBACK_RETAIN] Retaining existing cached samples (${existingCached.size}) on failure")
                            existingCached
                        } else {
                            throw e
                        }
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getActiveCalories(
        dateStr: String,
        forceRefresh: Boolean = false
    ): Int = withContext(Dispatchers.IO) {
        val date = parseLocalDate(dateStr)
        if (!forceRefresh) {
            val cached = cache.getActiveCalories(date)
            if (cached != null) {
                safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] Active Calories for $date ($cached kcal)")
                return@withContext cached
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.ACTIVE_CALORIES, date, date)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs[requestKey]
            if (existing != null && existing.isActive) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight Active Calories request for $date")
                @Suppress("UNCHECKED_CAST")
                existing as Deferred<Int>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading Active Calories from HealthConnect for $date")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readActiveCalories(dateStr)
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] Active Calories completed in ${duration}ms: $raw kcal")
                        cache.putActiveCalories(date, raw)
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] Active Calories failed after ${duration}ms: ${e.message}", e)
                        0
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getSleepSession(
        dateStr: String,
        forceRefresh: Boolean = false
    ): SleepData? = withContext(Dispatchers.IO) {
        val date = parseLocalDate(dateStr)
        if (!forceRefresh) {
            val cached = cache.getSleepSession(date)
            if (cached != null) {
                safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] Sleep Session for $date (${cached.minutesAsleep} mins)")
                return@withContext cached
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.SLEEP_SESSION, date, date)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs[requestKey]
            if (existing != null && existing.isActive) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight Sleep Session request for $date")
                @Suppress("UNCHECKED_CAST")
                existing as Deferred<SleepData?>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading Sleep Session from HealthConnect for $date")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readSleepSession(dateStr)
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] Sleep Session completed in ${duration}ms")
                        cache.putSleepSession(date, raw)
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] Sleep Session failed after ${duration}ms: ${e.message}", e)
                        null
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getRestingHeartRate(
        dateStr: String,
        forceRefresh: Boolean = false
    ): Int = withContext(Dispatchers.IO) {
        val date = parseLocalDate(dateStr)
        if (!forceRefresh) {
            val cached = cache.getRestingHr(date)
            if (cached != null) {
                safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] Resting HR for $date ($cached bpm)")
                return@withContext cached
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.RESTING_HR, date, date)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs[requestKey]
            if (existing != null && existing.isActive) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight Resting HR request for $date")
                @Suppress("UNCHECKED_CAST")
                existing as Deferred<Int>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading Resting HR from HealthConnect for $date")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readRestingHeartRate(dateStr) ?: 0
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] Resting HR completed in ${duration}ms: $raw bpm")
                        cache.putRestingHr(date, raw)
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] Resting HR failed after ${duration}ms: ${e.message}", e)
                        0
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getHeartRateVariability(
        days: Int = 1,
        targetDateStr: String? = null,
        forceRefresh: Boolean = false
    ): List<Pair<String, Double>> = withContext(Dispatchers.IO) {
        val targetDate = if (targetDateStr != null) parseLocalDate(targetDateStr) else LocalDate.now()
        val startDate = targetDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }

        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.HRV, dates)) {
            safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] HRV for $days days ($startDate..$targetDate)")
            return@withContext dates.flatMap { d -> cache.getHrv(d) ?: emptyList() }.distinctBy { it.first }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.HRV, startDate, targetDate, "days_$days")
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs.entries.firstOrNull { (k, j) ->
                k.metricType == HealthConnectMetricType.HRV &&
                        !k.startDate.isAfter(startDate) &&
                        !k.endDate.isBefore(targetDate) &&
                        j.isActive
            }
            if (existing != null) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight HRV request for range $startDate..$targetDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Double>>>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading HRV from HealthConnect: $days days ($startDate..$targetDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHeartRateVariability(days = days, targetDateStr = targetDateStr)
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] HRV completed in ${duration}ms, returned ${raw.size} entries")
                        raw.forEach { (dStr, valDouble) ->
                            try {
                                cache.putHrv(LocalDate.parse(dStr), listOf(dStr to valDouble))
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] HRV failed after ${duration}ms: ${e.message}", e)
                        emptyList()
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getSleepHistory(
        days: Int,
        targetToday: LocalDate = LocalDate.now(),
        forceRefresh: Boolean = false
    ): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        val endDate = targetToday
        val startDate = endDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }

        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.SLEEP, dates)) {
            safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] Sleep for $days days ($startDate to $endDate)")
            return@withContext dates.mapNotNull { d ->
                val mins = cache.getSleep(d)
                if (mins != null) d.toString() to mins else null
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.SLEEP, startDate, endDate)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs.entries.firstOrNull { (k, j) ->
                k.metricType == HealthConnectMetricType.SLEEP &&
                        !k.startDate.isAfter(startDate) &&
                        !k.endDate.isBefore(endDate) &&
                        j.isActive
            }
            if (existing != null) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight Sleep request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Int>>>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading Sleep from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalSleep(days = days, targetDateStr = endDate.toString())
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] Sleep read completed in ${duration}ms, returned ${raw.size} days")
                        raw.forEach { (dStr, mins) ->
                            try {
                                cache.putSleep(LocalDate.parse(dStr), mins)
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] Sleep read failed after ${duration}ms: ${e.message}", e)
                        emptyList()
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getHeartRateHistory(
        days: Int,
        targetToday: LocalDate = LocalDate.now(),
        forceRefresh: Boolean = false
    ): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        val endDate = targetToday
        val startDate = endDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }

        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.HEART_RATE, dates)) {
            safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] Heart Rate for $days days ($startDate to $endDate)")
            return@withContext dates.mapNotNull { d ->
                val bpm = cache.getHr(d)
                if (bpm != null) d.toString() to bpm else null
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.HEART_RATE, startDate, endDate)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs.entries.firstOrNull { (k, j) ->
                k.metricType == HealthConnectMetricType.HEART_RATE &&
                        !k.startDate.isAfter(startDate) &&
                        !k.endDate.isBefore(endDate) &&
                        j.isActive
            }
            if (existing != null) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight HR request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Int>>>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading Heart Rate from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalHeartRate(days = days)
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] HR read completed in ${duration}ms, returned ${raw.size} days")
                        raw.forEach { (dStr, bpm) ->
                            try {
                                cache.putHr(LocalDate.parse(dStr), bpm)
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] HR read failed after ${duration}ms: ${e.message}", e)
                        emptyList()
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getCaloriesHistory(
        days: Int,
        targetToday: LocalDate = LocalDate.now(),
        forceRefresh: Boolean = false
    ): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        val endDate = targetToday
        val startDate = endDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }

        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.CALORIES, dates)) {
            safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] Calories for $days days ($startDate to $endDate)")
            return@withContext dates.mapNotNull { d ->
                val cals = cache.getCalories(d)
                if (cals != null) d.toString() to cals else null
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.CALORIES, startDate, endDate)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs.entries.firstOrNull { (k, j) ->
                k.metricType == HealthConnectMetricType.CALORIES &&
                        !k.startDate.isAfter(startDate) &&
                        !k.endDate.isBefore(endDate) &&
                        j.isActive
            }
            if (existing != null) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight Calories request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Int>>>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading Calories from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalCalories(days = days)
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] Calories read completed in ${duration}ms, returned ${raw.size} days")
                        raw.forEach { (dStr, cals) ->
                            try {
                                cache.putCalories(LocalDate.parse(dStr), cals)
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] Calories read failed after ${duration}ms: ${e.message}", e)
                        emptyList()
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }

    suspend fun getHrSpikesHistory(
        days: Int,
        targetToday: LocalDate = LocalDate.now(),
        forceRefresh: Boolean = false,
        anchorDate: LocalDate = LocalDate.now()
    ): List<DailyHeartRateSummary> = withContext(Dispatchers.IO) {
        val endDate = targetToday
        val startDate = endDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }

        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.HR_SPIKES, dates)) {
            safeLogD("HealthConnectTiming", "[MEMORY_CACHE_HIT] HR Spikes for $days days ($startDate to $endDate)")
            return@withContext dates.mapNotNull { d -> cache.getSpikes(d) }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.HR_SPIKES, startDate, endDate)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            val existing = activeJobs.entries.firstOrNull { (k, j) ->
                k.metricType == HealthConnectMetricType.HR_SPIKES &&
                        !k.startDate.isAfter(startDate) &&
                        !k.endDate.isBefore(endDate) &&
                        j.isActive
            }
            if (existing != null) {
                safeLogD("HealthConnectTiming", "[DEDUP_WAIT] Reusing shared in-flight HR Spikes request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<DailyHeartRateSummary>>
            } else {
                safeLogD("HealthConnectTiming", "[IPC_START] Reading HR Spikes from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalHeartRateWithSpikes(days = days, anchorDate = anchorDate)
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogD("HealthConnectTiming", "[IPC_SUCCESS] HR Spikes read completed in ${duration}ms, returned ${raw.size} summaries")
                        raw.forEach { summary -> cache.putSpikes(summary) }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        safeLogE("HealthConnectTiming", "[IPC_FAILURE] HR Spikes read failed after ${duration}ms: ${e.message}", e)
                        emptyList()
                    } finally {
                        mutex.withLock { activeJobs.remove(requestKey) }
                    }
                }
                activeJobs[requestKey] = newJob
                newJob
            }
        }

        deferred.await()
    }
}

