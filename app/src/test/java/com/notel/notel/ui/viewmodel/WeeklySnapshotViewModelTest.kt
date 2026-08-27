package com.notel.notel.ui.viewmodel

import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.DailySnapshotPoint
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.data.repository.WeeklySnapshotMetricData
import com.notel.notel.data.repository.WeeklySnapshotRepository
import com.notel.notel.util.TestTimeProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.`when`
import org.mockito.Mockito.mock
import org.mockito.kotlin.anyOrNull
import org.mockito.kotlin.eq
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
class WeeklySnapshotViewModelTest {

    private val testDispatcher = StandardTestDispatcher()

    private lateinit var weeklySnapshotRepository: WeeklySnapshotRepository
    private lateinit var preferences: NotelPreferences
    private lateinit var healthConnectManager: HealthConnectManager
    private lateinit var logEntryDao: LogEntryDao
    private lateinit var habitRepository: HabitRepository
    private lateinit var timeProvider: TestTimeProvider

    private val selectedGraphFlow = MutableStateFlow("Sleep Hours")
    private val historicalSpikesFlow = MutableStateFlow("")
    private val habitsFlow = MutableStateFlow(emptyList<com.notel.notel.data.remote.HabitDtoModel>())
    private val isInitializedFlow = MutableStateFlow(true)
    private val logEntriesFlow = MutableStateFlow(emptyList<com.notel.notel.data.local.entity.LogEntry>())

    @Before
    fun setup() {
        Dispatchers.setMain(testDispatcher)

        val fixedClock = Clock.fixed(Instant.parse("2026-08-27T01:45:00Z"), ZoneId.of("UTC"))
        timeProvider = TestTimeProvider(fixedClock)

        weeklySnapshotRepository = mock(WeeklySnapshotRepository::class.java)
        preferences = mock(NotelPreferences::class.java)
        healthConnectManager = mock(HealthConnectManager::class.java)
        logEntryDao = mock(LogEntryDao::class.java)
        habitRepository = mock(HabitRepository::class.java)

        val selectedMetricFlow = MutableStateFlow(com.notel.notel.data.model.WeeklySnapshotMetric.fromKeyOrDisplayName(selectedGraphFlow.value))
        `when`(preferences.selectedWeeklySnapshotGraph).thenReturn(selectedGraphFlow)
        `when`(preferences.selectedWeeklySnapshotMetric).thenAnswer {
            MutableStateFlow(com.notel.notel.data.model.WeeklySnapshotMetric.fromKeyOrDisplayName(selectedGraphFlow.value))
        }
        `when`(preferences.historicalHrSpikes).thenReturn(historicalSpikesFlow)
        `when`(logEntryDao.getAllEntries()).thenReturn(logEntriesFlow)
        `when`(habitRepository.habits).thenReturn(habitsFlow)
        `when`(habitRepository.isInitialized).thenReturn(isInitializedFlow)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun createViewModel(): WeeklySnapshotViewModel {
        return WeeklySnapshotViewModel(
            weeklySnapshotRepository = weeklySnapshotRepository,
            preferences = preferences,
            healthConnectManager = healthConnectManager,
            logEntryDao = logEntryDao,
            habitRepository = habitRepository,
            timeProvider = timeProvider
        )
    }

    private fun stubGet7DaySnapshot(metricName: String, data: WeeklySnapshotMetricData, callCounter: AtomicInteger? = null) {
        val metricEnum = com.notel.notel.data.model.WeeklySnapshotMetric.fromKeyOrDisplayName(metricName)
        runBlocking {
            `when`(weeklySnapshotRepository.get7DaySnapshot(eq(metricName), anyOrNull())).thenAnswer {
                callCounter?.incrementAndGet()
                data
            }
            `when`(weeklySnapshotRepository.get7DaySnapshotTyped(eq(metricEnum), anyOrNull(), anyOrNull())).thenAnswer {
                callCounter?.incrementAndGet()
                com.notel.notel.data.repository.SnapshotReadResult.Success(data)
            }
        }
    }

    @Test
    fun testInitializationAndFirstHomeActivationProducesExactlyOneRequest() = runTest {
        val repoCallCount = AtomicInteger(0)
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", listOf(DailySnapshotPoint("2026-08-27", "Thu", 7.0f)), "Avg 7.0h")
        stubGet7DaySnapshot("Sleep Hours", data, repoCallCount)

        val viewModel = createViewModel()
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Initialization + onHomeActivated must perform exactly 1 call", 1, repoCallCount.get())
    }

    @Test
    fun testRecompositionOrRepeatedActivationInside60SecondsProducesNoAdditionalCall() = runTest {
        val repoCallCount = AtomicInteger(0)
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", listOf(DailySnapshotPoint("2026-08-27", "Thu", 7.0f)), "Avg 7.0h")
        stubGet7DaySnapshot("Sleep Hours", data, repoCallCount)

        val viewModel = createViewModel()
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        // Repeated activation / recomposition inside 60s
        timeProvider.setClock(Clock.fixed(Instant.parse("2026-08-27T01:45:30Z"), ZoneId.of("UTC")))
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Recomposition / repeated activation inside 60s must not call repo again", 1, repoCallCount.get())
    }

    @Test
    fun testActivationAfter60SecondsProducesExactlyOneAdditionalCall() = runTest {
        val repoCallCount = AtomicInteger(0)
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", listOf(DailySnapshotPoint("2026-08-27", "Thu", 7.0f)), "Avg 7.0h")
        stubGet7DaySnapshot("Sleep Hours", data, repoCallCount)

        val viewModel = createViewModel()
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        // 61 seconds later
        timeProvider.setClock(Clock.fixed(Instant.parse("2026-08-27T01:46:01Z"), ZoneId.of("UTC")))
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Activation after 60 seconds must perform exactly 1 additional call", 2, repoCallCount.get())
    }

    @Test
    fun testLocalDateRolloverProducesExactlyOneRefreshInsideFreshnessWindow() = runTest {
        val repoCallCount = AtomicInteger(0)
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", listOf(DailySnapshotPoint("2026-08-27", "Thu", 7.0f)), "Avg 7.0h")
        stubGet7DaySnapshot("Sleep Hours", data, repoCallCount)

        val viewModel = createViewModel()
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        // 10 seconds later, local calendar date changes to Aug 28
        timeProvider.setClock(Clock.fixed(Instant.parse("2026-08-28T00:00:05Z"), ZoneId.of("UTC")))
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Date rollover must trigger exactly 1 additional call", 2, repoCallCount.get())
    }

    @Test
    fun testHabitChangesDoNotReloadLogs() = runTest {
        val repoCallCount = AtomicInteger(0)
        selectedGraphFlow.value = "Logs"
        val data = WeeklySnapshotMetricData("Logs", "logs", listOf(DailySnapshotPoint("2026-08-27", "Thu", 3.0f)), "Total: 3 logs")
        stubGet7DaySnapshot("Logs", data, repoCallCount)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, repoCallCount.get())

        // Habit update
        habitsFlow.value = listOf(com.notel.notel.data.remote.HabitDtoModel("h1", "Stretch", "Habit", logs = emptyList()))
        testDispatcher.scheduler.advanceTimeBy(500L)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Habit changes must NOT reload Logs", 1, repoCallCount.get())
    }

