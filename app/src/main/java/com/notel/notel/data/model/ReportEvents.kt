package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Recorded-change events and before/after comparisons (Phase 2, WS-E).
 *
 * Sources:
 * - Medication starts/stops from the stored medication records'
 *   startedDate/endedDate (free-form user text; parsed best-effort, and the
 *   raw string is always shown next to any parsed date).
 * - Dose-change MENTIONS extracted from log text by keyword matching. There
 *   is no dose-history entity, so these are labeled explicitly as
 *   "recorded mention in logs" — never invented doses, dates, or adherence.
 *
 * Language rule (enforced in the sentence builders, not by convention):
 * correlation ONLY. "Average recorded sleep was lower in the two weeks after
 * the recorded medication change" — never "caused". Heart-rate rises are
 * never labeled orthostatic.
 */

private const val DAY_MS = 24 * 60 * 60 * 1000L

enum class MedicationChangeKind(val label: String) {
    STARTED("started"),
    STOPPED("stopped"),
    DOSE_MENTION("recorded mention in logs")
}

/** One annotated change event. [dateMs] null when the stored date text could not be parsed. */
data class MedicationChangeEvent(
    val medicationName: String,
    val kind: MedicationChangeKind,
    val dateMs: Long?,
    /** Raw stored/mentioned date text — always shown. */
    val dateLabel: String,
    /** Where this came from: "medication record" or "recorded mention in logs". */
    val evidence: String,
    /** Short log snippet for dose mentions (no PII beyond the user's own log text). */
    val snippet: String = ""
)

/** Deterministic before/after comparison of one metric around one event. */
data class BeforeAfterComparison(
    val eventLabel: String,
    val eventDateLabel: String,
    val metricLabel: String,
    val unit: String,
    val windowDays: Int,
    val beforeMean: Double?,
    val beforeDaysWithData: Int,
    val afterMean: Double?,
    val afterDaysWithData: Int,
    /** Other recorded changes inside either window — a listed limitation. */
    val overlappingEvents: List<String>
)

/** Tries several common date formats for the free-form medication date text. */
fun parseMedicationDate(raw: String?): Long? {
    if (raw.isNullOrBlank()) return null
    val text = raw.trim()
    if (text.equals("present", ignoreCase = true)) return null
    val zone = ZoneId.systemDefault()
    val patterns = listOf("yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "MMM d, yyyy", "MMM d yyyy", "d MMM yyyy")
    for (pattern in patterns) {
        try {
            val fmt = java.text.SimpleDateFormat(pattern, Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
                isLenient = false
            }
            val parsed = fmt.parse(text) ?: continue
            return parsed.time
        } catch (_: Exception) { /* try next */ }
    }
    // Last resort: a bare 4-digit year is not a usable event date.
    return null
}

private val DOSE_KEYWORDS = listOf(
    "increased", "decreased", "upped", "lowered", "raised dose", "doubled",
    "halved", "dose change", "dosage", "mg", "started taking", "stopped taking",
    "new prescription", "prescribed", "tapered", "tapering"
)

/**
 * Extracts medication change events from stored medication records and from
 * log text. Pure; unit-tested. Dose changes come ONLY from keyword matches
 * in the user's own log text and are labeled as mentions.
 */
fun extractMedicationEvents(
    medications: List<Medication>,
    logEntries: List<LogEntry>,
    categoriesMap: Map<Int, String>,
    medicationCategoryIds: Set<Int> = emptySet()
): List<MedicationChangeEvent> {
    val events = mutableListOf<MedicationChangeEvent>()

    for (med in medications) {
        val name = med.name.ifBlank { "Unnamed medication" }
        parseMedicationDate(med.startedDate)?.let { ms ->
            events.add(
                MedicationChangeEvent(
                    medicationName = name,
                    kind = MedicationChangeKind.STARTED,
                    dateMs = ms,
                    dateLabel = med.startedDate ?: "",
                    evidence = "medication record"
                )
            )
        } ?: run {
            // Unparseable/missing start date: still surface the record so the
            // report does not silently drop a medication, but without a date
            // it cannot anchor a before/after window.
            if (!med.startedDate.isNullOrBlank()) {
                events.add(
                    MedicationChangeEvent(
                        medicationName = name,
                        kind = MedicationChangeKind.STARTED,
                        dateMs = null,
                        dateLabel = med.startedDate,
                        evidence = "medication record (date as written)"
                    )
                )
            }
        }
        parseMedicationDate(med.endedDate)?.let { ms ->
            events.add(
                MedicationChangeEvent(
                    medicationName = name,
                    kind = MedicationChangeKind.STOPPED,
                    dateMs = ms,
                    dateLabel = med.endedDate ?: "",
                    evidence = "medication record"
                )
            )
        }
    }

    // Dose-change mentions: keyword scan over medication-category log text.
    // Category match by id when known, else by name containing "med".
    val medIds = medicationCategoryIds.ifEmpty {
        categoriesMap.filter { (_, name) -> "med" in name.lowercase(Locale.US) }.keys
    }
    val medLogs = logEntries.filter { it.categoryId in medIds }
    for (entry in medLogs) {
        val text = (entry.body + " " + entry.manualText).lowercase(Locale.US)
        if (DOSE_KEYWORDS.any { kw -> kw in text }) {
            val dateFmt = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US).withZone(ZoneId.systemDefault())
            val snippet = (entry.body.ifBlank { entry.manualText }).take(120)
            events.add(
                MedicationChangeEvent(
                    medicationName = guessMedicationName(text, medications),
                    kind = MedicationChangeKind.DOSE_MENTION,
                    dateMs = entry.timestamp,
                    dateLabel = dateFmt.format(Instant.ofEpochMilli(entry.timestamp)),
                    evidence = "recorded mention in logs",
                    snippet = snippet
                )
            )
        }
    }

    return events.sortedWith(
        compareBy<MedicationChangeEvent> { it.dateMs ?: Long.MAX_VALUE }.thenBy { it.medicationName }
    )
}

