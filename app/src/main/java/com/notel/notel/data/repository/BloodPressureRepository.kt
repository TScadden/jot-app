package com.notel.notel.data.repository

import android.util.Log
import com.notel.notel.data.healthconnect.BloodPressureSource
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.flow.first
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

sealed class HealthConnectStatus {
    object Available : HealthConnectStatus()
    object Unavailable : HealthConnectStatus()
    object PermissionRequired : HealthConnectStatus()
    data class Error(val message: String) : HealthConnectStatus()
}

data class BloodPressureFetchResult(
    val records: List<BloodPressureUiRecord>,
    val hcStatus: HealthConnectStatus,
    val hasManualReadings: Boolean
)

sealed class SaveResult {
    data class Success(val records: List<BloodPressureUiRecord>) : SaveResult()
    data class Failure(val errorMessage: String) : SaveResult()
}

sealed class BloodPressureTileState {
    object Checking : BloodPressureTileState()
    object HealthConnectUnavailable : BloodPressureTileState()
    object PermissionRequired : BloodPressureTileState()
    object NoData : BloodPressureTileState()
    object Error : BloodPressureTileState()
    data class Available(val latestReading: BloodPressureUiRecord) : BloodPressureTileState()
}

interface BloodPressureDataSource {
    fun checkAvailability(): Int // HealthConnectClient SDK status int
    suspend fun hasBloodPressurePermission(): Boolean
    suspend fun readBloodPressureRecords(days: Int = 180): List<BloodPressureUiRecord>
}

