package com.notel.notel.data.model

import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.MigraineAttack
import com.notel.notel.data.local.entity.SyncopeEvent
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import java.time.ZoneId

enum class ClinicalReportRangeType {
    FULL,
    LAST_30_DAYS,
    SINCE_LAST_MEETING,
    CUSTOM
}

private const val DAY_MS = 24 * 60 * 60 * 1000L

/**
 * User-selected report date window (Phase 1, WS-A). The screen builds one of
 * these; [toClinicalReportRange] resolves it to concrete epoch bounds for the
 * collector snapshot. AllTime means startEpochMs = 0 — every stored record,
 * no day cap and no entry-count cap.
 */
sealed interface ReportRange {
    data object Last30Days : ReportRange
    data object AllTime : ReportRange
    data class SinceLastMeeting(val meetingDateEpochMs: Long) : ReportRange
    data class Custom(val startEpochMs: Long, val endEpochMs: Long) : ReportRange

    /** Stable key for the "restore last report prefs" DataStore entry. */
    val prefsKey: String
        get() = when (this) {
            Last30Days -> "last30days"
            AllTime -> "alltime"
            is SinceLastMeeting -> "sincelastmeeting"
            is Custom -> "custom"
        }

    val label: String
        get() = when (this) {
            Last30Days -> "Last 30 days"
            AllTime -> "All time"
            is SinceLastMeeting -> "Since last meeting"
            is Custom -> "Custom range"
        }

    fun toClinicalReportRange(
        nowEpochMs: Long = System.currentTimeMillis(),
        timezoneId: String = ZoneId.systemDefault().id
    ): ClinicalReportRange {
        val (type, start, end) = when (this) {
            Last30Days -> Triple(
                ClinicalReportRangeType.LAST_30_DAYS,
                nowEpochMs - 30L * DAY_MS,
                nowEpochMs
            )
            AllTime -> Triple(ClinicalReportRangeType.FULL, 0L, nowEpochMs)
            is SinceLastMeeting -> Triple(
                ClinicalReportRangeType.SINCE_LAST_MEETING,
                meetingDateEpochMs.coerceAtMost(nowEpochMs),
                nowEpochMs
            )
            is Custom -> {
                val s = minOf(startEpochMs, endEpochMs).coerceAtMost(nowEpochMs)
                val e = maxOf(startEpochMs, endEpochMs).coerceAtMost(nowEpochMs).coerceAtLeast(s)
                Triple(ClinicalReportRangeType.CUSTOM, s, e)
            }
        }
        return ClinicalReportRange(type, start, end, timezoneId)
    }

    companion object {
        fun fromPrefsKey(key: String?): ReportRange = when (key) {
            "alltime" -> AllTime
            "sincelastmeeting" -> SinceLastMeeting(System.currentTimeMillis() - 30L * DAY_MS)
            "custom" -> Custom(
                System.currentTimeMillis() - 30L * DAY_MS,
                System.currentTimeMillis()
            )
            else -> Last30Days
        }
    }
}

/**
 * Report focus (Phase 1, WS-F). Health and Training resolve to fixed category
 * slug sets; Custom carries the user's selected categories plus optional
 * plain-language focus text. The collector filters log entries by these —
 * focus reaches the real pipeline, not just labels.
 */
sealed interface ReportFocus {
    val key: String
    val label: String
    val description: String

    data object Health : ReportFocus {
        override val key = "health"
        override val label = "Health"
        override val description = "Symptoms, meds, sleep, mood, and vitals"
    }

    data object Training : ReportFocus {
        override val key = "training"
        override val label = "Training"
        override val description = "Habits, vitals, and food"
    }

    data class Custom(val focusText: String = "") : ReportFocus {
        override val key = "custom"
        override val label = "Custom"
        override val description = "You pick the categories"
    }

    companion object {
        val entries: List<ReportFocus> get() = listOf(Health, Training, Custom())

        fun fromKey(key: String?, focusText: String = ""): ReportFocus = when (key) {
            "training" -> Training
            "custom" -> Custom(focusText)
            else -> Health
        }
    }
}

/** Category slugs bundled into each preset focus. */
val HEALTH_SLUGS = setOf("symptoms", "medication", "sleep", "mood", "heart_rate")
val TRAINING_SLUGS = setOf("personal", "heart_rate", "calories")

