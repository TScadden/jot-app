package com.notel.notel.ui.navigation

object WeeklySnapshotDestinationMapper {
    fun mapMetricToDestination(metricName: String): String {
        return when (metricName) {
            "Sleep Hours" -> "sleep"
            "Resting Heart Rate" -> "fitbit"
            "HR Spikes" -> "hr_spikes"
            "Calories" -> "key_metrics"
            "Logs" -> "history"
            "Habit Completion" -> "habits"
            "Blood Pressure" -> "blood_pressure"
            else -> "history"
        }
    }
}
