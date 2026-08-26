package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.LogEntryDao
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton

data class HealthComparisonItem(
    val metricName: String,
    val currentPeriod: String,
    val comparisonPeriod: String,
    val differenceText: String,
    val dataSource: String,
    val lastUpdatedTime: String,
    val isStaleOrOffline: Boolean = false
)

@Singleton
class HealthComparisonRepository @Inject constructor(
    private val healthConnectManager: HealthConnectManager,
    private val logEntryDao: LogEntryDao,
    private val habitRepository: HabitRepository
) {
    suspend fun getWhatChangedComparisons(todayStr: String = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE)): List<HealthComparisonItem> {
        val comparisons = mutableListOf<HealthComparisonItem>()
        val today = LocalDate.parse(todayStr)

        // 1. Sleep Comparison (bounded 7-day range)
        try {
            val sleepHistory = healthConnectManager.readHistoricalSleep(days = 8, targetDateStr = todayStr)
            val todaySleep = sleepHistory.firstOrNull { it.first == todayStr }?.second
            val previousDays = sleepHistory.filter { it.first != todayStr && it.second > 0 }

            if (todaySleep != null && previousDays.size >= 3) {
                val avgSleep = previousDays.map { it.second }.average()
                val diffMins = (todaySleep - avgSleep).toInt()
                val diffText = when {
                    diffMins < -15 -> "${Math.abs(diffMins)} minutes shorter than your seven-day average."
                    diffMins > 15 -> "$diffMins minutes longer than your seven-day average."
                    else -> "Close to your seven-day average."
                }
                comparisons.add(
                    HealthComparisonItem(
                        metricName = "Sleep Duration",
                        currentPeriod = "${todaySleep / 60}h ${todaySleep % 60}m today",
                        comparisonPeriod = "7-day avg (${(avgSleep / 60).toInt()}h ${(avgSleep % 60).toInt()}m)",
                        differenceText = "Sleep was $diffText",
                        dataSource = "Health Connect",
                        lastUpdatedTime = "Today"
                    )
                )
            }
        } catch (e: Exception) {
            // Fail safely
        }

        // 2. Resting Heart Rate Comparison
        try {
            val rhrHistory = healthConnectManager.readHistoricalHeartRate(days = 8)
            val todayRhr = rhrHistory.firstOrNull { it.first == todayStr }?.second
            val previousRhr = rhrHistory.filter { it.first != todayStr && it.second > 0 }

            if (todayRhr != null && previousRhr.size >= 3) {
                val avgRhr = previousRhr.map { it.second }.average().toInt()
                val diffBpm = todayRhr - avgRhr
                val diffText = when {
                    diffBpm > 5 -> "$diffBpm bpm higher than your seven-day average."
                    diffBpm < -5 -> "${Math.abs(diffBpm)} bpm lower than your seven-day average."
                    else -> "close to your recent average."
                }
                comparisons.add(
                    HealthComparisonItem(
                        metricName = "Resting Heart Rate",
                        currentPeriod = "$todayRhr bpm today",
                        comparisonPeriod = "7-day avg ($avgRhr bpm)",
                        differenceText = "Resting heart rate is $diffText",
                        dataSource = "Health Connect",
                        lastUpdatedTime = "Today"
                    )
                )
            }
        } catch (e: Exception) {
            // Fail safely
        }

        // 3. Symptom Frequency (Symptom Category ID = 5 or log body contains symptom keywords)
        try {
            val startTs = today.minusDays(7).atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
            val logs = logEntryDao.getEntriesInDateRangeDirect(startTs, System.currentTimeMillis())
            val symptomLogs = logs.filter { it.categoryId.toLong() == 5L || it.body.contains("headache", ignoreCase = true) || it.body.contains("nausea", ignoreCase = true) || it.body.contains("fatigue", ignoreCase = true) }

            if (symptomLogs.isNotEmpty()) {
                val count = symptomLogs.size
                comparisons.add(
                    HealthComparisonItem(
                        metricName = "Symptom Logs",
                        currentPeriod = "$count logged in past 7 days",
                        comparisonPeriod = "Previous week",
                        differenceText = "Symptoms were logged $count time${if (count > 1) "s" else ""} this week.",
                        dataSource = "Personal Log Entries",
                        lastUpdatedTime = "Today"
                    )
                )
            }
        } catch (e: Exception) {
            // Fail safely
        }

        return comparisons
    }
}
