package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One migraine attack: start/end timestamps plus optional per-phase detail.
 *
 * pressureAtStartHpa: surface pressure (hPa) captured from Open-Meteo at
 * attack start, for the known migraine/pressure-swing correlation. 0 = not captured.
 */
@Entity(tableName = "migraine_attacks")
data class MigraineAttack(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val startTimestamp: Long,
    val endTimestamp: Long? = null,
    /** Aura phase observed at onset, if any: NONE | VISUAL | SENSORY | SPEECH | MOTOR */
    val auraPhase: String = "NONE",
    /** Comma-separated names of medications taken for this attack */
    val medsTaken: String = "",
    /** Peak pain 1-10 reported during the attack */
    val painPeak: Int = 0,
    /** Relief rating at attack end, 1-5 (5 = fully relieved) */
    val reliefRating: Int = 0,
    val pressureAtStartHpa: Double = 0.0,
    val notes: String = "",
    val updatedAt: Long = System.currentTimeMillis()
)
