package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.data.repository.TemplateAndDefaultsRepository
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.`when`
import org.mockito.kotlin.any
import org.mockito.kotlin.whenever
import org.mockito.kotlin.verify
import org.mockito.kotlin.argThat
import org.mockito.kotlin.timeout
import org.mockito.kotlin.mock

@OptIn(ExperimentalCoroutinesApi::class)
class DirectQuickLogTest {

    private val testDispatcher = StandardTestDispatcher()
    private lateinit var logRepository: LogRepository
    private lateinit var categoryRepository: CategoryRepository
    private lateinit var preferences: NotelPreferences
    private lateinit var habitRepository: HabitRepository
    private lateinit var syncManager: SyncManager
    private lateinit var templateRepository: TemplateAndDefaultsRepository
    private lateinit var viewModel: QuickLogViewModel

    private val testCategory = Category(id = 1, name = "Symptoms", icon = "Favorite", colorHex = "#FF0000", isDefault = true, sortOrder = 0, slug = "symptom")

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)

        logRepository = mock()
        categoryRepository = mock()
        preferences = mock()
        habitRepository = mock()
        syncManager = mock()
        templateRepository = mock()

        `when`(categoryRepository.getAllCategories()).thenReturn(flowOf(listOf(testCategory)))
        `when`(preferences.onboardingComplete).thenReturn(flowOf(true))
        `when`(preferences.loggedDays).thenReturn(flowOf("[]"))
        `when`(preferences.knowledgeBase).thenReturn(flowOf(""))
        `when`(preferences.isUnlimited).thenReturn(flowOf(true))
        `when`(preferences.autoAiSuggestions).thenReturn(flowOf(false))
        `when`(preferences.eventCounters).thenReturn(flowOf("[]"))
        `when`(habitRepository.habits).thenReturn(kotlinx.coroutines.flow.MutableStateFlow(emptyList()))

        runBlocking {
            whenever(logRepository.insertEntry(any())).thenReturn(100L)
            whenever(logRepository.getRecentEntriesAll(org.mockito.ArgumentMatchers.anyInt())).thenReturn(emptyList())
        }

        val context: android.content.Context = mock()
        val cm: android.net.ConnectivityManager = mock()
        `when`(context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE)).thenReturn(cm)

        viewModel = QuickLogViewModel(
            logRepository,
            categoryRepository,
            preferences,
            habitRepository,
            syncManager,
            templateRepository,
            context
        )
        testDispatcher.scheduler.advanceUntilIdle()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun testLogButtonEnablement() {
        val initialState = viewModel.uiState.value
        assertFalse("Log button should be disabled when chips and manual text are empty", initialState.isLogEnabled)

        viewModel.toggleChip("Headache")
        assertTrue("Log button should be enabled when a chip is selected", viewModel.uiState.value.isLogEnabled)

        viewModel.toggleChip("Headache")
        assertFalse("Log button should be disabled when chip is deselected and text is empty", viewModel.uiState.value.isLogEnabled)

        viewModel.updateManualText("  Started after lunch  ")
        assertTrue("Log button should be enabled when manual text is non-blank", viewModel.uiState.value.isLogEnabled)

        viewModel.updateManualText("    ")
        assertFalse("Log button should be disabled when manual text is trimmed blank", viewModel.uiState.value.isLogEnabled)
    }

    @Test
    fun testMultiSelectionAndTypedTextFormatting() = runBlocking {
        whenever(logRepository.insertEntry(any())).thenReturn(101L)

        viewModel.toggleChip("Headache")
        viewModel.toggleChip("Fatigue")
        viewModel.updateManualText("  Started after lunch  ")

        viewModel.saveEntry()
        testDispatcher.scheduler.advanceUntilIdle()

        verify(logRepository, timeout(1000)).insertEntry(argThat {
            this.body == "Headache · Fatigue — Started after lunch"
        })

        // Form clears on success
        assertTrue(viewModel.uiState.value.selectedChips.isEmpty())
        assertEquals("", viewModel.uiState.value.manualText)
        assertEquals(101L, viewModel.uiState.value.lastLoggedEntryId)
    }

    @Test
    fun testLocalSaveFailureRetainsInput() = runBlocking {
        whenever(logRepository.insertEntry(any())).thenThrow(RuntimeException("Disk full"))

        viewModel.toggleChip("Nausea")
        viewModel.updateManualText("Felt severe")

        viewModel.saveEntry()
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertFalse(state.isSaving)
        assertEquals("Disk full", state.saveError)
        assertEquals(listOf("Nausea"), state.selectedChips)
        assertEquals("Felt severe", state.manualText)
    }

    @Test
    fun testSyncFailureDoesNotRemoveSavedLog() = runBlocking {
        whenever(logRepository.insertEntry(any())).thenReturn(202L)
        whenever(syncManager.pushEntries()).thenThrow(RuntimeException("Network error"))

        viewModel.toggleChip("Dizziness")
        viewModel.saveEntry()
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue(state.saveSuccess)
        assertEquals(202L, state.lastLoggedEntryId)
        assertTrue(state.selectedChips.isEmpty())
    }
}