/** Best-effort: which known medication name appears in the log text, else "a medication". */
private fun guessMedicationName(lowerText: String, medications: List<Medication>): String {
    for (med in medications) {
        val name = med.name.lowercase(Locale.US)
        if (name.length > 2 && name in lowerText) return med.name
    }
    return "a medication"
}

/**
 * Deterministic before/after windows around [eventDateMs]: the [windowDays]
 * before (exclusive of the event day) vs the [windowDays] after. Uses the
 * same (epochMs, value) points as the charts. Pure; unit-tested.
 *
 * Overlapping changes (other events with dates inside either window) are
 * returned as limitations — never silently ignored.
 */
fun compareBeforeAfter(
    eventDateMs: Long,
    eventLabel: String,
    eventDateText: String,
    metricLabel: String,
    unit: String,
    points: List<Pair<Long, Double>>,
    windowDays: Int = 14,
    otherEvents: List<MedicationChangeEvent> = emptyList()
): BeforeAfterComparison {
    val windowMs = windowDays * DAY_MS
    // Event day itself belongs to neither window (avoids partial-day bias).
    val dayStart = (eventDateMs / DAY_MS) * DAY_MS
    val beforePoints = points.filter { it.first in (dayStart - windowMs) until dayStart }
    val afterPoints = points.filter { it.first in (dayStart + DAY_MS) until (dayStart + DAY_MS + windowMs) }
    val before = beforePoints.map { it.second }
    val after = afterPoints.map { it.second }

    val overlapping = otherEvents
        .filter { it.dateMs != null && it.dateMs != eventDateMs }
        .filter { (it.dateMs!! - dayStart) in (-windowMs)..(windowMs + DAY_MS) }
        .map { "${it.medicationName} ${it.kind.label} (${it.dateLabel})" }
        .distinct()

    return BeforeAfterComparison(
        eventLabel = eventLabel,
        eventDateLabel = eventDateText,
        metricLabel = metricLabel,
        unit = unit,
        windowDays = windowDays,
        beforeMean = before.takeIf { it.isNotEmpty() }?.average(),
        beforeDaysWithData = beforePoints.map { it.first / DAY_MS }.toSet().size,
        afterMean = after.takeIf { it.isNotEmpty() }?.average(),
        afterDaysWithData = afterPoints.map { it.first / DAY_MS }.toSet().size,
        overlappingEvents = overlapping
    )
}

/**
 * Renders a comparison as correlation-only prose. The template is fixed so
 * no call site can accidentally write causal language. Pure; unit-tested.
 */
fun describeComparison(c: BeforeAfterComparison): String {
    fun fmt(v: Double?): String = v?.let { String.format(Locale.US, "%.1f", it) } ?: "no recorded data"
    val sb = StringBuilder()
    sb.append("Average recorded ${c.metricLabel} was ${fmt(c.beforeMean)} ${c.unit} in the ${c.windowDays} days before ")
    sb.append("vs ${fmt(c.afterMean)} ${c.unit} in the ${c.windowDays} days after the recorded ${c.eventLabel} (${c.eventDateLabel}). ")
    sb.append("Days with data: ${c.beforeDaysWithData} of ${c.windowDays} before; ${c.afterDaysWithData} of ${c.windowDays} after. ")
    if (c.overlappingEvents.isNotEmpty()) {
        sb.append("Limitation — overlapping recorded changes in the windows: ${c.overlappingEvents.joinToString("; ")}. ")
    }
    sb.append("This is an observed association, not evidence that the change caused the difference.")
    return sb.toString().trim()
}

/**
 * Short event-row label for tables and chart markers.
 */
fun eventMarkerLabel(event: MedicationChangeEvent): String =
    "${event.medicationName} ${event.kind.label}"
