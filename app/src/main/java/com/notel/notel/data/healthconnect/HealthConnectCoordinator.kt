package com.notel.notel.data.healthconnect

import android.util.Log
import com.notel.notel.data.model.WeeklySnapshotMetric
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
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
    BLOOD_PRESSURE("blood_pressure");

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
    val endDate: LocalDate
)

class HealthConnectHistoryCache {
    private val sleepCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>() // date -> (mins, timestamp)
    private val hrCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>() // date -> (bpm, timestamp)
    private val caloriesCache = ConcurrentHashMap<LocalDate, Pair<Int, Long>>() // date -> (cals, timestamp)
    private val spikesCache = ConcurrentHashMap<LocalDate, Pair<DailyHeartRateSummary, Long>>()

    fun putSleep(date: LocalDate, mins: Int) {
        sleepCache[date] = mins to System.currentTimeMillis()
    }

    fun getSleep(date: LocalDate): Int? = sleepCache[date]?.first

    fun putHr(date: LocalDate, bpm: Int) {
        hrCache[date] = bpm to System.currentTimeMillis()
    }

    fun getHr(date: LocalDate): Int? = hrCache[date]?.first

    fun putCalories(date: LocalDate, cals: Int) {
        caloriesCache[date] = cals to System.currentTimeMillis()
    }

    fun getCalories(date: LocalDate): Int? = caloriesCache[date]?.first

    fun putSpikes(summary: DailyHeartRateSummary) {
        try {
            val date = LocalDate.parse(summary.date)
            spikesCache[date] = summary to System.currentTimeMillis()
        } catch (e: Exception) {
            // ignore
        }
    }

    fun getSpikes(date: LocalDate): DailyHeartRateSummary? = spikesCache[date]?.first

    fun hasRange(metricType: HealthConnectMetricType, dates: List<LocalDate>): Boolean {
        return dates.all { d ->
            when (metricType) {
                HealthConnectMetricType.SLEEP -> getSleep(d) != null
                HealthConnectMetricType.HEART_RATE -> getHr(d) != null
                HealthConnectMetricType.CALORIES -> getCalories(d) != null
                HealthConnectMetricType.HR_SPIKES -> getSpikes(d) != null
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

    suspend fun getSleepHistory(
        days: Int,
        targetToday: LocalDate = LocalDate.now(),
        forceRefresh: Boolean = false
    ): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        val endDate = targetToday
        val startDate = endDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }
        val dateStrs = dates.map { it.toString() }

        // Check if memory cache has all dates unless forceRefresh requested
        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.SLEEP, dates)) {
            Log.d("HealthConnectCoordinator", "[MEMORY_CACHE_HIT] Sleep for $days days ($startDate to $endDate)")
            return@withContext dates.mapNotNull { d ->
                val mins = cache.getSleep(d)
                if (mins != null) d.toString() to mins else null
            }
        }

        val requestKey = HealthConnectRequestKey(HealthConnectMetricType.SLEEP, startDate, endDate)
        val startTimeMs = System.currentTimeMillis()

        val deferred = mutex.withLock {
            // Re-check existing job or larger enclosing job
            val existing = activeJobs.entries.firstOrNull { (k, j) ->
                k.metricType == HealthConnectMetricType.SLEEP &&
                        !k.startDate.isAfter(startDate) &&
                        !k.endDate.isBefore(endDate) &&
                        j.isActive
            }
            if (existing != null) {
                Log.d("HealthConnectCoordinator", "[DEDUP_WAIT] Reusing shared in-flight Sleep request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Int>>>
            } else {
                Log.d("HealthConnectCoordinator", "[IPC_START] Reading Sleep from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalSleep(days = days, targetDateStr = endDate.toString())
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.d("HealthConnectCoordinator", "[IPC_SUCCESS] Sleep read completed in ${duration}ms, returned ${raw.size} days")
                        raw.forEach { (dStr, mins) ->
                            try {
                                cache.putSleep(LocalDate.parse(dStr), mins)
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.e("HealthConnectCoordinator", "[IPC_FAILURE] Sleep read failed after ${duration}ms: ${e.message}", e)
                        throw e
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
            Log.d("HealthConnectCoordinator", "[MEMORY_CACHE_HIT] Heart Rate for $days days ($startDate to $endDate)")
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
                Log.d("HealthConnectCoordinator", "[DEDUP_WAIT] Reusing shared in-flight HR request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Int>>>
            } else {
                Log.d("HealthConnectCoordinator", "[IPC_START] Reading Heart Rate from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalHeartRate(days = days)
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.d("HealthConnectCoordinator", "[IPC_SUCCESS] HR read completed in ${duration}ms, returned ${raw.size} days")
                        raw.forEach { (dStr, bpm) ->
                            try {
                                cache.putHr(LocalDate.parse(dStr), bpm)
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.e("HealthConnectCoordinator", "[IPC_FAILURE] HR read failed after ${duration}ms: ${e.message}", e)
                        throw e
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
            Log.d("HealthConnectCoordinator", "[MEMORY_CACHE_HIT] Calories for $days days ($startDate to $endDate)")
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
                Log.d("HealthConnectCoordinator", "[DEDUP_WAIT] Reusing shared in-flight Calories request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<Pair<String, Int>>>
            } else {
                Log.d("HealthConnectCoordinator", "[IPC_START] Reading Calories from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalCalories(days = days)
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.d("HealthConnectCoordinator", "[IPC_SUCCESS] Calories read completed in ${duration}ms, returned ${raw.size} days")
                        raw.forEach { (dStr, cals) ->
                            try {
                                cache.putCalories(LocalDate.parse(dStr), cals)
                            } catch (e: Exception) {}
                        }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.e("HealthConnectCoordinator", "[IPC_FAILURE] Calories read failed after ${duration}ms: ${e.message}", e)
                        throw e
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
        forceRefresh: Boolean = false
    ): List<DailyHeartRateSummary> = withContext(Dispatchers.IO) {
        val endDate = targetToday
        val startDate = endDate.minusDays((days - 1).toLong())
        val dates = (0 until days).map { startDate.plusDays(it.toLong()) }

        if (!forceRefresh && cache.hasRange(HealthConnectMetricType.HR_SPIKES, dates)) {
            Log.d("HealthConnectCoordinator", "[MEMORY_CACHE_HIT] HR Spikes for $days days ($startDate to $endDate)")
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
                Log.d("HealthConnectCoordinator", "[DEDUP_WAIT] Reusing shared in-flight HR Spikes request for range $startDate..$endDate")
                @Suppress("UNCHECKED_CAST")
                existing.value as Deferred<List<DailyHeartRateSummary>>
            } else {
                Log.d("HealthConnectCoordinator", "[IPC_START] Reading HR Spikes from HealthConnect: $days days ($startDate..$endDate)")
                val newJob = async(Dispatchers.IO) {
                    try {
                        val raw = healthConnectManager.readHistoricalHeartRateWithSpikes(days = days)
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.d("HealthConnectCoordinator", "[IPC_SUCCESS] HR Spikes read completed in ${duration}ms, returned ${raw.size} summaries")
                        raw.forEach { summary -> cache.putSpikes(summary) }
                        raw
                    } catch (e: Exception) {
                        val duration = System.currentTimeMillis() - startTimeMs
                        Log.e("HealthConnectCoordinator", "[IPC_FAILURE] HR Spikes read failed after ${duration}ms: ${e.message}", e)
                        throw e
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
