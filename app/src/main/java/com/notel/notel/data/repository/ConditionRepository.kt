package com.notel.notel.data.repository

import android.util.Log
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

sealed class ConditionOperationResult {
    data class Success(val conditions: List<String>) : ConditionOperationResult()
    data class Failure(val errorMessage: String) : ConditionOperationResult()
}

@Singleton
class ConditionRepository @Inject constructor(
    private val preferences: NotelPreferences,
    private val syncManagerProvider: javax.inject.Provider<SyncManager>
) {
    private val tag = "ConditionRepository"
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()
    private val scope = CoroutineScope(Dispatchers.IO)

    private val _conditions = MutableStateFlow<List<String>>(emptyList())
    val conditions: StateFlow<List<String>> = _conditions.asStateFlow()

    private var syncDebounceJob: Job? = null
    private var lastLocalEditTimestamp: Long = 0L
    private val deletedConditionsTombstones = mutableSetOf<String>()

    init {
        scope.launch {
            loadInitialConditions()
        }
    }

    private suspend fun loadInitialConditions() {
        mutex.withLock {
            val rawJson = preferences.userConditions.first()
            val parsed = parseAndNormalizeJson(rawJson)
            _conditions.value = parsed
            logDebug("LOAD_INIT", parsed.size)
        }
    }

    suspend fun addCondition(conditionInput: String): ConditionOperationResult = mutex.withLock {
        val trimmed = conditionInput.trim()
        if (trimmed.isBlank()) {
            logDebug("ADD_REJECT_BLANK", _conditions.value.size)
            return ConditionOperationResult.Failure("Condition cannot be blank")
        }

        val currentList = _conditions.value.toMutableList()
        val existingIndex = currentList.indexOfFirst { it.equals(trimmed, ignoreCase = true) }

        if (existingIndex >= 0) {
            // Already present, preserve existing spelling
            logDebug("ADD_DUPLICATE_IGNORED", currentList.size)
            return ConditionOperationResult.Success(currentList)
        }

        currentList.add(trimmed)
        // Remove from deleted tombstones if re-added
        deletedConditionsTombstones.remove(trimmed.lowercase())

        return persistAndScheduleSync(currentList, "ADD")
    }

    suspend fun removeCondition(conditionInput: String): ConditionOperationResult = mutex.withLock {
        val trimmed = conditionInput.trim()
        if (trimmed.isBlank()) {
            return ConditionOperationResult.Success(_conditions.value)
        }

        val currentList = _conditions.value.toMutableList()
        val removed = currentList.removeAll { it.equals(trimmed, ignoreCase = true) }

        if (removed) {
            deletedConditionsTombstones.add(trimmed.lowercase())
            return persistAndScheduleSync(currentList, "REMOVE")
        }

        return ConditionOperationResult.Success(currentList)
    }

    suspend fun mergeServerConditions(serverConditionsRaw: String, serverTimestamp: Long = 0L): List<String> = mutex.withLock {
        // Stale server pull protection: if local edit happened after serverTimestamp, ignore server pull
        if (serverTimestamp > 0L && serverTimestamp < lastLocalEditTimestamp) {
            logDebug("MERGE_SERVER_STALE_IGNORED", _conditions.value.size)
            return _conditions.value
        }

        val serverList = parseAndNormalizeRawServer(serverConditionsRaw)
        val currentLocal = _conditions.value.toMutableList()

        val merged = mutableListOf<String>()
        // Preserve local order and entries first
        currentLocal.forEach { item ->
            val normalized = item.trim()
            if (normalized.isNotBlank() && merged.none { it.equals(normalized, ignoreCase = true) }) {
                merged.add(normalized)
            }
        }

        // Add non-tombstoned server entries
        serverList.forEach { serverItem ->
            val normalized = serverItem.trim()
            val lower = normalized.lowercase()
            if (normalized.isNotBlank() && !deletedConditionsTombstones.contains(lower)) {
                if (merged.none { it.equals(normalized, ignoreCase = true) }) {
                    merged.add(normalized)
                }
            }
        }

        if (merged != _conditions.value) {
            _conditions.value = merged
            try {
                val encoded = json.encodeToString(merged)
                preferences.setUserConditions(encoded)
                logDebug("MERGE_SERVER_SUCCESS", merged.size)
            } catch (e: Exception) {
                logError("MERGE_SERVER_SAVE_ERR", e)
            }
        }

        return merged
    }

    private suspend fun persistAndScheduleSync(newList: List<String>, opType: String): ConditionOperationResult {
        _conditions.value = newList
        lastLocalEditTimestamp = System.currentTimeMillis()

        try {
            val encoded = json.encodeToString(newList)
            preferences.setUserConditions(encoded)
            logDebug("PERSIST_OK_$opType", newList.size)
        } catch (e: Exception) {
            logError("PERSIST_ERR_$opType", e)
            return ConditionOperationResult.Failure("Failed to save condition locally")
        }

        scheduleDebouncedSync()
        return ConditionOperationResult.Success(newList)
    }

    private fun scheduleDebouncedSync() {
        syncDebounceJob?.cancel()
        syncDebounceJob = scope.launch {
            delay(1500L) // 1.5s debounce to coalesce rapid taps into a single push
            try {
                syncManagerProvider.get().pushProfileData()
                logDebug("SYNC_PUSH_OK", _conditions.value.size)
            } catch (e: Exception) {
                logError("SYNC_PUSH_ERR", e)
            }
        }
    }

    private fun parseAndNormalizeJson(jsonStr: String): List<String> {
        if (jsonStr.isBlank() || jsonStr == "[]") return emptyList()
        return try {
            val list = json.decodeFromString<List<String>>(jsonStr)
            normalizeList(list)
        } catch (e: Exception) {
            logError("PARSE_JSON_FAIL", e)
            emptyList()
        }
    }

    private fun parseAndNormalizeRawServer(raw: String): List<String> {
        if (raw.isBlank() || raw == "[]") return emptyList()
        return try {
            if (raw.trim().startsWith("[")) {
                val list = json.decodeFromString<List<String>>(raw)
                normalizeList(list)
            } else {
                val list = raw.split(",").map { it.trim() }
                normalizeList(list)
            }
        } catch (e: Exception) {
            val list = raw.split(",").map { it.trim() }
            normalizeList(list)
        }
    }

    fun normalizeList(input: List<String>): List<String> {
        val result = mutableListOf<String>()
        input.forEach { item ->
            val trimmed = item.trim()
            if (trimmed.isNotBlank()) {
                if (result.none { it.equals(trimmed, ignoreCase = true) }) {
                    result.add(trimmed)
                }
            }
        }
        return result
    }

    private fun logDebug(op: String, count: Int) {
        try {
            Log.d(tag, "ConditionOp: $op | Count: $count | Timestamp: ${System.currentTimeMillis()}")
        } catch (e: Throwable) {}
    }

    private fun logError(op: String, t: Throwable) {
        try {
            Log.e(tag, "ConditionOpErr: $op | Timestamp: ${System.currentTimeMillis()}", t)
        } catch (e: Throwable) {}
    }
}
