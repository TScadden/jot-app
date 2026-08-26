package com.notel.notel.ui.viewmodel

import org.junit.Assert.*
import org.junit.Test

class BannerAndNotificationFlowTest {

    @Test
    fun normalLog_emitsSingleEntryLoggedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        // Emit Normal Log event
        val event = QuickLogEvent.EntryLogged(entryId = 101L, message = "Entry logged")
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryLogged)
        val entryLogged = events.first() as QuickLogEvent.EntryLogged
        assertEquals(101L, entryLogged.entryId)
        assertEquals("Entry logged", entryLogged.message)
    }

    @Test
    fun repeatLast_emitsSingleEntryRepeatedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        val event = QuickLogEvent.EntryRepeated(entryId = 102L, message = "Last entry repeated")
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryRepeated)
        val entryRepeated = events.first() as QuickLogEvent.EntryRepeated
        assertEquals(102L, entryRepeated.entryId)
        assertEquals("Last entry repeated", entryRepeated.message)
    }

    @Test
    fun recentSuggestion_emitsSingleEntryLoggedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        val event = QuickLogEvent.EntryLogged(entryId = 103L, message = "Entry logged")
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryLogged)
        assertEquals(103L, (events.first() as QuickLogEvent.EntryLogged).entryId)
    }

    @Test
    fun pinnedTemplate_emitsSingleEntryLoggedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        val event = QuickLogEvent.EntryLogged(entryId = 104L, message = "Entry logged")
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryLogged)
        assertEquals("Entry logged", (events.first() as QuickLogEvent.EntryLogged).message)
    }

    @Test
    fun medicationTemplate_emitsSingleMedicationLoggedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        val event = QuickLogEvent.EntryLogged(entryId = 105L, message = "Medication logged")
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryLogged)
        assertEquals("Medication logged", (events.first() as QuickLogEvent.EntryLogged).message)
    }

    @Test
    fun universalAdd_emitsSingleEntryLoggedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        val event = QuickLogEvent.EntryLogged(entryId = 106L, message = "Entry logged")
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryLogged)
        assertEquals(106L, (events.first() as QuickLogEvent.EntryLogged).entryId)
    }

    @Test
    fun voiceLoggingResult_emitsSingleVoiceEntryLoggedEvent() {
        val events = mutableListOf<QuickLogEvent>()
        val listener: (QuickLogEvent) -> Unit = { events.add(it) }

        // VoiceLogActivity result handler path
        val voiceMsg = "Voice entry logged"
        val event = QuickLogEvent.EntryLogged(entryId = 0L, message = voiceMsg)
        listener(event)

        assertEquals(1, events.size)
        assertTrue(events.first() is QuickLogEvent.EntryLogged)
        assertEquals("Voice entry logged", (events.first() as QuickLogEvent.EntryLogged).message)
    }
}
