package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.ScheduledDoseOccurrenceDao
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.util.TimeProvider
import kotlinx.coroutines.flow.first
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

data class DailySnapshotPoint(
    val dateStr: String, // "YYYY-MM-DD"
    val dayLabel: String, // e.g. "Thu"
    val value: Float?,   // null if missing / unrecorded
    val secondaryValue: Float? = null // for Blood Pressure (systolic/diastolic)
)

data class WeeklySnapshotMetricData(
    val metricName: String,
    val unit: String,
    val points: List<DailySnapshotPoint>,
    val averageOrTotalText: String,
    val isAvailable: Boolean = true,
    val emptyMessage: String? = null
)

class WeeklySnapshotAggregator(
    private val timeProvider: TimeProvider
) {
    private val dateFormatter = DateTimeFormatter.ISO_LOCAL_DATE
    private val dayOfWeekFormatter = DateTimeFormatter.ofPattern("EEE", Locale.ENGLISH)

    fun get7DayDates(targetToday: LocalDate? = null): Pair<List<LocalDate>, Pair<List<String>, List<String>>> {
        val endDate = targetToday ?: timeProvider.today()
        val dates = (6 downTo 0).map { endDate.minusDays(it.toLong()) }
        val dateStrs = dates.map { it.format(dateFormatter) }
        val dayLabels = dates.map { it.format(dayOfWeekFormatter) }
        return Triple(dates, dateStrs, dayLabels).let { Pair(it.first, Pair(it.second, it.third)) }
    }

    fun aggregateSleep(dateStrs: List<String>, dayLabels: List<String>, rawHistory: List<Pair<String, Int>>): WeeklySnapshotMetricData {
        val map = rawHistory.toMap()
        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val mins = map[dStr]
            val value = if (mins != null && mins > 0) mins / 60f else null
            DailySnapshotPoint(dStr, label, value)
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            val avg = validVals.average()
            val h = avg.toInt()
            val m = ((avg - h) * 60).toInt()
            "7-Day Avg: ${h}h ${m}m"
        } else "Not enough sleep data yet"

        val emptyMsg = if (validVals.isEmpty()) "Not enough sleep data yet" else null
        return WeeklySnapshotMetricData("Sleep Hours", "h", points, avgText, emptyMessage = emptyMsg)
    }

    fun aggregateRestingHr(dateStrs: List<String>, dayLabels: List<String>, rawHistory: List<Pair<String, Int>>): WeeklySnapshotMetricData {
        val map = rawHistory.toMap()
        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val bpm = map[dStr]
            val value = if (bpm != null && bpm > 0) bpm.toFloat() else null
            DailySnapshotPoint(dStr, label, value)
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Avg: ${validVals.average().toInt()} bpm"
        } else "No heart rate data logged past 7 days"

        val emptyMsg = if (validVals.isEmpty()) "No heart rate data logged past 7 days" else null
        return WeeklySnapshotMetricData("Resting Heart Rate", "bpm", points, avgText, emptyMessage = emptyMsg)
    }

    fun aggregateCalories(dateStrs: List<String>, dayLabels: List<String>, rawHistory: List<Pair<String, Int>>): WeeklySnapshotMetricData {
        val map = rawHistory.toMap()
        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val cals = map[dStr]
            val value = if (cals != null && cals > 0) cals.toFloat() else null
            DailySnapshotPoint(dStr, label, value)
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Total: ${validVals.sum().toInt()} kcal"
        } else "No calorie data logged past 7 days"

        val emptyMsg = if (validVals.isEmpty()) "No calorie data logged past 7 days" else null
        return WeeklySnapshotMetricData("Calories", "kcal", points, avgText, emptyMessage = emptyMsg)
    }

    fun aggregateLogs(dateStrs: List<String>, dayLabels: List<String>, entries: List<LogEntry>): WeeklySnapshotMetricData {
        val zoneId = timeProvider.zoneId()
        val countsByDate = entries.groupBy {
            Instant.ofEpochMilli(it.timestamp).atZone(zoneId).toLocalDate().format(dateFormatter)
        }.mapValues { it.value.size }

        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val count = countsByDate[dStr] ?: 0
            DailySnapshotPoint(dStr, label, count.toFloat())
        }

        val total = points.sumOf { it.value?.toInt() ?: 0 }
        return WeeklySnapshotMetricData("Logs", "", points, "7-Day Total: $total logs")
    }

    fun aggregateSymptoms(
        dateStrs: List<String>,
        dayLabels: List<String>,
        entries: List<LogEntry>,
        symptomCategoryId: Int?
    ): WeeklySnapshotMetricData {
        val zoneId = timeProvider.zoneId()

        val symptomEntries = entries.filter { entry ->
            val matchesCategory = symptomCategoryId != null && entry.categoryId == symptomCategoryId
            val matchesLegacyTextFallback = entry.categoryId == 0 && (
                entry.body.contains("headache", ignoreCase = true) ||
                entry.body.contains("nausea", ignoreCase = true) ||
                entry.body.contains("fatigue", ignoreCase = true)
            )
            matchesCategory || matchesLegacyTextFallback
        }

        val countsByDate = symptomEntries.groupBy {
            Instant.ofEpochMilli(it.timestamp).atZone(zoneId).toLocalDate().format(dateFormatter)
        }.mapValues { it.value.size }

        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val count = countsByDate[dStr] ?: 0
            DailySnapshotPoint(dStr, label, count.toFloat())
        }

        val total = points.sumOf { it.value?.toInt() ?: 0 }
        return WeeklySnapshotMetricData("Symptoms", "", points, "7-Day Total: $total symptoms logged")
    }

    fun aggregateMedication(
        dates: List<LocalDate>,
        dayLabels: List<String>,
        occurrences: List<ScheduledDoseOccurrence>
    ): WeeklySnapshotMetricData {
        val today = timeProvider.today()
        val currentTime = LocalTime.now(timeProvider.clock())

        val grouped = occurrences.groupBy { it.scheduledDate }

        val points = dates.zip(dayLabels).map { (date, label) ->
            val dStr = date.format(dateFormatter)
            val dayOccs = (grouped[dStr] ?: emptyList()).distinctBy { it.occurrenceKey }

            val evaluatedOccurrences = dayOccs.filter { occ ->
                if (date.isBefore(today)) {
                    true
                } else if (date == today) {
                    if (occ.status == "TAKEN" || occ.status == "SKIPPED" || occ.status == "SNOOZED") {
                        true
                    } else if (occ.status == "PENDING") {
                        val scheduledTime = try {
                            if (!occ.scheduledTime.isNullOrBlank() && occ.scheduledTime.contains(":")) {
                                LocalTime.parse(occ.scheduledTime)
                            } else null
                        } catch (e: Exception) { null }

                        if (scheduledTime != null) {
                            scheduledTime.isBefore(currentTime) || scheduledTime == currentTime
                        } else true
                    } else false
                } else false
            }

            if (evaluatedOccurrences.isEmpty()) {
                DailySnapshotPoint(dStr, label, null)
            } else {
                val takenCount = evaluatedOccurrences.count { it.status == "TAKEN" }
                val totalCount = evaluatedOccurrences.size
                val pct = (takenCount.toFloat() / totalCount.toFloat()) * 100f
                DailySnapshotPoint(dStr, label, pct)
            }
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Adherence: ${validVals.average().toInt()}%"
        } else "No scheduled medication doses due in past 7 days"

        val emptyMsg = if (validVals.isEmpty()) "No scheduled medication doses due in past 7 days" else null
        return WeeklySnapshotMetricData("Medication Adherence", "%", points, avgText, emptyMessage = emptyMsg)
    }

    fun aggregateHabits(
        dateStrs: List<String>,
        dayLabels: List<String>,
        habits: List<HabitDtoModel>,
        isInitialized: Boolean
    ): WeeklySnapshotMetricData {
        if (!isInitialized) {
            val emptyPoints = dateStrs.zip(dayLabels).map { DailySnapshotPoint(it.first, it.second, null) }
            return WeeklySnapshotMetricData("Habit Completion", "%", emptyPoints, "Loading habits...", emptyMessage = null)
        }

        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            if (habits.isEmpty()) {
                DailySnapshotPoint(dStr, label, null)
            } else {
                val completedCount = habits.count { dStr in it.logs }
                val pct = (completedCount.toFloat() / habits.size.toFloat()) * 100f
                DailySnapshotPoint(dStr, label, pct)
            }
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Completion: ${validVals.average().toInt()}%"
        } else "No habits configured"

        val emptyMsg = if (habits.isEmpty()) "No habits configured" else if (validVals.isEmpty()) "No habit logs past 7 days" else null
        return WeeklySnapshotMetricData("Habit Completion", "%", points, avgText, emptyMessage = emptyMsg)
    }
}

