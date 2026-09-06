package com.notel.notel.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import com.notel.notel.data.healthconnect.BloodPressureSource
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.ui.viewmodel.BloodPressureViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito.*

class FakeDataStore : DataStore<Preferences> {
    private val key = stringPreferencesKey("manual_blood_pressure_logs")
    private val prefsState = MutableStateFlow<Preferences>(emptyPreferences())

    override val data: Flow<Preferences> = prefsState

    override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences {
        val newPrefs = transform(prefsState.value)
        prefsState.value = newPrefs
        return newPrefs
    }
}

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

class FakeNotelPreferences(dataStore: DataStore<Preferences>) : NotelPreferences(mock(android.content.Context::class.java), dataStore) {
    private val logsState = MutableStateFlow("[]")

    override val manualBloodPressureLogs: Flow<String> = logsState

    override suspend fun setManualBloodPressureLogs(jsonStr: String) {
        logsState.value = jsonStr
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class BloodPressureRepositoryTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val testDispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun createTestPreferences(): NotelPreferences {
        val prefs = mock(NotelPreferences::class.java)
        val logsState = MutableStateFlow("[]")
        `when`(prefs.manualBloodPressureLogs).thenReturn(logsState)
        runBlocking {
            `when`(prefs.setManualBloodPressureLogs(anyString())).thenAnswer { invocation ->
                val arg = invocation.arguments[0] as String
                logsState.value = arg
                Unit
            }
        }
        return prefs
    }

    @Test
    fun testBloodPressureUiRecordJsonRoundTrip() {
        val record = BloodPressureUiRecord(
            systolic = 120,
            diastolic = 80,
            timeEpochMs = 1700000000000L,
            id = "manual_1700000000000_120_80",
            source = BloodPressureSource.MANUAL
        )

        val encoded = json.encodeToString(record)
        val decoded = json.decodeFromString<BloodPressureUiRecord>(encoded)

        assertEquals(record, decoded)
    }

    @Test
    fun testBackwardsCompatibilityDecodingLegacyRecord() {
        val legacyJson = """{"systolic":130,"diastolic":85,"timeEpochMs":1700000000000}"""
        val decoded = json.decodeFromString<BloodPressureUiRecord>(legacyJson)

        assertEquals(130, decoded.systolic)
        assertEquals(85, decoded.diastolic)
        assertEquals(1700000000000L, decoded.timeEpochMs)
        assertEquals("manual_1700000000000_130_85", decoded.id)
        assertEquals(BloodPressureSource.MANUAL, decoded.source)
    }

    @Test
    fun testManualRecordPersistenceAcrossRepoRecreation() = runBlocking {
        val prefs = createTestPreferences()
        val fakeDs = FakeBloodPressureDataSource(sdkStatus = 0)
        val repo1 = BloodPressureRepository(fakeDs, prefs)

        val saveResult = repo1.addManualRecord(125, 82, 1700000000000L)
        assertTrue(saveResult is SaveResult.Success)

        val repo2 = BloodPressureRepository(fakeDs, prefs)
        val records = repo2.getRecords()

        assertEquals(1, records.size)
        assertEquals(125, records[0].systolic)
        assertEquals(82, records[0].diastolic)
        assertEquals(1700000000000L, records[0].timeEpochMs)
        assertEquals(BloodPressureSource.MANUAL, records[0].source)
    }

    @Test
    fun testManualRecordsRemainVisibleWhenHealthConnectFailsOrMissingPermission() = runBlocking {
        val prefs = createTestPreferences()
        val manualLog = listOf(
            BloodPressureUiRecord(118, 78, 1700000000000L, "m1", BloodPressureSource.MANUAL)
        )
        prefs.setManualBloodPressureLogs(json.encodeToString(manualLog))

        // Case A: Query failure
        val failingDs = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = true, shouldFailQuery = true)
        val repoFailing = BloodPressureRepository(failingDs, prefs)
        val fetchResultA = repoFailing.getFetchResult()

        assertEquals(1, fetchResultA.records.size)
        assertEquals(118, fetchResultA.records[0].systolic)
        assertTrue(fetchResultA.hcStatus is HealthConnectStatus.Error)

        // Case B: Permission missing
        val noPermDs = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = false)
        val repoNoPerm = BloodPressureRepository(noPermDs, prefs)
        val fetchResultB = repoNoPerm.getFetchResult()

        assertEquals(1, fetchResultB.records.size)
        assertTrue(fetchResultB.hcStatus is HealthConnectStatus.PermissionRequired)
    }

    @Test
    fun testGenuineQueryFailureNotShownAsNoReadings() = runBlocking {
        val fakeDs = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = true, shouldFailQuery = true)
        val repo = BloodPressureRepository(fakeDs)

        val tileState = repo.getTileState()
        assertTrue(tileState is BloodPressureTileState.Error)
    }

    @Test
    fun testMergingAndDeduplicationAndNewestFirstSorting() = runBlocking {
        val hcRecord = BloodPressureUiRecord(120, 80, 2000L, "hc_1", BloodPressureSource.HEALTH_CONNECT)
        val manualRecord = BloodPressureUiRecord(130, 85, 3000L, "m_1", BloodPressureSource.MANUAL)
        val restoredDuplicate = BloodPressureUiRecord(120, 80, 2000L, "hc_1", BloodPressureSource.HEALTH_CONNECT)

        val prefs = createTestPreferences()
        prefs.setManualBloodPressureLogs(json.encodeToString(listOf(manualRecord, restoredDuplicate)))

        val fakeDs = FakeBloodPressureDataSource(sdkStatus = 1, hasPermission = true, recordsToReturn = listOf(hcRecord))
        val repo = BloodPressureRepository(fakeDs, prefs)

        val records = repo.getRecords()

        assertEquals(2, records.size)
        assertEquals(3000L, records[0].timeEpochMs)
        assertEquals(130, records[0].systolic)
        assertEquals(2000L, records[1].timeEpochMs)
        assertEquals(120, records[1].systolic)
    }

    @Test
    fun testLocalSaveSurvivesServerSyncPushFailure() = runBlocking {
        val prefs = createTestPreferences()

        val syncManager = mock(com.notel.notel.data.sync.SyncManager::class.java)
        `when`(syncManager.pushProfileData()).thenThrow(RuntimeException("Network offline"))

        val fakeDs = FakeBloodPressureDataSource(sdkStatus = 0)
        val repo = BloodPressureRepository(fakeDs, prefs, syncManager)

        val saveResult = repo.addManualRecord(140, 90, 5000L)

        assertTrue(saveResult is SaveResult.Success)
        val records = repo.getRecords()
        assertEquals(1, records.size)
        assertEquals(140, records[0].systolic)
    }

    @Test
    fun testViewModelSaveUpdatesStateImmediately() = runBlocking {
        val prefs = createTestPreferences()
        val fakeDs = FakeBloodPressureDataSource(sdkStatus = 0)
        val repo = BloodPressureRepository(fakeDs, prefs)
        val viewModel = BloodPressureViewModel(repo)
        testDispatcher.scheduler.advanceUntilIdle()

        var callbackCalled = false
        viewModel.saveManualRecord(128, 84, 10000L) {
            callbackCalled = true
        }
        testDispatcher.scheduler.advanceUntilIdle()

        assertTrue(callbackCalled)
        val state = viewModel.uiState.value
        assertEquals(1, state.records.size)
        assertEquals(128, state.records[0].systolic)
        assertEquals(84, state.records[0].diastolic)
        assertEquals(10000L, state.records[0].timeEpochMs)
    }
}
