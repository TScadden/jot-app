package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

@Serializable
@Entity(tableName = "medication_side_effect_cache")
data class MedicationSideEffectCache(
    @PrimaryKey val medKey: String, // e.g. "semaglutide_0.5mg"
    val sideEffectsJson: String,  // JSON array of side effect items & durationMinutes
    val timestamp: Long = System.currentTimeMillis()
)
