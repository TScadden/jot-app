package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.dao.MedicationDao
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.MedicationSideEffectCache
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * Covers the archived-medication delete bug: deleteMedication() soft-deletes with a
 * tombstone (isDeleted = true) so sync can't resurrect the row, but the UI lists must
 * exclude tombstoned rows. Regression test: deleting an archived med must remove it
 * from archivedMedications (previously it stayed visible forever).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MedicationDeleteViewModelTest {

    private class FakeMedicationDao : MedicationDao {
        private val backing = MutableStateFlow<List<Medication>>(emptyList())
        private var nextId = 1L

        val current: List<Medication> get() = backing.value

        override fun getAllMedications(): Flow<List<Medication>> = backing.asStateFlow()

        override suspend fun insertMedication(medication: Medication): Long {
            val list = backing.value.toMutableList()
            return if (medication.id == 0L) {
                val id = nextId++
                list.add(medication.copy(id = id))
                backing.value = list
                id
            } else {
                val idx = list.indexOfFirst { it.id == medication.id }
                if (idx >= 0) list[idx] = medication else list.add(medication)
                backing.value = list
                medication.id
            }
        }

        override suspend fun deleteMedication(medication: Medication) {
            backing.value = backing.value.filterNot { it.id == medication.id }
        }

        override suspend fun getSideEffectCache(key: String): MedicationSideEffectCache? = null

        override suspend fun insertSideEffectCache(cache: MedicationSideEffectCache) {}

        override suspend fun clearAllSideEffectCache() {}

        override suspend fun deleteMedicationByName(name: String) {
            backing.value = backing.value.filterNot { it.name == name }
        }
    }

    private val testDispatcher = UnconfinedTestDispatcher()
    private lateinit var dao: FakeMedicationDao
    private lateinit var vm: MedicationsViewModel
    private val collectorScope = CoroutineScope(testDispatcher)
    private val collectorJobs = mutableListOf<Job>()

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        dao = FakeMedicationDao()
        val syncManager: SyncManager = mock()
        whenever(runBlocking { syncManager.pushProfileData(any()) }).thenReturn(true)
        vm = MedicationsViewModel(
            medicationDao = dao,
            logRepository = mock<LogRepository>(),
            preferences = mock<NotelPreferences>(),
            geminiService = mock<GeminiService>(),
            syncManager = syncManager
        )
        // Keep the WhileSubscribed(5000) StateFlows alive so .value reflects DB state.
        collectorJobs += collectorScope.launch { vm.activeMedications.collect {} }
        collectorJobs += collectorScope.launch { vm.archivedMedications.collect {} }
    }

    @After
    fun tearDown() {
        collectorJobs.forEach { it.cancel() }
        Dispatchers.resetMain()
    }

    @Test
    fun deleteArchivedMedication_removesItFromArchivedList() = runBlocking {
        dao.insertMedication(
            Medication(
                uuid = "uuid-thymosin",
                name = "Thymosin Alpha",
                dose = "10mg",
                frequency = "Daily",
                isArchived = true,
                endedDate = "Aug 27, 2026"
            )
        )
        val med = dao.current.first { it.name == "Thymosin Alpha" }
        assertTrue(vm.archivedMedications.value.any { it.id == med.id })

        vm.deleteMedication(med)

        // Unconfined dispatcher: viewModelScope.launch ran eagerly to completion.
        assertTrue(
            "Deleted archived med must leave the archived list",
            vm.archivedMedications.value.none { it.id == med.id }
        )
        assertTrue(vm.archivedMedications.value.isEmpty())

        // Tombstone must remain in the DB so sync can't resurrect it.
        val row = dao.current.first { it.id == med.id }
        assertTrue("Soft-delete tombstone must be written", row.isDeleted)
    }

    @Test
    fun deleteActiveMedication_removesItFromActiveList() = runBlocking {
        dao.insertMedication(
            Medication(
                uuid = "uuid-kpv",
                name = "KPV Peptide",
                dose = "5mg",
                isArchived = false
            )
        )
        val med = dao.current.first { it.name == "KPV Peptide" }
        assertTrue(vm.activeMedications.value.any { it.id == med.id })

        vm.deleteMedication(med)

        assertTrue(
            "Deleted active med must leave the active list",
            vm.activeMedications.value.none { it.id == med.id }
        )
        // Tombstone written, so the sync pull path won't resurrect it either.
        assertTrue(dao.current.first { it.id == med.id }.isDeleted)
    }
}