/**
 * Effective slug for preset matching. Stored slugs are null on databases
 * created before the slug column was backfilled, so fall back to the
 * canonical slug for the category id (null-slug fix, preserved here).
 */
fun effectiveSlug(category: Category): String =
    category.slug
        ?: com.notel.notel.data.local.DefaultCategories.slugById[category.id]
        ?: ""

/**
 * Resolves which category ids feed the report for a focus. Pure and
 * unit-tested. Custom intersects the user's selection with categories that
 * actually exist so stale ids never pass through.
 */
fun resolveFocusCategoryIds(
    allCategories: List<Category>,
    focus: ReportFocus,
    customIds: Set<Int>
): Set<Int> = when (focus) {
    ReportFocus.Health ->
        allCategories.filter { effectiveSlug(it) in HEALTH_SLUGS }.map { it.id }.toSet()
    ReportFocus.Training ->
        allCategories.filter { effectiveSlug(it) in TRAINING_SLUGS }.map { it.id }.toSet()
    is ReportFocus.Custom ->
        allCategories.filter { it.id in customIds }.map { it.id }.toSet()
}

data class ClinicalReportRange(
    val type: ClinicalReportRangeType,
    val startEpochMs: Long,
    val endEpochMs: Long,
    /** IANA zone the covered dates are expressed in; carried on the snapshot. */
    val timezoneId: String = ZoneId.systemDefault().id
) {
    val durationDays: Int
        get() = ((endEpochMs - startEpochMs) / DAY_MS).toInt().coerceAtLeast(1)
}

enum class DataSourceStatus {
    SUCCESS,
    NO_DATA,
    PERMISSION_DENIED,
    UNAVAILABLE,
    TIMED_OUT,
    ERROR
}

data class SectionMetadata(
    val sectionKey: String,
    val status: DataSourceStatus,
    val recordCount: Int = 0,
    val message: String? = null
)

data class ClinicalReportData(
    val range: ClinicalReportRange,
    val generationTimestamp: Long = System.currentTimeMillis(),
    /** Focus key ("health" | "training" | "custom") — one snapshot, shared by preview/stats/AI/PDF. */
    val focusKey: String = "health",
    /** Plain-language custom focus text (Custom focus only; blank otherwise). */
    val focusText: String = "",
    val logEntries: List<LogEntry> = emptyList(),
    val categoriesMap: Map<Int, String> = emptyMap(),
    val userContext: String = "",
    val userAge: Int = 0,
    val userHeight: Float = 0f,
    val userWeight: Float = 0f,
    val userGender: String = "",
    val conditions: List<String> = emptyList(),
    val medications: List<Medication> = emptyList(),
    val knowledgeDocuments: List<String> = emptyList(),
    val heartRateSeries: List<Pair<String, Int>> = emptyList(),
    val sleepSeries: List<Pair<String, Int>> = emptyList(),
    val deepSleepSeries: List<Pair<String, Int>> = emptyList(),
    val caloriesSeries: List<Pair<String, Int>> = emptyList(),
    val hrvSeries: List<Pair<String, Double>> = emptyList(),
    val heartRateSpikes: List<DailyHeartRateSummary> = emptyList(),
    val bloodPressureSeries: List<BloodPressureUiRecord> = emptyList(),
    val bodyLoadHistory: String = "",
    val syncopeEvents: List<SyncopeEvent> = emptyList(),
    val migraineAttacks: List<MigraineAttack> = emptyList(),
    val sectionMetadata: Map<String, SectionMetadata> = emptyMap()
) {
    val hasAnyData: Boolean
        get() = logEntries.isNotEmpty() ||
                heartRateSeries.isNotEmpty() ||
                sleepSeries.isNotEmpty() ||
                caloriesSeries.isNotEmpty() ||
                hrvSeries.isNotEmpty() ||
                heartRateSpikes.isNotEmpty() ||
                bloodPressureSeries.isNotEmpty() ||
                conditions.isNotEmpty() ||
                medications.isNotEmpty() ||
                knowledgeDocuments.isNotEmpty() ||
                syncopeEvents.isNotEmpty() ||
                migraineAttacks.isNotEmpty()
}