class BloodPressureRepository(
    private val dataSource: BloodPressureDataSource,
    private val preferences: NotelPreferences? = null,
    private val syncManager: com.notel.notel.data.sync.SyncManager? = null
) {
    private val tag = "BloodPressureRepo"
    private val json = Json { ignoreUnknownKeys = true }

    private fun logD(msg: String) {
        try { Log.d(tag, msg) } catch (e: Throwable) {}
    }
    private fun logW(msg: String, t: Throwable? = null) {
        try { Log.w(tag, msg, t) } catch (e: Throwable) {}
    }
    private fun logE(msg: String, t: Throwable? = null) {
        try { Log.e(tag, msg, t) } catch (e: Throwable) {}
    }

    suspend fun getManualRecords(): List<BloodPressureUiRecord> {
        if (preferences == null) return emptyList()
        return try {
            val jsonStr = preferences.manualBloodPressureLogs.first()
            if (jsonStr.isNotBlank() && jsonStr != "[]") {
                json.decodeFromString<List<BloodPressureUiRecord>>(jsonStr)
            } else {
                emptyList()
            }
        } catch (e: Exception) {
            logE("Failed to decode stored manual blood pressure logs", e)
            emptyList()
        }
    }

    suspend fun addManualRecord(
        systolic: Int,
        diastolic: Int,
        timeEpochMs: Long = System.currentTimeMillis()
    ): SaveResult {
        if (systolic <= 0 || diastolic <= 0) {
            logW("Invalid blood pressure values supplied to addManualRecord")
            return SaveResult.Failure("Invalid blood pressure values")
        }

        val newRecord = BloodPressureUiRecord(
            systolic = systolic,
            diastolic = diastolic,
            timeEpochMs = timeEpochMs,
            id = "manual_${timeEpochMs}_${systolic}_${diastolic}",
            source = BloodPressureSource.MANUAL
        )

        val currentManual = getManualRecords().toMutableList()
        currentManual.add(0, newRecord)

        if (preferences != null) {
            try {
                val encoded = json.encodeToString(currentManual)
                preferences.setManualBloodPressureLogs(encoded)
                logD("Successfully saved manual blood pressure record to local preferences")
            } catch (e: Exception) {
                logE("Failed to write manual blood pressure record to DataStore", e)
                return SaveResult.Failure(e.message ?: "Failed to write to local storage")
            }

            try {
                syncManager?.pushProfileData()
            } catch (e: Exception) {
                logW("Non-blocking profile sync push failed after manual BP save", e)
            }
        } else {
            logW("Preferences instance is null in BloodPressureRepository; manual save transient only")
        }

        val updatedRecords = fetchRecordsInternal().records
        return SaveResult.Success(updatedRecords)
    }

    suspend fun deleteManualRecord(recordId: String): SaveResult {
        if (preferences == null) {
            return SaveResult.Failure("Local preferences not available")
        }

        val currentManual = getManualRecords().toMutableList()
        val recordToDelete = currentManual.find { it.id == recordId }

        if (recordToDelete == null) {
            logW("Manual record with id $recordId not found for deletion")
            return SaveResult.Failure("Record not found or is managed by Health Connect")
        }

        if (recordToDelete.source != BloodPressureSource.MANUAL) {
            return SaveResult.Failure("Cannot delete records synced from Health Connect")
        }

        currentManual.removeAll { it.id == recordId }

        try {
            val encoded = json.encodeToString(currentManual)
            preferences.setManualBloodPressureLogs(encoded)
            logD("Successfully deleted manual record $recordId from DataStore")
        } catch (e: Exception) {
            logE("Failed to update DataStore after manual record deletion", e)
            return SaveResult.Failure(e.message ?: "Failed to update storage")
        }

        try {
            syncManager?.pushProfileData()
        } catch (e: Exception) {
            logW("Non-blocking profile sync push failed after manual BP deletion", e)
        }

        val updatedRecords = fetchRecordsInternal().records
        return SaveResult.Success(updatedRecords)
    }

    private suspend fun fetchRecordsInternal(): BloodPressureFetchResult {
        var hcStatus: HealthConnectStatus = HealthConnectStatus.Available
        var hcRecords: List<BloodPressureUiRecord> = emptyList()

        try {
            val sdkStatus = dataSource.checkAvailability()
            if (sdkStatus != 1) {
                hcStatus = HealthConnectStatus.Unavailable
                logD("Health Connect SDK status unavailable ($sdkStatus)")
            } else {
                val hasPerm = dataSource.hasBloodPressurePermission()
                if (!hasPerm) {
                    hcStatus = HealthConnectStatus.PermissionRequired
                    logD("Health Connect blood pressure permission missing")
                } else {
                    hcRecords = dataSource.readBloodPressureRecords()
                    logD("Successfully read ${hcRecords.size} records from Health Connect")
                }
            }
        } catch (e: Exception) {
            logE("Exception querying Health Connect blood pressure records", e)
            hcStatus = HealthConnectStatus.Error(e.message ?: "Failed to read Health Connect data")
        }

        val manualRecords = getManualRecords()
        val combined = mergeRecords(hcRecords, manualRecords)

        return BloodPressureFetchResult(
            records = combined,
            hcStatus = hcStatus,
            hasManualReadings = manualRecords.isNotEmpty()
        )
    }

    fun mergeRecords(
        hcRecords: List<BloodPressureUiRecord>,
        manualRecords: List<BloodPressureUiRecord>
    ): List<BloodPressureUiRecord> {
        val combined = hcRecords + manualRecords
        return combined
            .distinctBy { it.id }
            .sortedByDescending { it.timeEpochMs }
    }

    suspend fun getFetchResult(): BloodPressureFetchResult {
        return fetchRecordsInternal()
    }

    suspend fun getAllRecords(): List<BloodPressureUiRecord> {
        return fetchRecordsInternal().records
    }

    suspend fun getRecords(): List<BloodPressureUiRecord> {
        return fetchRecordsInternal().records
    }

    suspend fun getTileState(): BloodPressureTileState {
        val result = fetchRecordsInternal()
        if (result.records.isNotEmpty()) {
            return BloodPressureTileState.Available(result.records.first())
        }

        return when (result.hcStatus) {
            is HealthConnectStatus.Unavailable -> BloodPressureTileState.HealthConnectUnavailable
            is HealthConnectStatus.PermissionRequired -> BloodPressureTileState.PermissionRequired
            is HealthConnectStatus.Error -> BloodPressureTileState.Error
            is HealthConnectStatus.Available -> BloodPressureTileState.NoData
        }
    }
}


