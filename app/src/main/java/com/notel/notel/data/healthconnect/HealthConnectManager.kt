package com.notel.notel.data.healthconnect

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.AggregateGroupByDurationRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.notel.notel.ui.viewmodel.SleepData
import java.time.Duration
import java.time.Instant
import java.time.ZonedDateTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlinx.serialization.Serializable

@Serializable
data class SpikeEventRecord(
    val peakBpm: Int,
    val durationMins: Int,
    val startTimeMs: Long = 0L
)

/** Per-day heart rate summary exposing spike data for POTS-aware AI analysis. */
@Serializable
data class DailyHeartRateSummary(
    val date: String,
    val avg: Int,
    val max: Int,
    val min: Int,
    val baseline: Int,      // 10th-percentile — true resting estimate
    val spikeCount: Int,    // total readings >= SPIKE_THRESHOLD_BPM
    val daySpikeCount: Int = 0,   // Spikes from 7am-10pm
    val nightSpikeCount: Int = 0, // Spikes from 10pm-7am
    val maxDelta: Int,      // max - baseline (key POTS orthostatic delta)
    val totalReadings: Int,
    val eventsList: List<SpikeEventRecord> = emptyList()
) {
    companion object {
        const val SPIKE_THRESHOLD_BPM = 100  // adjust if needed
    }
}

class HealthConnectManager(private val context: Context) {
    val healthConnectClient by lazy { HealthConnectClient.getOrCreate(context) }

    val permissions by lazy {
        setOf(
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class),
            HealthPermission.getReadPermission(StepsRecord::class),
            HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(TotalCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(BasalMetabolicRateRecord::class),
            HealthPermission.getReadPermission(WeightRecord::class),
            HealthPermission.getReadPermission(HeightRecord::class),
            HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
            HealthPermission.getReadPermission(PowerRecord::class)
        )
    }

    fun checkAvailability(): Int {
        return HealthConnectClient.getSdkStatus(context, "com.google.android.apps.healthdata")
    }

    suspend fun hasAllPermissions(): Boolean {
        if (checkAvailability() != HealthConnectClient.SDK_AVAILABLE) return false
        val granted = healthConnectClient.permissionController.getGrantedPermissions()
        return granted.containsAll(permissions)
    }

    private fun startOfDate(dateStr: String): Instant {
        return try {
            val zoneId = ZoneId.systemDefault()
            if (dateStr == "today" || dateStr.isBlank()) {
                ZonedDateTime.now(zoneId).truncatedTo(ChronoUnit.DAYS).toInstant()
            } else {
                val localDate = java.time.LocalDate.parse(dateStr)
                localDate.atStartOfDay(zoneId).toInstant()
            }
        } catch (e: Exception) {
            ZonedDateTime.now(ZoneId.systemDefault()).truncatedTo(ChronoUnit.DAYS).toInstant()
        }
    }

    private fun endOfDate(dateStr: String): Instant = startOfDate(dateStr).plus(1, ChronoUnit.DAYS)

