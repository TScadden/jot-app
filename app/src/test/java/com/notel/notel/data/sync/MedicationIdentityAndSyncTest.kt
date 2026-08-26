package com.notel.notel.data.sync

import com.notel.notel.data.local.entity.Medication
import com.notel.notel.ui.viewmodel.Medication as MedicationDto
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class MedicationIdentityAndSyncTest {

    // Pure production reconciliation logic helper for test verification
    private fun reconcileMedications(
        existingMeds: List<Medication>,
        serverMeds: List<MedicationDto>
    ): List<Medication> {
        val resultMap = existingMeds.associateBy { if (it.uuid.isNotBlank()) it.uuid else it.id.toString() }.toMutableMap()

        for (med in serverMeds) {
            val serverUuid = med.id
            val existingMatch = existingMeds.find { 
                if (serverUuid.isNotBlank() && it.uuid.isNotBlank()) {
                    it.uuid == serverUuid
                } else {
                    it.name.trim().equals(med.name.trim(), ignoreCase = true) && 
                    it.startedDate == med.startDate.trim().ifEmpty { null }
                }
            }

            if (existingMatch != null) {
                // Do not resurrect explicitly deleted local medications
                if (existingMatch.isDeleted && existingMatch.updatedAt >= med.updatedAt) {
                    continue
                }
                // Do not overwrite a newer local edit with a stale snapshot
                if (existingMatch.updatedAt > med.updatedAt) {
                    continue
                }
            }

            if (med.isDeleted) {
                if (existingMatch != null) {
                    val key = if (existingMatch.uuid.isNotBlank()) existingMatch.uuid else existingMatch.id.toString()
                    resultMap[key] = existingMatch.copy(
                        isDeleted = true,
                        updatedAt = maxOf(med.updatedAt, existingMatch.updatedAt)
                    )
                }
                continue
            }

            val targetUuid = if (serverUuid.isNotBlank()) serverUuid else (existingMatch?.uuid?.ifBlank { null } ?: UUID.randomUUID().toString())
            val dbMed = Medication(
                id = existingMatch?.id ?: 0L,
                uuid = targetUuid,
                name = med.name.trim(),
                dose = if (med.dose.isNotBlank()) med.dose else (existingMatch?.dose ?: "As prescribed"),
                frequency = if (med.frequency.isNotBlank()) med.frequency else (existingMatch?.frequency ?: "Daily"),
                timesPerDay = existingMatch?.timesPerDay ?: 1,
                notes = existingMatch?.notes ?: "",
                isArchived = !med.isPresent,
                startedDate = med.startDate.trim().ifEmpty { null },
                endedDate = if (!med.isPresent) med.endDate.trim().ifEmpty { null } else null,
                updatedAt = maxOf(med.updatedAt, existingMatch?.updatedAt ?: 0L),
                isDeleted = false
            )
            resultMap[targetUuid] = dbMed
        }

        return resultMap.values.toList()
    }

    @Test
    fun pull_neverDeletesPendingLocalMedications() {
        val pendingLocal = Medication(
            id = 1L,
            uuid = "local-uuid-1",
            name = "Aspirin",
            dose = "81mg",
            frequency = "Daily",
            startedDate = "2026-01-01"
        )
        val existing = listOf(pendingLocal)
        val serverPayload = emptyList<MedicationDto>()

        val merged = reconcileMedications(existing, serverPayload)

        assertEquals(1, merged.size)
        assertEquals("local-uuid-1", merged.first().uuid)
        assertEquals("Aspirin", merged.first().name)
        assertFalse(merged.first().isDeleted)
    }

    @Test
    fun pull_doesNotCollapseDuplicateNames() {
        val med1 = Medication(
            id = 10L,
            uuid = "uuid-morning-aspirin",
            name = "Aspirin",
            dose = "81mg",
            frequency = "Morning"
        )
        val med2 = Medication(
            id = 11L,
            uuid = "uuid-evening-aspirin",
            name = "Aspirin",
            dose = "325mg",
            frequency = "Evening"
        )
        val existing = listOf(med1, med2)

        val serverPayload = listOf(
            MedicationDto(id = "uuid-morning-aspirin", name = "Aspirin", dose = "81mg", frequency = "Morning", isPresent = true),
            MedicationDto(id = "uuid-evening-aspirin", name = "Aspirin", dose = "325mg", frequency = "Evening", isPresent = true)
        )

        val merged = reconcileMedications(existing, serverPayload).filter { !it.isDeleted }

        assertEquals(2, merged.size)
        val uids = merged.map { it.uuid }.toSet()
        assertTrue(uids.contains("uuid-morning-aspirin"))
        assertTrue(uids.contains("uuid-evening-aspirin"))
    }

    @Test
    fun pull_doesNotResurrectExplicitDeletions() {
        val deletedLocal = Medication(
            id = 5L,
            uuid = "uuid-deleted-med",
            name = "Lisinopril",
            dose = "10mg",
            frequency = "Daily",
            isDeleted = true,
            updatedAt = 2000L
        )
        val existing = listOf(deletedLocal)

        val staleServerMed = MedicationDto(
            id = "uuid-deleted-med",
            name = "Lisinopril",
            dose = "10mg",
            frequency = "Daily",
            isPresent = true,
            updatedAt = 1000L,
            isDeleted = false
        )

        val merged = reconcileMedications(existing, listOf(staleServerMed))
        val activeMeds = merged.filter { !it.isDeleted }

        assertTrue(activeMeds.isEmpty())
        assertTrue(merged.find { it.uuid == "uuid-deleted-med" }?.isDeleted == true)
    }

    @Test
    fun pull_doesNotOverwriteNewerLocalEditWithStaleSnapshot() {
        val localEdit = Medication(
            id = 2L,
            uuid = "uuid-med-1",
            name = "Metformin",
            dose = "1000mg", // Edited locally to 1000mg
            frequency = "Twice Daily",
            updatedAt = 5000L
        )
        val existing = listOf(localEdit)

        val staleServerSnapshot = MedicationDto(
            id = "uuid-med-1",
            name = "Metformin",
            dose = "500mg", // Stale server dose
            frequency = "Daily",
            updatedAt = 2000L
        )

        val merged = reconcileMedications(existing, listOf(staleServerSnapshot))

        assertEquals(1, merged.size)
        assertEquals("1000mg", merged.first().dose)
        assertEquals("Twice Daily", merged.first().frequency)
        assertEquals(5000L, merged.first().updatedAt)
    }

    @Test
    fun pull_preservesDosageAndFrequencyFromRemote() {
        val existing = emptyList<Medication>()
        val serverMed = MedicationDto(
            id = "uuid-remote-med",
            name = "Propranolol",
            dose = "20mg",
            frequency = "Three times daily",
            startDate = "2026-02-01",
            isPresent = true,
            updatedAt = 3000L
        )

        val merged = reconcileMedications(existing, listOf(serverMed))

        assertEquals(1, merged.size)
        val med = merged.first()
        assertEquals("uuid-remote-med", med.uuid)
        assertEquals("Propranolol", med.name)
        assertEquals("20mg", med.dose)
        assertEquals("Three times daily", med.frequency)
        assertEquals("2026-02-01", med.startedDate)
        assertFalse(med.isArchived)
    }
}
