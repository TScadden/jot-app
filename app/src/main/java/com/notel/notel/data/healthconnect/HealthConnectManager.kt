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
    val durationMins: Int
)

/** Per-day heart rate summary exposing spike data for POTS-aware AI analysis. */
@Serializable
data class DailyHeartRateSummary(
    val date: String,
    val avg: Int,
    val max: Int,
    val min: Int,
    val baseline: Int,      // 10th-percentile — true resting estimate
    val spikeCount: Int,    // readings >= SPIKE_THRESHOLD_BPM
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
            HealthPermission.getReadPermission(HeightRecord::class)
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

    suspend fun readHeartRateIntraday(dateStr: String): List<Pair<String, Int>> {
        try {
            val startOfDay = if (dateStr == "today" || dateStr.isBlank()) Instant.now().truncatedTo(ChronoUnit.DAYS) else Instant.parse("${dateStr}T00:00:00Z")
            val endOfDay = startOfDay.plus(1, ChronoUnit.DAYS)
            
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = HeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(startOfDay, endOfDay)
                )
            )
            
            val result = mutableListOf<Pair<String, Int>>()
            response.records.forEach { record ->
                record.samples.forEach { sample ->
                    val zdt = ZonedDateTime.ofInstant(sample.time, ZoneId.systemDefault())
                    val timeStr = String.format("%02d:%02d:%02d", zdt.hour, zdt.minute, zdt.second)
                    result.add(timeStr to sample.beatsPerMinute.toInt())
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
            val startOfDay = if (dateStr == "today" || dateStr.isBlank()) Instant.now().truncatedTo(ChronoUnit.DAYS) else Instant.parse("${dateStr}T00:00:00Z")
            val endOfDay = startOfDay.plus(1, ChronoUnit.DAYS)
            
            val response = healthConnectClient.aggregate(
                AggregateRequest(
                    metrics = setOf(TotalCaloriesBurnedRecord.ENERGY_TOTAL, ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(startOfDay, endOfDay)
                )
            )
            
            val totalKcal = response[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories?.toInt() 
                ?: response[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories?.toInt() ?: 0
            
            return totalKcal
        } catch(e: Exception) {
            return 0
        }
    }
    
    private fun startOfDate(dateStr: String): Instant? = try { if (dateStr=="today") Instant.now().truncatedTo(ChronoUnit.DAYS) else Instant.parse("${dateStr}T00:00:00Z") } catch(e: Exception) { null }
    private fun endOfDate(dateStr: String): Instant? = startOfDate(dateStr)?.plus(1, ChronoUnit.DAYS)


    suspend fun readSleepSession(dateStr: String): SleepData? {
        try {
            val startOfDay = if (dateStr == "today" || dateStr.isBlank()) Instant.now().truncatedTo(ChronoUnit.DAYS) else Instant.parse("${dateStr}T00:00:00Z")
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
                
                var eventCount = 0
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
                                eventRecords.add(SpikeEventRecord(currentEventPeak, dur))
                            }
                            eventCount++
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
                    eventRecords.add(SpikeEventRecord(currentEventPeak, dur))
                }

                DailyHeartRateSummary(
                    date = date,
                    avg = avg,
                    max = max,
                    min = min,
                    baseline = baseline,
                    spikeCount = eventCount,
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
            val end = Instant.now().plus(1, ChronoUnit.DAYS).truncatedTo(ChronoUnit.DAYS)
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
            val end = Instant.now().plus(1, ChronoUnit.DAYS).truncatedTo(ChronoUnit.DAYS)
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

    suspend fun readHistoricalSleep(days: Int = 180): List<Pair<String, Int>> {
        try {
            // End date slightly shifted to capture sessions that end on the 'end' date
            val end = Instant.now().plus(1, ChronoUnit.DAYS).truncatedTo(ChronoUnit.DAYS)
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
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
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }
            
            val dailySessions = mutableMapOf<String, Int>()
            
            response.records.forEach { session ->
                val dateStr = formatter.format(java.util.Date(session.endTime.toEpochMilli()))
                var awake = 0L
                session.stages.forEach { stage ->
                    if (stage.stage in listOf(SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED)) {
                        awake += Duration.between(stage.startTime, stage.endTime).toMinutes()
                    }
                }
                val asleep = Duration.between(session.startTime, session.endTime).toMinutes() - awake
                // Prefer the longest session if multiple exist (e.g. nap vs main sleep)
                if (asleep > (dailySessions[dateStr] ?: 0)) {
                    dailySessions[dateStr] = asleep.toInt()
                }
            }
            
            return dailySessions.keys.map { it to dailySessions[it]!! }.sortedBy { it.first }
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

    fun requestPermissionsActivityContract(): androidx.activity.result.contract.ActivityResultContract<Set<String>, Set<String>> {
        return PermissionController.createRequestPermissionResultContract()
    }
}
