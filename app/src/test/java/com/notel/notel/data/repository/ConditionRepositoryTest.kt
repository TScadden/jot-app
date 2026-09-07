package com.notel.notel.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.*
import javax.inject.Provider

    private lateinit var preferences: NotelPreferences

    private fun createPreferencesMock(): NotelPreferences {
        val conditionsState = MutableStateFlow("[]")
        val prefs = mock(NotelPreferences::class.java)
        `when`(prefs.userConditions).thenReturn(conditionsState)
        runBlocking {
            doAnswer { invocation ->
                val arg = invocation.getArgument<String>(0)
                conditionsState.value = arg
                null
            }.`when`(prefs).setUserConditions(anyString())
        }
        return prefs
    }

@OptIn(ExperimentalCoroutinesApi::class)
class ConditionRepositoryTest {

    private val testDispatcher = StandardTestDispatcher()
    private lateinit var preferences: NotelPreferences
    private lateinit var syncManager: SyncManager
    private lateinit var syncManagerProvider: Provider<SyncManager>
    private lateinit var repository: ConditionRepository

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        preferences = createPreferencesMock()
        syncManager = mock(SyncManager::class.java)
        syncManagerProvider = Provider { syncManager }
        repository = ConditionRepository(preferences, syncManagerProvider)
        testDispatcher.scheduler.advanceUntilIdle()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun testRapidConcurrentAdditionsPreservesAllConditions() = runBlocking {
        val jobs = listOf(
            launch { repository.addCondition(" POTS ") },
            launch { repository.addCondition("Ehlers-Danlos Syndrome") },
            launch { repository.addCondition("MCAS") }
        )
        jobs.joinAll()
        testDispatcher.scheduler.advanceUntilIdle()

        val list = repository.conditions.value
        assertEquals(3, list.size)
        assertTrue(list.contains("POTS"))
        assertTrue(list.contains("Ehlers-Danlos Syndrome"))
        assertTrue(list.contains("MCAS"))
    }

    @Test
    fun testAddAndRemoveConcurrency() = runBlocking {
        repository.addCondition("Migraine")
        testDispatcher.scheduler.advanceUntilIdle()

        val jobs = listOf(
            launch { repository.addCondition("Asthma") },
            launch { repository.removeCondition("Migraine") },
            launch { repository.addCondition("POTS") }
        )
        jobs.joinAll()
        testDispatcher.scheduler.advanceUntilIdle()

        val list = repository.conditions.value
        assertEquals(2, list.size)
        assertFalse(list.contains("Migraine"))
        assertTrue(list.contains("Asthma"))
        assertTrue(list.contains("POTS"))
    }

    @Test
    fun testCaseInsensitiveDeduplicationAndWhitespaceTrimming() = runBlocking {
        repository.addCondition("  Fibromyalgia  ")
        repository.addCondition("fibromyalgia")
        repository.addCondition("FIBROMYALGIA")
        testDispatcher.scheduler.advanceUntilIdle()

        val list = repository.conditions.value
        assertEquals(1, list.size)
        assertEquals("Fibromyalgia", list[0])
    }

    @Test
    fun testRejectBlankCondition() = runBlocking {
        val res = repository.addCondition("   ")
        assertTrue(res is ConditionOperationResult.Failure)
        assertEquals(0, repository.conditions.value.size)
    }

    @Test
    fun testMalformedLegacyJsonHandledWithoutCrashing() = runBlocking {
        preferences.setUserConditions("{malformed_json_str")
        val repo = ConditionRepository(preferences, syncManagerProvider)
        testDispatcher.scheduler.advanceUntilIdle()

        assertEquals(0, repo.conditions.value.size)

        val addRes = repo.addCondition("Lyme Disease")
        assertTrue(addRes is ConditionOperationResult.Success)
        assertEquals(1, repo.conditions.value.size)
        assertEquals("Lyme Disease", repo.conditions.value[0])
    }

    @Test
    fun testStaleServerResponseIgnored() = runBlocking {
        repository.addCondition("Local Condition A")
        testDispatcher.scheduler.advanceUntilIdle()

        // Server pull completed with timestamp before local edit
        val serverJson = """["Stale Server Condition"]"""
        val merged = repository.mergeServerConditions(serverJson, serverTimestamp = 1000L)

        assertEquals(1, merged.size)
        assertEquals("Local Condition A", merged[0])
    }

    @Test
    fun testTombstonePreventsDeletedItemResurrectionOnServerMerge() = runBlocking {
        repository.addCondition("Condition To Delete")
        testDispatcher.scheduler.advanceUntilIdle()

        repository.removeCondition("Condition To Delete")
        testDispatcher.scheduler.advanceUntilIdle()

        val serverJson = """["Condition To Delete", "New Server Condition"]"""
        val merged = repository.mergeServerConditions(serverJson, serverTimestamp = System.currentTimeMillis() + 1000L)

        assertEquals(1, merged.size)
        assertEquals("New Server Condition", merged[0])
    }
}
