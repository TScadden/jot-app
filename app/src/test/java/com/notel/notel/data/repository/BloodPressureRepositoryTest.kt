package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class FakeBloodPressureDataSource(
    var sdkStatus: Int = 1,
    var hasPermission: Boolean = true,
    var shouldFailQuery: Boolean = false,
    var recordsToReturn: List<BloodPressureUiRecord> = emptyList()
) : BloodPressureDataSource {
    var queryCount = 0

    override fun checkAvailability(): Int {
        return sdkStatus
    }

    override suspend fun hasBloodPressurePermission(): Boolean {
        return hasPermission
    }

    override suspend fun readBloodPressureRecords(days: Int): List<BloodPressureUiRecord> {
        queryCount++
        if (shouldFailQuery) {
            throw RuntimeException("Query error")
        }
        return recordsToReturn
    }
}

class BloodPressureRepositoryTest {

    @Test
    fun testHealthConnectUnavailable() = runBlocking {
        val fake = FakeBloodPressureDataSource(sdkStatus = 0)
        val repo = BloodPressureRepository(fake)

        val state = repo.getTileState()

        assertTrue(state is BloodPressureTileState.HealthConnectUnavailable)
        assertEquals(0, fake.queryCount)
    }

    @Test
    fun testPermissionMissing() = runBlocking {
        val fake = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = false)
        val repo = BloodPressureRepository(fake)

        val state = repo.getTileState()

        assertTrue(state is BloodPressureTileState.PermissionRequired)
        assertEquals(0, fake.queryCount)
    }

    @Test
    fun testPermissionGrantedWithNoRecords() = runBlocking {
        val fake = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = true, recordsToReturn = emptyList())
        val repo = BloodPressureRepository(fake)

        val state = repo.getTileState()

        assertTrue(state is BloodPressureTileState.NoData)
        assertEquals(1, fake.queryCount)
    }

    @Test
    fun testQueryFailure() = runBlocking {
        val fake = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = true, shouldFailQuery = true)
        val repo = BloodPressureRepository(fake)

        val state = repo.getTileState()

        assertTrue(state is BloodPressureTileState.Error)
        assertEquals(1, fake.queryCount)
    }

    @Test
    fun testSuccessfulRecordsAndNewestFirstMapping() = runBlocking {
        val record1 = BloodPressureUiRecord(systolic = 120, diastolic = 80, timeEpochMs = 1000L)
        val record2 = BloodPressureUiRecord(systolic = 135, diastolic = 88, timeEpochMs = 5000L)
        val record3 = BloodPressureUiRecord(systolic = 118, diastolic = 78, timeEpochMs = 3000L)

        val fake = FakeBloodPressureDataSource(
            sdkStatus = 1,
            hasPermission = true,
            recordsToReturn = listOf(record1, record2, record3)
        )
        val repo = BloodPressureRepository(fake)

        val state = repo.getTileState()

        assertTrue(state is BloodPressureTileState.Available)
        val available = state as BloodPressureTileState.Available
        assertEquals(135, available.latestReading.systolic)
        assertEquals(88, available.latestReading.diastolic)
        assertEquals(5000L, available.latestReading.timeEpochMs)

        val records = repo.getRecords()
        assertEquals(3, records.size)
        assertEquals(120, records[0].systolic)
        assertEquals(80, records[0].diastolic)
    }

    @Test
    fun testPermissionRevocationClearsDataState() = runBlocking {
        val fake = FakeBloodPressureDataSource(
            sdkStatus = 1,
            hasPermission = true,
            recordsToReturn = listOf(BloodPressureUiRecord(120, 80, 1000L))
        )
        val repo = BloodPressureRepository(fake)

        var state = repo.getTileState()
        assertTrue(state is BloodPressureTileState.Available)

        // Revoke permission
        fake.hasPermission = false
        state = repo.getTileState()
        assertTrue(state is BloodPressureTileState.PermissionRequired)

        val records = repo.getRecords()
        assertTrue(records.isEmpty())
    }
}
