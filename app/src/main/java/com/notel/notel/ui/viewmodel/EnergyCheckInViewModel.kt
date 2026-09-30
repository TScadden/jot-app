package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalTime
import java.time.ZonedDateTime
import javax.inject.Inject

/**
 * Tabs Lab energy check-in (Sep 2026, redesigned): a prominent card at the top of
 * the Home ("Today") screen. Five flat 1-5 selector buttons. One tap creates a
 * REAL LogEntry (source "Energy check-in") in the Mood & Energy category; the
 * card then slides off to the left for the day.
 *
 * Visibility is driven purely by the existence of today's energy log entry: the
 * card shows when no such entry exists for the current "energy day" (the day
 * starting at 4am local). Deleting the entry in History makes the card reappear,
 * so they can log a new number. There is no local dismissed flag.
 */
data class EnergyCheckInUiState(
    val visible: Boolean = false
)

/** Identifies energy check-in entries among the Mood & Energy category's rows. */
const val ENERGY_CHECKIN_SOURCE = "Energy check-in"

/** Seeded "Mood & Energy" category; resolved by slug at runtime with this as fallback id. */
const val ENERGY_CATEGORY_SLUG = "mood"
const val ENERGY_CATEGORY_FALLBACK_ID = 6

/** The energy day starts at 4am local time. */
const val ENERGY_DAY_START_HOUR = 4

/**
 * Start of the current "energy day": 4am local. Before 4am it is still
 * yesterday's energy day; the new day begins at 04:00.
 * Pure function, unit-testable.
 */
fun energyDayStart(now: ZonedDateTime = ZonedDateTime.now()): ZonedDateTime {
    val day = if (now.toLocalTime().isBefore(LocalTime.of(ENERGY_DAY_START_HOUR, 0))) {
        now.toLocalDate().minusDays(1)
    } else {
        now.toLocalDate()
    }
    return day.atStartOfDay(now.zone).plusHours(ENERGY_DAY_START_HOUR.toLong())
}

@HiltViewModel
class EnergyCheckInViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(EnergyCheckInUiState())
    val uiState = _uiState.asStateFlow()

    @Volatile
    private var energyCategoryId: Int = ENERGY_CATEGORY_FALLBACK_ID

    /**
     * Guards against a double-tap landing two entries before the new row flows
     * back through the category flow. Reset once the entry is observed (or the
     * insert fails), and cleared whenever the card is visible again.
     */
    @Volatile
    private var tapInFlight: Boolean = false

    /**
     * Re-emits every minute so a 4am rollover (or a History delete landing via
     * the entry flow) re-evaluates the window without an app restart.
     */
    private val dayTicker = flow {
        while (true) {
            emit(System.currentTimeMillis())
            delay(60_000)
        }
    }

    init {
        viewModelScope.launch {
            energyCategoryId = try {
                categoryRepository.findCategoryIdBySlug(ENERGY_CATEGORY_SLUG, ENERGY_CATEGORY_FALLBACK_ID)
            } catch (e: Exception) {
                ENERGY_CATEGORY_FALLBACK_ID
            }
            combine(
                logRepository.getEntriesByCategory(energyCategoryId),
                dayTicker
            ) { entries, _ ->
                val windowStart = energyDayStart()
                val startMillis = windowStart.toInstant().toEpochMilli()
                val endMillis = windowStart.plusDays(1).toInstant().toEpochMilli()
                entries.any { entry ->
                    entry.source == ENERGY_CHECKIN_SOURCE &&
                        entry.timestamp in startMillis until endMillis
                }
            }.collect { hasEntry ->
                if (hasEntry) tapInFlight = false
                _uiState.update { it.copy(visible = !hasEntry) }
            }
        }
    }

    /**
     * One tap logs the rating as a real log entry (DIRTY, syncs like any entry).
     * The card slides away once the new row flows back through the category flow.
     */
    fun selectLevel(level: Int) {
        if (level !in 1..5 || tapInFlight) return
        tapInFlight = true
        viewModelScope.launch {
            try {
                logRepository.insertEntry(
                    LogEntry(
                        categoryId = energyCategoryId,
                        body = "Energy: $level/5",
                        source = ENERGY_CHECKIN_SOURCE
                    )
                )
            } catch (e: Exception) {
                tapInFlight = false
            }
        }
    }
}
