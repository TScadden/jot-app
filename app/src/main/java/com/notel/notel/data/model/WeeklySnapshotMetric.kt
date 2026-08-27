package com.notel.notel.data.model

/**
 * Stable enum identifiers for Weekly Snapshot metrics.
 * Uses [stableKey] for preferences and internal routing.
 */
enum class WeeklySnapshotMetric(
    val stableKey: String,
    val displayName: String
) {
    SLEEP_HOURS("sleep_hours", "Sleep Hours"),
    RESTING_HEART_RATE("resting_heart_rate", "Resting Heart Rate"),
    HR_SPIKES("hr_spikes", "HR Spikes"),
    CALORIES("calories", "Active Calories"),
    LOGS("logs", "Logs"),
    HABIT_COMPLETION("habit_completion", "Habit Completion"),
    BLOOD_PRESSURE("blood_pressure", "Blood Pressure");

    companion object {
        val DEFAULT = SLEEP_HOURS

        fun fromKeyOrDisplayName(value: String?): WeeklySnapshotMetric {
            if (value.isNullOrBlank()) return DEFAULT
            return values().firstOrNull { 
                it.stableKey.equals(value, ignoreCase = true) || 
                it.displayName.equals(value, ignoreCase = true) 
            } ?: DEFAULT
        }
    }
}
