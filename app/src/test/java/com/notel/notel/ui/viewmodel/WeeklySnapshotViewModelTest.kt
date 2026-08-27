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
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyOrNull
import org.mockito.ArgumentMatchers.eq
import org.mockito.Mockito.`when`
import org.mockito.Mockito.mock
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

        `when`(preferences.selectedWeeklySnapshotGraph).thenReturn(selectedGraphFlow)
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

    @Test
    fun testNoSleepRecordForTodayButEarlierDaysExist_rendersPartialChart() = runTest {
        val repoCallCount = AtomicInteger(0)
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

        `when`(weeklySnapshotRepository.get7DaySnapshot(eq("Sleep Hours"), anyOrNull())).thenAnswer {
            repoCallCount.incrementAndGet()
            data
        }

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue("State must be ReadyWithData for partial chart", state is WeeklySnapshotState.ReadyWithData)
        val readyState = state as WeeklySnapshotState.ReadyWithData
        assertNull("Today's point is null", readyState.metricData.points.last().value)
        assertEquals("Repository call count", 1, repoCallCount.get())
    }

    @Test
    fun testNoSleepRecordsForAll7Days_becomesReadyEmpty() = runTest {
        val repoCallCount = AtomicInteger(0)
        val points = List(7) { DailySnapshotPoint("2026-08-21", "Fri", null) }
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", points, "No sleep data available past 7 days", emptyMessage = "No sleep data available for the past 7 days")

        `when`(weeklySnapshotRepository.get7DaySnapshot(eq("Sleep Hours"), anyOrNull())).thenAnswer {
            repoCallCount.incrementAndGet()
            data
        }

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue("State must be ReadyEmpty when all 7 days are null", state is WeeklySnapshotState.ReadyEmpty)
        val emptyState = state as WeeklySnapshotState.ReadyEmpty
        assertEquals("No sleep data available for the past 7 days", emptyState.emptyMessage)
        assertEquals("Repository call count", 1, repoCallCount.get())
    }

    @Test
    fun testUnrelatedRoomUpdateDoesNotReloadSleep() = runTest {
        val repoCallCount = AtomicInteger(0)
        val points = listOf(DailySnapshotPoint("2026-08-21", "Fri", 8.0f))
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", points, "Avg 8.0h")

        `when`(weeklySnapshotRepository.get7DaySnapshot(eq("Sleep Hours"), anyOrNull())).thenAnswer {
            repoCallCount.incrementAndGet()
            data
        }

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, repoCallCount.get())

        // Trigger unrelated log entry Room flow update
        logEntriesFlow.value = listOf(com.notel.notel.data.local.entity.LogEntry(id = 1, timestamp = 1000L, categoryId = 1, body = "Note"))
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Unrelated Room update must not reload Sleep Hours", 1, repoCallCount.get())
    }

    @Test
    fun testManualRefreshFromEmptyStatePerformsOneRequest() = runTest {
        val repoCallCount = AtomicInteger(0)
        val points = List(7) { DailySnapshotPoint("2026-08-21", "Fri", null) }
        val data = WeeklySnapshotMetricData("Sleep Hours", "h", points, "No sleep data", emptyMessage = "No sleep data available for the past 7 days")

        `when`(weeklySnapshotRepository.get7DaySnapshot(eq("Sleep Hours"), anyOrNull())).thenAnswer {
            repoCallCount.incrementAndGet()
            data
        }

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
        assertEquals(1, repoCallCount.get())

        viewModel.refresh()
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals("Manual refresh must perform exactly 1 extra request", 2, repoCallCount.get())
    }

    @Test
    fun testHealthConnectTimeoutBecomesRetryableError() = runTest {
        `when`(weeklySnapshotRepository.get7DaySnapshot(eq("Sleep Hours"), anyOrNull())).thenAnswer {
            throw kotlinx.coroutines.TimeoutCancellationException("Timed out")
        }

        val viewModel = createViewModel()
        testDispatcher.scheduler.advanceUntilIdle()

        val state = viewModel.uiState.value
        assertTrue("State must be Error on timeout", state is WeeklySnapshotState.Error)
        val errorState = state as WeeklySnapshotState.Error
        assertTrue(errorState.message.contains("timed out"))
    }
}
