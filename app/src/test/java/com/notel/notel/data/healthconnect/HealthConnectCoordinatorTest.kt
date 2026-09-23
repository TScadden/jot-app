package com.notel.notel.data.healthconnect

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.*
import java.time.LocalDate

@OptIn(ExperimentalCoroutinesApi::class)
class HealthConnectCoordinatorTest {

    private lateinit var healthConnectManager: HealthConnectManager
    private lateinit var coordinator: HealthConnectCoordinator

    @Before
    fun setUp() {
        healthConnectManager = mock(HealthConnectManager::class.java)
        coordinator = HealthConnectCoordinator(healthConnectManager)
    }

    @Test
    fun testMemoryCacheHitReturnsWithoutRequerying() = runTest {
        val today = LocalDate.now().toString()
        val dummyData = listOf(1620000000000L to 72)
        `when`(healthConnectManager.readHeartRateIntraday(today)).thenReturn(dummyData)

        // First call populates cache
        val firstCall = coordinator.getIntradayHeartRate(today)
        assertEquals(dummyData, firstCall)
        verify(healthConnectManager, times(1)).readHeartRateIntraday(today)

        // Second call hits memory cache
        val secondCall = coordinator.getIntradayHeartRate(today)
        assertEquals(dummyData, secondCall)
        // Ensure readHeartRateIntraday was not called a second time
        verify(healthConnectManager, times(1)).readHeartRateIntraday(today)
    }

    @Test
    fun testInFlightDeduplicationReusesActiveJob() = runTest {
        val today = LocalDate.now().toString()
        val dummyData = listOf(1620000000000L to 80)
        `when`(healthConnectManager.readHeartRateIntraday(today)).thenReturn(dummyData)

        val job1 = async { coordinator.getIntradayHeartRate(today) }
        val job2 = async { coordinator.getIntradayHeartRate(today) }

        val res1 = job1.await()
        val res2 = job2.await()

        assertEquals(dummyData, res1)
        assertEquals(dummyData, res2)
        verify(healthConnectManager, times(1)).readHeartRateIntraday(today)
    }

    @Test
    fun testPurposeSpecificRangeHistory() = runTest {
        val dummy7Days = (0 until 7).map { "2026-09-${15 + it}" to (60 + it) }
        `when`(healthConnectManager.readHistoricalHeartRate(7)).thenReturn(dummy7Days)

        val result = coordinator.getHeartRateHistory(7)
        assertEquals(7, result.size)
        verify(healthConnectManager, times(1)).readHistoricalHeartRate(7)
    }

    @Test
    fun testLongTermRangeReportNotTruncated() = runTest {
        val dummy30Days = (0 until 30).map { "2026-09-${1 + it}" to (65 + (it % 10)) }
        `when`(healthConnectManager.readHistoricalHeartRate(30)).thenReturn(dummy30Days)

        val result = coordinator.getHeartRateHistory(30)
        assertEquals(30, result.size)
        verify(healthConnectManager, times(1)).readHistoricalHeartRate(30)
    }
}