    suspend fun readHeartRateIntraday(dateStr: String): List<Pair<Long, Int>> {
        try {
            val start = startOfDate(dateStr)
            val end = endOfDate(dateStr)
            
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = HeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end)
                )
            )
            
            val result = mutableListOf<Pair<Long, Int>>()
            response.records.forEach { record ->
                record.samples.forEach { sample ->
                    result.add(sample.time.toEpochMilli() to sample.beatsPerMinute.toInt())
                }
            }
            return result.sortedBy { it.first }
        } catch(e: Exception) {
            return emptyList()
        }
    }

    suspend fun readLatestHeartRate(since: Instant): List<Pair<Long, Int>> {
        try {
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = HeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(since, Instant.now())
                )
            )
            
            val result = mutableListOf<Pair<Long, Int>>()
            response.records.forEach { record ->
                record.samples.forEach { sample ->
                    result.add(sample.time.toEpochMilli() to sample.beatsPerMinute.toInt())
                }
            }
            return result.sortedBy { it.first }
        } catch(e: Exception) {
            return emptyList()
        }
    }

    suspend fun readHeartRateAverage(dateStr: String): Int {
        val intraday = readHeartRateIntraday(dateStr)
        if (intraday.isEmpty()) return 0
        return intraday.map { it.second }.average().toInt()
    }

    suspend fun readActiveCalories(dateStr: String): Int {
         try {
            val start = startOfDate(dateStr)
            val end = endOfDate(dateStr)
            
            val response = healthConnectClient.aggregate(
                AggregateRequest(
                    metrics = setOf(TotalCaloriesBurnedRecord.ENERGY_TOTAL, ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(start, end)
                )
            )
            
            val totalKcal = response[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories?.toInt() 
                ?: response[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories?.toInt() ?: 0
            
            return totalKcal
        } catch(e: Exception) {
            return 0
        }
    }


    suspend fun readSleepSession(dateStr: String): SleepData? {
        try {
            val startOfDay = if (dateStr == "today" || dateStr.isBlank()) ZonedDateTime.now(ZoneId.systemDefault()).truncatedTo(ChronoUnit.DAYS).toInstant() else Instant.parse("${dateStr}T00:00:00Z")
            val endOfDay = startOfDay.plus(1, ChronoUnit.DAYS)
            
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = SleepSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(startOfDay.minus(1, ChronoUnit.DAYS), endOfDay)
                )
            )
            
            var targetSession: SleepSessionRecord? = null
            var maxDuration = 0L

            response.records.forEach { session ->
                if (session.endTime.isAfter(startOfDay) && session.endTime.isBefore(endOfDay.plus(12, ChronoUnit.HOURS))) {
                    val duration = ChronoUnit.MINUTES.between(session.startTime, session.endTime)
                    if (duration > maxDuration) {
                        maxDuration = duration
                        targetSession = session
                    }
                }
            }
            
            val session = targetSession ?: return null

            var deep = 0
            var light = 0
            var rem = 0
            var awake = 0
            session.stages.forEach { stage ->
                val durationMins = ChronoUnit.MINUTES.between(stage.startTime, stage.endTime).toInt()
                when (stage.stage) {
                    SleepSessionRecord.STAGE_TYPE_DEEP -> deep += durationMins
                    SleepSessionRecord.STAGE_TYPE_LIGHT -> light += durationMins
                    SleepSessionRecord.STAGE_TYPE_REM -> rem += durationMins
                    SleepSessionRecord.STAGE_TYPE_AWAKE -> awake += durationMins
                    SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED -> awake += durationMins
                    SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> awake += durationMins
                }
            }

            val timeInBed = ChronoUnit.MINUTES.between(session.startTime, session.endTime).toInt()
            val totalAsleep = timeInBed - awake
            var efficiency = 0
            if (timeInBed > 0) {
                efficiency = ((totalAsleep.toFloat() / timeInBed.toFloat()) * 100).toInt()
            }

            return SleepData(
                minutesAsleep = totalAsleep,
                timeInBed = timeInBed,
                deepMinutes = deep,
                lightMinutes = light,
                remMinutes = rem,
                wakeMinutes = awake,
                efficiency = efficiency
            )
        } catch(e: Exception) {
            return null
        }
    }

    /** Reads raw intraday HR samples for the past [days] days and computes
     *  spike statistics per day — critical for POTS/MCAS users whose daily
     *  averages appear normal while they experience large orthostatic spikes.
     */
    suspend fun readHistoricalHeartRateWithSpikes(days: Int = 30): List<DailyHeartRateSummary> {
        try {
            val zoneId = ZoneId.systemDefault()
            val end = Instant.now()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)

            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = HeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end)
                )
            )

            // Group all samples by local date string mapping to time and bpm
            val byDay = mutableMapOf<String, MutableList<Pair<Long, Int>>>()
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
            response.records.forEach { record ->
                record.samples.forEach { sample ->
                    val timestamp = sample.time.toEpochMilli()
                    val dateStr = sdf.format(java.util.Date(timestamp))
                    byDay.getOrPut(dateStr) { mutableListOf() }.add(timestamp to sample.beatsPerMinute.toInt())
                }
            }

            val threshold = DailyHeartRateSummary.SPIKE_THRESHOLD_BPM
            return byDay.map { (date, samples) ->
                val sortedSamples = samples.sortedBy { it.first }
                val bpmList = sortedSamples.map { it.second }.sorted()
                val avg = bpmList.average().toInt()
                val max = bpmList.last()
                val min = bpmList.first()
                val p10Index = (bpmList.size * 0.10).toInt().coerceAtLeast(0)
                val baseline = bpmList[p10Index]
                val maxDelta = max - baseline
                
                var dayCount = 0
                var nightCount = 0
                val eventRecords = mutableListOf<SpikeEventRecord>()
                var currentEventPeak = 0
                var currentEventStart = 0L
                var inEvent = false
                var eventEndMs = 0L
                
                for (s in sortedSamples) {
                    if (s.second >= threshold) {
                        if (!inEvent || s.first > eventEndMs) {
                            if (inEvent) {
                                val dur = maxOf(1, ((eventEndMs - 300000L - currentEventStart) / 60000L).toInt())
                                eventRecords.add(SpikeEventRecord(currentEventPeak, dur, currentEventStart))
                                
                                val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(currentEventStart), zoneId).hour
                                if (h in 7..21) dayCount++ else nightCount++
                            }
                            inEvent = true
                            currentEventStart = s.first
                            currentEventPeak = s.second
                        } else {
                            currentEventPeak = maxOf(currentEventPeak, s.second)
                        }
                        eventEndMs = s.first + 300000L
                    }
                }
                if (inEvent) {
                    val dur = maxOf(1, ((eventEndMs - 300000L - currentEventStart) / 60000L).toInt())
                    eventRecords.add(SpikeEventRecord(currentEventPeak, dur, currentEventStart))
                    val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(currentEventStart), zoneId).hour
                    if (h in 7..21) dayCount++ else nightCount++
                }

                DailyHeartRateSummary(
                    date = date,
                    avg = avg,
                    max = max,
                    min = min,
                    baseline = baseline,
                    spikeCount = dayCount + nightCount,
                    daySpikeCount = dayCount,
                    nightSpikeCount = nightCount,
                    maxDelta = maxDelta,
                    totalReadings = sortedSamples.size,
                    eventsList = eventRecords
                )
            }.sortedByDescending { it.date }
        } catch (e: Exception) {
            return emptyList()
        }
    }

    suspend fun readHistoricalHeartRate(days: Int = 180): List<Pair<String, Int>> {
        try {
            val end = ZonedDateTime.now(ZoneId.systemDefault()).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
            val response = healthConnectClient.aggregateGroupByDuration(
                AggregateGroupByDurationRequest(
                    metrics = setOf(HeartRateRecord.BPM_AVG),
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    timeRangeSlicer = Duration.ofDays(1)
                )
            )
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }
            
            return response.mapNotNull { bucket ->
                val avg = bucket.result[HeartRateRecord.BPM_AVG]
                if (avg != null && avg > 0) {
                    val dateStr = formatter.format(java.util.Date(bucket.startTime.toEpochMilli()))
                    dateStr to avg.toInt()
                } else null
            }.sortedBy { it.first }
        } catch(e: Exception) {
            return emptyList()
        }
    }

    suspend fun readHistoricalCalories(days: Int = 180): List<Pair<String, Int>> {
        try {
            val end = ZonedDateTime.now(ZoneId.systemDefault()).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
            val response = healthConnectClient.aggregateGroupByDuration(
                AggregateGroupByDurationRequest(
                    metrics = setOf(TotalCaloriesBurnedRecord.ENERGY_TOTAL, ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    timeRangeSlicer = Duration.ofDays(1)
                )
            )
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }
            
            return response.mapNotNull { bucket ->
                val total = bucket.result[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories 
                    ?: bucket.result[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories
                
                if (total != null && total > 0) {
                    val dateStr = formatter.format(java.util.Date(bucket.startTime.toEpochMilli()))
                    dateStr to total.toInt()
                } else null
            }.sortedBy { it.first }
        } catch(e: Exception) {
            return emptyList()
        }
    }

    suspend fun readHistoricalSleep(days: Int = 180, targetDateStr: String? = null): List<Pair<String, Int>> {
        try {
            val anchorDate = if (targetDateStr != null) {
                ZonedDateTime.of(java.time.LocalDate.parse(targetDateStr), java.time.LocalTime.MAX, ZoneId.systemDefault())
            } else {
                ZonedDateTime.now(ZoneId.systemDefault())
            }
            
            // Clamp end to now; HealthConnect rejects future timestamps unconditionally
            var end = anchorDate.plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            if (end.isAfter(Instant.now())) {
                end = Instant.now()
            }
            
            val start = anchorDate.minusDays(days.toLong()).truncatedTo(ChronoUnit.DAYS).toInstant()
            
            // Note: SLEEP_SESSION_DURATION_TOTAL is the best way to get total minutes,
            // but for actual 'minutes asleep' we might still need sessions if we want awake deduction.
            // For general trends, session duration is standard.
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = SleepSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end)
                )
            )
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone(ZoneId.systemDefault())
            }
            
            val dailySessions = mutableMapOf<String, Int>()
            
            // Pre-seed the requested trailing window with 0s so fully missing days correctly hit the penalty
            for (i in 0 until days) {
                val d = anchorDate.minusDays(i.toLong())
                val dStr = String.format("%04d-%02d-%02d", d.year, d.monthValue, d.dayOfMonth)
                dailySessions[dStr] = 0
            }
            
            val sessionIntervals = mutableListOf<Triple<Instant, Instant, Int>>()
            
            response.records.forEach { session ->
                var awake = 0L
                session.stages.forEach { stage ->
                    if (stage.stage in listOf(SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED)) {
                        awake += Duration.between(stage.startTime, stage.endTime).toMinutes()
                    }
                }
                val asleep = Duration.between(session.startTime, session.endTime).toMinutes() - awake
                sessionIntervals.add(Triple(session.startTime, session.endTime, asleep.toInt()))
            }
            
            // Sort by start time and filter overlaps to prevent double-counting
            val sortedSessions = sessionIntervals.sortedBy { it.first }
            val uniqueSessions = mutableListOf<Triple<Instant, Instant, Int>>()
            
            sortedSessions.forEach { current ->
                val overlap = uniqueSessions.find { 
                    (current.first.isBefore(it.second) && current.second.isAfter(it.first))
                }
                
                if (overlap == null) {
                    uniqueSessions.add(current)
                } else {
                    // If they overlap significantly, prefer the longer one
                    if (current.third > overlap.third) {
                        uniqueSessions.remove(overlap)
                        uniqueSessions.add(current)
                    }
                }
            }
            
            uniqueSessions.forEach { session ->
                val dateStr = formatter.format(java.util.Date(session.second.toEpochMilli()))
                if (dailySessions.containsKey(dateStr)) {
                    dailySessions[dateStr] = (dailySessions[dateStr] ?: 0) + session.third
                }
            }
            
            return dailySessions.entries.map { it.key to it.value }.sortedBy { it.first }
        } catch(e: Exception) {
            return emptyList()
        }
    }

    suspend fun readLatestWeight(): Float? {
        try {
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = WeightRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(Instant.now().minus(365, ChronoUnit.DAYS), Instant.now()),
                    ascendingOrder = false
                )
            )
            val latest = response.records.firstOrNull() ?: return null
            return latest.weight.inPounds.toFloat()
        } catch(e: Exception) { return null }
    }

    suspend fun readLatestHeight(): Float? {
        try {
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = HeightRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(Instant.now().minus(365, ChronoUnit.DAYS), Instant.now()),
                    ascendingOrder = false
                )
            )
            val latest = response.records.firstOrNull() ?: return null
            return latest.height.inInches.toFloat()
        } catch(e: Exception) { return null }
    }

    suspend fun readHeartRateVariability(days: Int = 30): List<Pair<String, Double>> {
        try {
            val end = ZonedDateTime.now(ZoneId.systemDefault()).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = HeartRateVariabilityRmssdRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end)
                )
            )
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }
            
            // Group by day, take mean of RMSSD for the day (ideally nocturnal but depends on wearable source)
            val dailyValues = response.records.groupBy { 
                formatter.format(java.util.Date(it.time.toEpochMilli()))
            }.mapValues { entry ->
                entry.value.map { it.heartRateVariabilityMillis }.average()
            }
            
            return dailyValues.toList().sortedBy { it.first }
        } catch(e: Exception) {
            return emptyList()
        }
    }

    fun requestPermissionsActivityContract(): androidx.activity.result.contract.ActivityResultContract<Set<String>, Set<String>> {
        return PermissionController.createRequestPermissionResultContract()
    }
}
