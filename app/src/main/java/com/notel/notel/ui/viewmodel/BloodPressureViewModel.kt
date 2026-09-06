package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.repository.BloodPressureFetchResult
import com.notel.notel.data.repository.BloodPressureRepository
import com.notel.notel.data.repository.HealthConnectStatus
import com.notel.notel.data.repository.SaveResult
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class BloodPressureUiState(
    val isLoading: Boolean = true,
    val isRefreshing: Boolean = false,
    val isSaving: Boolean = false,
    val records: List<BloodPressureUiRecord> = emptyList(),
    val hcStatus: HealthConnectStatus = HealthConnectStatus.Available,
    val hasManualReadings: Boolean = false,
    val errorMessage: String? = null,
    val saveErrorMessage: String? = null
)

@HiltViewModel
class BloodPressureViewModel @Inject constructor(
    private val repository: BloodPressureRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(BloodPressureUiState())
    val uiState: StateFlow<BloodPressureUiState> = _uiState.asStateFlow()

    init {
        loadData(isRefresh = false)
    }

    fun loadData(isRefresh: Boolean = false) {
        viewModelScope.launch {
            if (isRefresh) {
                _uiState.update { it.copy(isRefreshing = true, errorMessage = null) }
            } else {
                _uiState.update { it.copy(isLoading = true, errorMessage = null) }
            }

            val fetchResult: BloodPressureFetchResult = repository.getFetchResult()

            _uiState.update { current ->
                current.copy(
                    isLoading = false,
                    isRefreshing = false,
                    records = fetchResult.records,
                    hcStatus = fetchResult.hcStatus,
                    hasManualReadings = fetchResult.hasManualReadings,
                    errorMessage = if (fetchResult.hcStatus is HealthConnectStatus.Error) {
                        (fetchResult.hcStatus as HealthConnectStatus.Error).message
                    } else null
                )
            }
        }
    }

    fun saveManualRecord(
        systolic: Int,
        diastolic: Int,
        selectedTimeMs: Long,
        onSuccess: () -> Unit
    ) {
        val newRecord = BloodPressureUiRecord(
            systolic = systolic,
            diastolic = diastolic,
            timeEpochMs = selectedTimeMs,
            id = "manual_${selectedTimeMs}_${systolic}_${diastolic}",
            source = com.notel.notel.data.healthconnect.BloodPressureSource.MANUAL
        )

        // Optimistically insert reading into UI state immediately so screen updates with zero delay
        _uiState.update { current ->
            val updated = (listOf(newRecord) + current.records)
                .distinctBy { it.id }
                .sortedByDescending { it.timeEpochMs }
            current.copy(
                records = updated,
                hasManualReadings = true,
                isSaving = false,
                saveErrorMessage = null
            )
        }
        onSuccess()

        viewModelScope.launch {
            when (val saveResult = repository.addManualRecord(systolic, diastolic, selectedTimeMs)) {
                is SaveResult.Success -> {
                    // Update state with final merged data from repository
                    _uiState.update { current ->
                        current.copy(
                            records = saveResult.records,
                            hasManualReadings = true
                        )
                    }
                }
                is SaveResult.Failure -> {
                    // Rollback optimistic update if persistence failed
                    val fetchResult = repository.getFetchResult()
                    _uiState.update { current ->
                        current.copy(
                            records = fetchResult.records,
                            saveErrorMessage = saveResult.errorMessage
                        )
                    }
                }
            }
        }
    }

    fun deleteManualRecord(recordId: String) {
        // Optimistically remove the record instantly from UI state so the user sees immediate deletion
        _uiState.update { current ->
            val remainingRecords = current.records.filterNot { it.id == recordId }
            current.copy(
                records = remainingRecords,
                hasManualReadings = remainingRecords.any { it.source == com.notel.notel.data.healthconnect.BloodPressureSource.MANUAL }
            )
        }

        viewModelScope.launch {
            when (val result = repository.deleteManualRecord(recordId)) {
                is SaveResult.Success -> {
                    val fetchResult = repository.getFetchResult()
                    _uiState.update { current ->
                        current.copy(
                            records = fetchResult.records,
                            hasManualReadings = fetchResult.hasManualReadings
                        )
                    }
                }
                is SaveResult.Failure -> {
                    // Restore records if backend/storage deletion failed
                    val fetchResult = repository.getFetchResult()
                    _uiState.update { current ->
                        current.copy(
                            records = fetchResult.records,
                            hasManualReadings = fetchResult.hasManualReadings,
                            errorMessage = result.errorMessage
                        )
                    }
                }
            }
        }
    }

    fun clearSaveError() {
        _uiState.update { it.copy(saveErrorMessage = null) }
    }
}
