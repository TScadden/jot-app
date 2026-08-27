package com.notel.notel.ui.navigation

object WeeklySnapshotDestinationMapper {
    fun mapMetricToDestination(metricName: String): String {
        return when (metricName) {
            "Sleep Hours" -> "sleep"
            "Resting Heart Rate" -> "fitbit"
            "Calories" -> "key_metrics"
            "Logs" -> "history"
            "Symptoms" -> "history"
            "Medication Adherence" -> "medications"
            "Habit Completion" -> "habits"
            "Blood Pressure" -> "blood_pressure"
            else -> "history"
        }
    }
}
