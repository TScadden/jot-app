package com.notel.notel.ui.screen

import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.viewmodel.ENERGY_CHECKIN_SOURCE
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever
import org.mockito.kotlin.argumentCaptor

/**
 * Tess verification: energy check-in entries are fully locked against editing
 * (text AND category) at the ViewModel save-path level, while delete keeps
 * working and normal entries keep full edit behavior.
 *
 * Gating is on `source == "Energy check-in"`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EntryDetailLockGuardTest {

    private class FakeLogEntryDao : LogEntryDao {
        private val flows = mutableMapOf<Long, MutableStateFlow<LogEntry?>>()

        fun seed(entry: LogEntry) {
            flows[entry.id] = MutableStateFlow(entry)
        }

        override fun getEntryByIdFlow(id: Long): Flow<LogEntry?> =
            flows.getOrPut(id) { MutableStateFlow(null) }.asStateFlow()

        override suspend fun insertEntry(entry: LogEntry): Long = TODO("unused")
        override suspend fun insertAll(entries: List<LogEntry>) = TODO("unused")
        override suspend fun updateEntry(entry: LogEntry) = TODO("unused")
        override suspend fun deleteEntry(entry: LogEntry) = TODO("unused")
        override fun getAllEntries(): Flow<List<LogEntry>> = TODO("unused")
        override fun getEntriesByCategory(categoryId: Int): Flow<List<LogEntry>> = TODO("unused")
        override fun searchEntries(query: String): Flow<List<LogEntry>> = TODO("unused")
        override suspend fun getRecentEntries(categoryId: Int, limit: Int): List<LogEntry> = TODO("unused")
        override suspend fun updateEntryCategory(entryId: Long, categoryId: Int, chips: String, updatedAt: Long) = TODO("unused")
        override suspend fun updateEntryText(entryId: Long, body: String, manualText: String, updatedAt: Long) = TODO("unused")
        override suspend fun markSyncedIfUnchanged(entryId: Long, expectedUpdatedAt: Long, syncState: com.notel.notel.data.local.entity.EntrySyncState): Int = TODO("unused")
        override suspend fun getDirtyEntries(): List<LogEntry> = TODO("unused")
        override suspend fun getEntryById(id: Long): LogEntry? = TODO("unused")
        override suspend fun getRecentEntriesAll(limit: Int): List<LogEntry> = TODO("unused")
        override suspend fun countEntries(): Int = TODO("unused")
        override suspend fun getEntryCountSince(since: Long): Int = TODO("unused")
        override suspend fun getEntryCountInRange(start: Long, end: Long): Int = TODO("unused")
        override suspend fun getRecentEntriesInRange(start: Long, end: Long): List<LogEntry> = TODO("unused")
        override suspend fun getRecentEntriesBefore(end: Long, limit: Int): List<LogEntry> = TODO("unused")
        override suspend fun getEntriesInDateRangeDirect(start: Long, end: Long): List<LogEntry> = TODO("unused")
    }

    private lateinit var dao: FakeLogEntryDao
    private lateinit var logRepository: LogRepository
    private lateinit var categoryRepository: CategoryRepository
    private lateinit var viewModel: EntryDetailViewModel
    private val testDispatcher = UnconfinedTestDispatcher()
    private val collectorScope = CoroutineScope(testDispatcher)
    private val collectorJobs = mutableListOf<Job>()

    private val checkInEntry = LogEntry(
        id = 1L,
        categoryId = 7,
        body = "Feeling: 4/5 Today",
        chips = "[\"Daily Ranking\"]",
        source = ENERGY_CHECKIN_SOURCE
    )
    private val normalEntry = LogEntry(
        id = 2L,
        categoryId = 3,
        body = "Original body",
        manualText = "Original manual",
        chips = "[\"General\"]",
        source = null
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        dao = FakeLogEntryDao()
        logRepository = mock()
        categoryRepository = mock()
        whenever(categoryRepository.getAllCategories()).thenReturn(flowOf(emptyList()))
        viewModel = EntryDetailViewModel(logRepository, categoryRepository, dao)
        // Keep the WhileSubscribed(5000) StateFlows alive so .value reflects state.
        collectorJobs += collectorScope.launch { viewModel.entry.collect {} }
        collectorJobs += collectorScope.launch { viewModel.categories.collect {} }
    }

    @After
    fun tearDown() {
        collectorJobs.forEach { it.cancel() }
        Dispatchers.resetMain()
    }

    @Test
    fun checkInEntry_updateText_doesNotPersist() {
        dao.seed(checkInEntry)
        viewModel.loadEntry(1L)

        viewModel.updateText("hacked body", "hacked manual")

        verify(logRepository, never()).updateEntry(any())
    }

    @Test
    fun checkInEntry_updateCategory_doesNotPersist() {
        dao.seed(checkInEntry)
        viewModel.loadEntry(1L)

        viewModel.updateCategory(99)

        verify(logRepository, never()).updateEntry(any())
    }

    @Test
    fun normalEntry_updateText_updatesBodyAndKeepsChips() {
        dao.seed(normalEntry)
        viewModel.loadEntry(2L)

        viewModel.updateText("Edited body", "Edited manual")

        val captor = argumentCaptor<LogEntry>()
        verify(logRepository).updateEntry(captor.capture())
        val saved = captor.firstValue
        assertEquals("Edited body", saved.body)
        assertEquals("Edited manual", saved.manualText)
        assertEquals(normalEntry.categoryId, saved.categoryId)
        // Tag re-stamping leaves normal entries' chips untouched.
        assertEquals(normalEntry.chips, saved.chips)
    }

    @Test
    fun normalEntry_updateCategory_updatesCategory() {
        dao.seed(normalEntry)
        viewModel.loadEntry(2L)

        viewModel.updateCategory(9)

        val captor = argumentCaptor<LogEntry>()
        verify(logRepository).updateEntry(captor.capture())
        val saved = captor.firstValue
        assertEquals(9, saved.categoryId)
        assertEquals(normalEntry.body, saved.body)
    }

    @Test
    fun checkInEntry_delete_stillWorks() {
        dao.seed(checkInEntry)
        viewModel.loadEntry(1L)

        var done = false
        viewModel.deleteEntry(checkInEntry) { done = true }

        verify(logRepository).deleteEntry(checkInEntry)
        assertTrue(done)
    }
}
