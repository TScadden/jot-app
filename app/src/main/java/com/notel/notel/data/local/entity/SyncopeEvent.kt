package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One syncope (faint) or near-syncope episode.
 *
 * type: "FULL" | "NEAR"
 * prodromeJson: JSON array of prodrome symptom labels
 * postureAtOnset: "STANDING" | "SITTING" | "LYING" | "UNKNOWN"
 * location: "HOME" | "OUT" | "UNKNOWN"
 * heartRateAround: beats-per-minute captured from Health Connect around the
 * event window, or 0 when unavailable.
 */
@Entity(tableName = "syncope_events")
data class SyncopeEvent(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val timestamp: Long,
    val type: String = "NEAR",
    val prodromeJson: String = "[]",
    val postureAtOnset: String = "UNKNOWN",
    val location: String = "UNKNOWN",
    val heartRateAround: Int = 0,
    val recoveryMinutes: Int = 0,
    val notes: String = "",
    val updatedAt: Long = System.currentTimeMillis()
)
