package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.SyncopeEventDao
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.SyncopeEvent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Fast capture for syncope / near-syncope episodes. Optionally attaches the
 * heart rate measured around the event (Health Connect, ±5 minutes) and
 * always writes a Symptoms-category LogEntry so the episode appears in the
 * existing Trends/report pipeline. The first-class [SyncopeEvent] rows feed
 * the clinical report collector (safety-relevant doctor history).
 */
@Singleton
class SyncopeRepository @Inject constructor(
    private val dao: SyncopeEventDao,
    private val logEntryDao: LogEntryDao,
    private val healthConnectManager: HealthConnectManager
) {
    val allEvents: Flow<List<SyncopeEvent>> = dao.getAllEvents()

    suspend fun logEvent(
        type: String,
        prodromes: List<String>,
        postureAtOnset: String,
        location: String,
        recoveryMinutes: Int,
        notes: String = ""
    ): SyncopeEvent = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val hr = readHeartRateAround(now)
        val event = SyncopeEvent(
            timestamp = now,
            type = if (type.uppercase() == "FULL") "FULL" else "NEAR",
            prodromeJson = Json.encodeToString(prodromes),
            postureAtOnset = postureAtOnset.uppercase(),
            location = location.uppercase(),
            heartRateAround = hr,
            recoveryMinutes = recoveryMinutes.coerceAtLeast(0),
            notes = notes
        )
        val id = dao.insertEvent(event)
        writeTrendsEntry(event.copy(id = id))
        event.copy(id = id)
    }

    suspend fun getRecentEvents(days: Int): List<SyncopeEvent> = withContext(Dispatchers.IO) {
        dao.getEventsSince(System.currentTimeMillis() - days * 24L * 60 * 60 * 1000L)
    }

    private suspend fun readHeartRateAround(timestampMs: Long): Int {
        return try {
            if (!healthConnectManager.hasAllPermissions()) return 0
            val since = Instant.ofEpochMilli(timestampMs - 5 * 60 * 1000L)
            val samples = healthConnectManager.readLatestHeartRate(since)
                .filter { it.first <= timestampMs + 5 * 60 * 1000L }
                .map { it.second }
            if (samples.isEmpty()) 0 else samples.max()
        } catch (e: Exception) { 0 }
    }

    private suspend fun writeTrendsEntry(event: SyncopeEvent) {
        val kind = if (event.type == "FULL") "Syncope (faint)" else "Near-syncope"
        val prodromes = try {
            Json.decodeFromString<List<String>>(event.prodromeJson)
        } catch (e: Exception) { emptyList() }
        val prodromeText = prodromes.takeIf { it.isNotEmpty() }?.joinToString(", ") ?: "no prodromes logged"
        val hrText = if (event.heartRateAround > 0) " HR ~${event.heartRateAround} bpm." else ""
        val body = "$kind — ${event.postureAtOnset.lowercase()} at onset, ${event.location.lowercase()}. Prodromes: $prodromeText.$hrText Recovery ~${event.recoveryMinutes} min."
        logEntryDao.insertEntry(
            LogEntry(
                timestamp = event.timestamp,
                categoryId = 1, // Symptoms
                body = body,
                chips = """["${if (event.type == "FULL") "Syncope" else "Near-syncope"}"]""",
                manualText = event.notes
            )
        )
    }
}
