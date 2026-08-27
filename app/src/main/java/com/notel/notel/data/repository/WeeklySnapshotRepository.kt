package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.ScheduledDoseOccurrenceDao
import com.notel.notel.data.remote.HabitDtoModel
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton

data class DailySnapshotPoint(
    val dateStr: String, // "YYYY-MM-DD"
    val dayLabel: String, // e.g. "Thu", "8/27"
    val value: Float?,   // null if missing / unrecorded
    val secondaryValue: Float? = null // for Blood Pressure (systolic/diastolic)
)

data class WeeklySnapshotMetricData(
    val metricName: String,
    val unit: String,
    val points: List<DailySnapshotPoint>,
    val averageOrTotalText: String,
    val isAvailable: Boolean = true
)

@Singleton
class WeeklySnapshotRepository @Inject constructor(
    private val healthConnectManager: HealthConnectManager,
    private val logEntryDao: LogEntryDao,
    private val categoryDao: CategoryDao,
    private val scheduledDoseOccurrenceDao: ScheduledDoseOccurrenceDao,
    private val habitRepository: HabitRepository
) {
    private val dateFormatter = DateTimeFormatter.ISO_LOCAL_DATE
    private val labelFormatter = DateTimeFormatter.ofPattern("M/d")

    suspend fun get7DaySnapshot(metricName: String, todayStr: String = LocalDate.now().toString()): WeeklySnapshotMetricData {
        val endDate = try { LocalDate.parse(todayStr) } catch (e: Exception) { LocalDate.now() }
        val dates = (6 downTo 0).map { endDate.minusDays(it.toLong()) }
        val dateStrs = dates.map { it.format(dateFormatter) }
        val dayLabels = dates.map { it.format(labelFormatter) }

        return when (metricName) {
            "Sleep Hours" -> getSleepSnapshot(dateStrs, dayLabels)
            "Resting Heart Rate" -> getRestingHrSnapshot(dateStrs, dayLabels)
            "Calories" -> getCaloriesSnapshot(dateStrs, dayLabels)
            "Logs" -> getLogsSnapshot(dates, dateStrs, dayLabels)
            "Symptoms" -> getSymptomsSnapshot(dates, dateStrs, dayLabels)
            "Medication Adherence" -> getMedicationSnapshot(dateStrs, dayLabels)
            "Habit Completion" -> getHabitsSnapshot(dateStrs, dayLabels)
            "Blood Pressure" -> getBloodPressureSnapshot(dates, dateStrs, dayLabels)
            else -> getSleepSnapshot(dateStrs, dayLabels)
        }
    }

    private suspend fun getSleepSnapshot(dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val history = healthConnectManager.readHistoricalSleep(days = 10, targetDateStr = dateStrs.last())
        val map = history.toMap()

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
        } else "No sleep data logged past 7 days"

        return WeeklySnapshotMetricData("Sleep Hours", "h", points, avgText)
    }

    private suspend fun getRestingHrSnapshot(dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val history = healthConnectManager.readHistoricalHeartRate(days = 10)
        val map = history.toMap()

        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val bpm = map[dStr]
            val value = if (bpm != null && bpm > 0) bpm.toFloat() else null
            DailySnapshotPoint(dStr, label, value)
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Avg: ${validVals.average().toInt()} bpm"
        } else "No heart rate data logged past 7 days"

        return WeeklySnapshotMetricData("Resting Heart Rate", "bpm", points, avgText)
    }

    private suspend fun getCaloriesSnapshot(dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val history = healthConnectManager.readHistoricalCalories(days = 10)
        val map = history.toMap()

        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val cals = map[dStr]
            val value = if (cals != null && cals > 0) cals.toFloat() else null
            DailySnapshotPoint(dStr, label, value)
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Total: ${validVals.sum().toInt()} kcal"
        } else "No calorie data logged past 7 days"

        return WeeklySnapshotMetricData("Calories", "kcal", points, avgText)
    }

    private suspend fun getLogsSnapshot(dates: List<LocalDate>, dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val startTs = dates.first().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val endTs = dates.last().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val entries = logEntryDao.getEntriesInDateRangeDirect(startTs, endTs)

        val zoneId = ZoneId.systemDefault()
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

    private suspend fun getSymptomsSnapshot(dates: List<LocalDate>, dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val symptomCategory = categoryDao.getCategoryBySlug("symptoms")
        val symptomCategoryId = symptomCategory?.id

        val startTs = dates.first().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val endTs = dates.last().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val entries = logEntryDao.getEntriesInDateRangeDirect(startTs, endTs)

        val symptomEntries = entries.filter { entry ->
            val matchesCategory = symptomCategoryId != null && entry.categoryId == symptomCategoryId
            val matchesLegacyTextFallback = entry.categoryId == 0 && (
                entry.body.contains("headache", ignoreCase = true) ||
                entry.body.contains("nausea", ignoreCase = true) ||
                entry.body.contains("fatigue", ignoreCase = true)
            )
            matchesCategory || matchesLegacyTextFallback
        }

        val zoneId = ZoneId.systemDefault()
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

    private suspend fun getMedicationSnapshot(dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val points = dateStrs.zip(dayLabels).map { (dStr, label) ->
            val occurrences = scheduledDoseOccurrenceDao.getOccurrencesForDateDirect(dStr)
            if (occurrences.isEmpty()) {
                DailySnapshotPoint(dStr, label, null)
            } else {
                val taken = occurrences.count { it.status == "TAKEN" }
                val total = occurrences.size
                val pct = (taken.toFloat() / total.toFloat()) * 100f
                DailySnapshotPoint(dStr, label, pct)
            }
        }

        val validVals = points.mapNotNull { it.value }
        val avgText = if (validVals.isNotEmpty()) {
            "7-Day Adherence: ${validVals.average().toInt()}%"
        } else "No scheduled medication doses in past 7 days"

        return WeeklySnapshotMetricData("Medication Adherence", "%", points, avgText)
    }

    private suspend fun getHabitsSnapshot(dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val habits = habitRepository.habits.value
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

        return WeeklySnapshotMetricData("Habit Completion", "%", points, avgText)
    }

    private suspend fun getBloodPressureSnapshot(dates: List<LocalDate>, dateStrs: List<String>, dayLabels: List<String>): WeeklySnapshotMetricData {
        val hasPermission = healthConnectManager.hasBloodPressurePermission()
        if (!hasPermission) {
            val emptyPoints = dateStrs.zip(dayLabels).map { DailySnapshotPoint(it.first, it.second, null) }
            return WeeklySnapshotMetricData("Blood Pressure", "mmHg", emptyPoints, "Blood Pressure permission not granted", isAvailable = false)
        }

        val bpRecords = healthConnectManager.readBloodPressureRecords(days = 10)
        if (bpRecords.isEmpty()) {
            val emptyPoints = dateStrs.zip(dayLabels).map { DailySnapshotPoint(it.first, it.second, null) }
            return WeeklySnapshotMetricData("Blood Pressure", "mmHg", emptyPoints, "No blood pressure records found in Health Connect", isAvailable = false)
        }

        val zoneId = ZoneId.systemDefault()
        val grouped = bpRecords.groupBy {
            Instant.ofEpochMilli(it.timeEpochMs).atZone(zoneId).toLocalDate().format(dateFormatter)
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

        return WeeklySnapshotMetricData("Blood Pressure", "mmHg", points, avgText, isAvailable = true)
    }
}
