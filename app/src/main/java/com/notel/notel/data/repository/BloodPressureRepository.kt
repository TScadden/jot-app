package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.BloodPressureUiRecord

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
    private val dataSource: BloodPressureDataSource
) {
    suspend fun getTileState(): BloodPressureTileState {
        val sdkStatus = try {
            dataSource.checkAvailability()
        } catch (e: Exception) {
            return BloodPressureTileState.Error
        }

        // SDK_AVAILABLE is constant 1 in HealthConnectClient
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

        val records = try {
            dataSource.readBloodPressureRecords()
        } catch (e: Exception) {
            return BloodPressureTileState.Error
        }

        if (records.isEmpty()) {
            return BloodPressureTileState.NoData
        }

        val latest = records.maxByOrNull { it.timeEpochMs } ?: return BloodPressureTileState.NoData
        return BloodPressureTileState.Available(latest)
    }

    suspend fun getRecords(): List<BloodPressureUiRecord> {
        val sdkStatus = dataSource.checkAvailability()
        if (sdkStatus != 1 || !dataSource.hasBloodPressurePermission()) {
            return emptyList()
        }
        return dataSource.readBloodPressureRecords()
    }
}
