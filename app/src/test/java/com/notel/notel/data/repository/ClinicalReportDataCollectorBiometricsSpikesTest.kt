package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.healthconnect.HealthConnectCoordinator
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.KnowledgeDocumentDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.entity.AiInsight
import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.*

class ClinicalReportDataCollectorBiometricsSpikesTest {

    private val json = Json { ignoreUnknownKeys = true }
    private lateinit var insightsFlow: MutableStateFlow<String>
    private lateinit var collector: ClinicalReportDataCollector

    private fun insight(date: String, text: String): AiInsight =
        AiInsight(
            id = "biometrics_${date}_v6",
            text = text,
            timestamp = 0L,
            type = "Biometrics"
        )

    private fun payload(spikes: String?): String {
        val spikesJson = if (spikes == null) "" else ",\"spikes\":$spikes"
        return "{\"sleepMins\":400,\"deepSleepMins\":90,\"avgHr\":72,\"hrv\":55.0,\"calories\":2400$spikesJson}"
    }

    @Before
    fun setUp() {
        insightsFlow = MutableStateFlow("")
        val preferences = mock(NotelPreferences::class.java)
        `when`(preferences.aiInsights).thenReturn(insightsFlow)

        collector = ClinicalReportDataCollector(
            mock(LogEntryDao::class.java),
            mock(KnowledgeDocumentDao::class.java),
            preferences,
            mock(ConditionRepository::class.java),
            mock(BloodPressureRepository::class.java),
            mock(HealthConnectCoordinator::class.java),
            mock(HealthConnectManager::class.java)
        )
    }

    @OptIn(ExperimentalStdlibApi::class)
    @Suppress("UNCHECKED_CAST")
    private fun readBiometricsSpikes(minDate: String): List<DailyHeartRateSummary> =
        runBlocking {
            // Private suspend funs compile to JVM methods with a trailing
            // Continuation parameter, so invoke with the coroutine's own
            // continuation (directly or after suspension).
            val method = ClinicalReportDataCollector::class.java.declaredMethods
                .first { it.name == "readBiometricsSpikes" }
            method.isAccessible = true
            suspendCoroutineUninterceptedOrReturn { cont ->
                method.invoke(collector, minDate, cont)
            } as List<DailyHeartRateSummary>
        }

    @Test
    fun `insight with spikes 5 produces one entry with spikeCount 5`() {
        insightsFlow.value = json.encodeToString(
            listOf(insight("2026-09-30", payload("5")))
        )

        val result = readBiometricsSpikes("2026-09-01")

        assertEquals(1, result.size)
        assertEquals("2026-09-30", result[0].date)
        assertEquals(5, result[0].spikeCount)
    }

    @Test
    fun `insight without spikes key is skipped`() {
        insightsFlow.value = json.encodeToString(
            listOf(
                insight("2026-09-30", payload("5")),
                insight("2026-09-29", payload(null)) // no "spikes" key at all
            )
        )

        val result = readBiometricsSpikes("2026-09-01")

        assertEquals(1, result.size)
        assertEquals("2026-09-30", result[0].date)
    }

    @Test
    fun `spikes zero is included as zero, matching the dashboard rule`() {
        // "spikes":0 is ambiguous (true zero vs spikes-unknown), but the
        // dashboard treats it as data and this layer stays consistent.
        insightsFlow.value = json.encodeToString(
            listOf(insight("2026-09-30", payload("0")))
        )

        val result = readBiometricsSpikes("2026-09-01")

        assertEquals(1, result.size)
        assertEquals(0, result[0].spikeCount)
    }

    @Test
    fun `no insights returns emptyList so the pipeline falls through to the Health Connect read`() {
        insightsFlow.value = "[]"

        assertTrue(readBiometricsSpikes("2026-09-01").isEmpty())
    }

    @Test
    fun `blank insights store returns emptyList`() {
        insightsFlow.value = ""

        assertTrue(readBiometricsSpikes("2026-09-01").isEmpty())
    }

    @Test
    fun `insights before minDate are excluded`() {
        insightsFlow.value = json.encodeToString(
            listOf(
                insight("2026-08-15", payload("7")),
                insight("2026-09-30", payload("3"))
            )
        )

        val result = readBiometricsSpikes("2026-09-01")

        assertEquals(1, result.size)
        assertEquals("2026-09-30", result[0].date)
        assertEquals(3, result[0].spikeCount)
    }

    @Test
    fun `non-v6 and non-biometrics insights are ignored`() {
        val other = AiInsight(
            id = "biometrics_2026-09-30_v5",
            text = payload("9"),
            timestamp = 0L,
            type = "Biometrics"
        )
        val summary = AiInsight(
            id = "summary_2026-09-30_v6",
            text = payload("9"),
            timestamp = 0L,
            type = "SUMMARY"
        )
        insightsFlow.value = json.encodeToString(
            listOf(insight("2026-09-30", payload("2")), other, summary)
        )

        val result = readBiometricsSpikes("2026-09-01")

        assertEquals(1, result.size)
        assertEquals(2, result[0].spikeCount)
    }

    @Test
    fun `mixed days produce sorted entries with only date and spikeCount populated`() {
        insightsFlow.value = json.encodeToString(
            listOf(
                insight("2026-10-01", payload("1")),
                insight("2026-09-30", payload("5"))
            )
        )

        val result = readBiometricsSpikes("2026-09-01")

        assertEquals(listOf("2026-09-30", "2026-10-01"), result.map { it.date })
        assertEquals(listOf(5, 1), result.map { it.spikeCount })
        result.forEach {
            assertEquals(0, it.avg)
            assertEquals(0, it.max)
            assertEquals(0, it.min)
            assertEquals(0, it.baseline)
        }
    }
}