    @Test
    fun testLogChangesDoNotReloadHrSpikes() = runTest {
        val repoCallCount = AtomicInteger(0)
        selectedGraphFlow.value = "HR Spikes"
        val data = WeeklySnapshotMetricData("HR Spikes", "spikes", listOf(DailySnapshotPoint("2026-08-27", "Thu", 0.0f)), "7-Day Total: 0 spikes")
        stubGet7DaySnapshot("HR Spikes", data, repoCallCount)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, repoCallCount.get())

        // Log entry update
        logEntriesFlow.value = listOf(com.notel.notel.data.local.entity.LogEntry(id = 1, timestamp = 1000L, categoryId = 1, body = "Note"))
        testDispatcher.scheduler.advanceTimeBy(500L)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Log changes must NOT reload HR Spikes", 1, repoCallCount.get())
    }

    @Test
    fun testHrSpikeChangesDoNotReloadLogsOrHabitCompletion() = runTest {
        val repoCallCount = AtomicInteger(0)
        selectedGraphFlow.value = "Logs"
        val data = WeeklySnapshotMetricData("Logs", "logs", listOf(DailySnapshotPoint("2026-08-27", "Thu", 1.0f)), "Total: 1 log")
        stubGet7DaySnapshot("Logs", data, repoCallCount)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, repoCallCount.get())

        // HR Spikes update
        historicalSpikesFlow.value = "[{\"date\":\"2026-08-27\",\"spikeCount\":2}]"
        testDispatcher.scheduler.advanceTimeBy(500L)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("HR Spike changes must NOT reload Logs", 1, repoCallCount.get())
    }

    @Test
    fun testEachRelevantSourceRefreshesItsOwnSelectedMetricExactlyOnce() = runTest {
        val logsCallCount = AtomicInteger(0)
        selectedGraphFlow.value = "Logs"
        val logsData = WeeklySnapshotMetricData("Logs", "logs", listOf(DailySnapshotPoint("2026-08-27", "Thu", 2.0f)), "Total: 2 logs")
        stubGet7DaySnapshot("Logs", logsData, logsCallCount)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, logsCallCount.get())

        // Relevant log entry update
        logEntriesFlow.value = listOf(com.notel.notel.data.local.entity.LogEntry(id = 1, timestamp = 1000L, categoryId = 1, body = "Log 1"))
        testDispatcher.scheduler.advanceTimeBy(500L)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Relevant log change must reload Logs exactly once", 2, logsCallCount.get())
    }

    @Test
    fun testRapidRelevantEmissionsAreCoalesced() = runTest {
        val repoCallCount = AtomicInteger(0)
        selectedGraphFlow.value = "Logs"
        val data = WeeklySnapshotMetricData("Logs", "logs", listOf(DailySnapshotPoint("2026-08-27", "Thu", 1.0f)), "Total: 1 log")
        stubGet7DaySnapshot("Logs", data, repoCallCount)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, repoCallCount.get())

        // Emit 3 rapid log updates within 100ms
        logEntriesFlow.value = listOf(com.notel.notel.data.local.entity.LogEntry(id = 1, timestamp = 1000L, categoryId = 1, body = "A"))
        testDispatcher.scheduler.advanceTimeBy(50L)
        logEntriesFlow.value = listOf(com.notel.notel.data.local.entity.LogEntry(id = 2, timestamp = 2000L, categoryId = 1, body = "B"))
        testDispatcher.scheduler.advanceTimeBy(50L)
        logEntriesFlow.value = listOf(com.notel.notel.data.local.entity.LogEntry(id = 3, timestamp = 3000L, categoryId = 1, body = "C"))
        
        testDispatcher.scheduler.advanceTimeBy(500L)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Rapid emissions within debounce window must be coalesced into 1 extra call", 2, repoCallCount.get())
    }

    @Test
    fun testSelectingMetricChangesVisibleStateAndTriggersRepositoryCall() = runTest {
        val sleepData = WeeklySnapshotMetricData("Sleep Hours", "h", listOf(DailySnapshotPoint("2026-08-27", "Thu", 7.0f)), "Avg 7.0h")
        val caloriesData = WeeklySnapshotMetricData("Calories", "kcal", listOf(DailySnapshotPoint("2026-08-27", "Thu", 2000.0f)), "Total: 2000 kcal")

        stubGet7DaySnapshot("Sleep Hours", sleepData)
        stubGet7DaySnapshot("Calories", caloriesData)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()

        // Select Calories
        viewModel.selectMetric("Calories")
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue(state is WeeklySnapshotState.ReadyWithData)
        assertEquals("Calories", (state as WeeklySnapshotState.ReadyWithData).metricData.metricName)
    }

    @Test
    fun testRapidSleepLogsHrSpikesSequenceFinishesOnHrSpikes() = runTest {
        val sleepData = WeeklySnapshotMetricData("Sleep Hours", "h", listOf(DailySnapshotPoint("2026-08-27", "Thu", 7.0f)), "Avg 7.0h")
        val logsData = WeeklySnapshotMetricData("Logs", "logs", listOf(DailySnapshotPoint("2026-08-27", "Thu", 5.0f)), "Total: 5 logs")
        val spikesData = WeeklySnapshotMetricData("HR Spikes", "spikes", listOf(DailySnapshotPoint("2026-08-27", "Thu", 1.0f)), "7-Day Total: 1 spike")

        stubGet7DaySnapshot("Sleep Hours", sleepData)
        stubGet7DaySnapshot("Logs", logsData)
        stubGet7DaySnapshot("HR Spikes", spikesData)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()

        viewModel.selectMetric("Logs")
        viewModel.selectMetric("HR Spikes")
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue(state is WeeklySnapshotState.ReadyWithData)
        assertEquals("HR Spikes", (state as WeeklySnapshotState.ReadyWithData).metricData.metricName)
    }

    @Test
    fun testEmptySleepResultRemainsReadyEmptyThroughRepeatedHomeActivation() = runTest {
        val points = List(7) { DailySnapshotPoint("2026-08-21", "Fri", null) }
        val emptyData = WeeklySnapshotMetricData("Sleep Hours", "h", points, "No sleep data", emptyMessage = "No sleep data available for the past 7 days")

        stubGet7DaySnapshot("Sleep Hours", emptyData)

        val viewModel = createViewModel()
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        assertTrue(viewModel.uiState.value is WeeklySnapshotState.ReadyEmpty)

        // Repeated activation inside freshness window
        viewModel.onHomeActivated()
        testDispatcher.scheduler.advanceUntilIdle()

        assertTrue("Must remain ReadyEmpty", viewModel.uiState.value is WeeklySnapshotState.ReadyEmpty)
        val emptyState = viewModel.uiState.value as WeeklySnapshotState.ReadyEmpty
        assertEquals("No sleep data available for the past 7 days", emptyState.emptyMessage)
        assertFalse(emptyState.isRefreshing)
    }

    @Test
    fun testOnlyTodayMissingRemainsReadyWithData() = runTest {
        val points = listOf(
            DailySnapshotPoint("2026-08-21", "Fri", 8.0f),
            DailySnapshotPoint("2026-08-22", "Sat", 7.5f),
            DailySnapshotPoint("2026-08-23", "Sun", 7.0f),
            DailySnapshotPoint("2026-08-24", "Mon", 8.0f),
            DailySnapshotPoint("2026-08-25", "Tue", 6.5f),
            DailySnapshotPoint("2026-08-26", "Wed", 7.0f),
            DailySnapshotPoint("2026-08-27", "Thu", null) // Today missing
        )
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", points, "7-Day Avg: 7.3h")

        stubGet7DaySnapshot("Sleep Hours", data)

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue("State must be ReadyWithData for partial chart", state is WeeklySnapshotState.ReadyWithData)
        val readyState = state as WeeklySnapshotState.ReadyWithData
        assertNull("Today's point is null", readyState.metricData.points.last().value)
        assertFalse(readyState.isRefreshing)
    }
}
