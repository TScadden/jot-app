package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import org.junit.Assert.*
import org.junit.Test

class ReportEventsTest {

    private val dayMs = 24 * 60 * 60 * 1000L
    private val now = 1_790_496_000_000L

    private fun med(
        name: String,
        started: String? = null,
        ended: String? = null
    ) = Medication(name = name, startedDate = started, endedDate = ended)

    @Test
    fun parseMedicationDate_acceptsCommonFormats() {
        assertNotNull(parseMedicationDate("2026-03-15"))
        assertNotNull(parseMedicationDate("03/15/2026"))
        assertNotNull(parseMedicationDate("Mar 15, 2026"))
        assertNull(parseMedicationDate("Present"))
        assertNull(parseMedicationDate("sometime last spring"))
        assertNull(parseMedicationDate(""))
        assertNull(parseMedicationDate(null))
    }

    @Test
    fun extractMedicationEvents_startAndStopFromRecords() {
        val events = extractMedicationEvents(
            medications = listOf(med("Ivabradine", started = "2026-07-01", ended = "2026-08-15")),
            logEntries = emptyList(),
            categoriesMap = emptyMap()
        )
        assertEquals(2, events.size)
        assertEquals(MedicationChangeKind.STARTED, events[0].kind)
        assertEquals(MedicationChangeKind.STOPPED, events[1].kind)
        assertEquals("medication record", events[0].evidence)
        assertTrue(events[0].dateMs!! < events[1].dateMs!!)
    }

    @Test
    fun extractMedicationEvents_unparseableDateSurfacesWithoutAnchoring() {
        val events = extractMedicationEvents(
            medications = listOf(med("Creatine", started = "last spring-ish")),
            logEntries = emptyList(),
            categoriesMap = emptyMap()
        )
        assertEquals(1, events.size)
        assertNull(events[0].dateMs)
        assertEquals("last spring-ish", events[0].dateLabel)
        assertTrue(events[0].evidence.contains("date as written"))
    }

    @Test
    fun extractMedicationEvents_doseMentionLabeledAsMention() {
        val entry = LogEntry(
            id = 1, timestamp = now - 3 * dayMs, categoryId = 8,
            body = "Doctor increased ivabradine to 7.5mg twice daily"
        )
        val events = extractMedicationEvents(
            medications = listOf(med("Ivabradine", started = "2026-07-01")),
            logEntries = listOf(entry),
            categoriesMap = mapOf(8 to "Medication")
        )
        val mention = events.firstOrNull { it.kind == MedicationChangeKind.DOSE_MENTION }
        assertNotNull(mention)
        assertEquals("recorded mention in logs", mention!!.evidence)
        assertEquals("Ivabradine", mention.medicationName)
        assertTrue(mention.snippet.contains("7.5mg"))
    }

    @Test
    fun extractMedicationEvents_noKeywordNoMention() {
        val entry = LogEntry(
            id = 1, timestamp = now - 3 * dayMs, categoryId = 8,
            body = "Took my morning pills with breakfast"
        )
        val events = extractMedicationEvents(
            medications = listOf(med("Ivabradine", started = "2026-07-01")),
            logEntries = listOf(entry),
            categoriesMap = mapOf(8 to "Medication")
        )
        assertTrue(events.none { it.kind == MedicationChangeKind.DOSE_MENTION })
    }

    @Test
    fun compareBeforeAfter_deterministicWindows() {
        // 40 days of sleep hours: 8h before the event, 6h after.
        val eventDay = (now / dayMs) * dayMs - 20 * dayMs
        val points = (0 until 40).map { d ->
            val ts = (now / dayMs) * dayMs - d * dayMs
            ts to if (ts < eventDay) 8.0 else 6.0
        }
        val cmp = compareBeforeAfter(
            eventDateMs = eventDay,
            eventLabel = "TestMed started",
            eventDateText = "Sep 11, 2026",
            metricLabel = "sleep",
            unit = "h",
            points = points,
            windowDays = 14
        )
        assertEquals(8.0, cmp.beforeMean!!, 1e-9)
        assertEquals(6.0, cmp.afterMean!!, 1e-9)
        assertEquals(14, cmp.beforeDaysWithData)
        assertEquals(14, cmp.afterDaysWithData)
        assertTrue(cmp.overlappingEvents.isEmpty())
    }

    @Test
    fun compareBeforeAfter_missingDataIsNullNotZero() {
        val cmp = compareBeforeAfter(
            eventDateMs = now - 20 * dayMs,
            eventLabel = "TestMed started",
            eventDateText = "Sep 11, 2026",
            metricLabel = "sleep",
            unit = "h",
            points = emptyList(),
            windowDays = 14
        )
        assertNull(cmp.beforeMean)
        assertNull(cmp.afterMean)
        assertEquals(0, cmp.beforeDaysWithData)
    }

    @Test
    fun compareBeforeAfter_overlappingEventsListedAsLimitation() {
        val eventDay = now - 20 * dayMs
        val other = MedicationChangeEvent(
            medicationName = "OtherMed",
            kind = MedicationChangeKind.STOPPED,
            dateMs = eventDay + 5 * dayMs,
            dateLabel = "Sep 16, 2026",
            evidence = "medication record"
        )
        val cmp = compareBeforeAfter(
            eventDateMs = eventDay,
            eventLabel = "TestMed started",
            eventDateText = "Sep 11, 2026",
            metricLabel = "sleep",
            unit = "h",
            points = listOf((eventDay - dayMs) to 7.0, (eventDay + 2 * dayMs) to 7.0),
            windowDays = 14,
            otherEvents = listOf(other)
        )
        assertEquals(1, cmp.overlappingEvents.size)
        assertTrue(cmp.overlappingEvents[0].contains("OtherMed"))
    }

    @Test
    fun describeComparison_correlationLanguageOnly() {
        val cmp = BeforeAfterComparison(
            eventLabel = "TestMed started",
            eventDateLabel = "Sep 11, 2026",
            metricLabel = "sleep",
            unit = "h",
            windowDays = 14,
            beforeMean = 8.0, beforeDaysWithData = 14,
            afterMean = 6.0, afterDaysWithData = 12,
            overlappingEvents = emptyList()
        )
        val text = describeComparison(cmp)
        assertTrue(text.contains("Average recorded sleep was 8.0 h in the 14 days before"))
        assertTrue(text.contains("vs 6.0 h in the 14 days after the recorded TestMed started"))
        assertTrue(text.contains("observed association, not evidence that the change caused"))
        // Must never read as causal.
        assertFalse(text.contains("caused the difference") && !text.contains("not evidence"))
        assertFalse(text.lowercase().contains("orthostatic"))
    }
}