@Singleton
class WeeklySnapshotRepository @Inject constructor(
    private val healthConnectManager: HealthConnectManager,
    private val logEntryDao: LogEntryDao,
    private val categoryDao: CategoryDao,
    private val scheduledDoseOccurrenceDao: ScheduledDoseOccurrenceDao,
    private val habitRepository: HabitRepository,
    private val timeProvider: TimeProvider
) {
    val aggregator = WeeklySnapshotAggregator(timeProvider)

    suspend fun get7DaySnapshot(metricName: String, targetToday: LocalDate? = null): WeeklySnapshotMetricData {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates(targetToday)
        val (dateStrs, dayLabels) = dateStrsAndLabels

        return when (metricName) {
            "Sleep Hours" -> {
                val raw = healthConnectManager.readHistoricalSleep(days = 10, targetDateStr = dateStrs.last())
                aggregator.aggregateSleep(dateStrs, dayLabels, raw)
            }
            "Resting Heart Rate" -> {
                val raw = healthConnectManager.readHistoricalHeartRate(days = 10)
                aggregator.aggregateRestingHr(dateStrs, dayLabels, raw)
            }
            "Calories" -> {
                val raw = healthConnectManager.readHistoricalCalories(days = 10)
                aggregator.aggregateCalories(dateStrs, dayLabels, raw)
            }
            "Logs" -> {
                val zoneId = timeProvider.zoneId()
                val startTs = dates.first().atStartOfDay(zoneId).toInstant().toEpochMilli()
                val endTs = dates.last().plusDays(1).atStartOfDay(zoneId).toInstant().toEpochMilli()
                val entries = logEntryDao.getEntriesInDateRangeDirect(startTs, endTs)
                aggregator.aggregateLogs(dateStrs, dayLabels, entries)
            }
            "Symptoms" -> {
                val category = categoryDao.getCategoryBySlug("symptoms")
                val zoneId = timeProvider.zoneId()
                val startTs = dates.first().atStartOfDay(zoneId).toInstant().toEpochMilli()
                val endTs = dates.last().plusDays(1).atStartOfDay(zoneId).toInstant().toEpochMilli()
                val entries = logEntryDao.getEntriesInDateRangeDirect(startTs, endTs)
                aggregator.aggregateSymptoms(dateStrs, dayLabels, entries, category?.id)
            }
            "Medication Adherence" -> {
                val occurrences = scheduledDoseOccurrenceDao.getOccurrencesForDateDirect("") // fallback range
                aggregator.aggregateMedication(dates, dayLabels, occurrences)
            }
            "Habit Completion" -> {
                val isInit = habitRepository.isInitialized.value
                val habits = habitRepository.habits.value
                aggregator.aggregateHabits(dateStrs, dayLabels, habits, isInit)
            }
            "Blood Pressure" -> getBloodPressureSnapshot(dates, dateStrs, dayLabels)
            else -> {
                val raw = healthConnectManager.readHistoricalSleep(days = 10, targetDateStr = dateStrs.last())
                aggregator.aggregateSleep(dateStrs, dayLabels, raw)
            }
        }
    }

    private suspend fun getBloodPressureSnapshot(dates: List<LocalDate>, dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val hasPermission = try { healthConnectManager.hasBloodPressurePermission() } catch (e: Exception) { false }
        if (!hasPermission) {
            val emptyPoints = dateStrs.zip(dayLabels).map { DailySnapshotPoint(it.first, it.second, null) }
            return WeeklySnapshotMetricData("Blood Pressure", "mmHg", emptyPoints, "Blood Pressure permission not granted", isAvailable = false, emptyMessage = "Blood Pressure permission not granted")
        }

        val bpRecords = try { healthConnectManager.readBloodPressureRecords(days = 10) } catch (e: Exception) { emptyList() }
        if (bpRecords.isEmpty()) {
            val emptyPoints = dateStrs.zip(dayLabels).map { DailySnapshotPoint(it.first, it.second, null) }
            return WeeklySnapshotMetricData("Blood Pressure", "mmHg", emptyPoints, "No blood pressure records found", isAvailable = false, emptyMessage = "No blood pressure records found")
        }

        val zoneId = timeProvider.zoneId()
        val grouped = bpRecords.groupBy {
            Instant.ofEpochMilli(it.timeEpochMs).atZone(zoneId).toLocalDate().format(DateTimeFormatter.ISO_LOCAL_DATE)
        }

        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val dayRecords = grouped[dStr]
            if (dayRecords.isNullOrEmpty()) {
                DailySnapshotPoint(dStr, label, null, null)
            } else {
                val avgSys = dayRecords.map { it.systolic }.average().toFloat()
                val avgDia = dayRecords.map { it.diastolic }.average().toFloat()
                DailySnapshotPoint(dStr, label, avgSys, avgDia)
            }
        }

        val validSys = points.mapNotNull { it.value }
        val validDia = points.mapNotNull { it.secondaryValue }

        val avgText = if (validSys.isNotEmpty() && validDia.isNotEmpty()) {
            "7-Day Avg: ${validSys.average().toInt()}/${validDia.average().toInt()} mmHg"
        } else "No blood pressure data logged past 7 days"

        val emptyMsg = if (validSys.isEmpty()) "No blood pressure data logged past 7 days" else null
        return WeeklySnapshotMetricData("Blood Pressure", "mmHg", points, avgText, isAvailable = true, emptyMessage = emptyMsg)
    }
}
