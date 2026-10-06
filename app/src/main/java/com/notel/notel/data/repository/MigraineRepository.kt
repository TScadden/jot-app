package com.notel.notel.data.repository

import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.MigraineAttackDao
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.MigraineAttack
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.WeatherApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Migraine attack lifecycle: one-tap start/stop, mid-attack minimal logging,
 * auto-attached barometric pressure, and a Symptoms-category LogEntry on
 * completion so the attack flows into the existing Trends/report pipeline.
 */
@Singleton
class MigraineRepository @Inject constructor(
    private val dao: MigraineAttackDao,
    private val logEntryDao: LogEntryDao,
    private val preferences: NotelPreferences
) {
    private val weatherApi = WeatherApi()

    val allAttacks: Flow<List<MigraineAttack>> = dao.getAllAttacks()

    suspend fun getActiveAttack(): MigraineAttack? = withContext(Dispatchers.IO) {
        val id = preferences.activeMigraineAttackId.first()
        if (id == 0L) dao.getActiveAttack() else dao.getAttack(id)
    }

    /** Starts an attack; auto-attaches barometric pressure via Open-Meteo. */
    suspend fun startAttack(): MigraineAttack = withContext(Dispatchers.IO) {
        val pressure = fetchPressure()
        val attack = MigraineAttack(
            startTimestamp = System.currentTimeMillis(),
            pressureAtStartHpa = pressure
        )
        val id = dao.insertAttack(attack)
        preferences.setActiveMigraineAttackId(id)
        dao.getAttack(id) ?: attack.copy(id = id)
    }

    /** Updates mid-attack detail (aura phase, meds taken, peak pain so far). */
    suspend fun updateActiveAttack(
        auraPhase: String? = null,
        medsTaken: String? = null,
        painPeak: Int? = null,
        notes: String? = null
    ) = withContext(Dispatchers.IO) {
        val active = getActiveAttack() ?: return@withContext
        dao.updateAttack(
            active.copy(
                auraPhase = auraPhase ?: active.auraPhase,
                medsTaken = medsTaken ?: active.medsTaken,
                painPeak = painPeak ?: active.painPeak,
                notes = notes ?: active.notes,
                updatedAt = System.currentTimeMillis()
            )
        )
    }

    /** Ends the attack with a relief rating and feeds it into Trends. */
    suspend fun endAttack(reliefRating: Int, finalPainPeak: Int? = null) = withContext(Dispatchers.IO) {
        val active = getActiveAttack() ?: return@withContext
        val now = System.currentTimeMillis()
        val finished = active.copy(
            endTimestamp = now,
            reliefRating = reliefRating.coerceIn(0, 5),
            painPeak = finalPainPeak ?: active.painPeak,
            updatedAt = now
        )
        dao.updateAttack(finished)
        preferences.setActiveMigraineAttackId(0L)
        writeTrendsEntry(finished)
    }

    suspend fun getRecentAttacks(days: Int): List<MigraineAttack> = withContext(Dispatchers.IO) {
        dao.getAttacksSince(System.currentTimeMillis() - days * 24L * 60 * 60 * 1000L)
    }

    private suspend fun fetchPressure(): Double {
        return try {
            val lat = preferences.lastKnownLat.first().takeIf { it != 0.0 } ?: return 0.0
            val lon = preferences.lastKnownLon.first().takeIf { it != 0.0 } ?: return 0.0
            weatherApi.getPressureOutlook(lat, lon)?.currentHpa ?: 0.0
        } catch (e: Exception) { 0.0 }
    }

    private fun fmt(ts: Long): String =
        LocalDateTime.ofInstant(java.time.Instant.ofEpochMilli(ts), ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("MMM d, h:mm a"))

    private suspend fun writeTrendsEntry(attack: MigraineAttack) {
        val durationMin = attack.endTimestamp?.let { (it - attack.startTimestamp) / 60000 }
        val durationText = durationMin?.let { "${it}m" } ?: "ongoing"
        val medsText = attack.medsTaken.ifBlank { "no meds logged" }
        val auraText = attack.auraPhase.lowercase().takeIf { it != "none" }?.let { "Aura: $it. " } ?: ""
        val body = "Migraine attack — $durationText. ${auraText}Peak pain ${attack.painPeak}/10. Meds: $medsText. Relief ${attack.reliefRating}/5. Started ${fmt(attack.startTimestamp)}."
        logEntryDao.insertEntry(
            LogEntry(
                timestamp = attack.startTimestamp,
                categoryId = 1, // Symptoms
                body = body,
                chips = """["Migraine attack"]""",
                manualText = "Ended ${attack.endTimestamp?.let { fmt(it) } ?: ""}"
            )
        )
    }
}
