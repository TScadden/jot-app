package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.flow.first
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

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
    private val preferences: NotelPreferences? = null
) {
    private val json = Json { ignoreUnknownKeys = true }

    private suspend fun getManualRecords(): List<BloodPressureUiRecord> {
        if (preferences == null) return emptyList()
        return try {
            val jsonStr = preferences.manualBloodPressureLogs.first()
            if (jsonStr.isNotBlank() && jsonStr != "[]") {
                json.decodeFromString<List<BloodPressureUiRecord>>(jsonStr)
            } else {
                emptyList()
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun addManualRecord(systolic: Int, diastolic: Int, timeEpochMs: Long = System.currentTimeMillis()): List<BloodPressureUiRecord> {
        val newRecord = BloodPressureUiRecord(
            systolic = systolic,
            diastolic = diastolic,
            timeEpochMs = timeEpochMs
        )
        val current = getManualRecords().toMutableList()
        current.add(0, newRecord)
        if (preferences != null) {
            try {
                preferences.setManualBloodPressureLogs(json.encodeToString(current))
            } catch (e: Exception) { /* ignore */ }
        }
        return getAllRecords()
    }

    suspend fun getAllRecords(): List<BloodPressureUiRecord> {
        val hcRecords = try {
            val sdkStatus = dataSource.checkAvailability()
            if (sdkStatus == 1 && dataSource.hasBloodPressurePermission()) {
                dataSource.readBloodPressureRecords()
            } else {
                emptyList()
            }
        } catch (e: Exception) {
            emptyList()
        }

        val manualRecords = getManualRecords()
        val combined = (hcRecords + manualRecords)
        return combined.distinctBy { it.timeEpochMs }.sortedByDescending { it.timeEpochMs }
    }

    suspend fun getTileState(): BloodPressureTileState {
        val manualRecords = getManualRecords()
        if (manualRecords.isNotEmpty()) {
            val hcRecords = try {
                if (dataSource.checkAvailability() == 1 && dataSource.hasBloodPressurePermission()) {
                    dataSource.readBloodPressureRecords()
                } else emptyList()
            } catch (e: Exception) { emptyList() }
            val combined = (hcRecords + manualRecords).sortedByDescending { it.timeEpochMs }
            return BloodPressureTileState.Available(combined.first())
        }

        val sdkStatus = try {
            dataSource.checkAvailability()
        } catch (e: Exception) {
            return BloodPressureTileState.Error
        }

        if (sdkStatus != 1) {
            return BloodPressureTileState.HealthConnectUnavailable
        }

        val hasPermission = try {
            dataSource.hasBloodPressurePermission()
        } catch (e: Exception) {
            return BloodPressureTileState.Error
        }

        if (!hasPermission) {
            return BloodPressureTileState.PermissionRequired
        }

        val hcRecords = try {
            dataSource.readBloodPressureRecords()
        } catch (e: Exception) {
            return BloodPressureTileState.Error
        }

        if (hcRecords.isEmpty()) {
            return BloodPressureTileState.NoData
        }

        val latest = hcRecords.maxByOrNull { it.timeEpochMs } ?: return BloodPressureTileState.NoData
        return BloodPressureTileState.Available(latest)
    }

    suspend fun getRecords(): List<BloodPressureUiRecord> {
        val hcRecords = try {
            val sdkStatus = dataSource.checkAvailability()
            if (sdkStatus == 1 && dataSource.hasBloodPressurePermission()) {
                dataSource.readBloodPressureRecords()
            } else {
                emptyList()
            }
        } catch (e: Exception) {
            emptyList()
        }

        val manualRecords = getManualRecords()
        val combined = (hcRecords + manualRecords)
        return combined.distinctBy { it.timeEpochMs }.sortedByDescending { it.timeEpochMs }
    }
}

