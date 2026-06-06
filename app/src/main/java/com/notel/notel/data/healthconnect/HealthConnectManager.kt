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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Serializable
data class SpikeEventRecord(
    val peakBpm: Int,
    val durationMins: Int,
    val startTimeMs: Long = 0L
)

@Serializable
data class DailySleepSummary(
    val date: String,
    val minutesAsleep: Int,
    val deepMinutes: Int
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
    val awakeAvg: Int = 0,        // Avg between 7am and 10pm
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

    private fun getSessionPriority(packageName: String): Int {
        return when (packageName) {
            "com.fitbit.FitbitMobile" -> 100
            "com.ouraring.oura" -> 90
            "com.google.android.apps.fitness" -> 80
            "com.sec.android.app.shealth" -> 80
            "com.urbandroid.sleep" -> 70
            "com.sleepcycle.android" -> 70
            "com.notel.notel" -> -100
            else -> 0
        }
    }

    private fun deduplicateSleepSessions(sessions: List<SleepSessionRecord>): List<SleepSessionRecord> {
        val sorted = sessions.sortedBy { it.startTime }
        val result = mutableListOf<SleepSessionRecord>()
        for (session in sorted) {
            if (result.isEmpty()) {
                result.add(session)
            } else {
                val last = result.last()
                if (session.startTime.isBefore(last.endTime)) {
                    val lastPkg = last.metadata.dataOrigin.packageName
                    val currentPkg = session.metadata.dataOrigin.packageName
                    val lastPriority = getSessionPriority(lastPkg)
                    val currentPriority = getSessionPriority(currentPkg)
                    if (currentPriority > lastPriority) {
                        result[result.size - 1] = session
                    } else if (currentPriority == lastPriority) {
                        val lastDuration = Duration.between(last.startTime, last.endTime).toMillis()
                        val currentDuration = Duration.between(session.startTime, session.endTime).toMillis()
                        if (currentDuration > lastDuration) {
                            result[result.size - 1] = session
                        }
                    }
                } else {
                    result.add(session)
                }
            }
        }
        return result
    }

    private fun mergeIntervals(intervals: List<Pair<Instant, Instant>>): List<Pair<Instant, Instant>> {
        if (intervals.isEmpty()) return emptyList()
        val sorted = intervals.sortedBy { it.first }
        val result = mutableListOf<Pair<Instant, Instant>>()
        var current = sorted[0]
        for (i in 1 until sorted.size) {
            val next = sorted[i]
            if (next.first.isBefore(current.second) || next.first == current.second) {
                if (next.second.isAfter(current.second)) {
                    current = current.first to next.second
                }
            } else {
                result.add(current)
                current = next
            }
        }
        result.add(current)
        return result
    }

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
            HealthPermission.getReadPermission(RespiratoryRateRecord::class),
            HealthPermission.getReadPermission(OxygenSaturationRecord::class),
            HealthPermission.getReadPermission(RestingHeartRateRecord::class),
            HealthPermission.getReadPermission(PowerRecord::class),
            "android.permission.health.READ_HEALTH_DATA_HISTORY"
        )
    }

    fun checkAvailability(): Int {
        return HealthConnectClient.getSdkStatus(context, "com.google.android.apps.healthdata")
    }

    suspend fun hasAllPermissions(): Boolean {
        if (checkAvailability() != HealthConnectClient.SDK_AVAILABLE) return false
        val granted = healthConnectClient.permissionController.getGrantedPermissions()
        return granted.isNotEmpty()
    }

    suspend fun hasFullPermissions(): Boolean {
        if (checkAvailability() != HealthConnectClient.SDK_AVAILABLE) return false
        val granted = healthConnectClient.permissionController.getGrantedPermissions()
        return granted.containsAll(permissions)
    }

    suspend fun hasBasicPermissions(): Boolean {
        if (checkAvailability() != HealthConnectClient.SDK_AVAILABLE) return false
        val granted = healthConnectClient.permissionController.getGrantedPermissions()
        val basic = setOf(
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class)
        )
        return granted.containsAll(basic)
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
            
            val active = response[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories?.toInt()
            val total = response[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories?.toInt()
            
            return active ?: total ?: 0
        } catch(e: Exception) {
            return 0
        }
    }

    suspend fun readHistoricalCalories(days: Int = 30): List<Pair<String, Int>> {
        try {
            val zoneId = java.time.ZoneId.systemDefault()
            val end = java.time.ZonedDateTime.now(zoneId).plusDays(1).truncatedTo(java.time.temporal.ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), java.time.temporal.ChronoUnit.DAYS)
            
            val response = healthConnectClient.aggregateGroupByDuration(
                AggregateGroupByDurationRequest(
                    metrics = setOf(TotalCaloriesBurnedRecord.ENERGY_TOTAL, ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    timeRangeSlicer = Duration.ofDays(1)
                )
            )
            
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone(zoneId)
            }
            return response.map { bucket ->
                val date = sdf.format(java.util.Date.from(bucket.startTime))
                val active = bucket.result[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories?.toInt()
                val total = bucket.result[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories?.toInt()
                date to (active ?: total ?: 0)
            }
        } catch(e: Exception) {
            return emptyList()
        }
    }


    suspend fun readSleepSession(dateStr: String): SleepData? {
        try {
            val startOfDay = if (dateStr == "today" || dateStr.isBlank()) {
                ZonedDateTime.now(ZoneId.systemDefault()).truncatedTo(ChronoUnit.DAYS).toInstant()
            } else {
                java.time.LocalDate.parse(dateStr).atStartOfDay(java.time.ZoneId.systemDefault()).toInstant()
            }
            val endOfDay = startOfDay.plus(1, ChronoUnit.DAYS)
            
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = SleepSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(startOfDay.minus(1, ChronoUnit.DAYS), endOfDay)
                )
            )
            
            var targetSession: SleepSessionRecord? = null
            var maxPriority = -999
            var maxDuration = -1L

            response.records.forEach { session ->
                if (session.endTime.isAfter(startOfDay) && session.endTime.isBefore(endOfDay.plus(12, ChronoUnit.HOURS))) {
                    val pkg = session.metadata.dataOrigin.packageName
                    val priority = getSessionPriority(pkg)
                    val duration = ChronoUnit.MINUTES.between(session.startTime, session.endTime)
                    if (priority > maxPriority || (priority == maxPriority && duration > maxDuration)) {
                        maxPriority = priority
                        maxDuration = duration
                        targetSession = session
                    }
                }
            }
            
            val session = targetSession ?: return null

            val deepIntervals = session.stages.filter { it.stage == SleepSessionRecord.STAGE_TYPE_DEEP }.map { it.startTime to it.endTime }
            val lightIntervals = session.stages.filter { it.stage == SleepSessionRecord.STAGE_TYPE_LIGHT }.map { it.startTime to it.endTime }
            val remIntervals = session.stages.filter { it.stage == SleepSessionRecord.STAGE_TYPE_REM }.map { it.startTime to it.endTime }
            val awakeIntervals = session.stages.filter { it.stage in listOf(SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED) }.map { it.startTime to it.endTime }

            val deep = mergeIntervals(deepIntervals).sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
            val light = mergeIntervals(lightIntervals).sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
            val rem = mergeIntervals(remIntervals).sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
            val awake = mergeIntervals(awakeIntervals).sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }

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
    suspend fun readHistoricalHeartRateWithSpikes(days: Int = 30): List<DailyHeartRateSummary> = withContext(Dispatchers.IO) {
        try {
            val zoneId = ZoneId.systemDefault()
            val end = java.time.ZonedDateTime.now(zoneId).plusDays(1).truncatedTo(java.time.temporal.ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), java.time.temporal.ChronoUnit.DAYS)

            val results = mutableListOf<DailyHeartRateSummary>()
            var lastDayStart = 0L
            var lastDayEnd = 0L
            var lastDateStr = ""

            // Query in 30-day chunks to keep database roundtrips low while maintaining low memory footprint
            var currentStart = start
            while (currentStart.isBefore(end)) {
                val currentEnd = minOf(currentStart.plus(30, ChronoUnit.DAYS), end)
                
                val chunkByDay = mutableMapOf<String, MutableList<HeartSample>>()
                var pageToken: String? = null
                do {
                    val response = healthConnectClient.readRecords(
                        ReadRecordsRequest(
                            recordType = HeartRateRecord::class,
                            timeRangeFilter = TimeRangeFilter.between(currentStart, currentEnd),
                            pageToken = pageToken
                        )
                    )

                    response.records.forEach { record ->
                        record.samples.forEach { sample ->
                            val timestamp = sample.time.toEpochMilli()
                            val dateStr = if (timestamp in lastDayStart until lastDayEnd) {
                                lastDateStr
                            } else {
                                val zdt = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(timestamp), zoneId)
                                val startOfDay = zdt.truncatedTo(ChronoUnit.DAYS)
                                lastDayStart = startOfDay.toInstant().toEpochMilli()
                                lastDayEnd = startOfDay.plusDays(1).toInstant().toEpochMilli()
                                lastDateStr = zdt.toLocalDate().toString()
                                lastDateStr
                            }
                            val millisSinceStartOfDay = timestamp - lastDayStart
                            val hour = (millisSinceStartOfDay / 3600000L).toInt()
                            chunkByDay.getOrPut(dateStr) { mutableListOf() }.add(HeartSample(timestamp, sample.beatsPerMinute.toInt(), hour))
                        }
                    }
                    pageToken = response.pageToken
                } while (pageToken != null)

                val threshold = DailyHeartRateSummary.SPIKE_THRESHOLD_BPM
                chunkByDay.forEach { (date, samples) ->
                    val sortedSamples = samples.sortedBy { it.time }
                    val bpmList = sortedSamples.map { it.bpm }.sorted()
                    val avg = bpmList.average().toInt()
                    val max = bpmList.last()
                    val min = bpmList.first()
                    val p10Index = (bpmList.size * 0.10).toInt().coerceAtLeast(0)
                    val baseline = bpmList[p10Index]
                    val maxDelta = max - baseline
                    
                    val daytimeSamples = sortedSamples.filter { it.hour in 7..21 }
                    val awakeAvg = if (daytimeSamples.isNotEmpty()) daytimeSamples.map { it.bpm }.average().toInt() else avg

                    var dayCount = 0
                    var nightCount = 0
                    val eventRecords = mutableListOf<SpikeEventRecord>()
                    var currentEventPeak = 0
                    var currentEventStart = 0L
                    var currentEventStartHour = 0
                    var inEvent = false
                    var eventEndMs = 0L
                    
                    for (s in sortedSamples) {
                        if (s.bpm >= threshold) {
                            if (!inEvent || s.time > eventEndMs) {
                                if (inEvent) {
                                    val dur = maxOf(1, ((eventEndMs - 300000L - currentEventStart) / 60000L).toInt())
                                    eventRecords.add(SpikeEventRecord(currentEventPeak, dur, currentEventStart))
                                    
                                    if (currentEventStartHour in 7..21) dayCount++ else nightCount++
                                }
                                inEvent = true
                                currentEventStart = s.time
                                currentEventStartHour = s.hour
                                currentEventPeak = s.bpm
                            } else {
                                currentEventPeak = maxOf(currentEventPeak, s.bpm)
                            }
                            eventEndMs = s.time + 300000L
                        }
                    }
                    if (inEvent) {
                        val dur = maxOf(1, ((eventEndMs - 300000L - currentEventStart) / 60000L).toInt())
                        eventRecords.add(SpikeEventRecord(currentEventPeak, dur, currentEventStart))
                        if (currentEventStartHour in 7..21) dayCount++ else nightCount++
                    }

                    results.add(
                        DailyHeartRateSummary(
                            date = date,
                            avg = avg,
                            max = max,
                            min = min,
                            baseline = baseline,
                            spikeCount = dayCount + nightCount,
                            daySpikeCount = dayCount,
                            nightSpikeCount = nightCount,
                            awakeAvg = awakeAvg,
                            maxDelta = maxDelta,
                            totalReadings = sortedSamples.size,
                            eventsList = eventRecords
                        )
                    )
                }

                currentStart = currentEnd
            }

            results.sortedByDescending { it.date }
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun readHistoricalHeartRate(days: Int = 180): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        try {
            val end = ZonedDateTime.now(ZoneId.systemDefault()).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone(java.time.ZoneId.systemDefault().id)
            }

            // 1. Try to read RestingHeartRateRecord first
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = RestingHeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end)
                )
            )
            
            val rhrList = response.records.map { record ->
                val dateStr = formatter.format(java.util.Date(record.time.toEpochMilli()))
                dateStr to record.beatsPerMinute.toInt()
            }.distinctBy { it.first }
            
            if (rhrList.isNotEmpty()) {
                return@withContext rhrList.sortedBy { it.first }
            }
            
            // 2. Fall back to Aggregate BPM_AVG if Resting HR is not available
            val aggResponse = healthConnectClient.aggregateGroupByDuration(
                AggregateGroupByDurationRequest(
                    metrics = setOf(HeartRateRecord.BPM_AVG),
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    timeRangeSlicer = Duration.ofDays(1)
                )
            )
            
            aggResponse.mapNotNull { bucket ->
                val avg = bucket.result[HeartRateRecord.BPM_AVG]
                if (avg != null && avg > 0) {
                    val dateStr = formatter.format(java.util.Date(bucket.startTime.toEpochMilli()))
                    dateStr to avg.toInt()
                } else null
            }.sortedBy { it.first }
        } catch(e: Exception) {
            emptyList()
        }
    }


    suspend fun readHistoricalSleep(days: Int = 180, targetDateStr: String? = null): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        try {
            val anchorDate = if (targetDateStr != null) {
                ZonedDateTime.of(java.time.LocalDate.parse(targetDateStr), java.time.LocalTime.MAX, ZoneId.systemDefault())
            } else {
                ZonedDateTime.now(ZoneId.systemDefault())
            }
            
            // Ensure end is the end of the ANCHOR day to include all records for that date
            val endOfAnchor = anchorDate.with(java.time.LocalTime.MAX).toInstant()
            val end = if (endOfAnchor.isAfter(Instant.now())) Instant.now() else endOfAnchor
            
            val start = anchorDate.minusDays(days.toLong()).truncatedTo(ChronoUnit.DAYS).toInstant()
            
            val records = mutableListOf<SleepSessionRecord>()
            var pageToken: String? = null
            do {
                val pageResponse = healthConnectClient.readRecords(
                    ReadRecordsRequest(
                        recordType = SleepSessionRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(start, end),
                        pageToken = pageToken
                    )
                )
                records.addAll(pageResponse.records)
                pageToken = pageResponse.pageToken
            } while (pageToken != null)
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone(ZoneId.systemDefault().id)
            }
            
            val dailySessions = mutableMapOf<String, Int>()
            
            val sessionIntervals = mutableListOf<Triple<Instant, Instant, Int>>()
            
            val deduplicatedRecords = deduplicateSleepSessions(records)
            deduplicatedRecords.forEach { session ->
                val awakeIntervals = session.stages
                    .filter { it.stage in listOf(SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED) }
                    .map { it.startTime to it.endTime }
                val awake = mergeIntervals(awakeIntervals).sumOf { Duration.between(it.first, it.second).toMinutes() }
                val asleep = Duration.between(session.startTime, session.endTime).toMinutes() - awake
                sessionIntervals.add(Triple(session.startTime, session.endTime, asleep.toInt()))
            }
            
            // Logic: Merge overlapping intervals into unique non-overlapping blocks
            val mergedIntervals = mutableListOf<Pair<Instant, Instant>>()
            val sortedSessions = sessionIntervals.sortedBy { it.first }
            
            if (sortedSessions.isNotEmpty()) {
                var currentStart = sortedSessions[0].first
                var currentEnd = sortedSessions[0].second
                
                for (i in 1 until sortedSessions.size) {
                    val next = sortedSessions[i]
                    if (next.first.isBefore(currentEnd) || next.first == currentEnd) {
                        // Overlap! Extend global end
                        if (next.second.isAfter(currentEnd)) {
                            currentEnd = next.second
                        }
                    } else {
                        // Gap! Push previous and start new
                        mergedIntervals.add(currentStart to currentEnd)
                        currentStart = next.first
                        currentEnd = next.second
                    }
                }
                mergedIntervals.add(currentStart to currentEnd)
            }
            
            // Now distribute the merged duration to the appropriate days
            mergedIntervals.forEach { (start, end) ->
                val dateStr = formatter.format(java.util.Date(end.toEpochMilli()))
                
                // Correctly handle awake stages by taking their union as well
                val awakeIntervals = mutableListOf<Pair<Instant, Instant>>()
                records.forEach { record ->
                    if (record.startTime.isBefore(end) && record.endTime.isAfter(start)) {
                        record.stages.forEach { stage ->
                            if (stage.stage in listOf(SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED)) {
                                val s = if (stage.startTime.isAfter(start)) stage.startTime else start
                                val e = if (stage.endTime.isBefore(end)) stage.endTime else end
                                if (e.isAfter(s)) awakeIntervals.add(s to e)
                            }
                        }
                    }
                }
                
                // Merge awake intervals
                val sortedAwake = awakeIntervals.sortedBy { it.first }
                var netAwake = 0L
                if (sortedAwake.isNotEmpty()) {
                    var aStart = sortedAwake[0].first
                    var aEnd = sortedAwake[0].second
                    for (j in 1 until sortedAwake.size) {
                        val n = sortedAwake[j]
                        if (n.first.isBefore(aEnd) || n.first == aEnd) {
                            if (n.second.isAfter(aEnd)) aEnd = n.second
                        } else {
                            netAwake += Duration.between(aStart, aEnd).toMinutes()
                            aStart = n.first
                            aEnd = n.second
                        }
                    }
                    netAwake += Duration.between(aStart, aEnd).toMinutes()
                }
                
                val duration = Duration.between(start, end).toMinutes() - netAwake
                dailySessions[dateStr] = (dailySessions[dateStr] ?: 0) + duration.toInt()
            }
            

            
            dailySessions.entries.map { it.key to it.value }.sortedBy { it.first }
        } catch(e: Exception) {
            emptyList()
        }
    }

    suspend fun readLatestWeight(dateStr: String): Float? {
        try {
            val start = startOfDate(dateStr).minus(90, ChronoUnit.DAYS)
            val end = endOfDate(dateStr)
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = WeightRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    ascendingOrder = false,
                    pageSize = 1
                )
            )
            val weightKg = response.records.firstOrNull()?.weight?.inKilograms ?: return null
            return (weightKg * 2.20462).toFloat()
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

    suspend fun readHeartRateVariability(days: Int = 30): List<Pair<String, Double>> = withContext(Dispatchers.IO) {
        try {
            val end = ZonedDateTime.now(ZoneId.systemDefault()).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
            val records = mutableListOf<HeartRateVariabilityRmssdRecord>()
            var pageToken: String? = null
            do {
                val pageResponse = healthConnectClient.readRecords(
                    ReadRecordsRequest(
                        recordType = HeartRateVariabilityRmssdRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(start, end),
                        pageToken = pageToken
                    )
                )
                records.addAll(pageResponse.records)
                pageToken = pageResponse.pageToken
            } while (pageToken != null)
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone(java.time.ZoneId.systemDefault())
            }
            
            val dailyValues = records.groupBy { 
                formatter.format(java.util.Date(it.time.toEpochMilli()))
            }.mapValues { entry ->
                entry.value.map { it.heartRateVariabilityMillis }.average()
            }
            
            dailyValues.toList().sortedBy { it.first }
        } catch(e: Exception) {
            emptyList()
        }
    }

    suspend fun readRespiratoryRate(dateStr: String): Double? {
        try {
            val end = endOfDate(dateStr)
            val start = startOfDate(dateStr).minus(30, ChronoUnit.DAYS)
            
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = RespiratoryRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    ascendingOrder = false,
                    pageSize = 1
                )
            )
            return response.records.firstOrNull()?.rate
        } catch(e: Exception) { return null }
    }

    suspend fun readOxygenSaturation(dateStr: String): Double? {
        try {
            val end = endOfDate(dateStr)
            val start = startOfDate(dateStr).minus(30, ChronoUnit.DAYS)

            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = OxygenSaturationRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    ascendingOrder = false,
                    pageSize = 1
                )
            )
            val record = response.records.firstOrNull()
            android.util.Log.d("HealthConnectManager", "Oxygen saturation record for $dateStr: $record")
            val rawVal = record?.percentage?.value
            return if (rawVal != null) {
                if (rawVal <= 1.0) rawVal * 100.0 else rawVal
            } else null
        } catch(e: Exception) {
            android.util.Log.e("HealthConnectManager", "Error reading oxygen saturation for $dateStr: ${e.message}", e)
            return null
        }
    }

    suspend fun readRestingHeartRate(dateStr: String): Int? {
        try {
            val start = startOfDate(dateStr)
            val end = endOfDate(dateStr)
            val response = healthConnectClient.readRecords(
                ReadRecordsRequest(
                    recordType = RestingHeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    ascendingOrder = false,
                    pageSize = 1
                )
            )
            return response.records.firstOrNull()?.beatsPerMinute?.toInt()
        } catch(e: Exception) { return null }
    }

    suspend fun readHistoricalSleepWithDeep(days: Int = 180): List<DailySleepSummary> = withContext(Dispatchers.IO) {
        try {
            val end = ZonedDateTime.now(ZoneId.systemDefault()).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(days.toLong(), ChronoUnit.DAYS)
            
            val records = mutableListOf<SleepSessionRecord>()
            var pageToken: String? = null
            do {
                val pageResponse = healthConnectClient.readRecords(
                    ReadRecordsRequest(
                        recordType = SleepSessionRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(start, end),
                        pageToken = pageToken
                    )
                )
                records.addAll(pageResponse.records)
                pageToken = pageResponse.pageToken
            } while (pageToken != null)
            
            val formatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                timeZone = java.util.TimeZone.getTimeZone(ZoneId.systemDefault().id)
            }

            records.forEach { session ->
                val dateStr = formatter.format(java.util.Date(session.endTime.toEpochMilli()))
                if (dateStr == "2026-05-26") {
                    val packageName = session.metadata.dataOrigin.packageName
                    android.util.Log.d("HealthConnectManager", "RAW May 26 Session: ${session.startTime} to ${session.endTime} from package $packageName")
                    android.util.Log.d("HealthConnectManager", "  Raw stages count: ${session.stages.size}")
                    session.stages.forEachIndexed { sIdx, stage ->
                        android.util.Log.d("HealthConnectManager", "    Stage $sIdx: type=${stage.stage}, ${stage.startTime} to ${stage.endTime} (${java.time.Duration.between(stage.startTime, stage.endTime).toMinutes()} mins)")
                    }
                }
            }
            
            // Group all sessions by the date of their end time (the "wakeup" date),
            // then per date pick only the LONGEST session. Fitbit writes multiple
            // SleepSessionRecord entries per night (one full-session + sub-stage entries)
            // which are non-overlapping so deduplication doesn't filter them, causing
            // deep minutes to be summed and massively inflated (e.g. 49m → 293m).
            val sessionsByDate = mutableMapOf<String, SleepSessionRecord>()
            val deduplicatedRecords = deduplicateSleepSessions(records)
            deduplicatedRecords.forEach { session ->
                val dateStr = formatter.format(java.util.Date(session.endTime.toEpochMilli()))
                val existing = sessionsByDate[dateStr]
                
                val pkg = session.metadata.dataOrigin.packageName
                val priority = getSessionPriority(pkg)
                val thisDuration = Duration.between(session.startTime, session.endTime).toMillis()
                
                if (existing == null) {
                    sessionsByDate[dateStr] = session
                } else {
                    val existingPkg = existing.metadata.dataOrigin.packageName
                    val existingPriority = getSessionPriority(existingPkg)
                    val existingDuration = Duration.between(existing.startTime, existing.endTime).toMillis()
                    
                    if (priority > existingPriority || (priority == existingPriority && thisDuration > existingDuration)) {
                        sessionsByDate[dateStr] = session
                    }
                }
            }

            sessionsByDate.map { (dateStr, session) ->
                val deepIntervals = session.stages.filter { it.stage == SleepSessionRecord.STAGE_TYPE_DEEP }.map { it.startTime to it.endTime }
                val awakeIntervals = session.stages.filter { it.stage in listOf(SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED) }.map { it.startTime to it.endTime }
                
                if (dateStr == "2026-05-26") {
                    android.util.Log.d("HealthConnectManager", "May 26 Session: ${session.startTime} to ${session.endTime}")
                    android.util.Log.d("HealthConnectManager", "Raw deep intervals count: ${deepIntervals.size}")
                    deepIntervals.forEachIndexed { index, pair ->
                        android.util.Log.d("HealthConnectManager", "  Deep interval $index: ${pair.first} to ${pair.second} (${java.time.Duration.between(pair.first, pair.second).toMinutes()} mins)")
                    }
                }
                
                val deep = mergeIntervals(deepIntervals).sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
                
                if (dateStr == "2026-05-26") {
                    val mergedDeep = mergeIntervals(deepIntervals)
                    android.util.Log.d("HealthConnectManager", "Merged deep intervals count: ${mergedDeep.size}, total minutes: $deep")
                    mergedDeep.forEachIndexed { index, pair ->
                        android.util.Log.d("HealthConnectManager", "  Merged interval $index: ${pair.first} to ${pair.second} (${java.time.Duration.between(pair.first, pair.second).toMinutes()} mins)")
                    }
                }
                val awake = mergeIntervals(awakeIntervals).sumOf { Duration.between(it.first, it.second).toMinutes() }

                val duration = Duration.between(session.startTime, session.endTime).toMinutes()
                val asleep = (duration - awake).toInt().coerceAtLeast(0)
                DailySleepSummary(
                    date = dateStr,
                    minutesAsleep = asleep,
                    deepMinutes = deep
                )
            }.sortedByDescending { it.date }
        } catch(e: Exception) {
            emptyList()
        }
    }

    fun requestPermissionsActivityContract(): androidx.activity.result.contract.ActivityResultContract<Set<String>, Set<String>> {
        return PermissionController.createRequestPermissionResultContract()
    }
}

private class HeartSample(val time: Long, val bpm: Int, val hour: Int)

