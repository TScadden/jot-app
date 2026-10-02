package com.notel.notel.data.model

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale

/**
 * A scheduled report-preparation event (Phase 2, WS-H).
 *
 * Extends the old appointment card (a date + a report type + a day-before
 * nudge) into a full event model: name/type, datetime + timezone, focus,
 * range, custom selections, last-meeting date, auto-prepare on/off, and
 * preparation timing (day before / day of at a chosen time, or an explicit
 * reminder-only alternative that keeps the old nudge behavior).
 *
 * Stored as a JSON list in DataStore (NotelPreferences.reportEvents) —
 * no new Room entity needed for this; the generated drafts are already
 * persisted as SavedReport rows (WS-G) with [eventId] linking back.
 */
@Serializable
data class ScheduledReportEvent(
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    /** "doctor" | "coaching" | "race" | "custom" */
    val type: String = "doctor",
    /** Event datetime, epoch millis in [timezoneId]. */
    val dateTimeMs: Long,
    val timezoneId: String = ZoneId.systemDefault().id,
    val focusKey: String = "health",
    val focusText: String = "",
    val customCategoryIds: Set<Int> = emptySet(),
    /** ReportRange.prefsKey the draft should cover. */
    val rangeType: String = "sincelastmeeting",
    /** Concrete bounds for custom ranges. */
    val rangeStartMs: Long = 0L,
    val rangeEndMs: Long = 0L,
    /** Explicit meeting date for "since last meeting" ranges. */
    val meetingDateMs: Long? = null,
    val lastMeetingDateMs: Long? = null,
    val autoPrepare: Boolean = true,
    /** "day_before" | "day_of" | "reminder_only" */
    val prepTiming: String = "day_before",
    /** "HH:mm" in [timezoneId]. */
    val prepTimeOfDay: String = "09:00",
    // ── Run bookkeeping (updated by the worker; shown as job status) ──
    val lastRunAtMs: Long? = null,
    /** "scheduled" | "running" | "ready" | "failed" | null (never run) */
    val lastRunStatus: String? = null,
    /** Snapshot generation timestamp = actual data cutoff of the last draft. */
    val lastDataCutoffMs: Long? = null,
    val lastError: String? = null
) {
    /** Explicit alternative: no auto-generation, just the reminder nudge. */
    val isReminderOnly: Boolean get() = prepTiming == "reminder_only" || !autoPrepare
}

val REPORT_EVENT_TYPES = mapOf(
    "doctor" to "Doctor visit",
    "coaching" to "Coaching session",
    "race" to "Race / event",
    "custom" to "Custom"
)

val REPORT_PREP_TIMINGS = mapOf(
    "day_before" to "Day before",
    "day_of" to "Day of",
    "reminder_only" to "Reminder only (no auto-draft)"
)

/**
 * Computes the exact-alarm fire time for an event's preparation step.
 * Day-before/day-of at [ScheduledReportEvent.prepTimeOfDay] in the event's
 * timezone. Returns null when the event is reminder-only or the fire time
 * is already past. Pure; unit-tested.
 */
fun prepFireTimeMs(event: ScheduledReportEvent, nowMs: Long = System.currentTimeMillis()): Long? {
    if (event.isReminderOnly) return null
    val zone = try { ZoneId.of(event.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
    val (hour, minute) = event.prepTimeOfDay.split(":").mapNotNull { it.toIntOrNull() }
        .let { parts -> if (parts.size == 2) parts[0] to parts[1] else 9 to 0 }
    val eventDay = ZonedDateTime.ofInstant(Instant.ofEpochMilli(event.dateTimeMs), zone).toLocalDate()
    val targetDay = when (event.prepTiming) {
        "day_of" -> eventDay
        else -> eventDay.minusDays(1)
    }
    val fireAt = ZonedDateTime.of(targetDay, java.time.LocalTime.of(hour.coerceIn(0, 23), minute.coerceIn(0, 59)), zone)
        .toInstant().toEpochMilli()
    return if (fireAt > nowMs) fireAt else null
}

/**
 * Resolves the report range a draft should cover for [event].
 * "sincelastmeeting" anchors at meetingDateMs, then lastMeetingDateMs, then
 * falls back to 30 days (never silently unbounded). Pure; unit-tested.
 */
fun resolveEventRange(event: ScheduledReportEvent, nowMs: Long = System.currentTimeMillis()): ReportRange =
    when (event.rangeType) {
        "alltime" -> ReportRange.AllTime
        "custom" -> ReportRange.Custom(event.rangeStartMs, event.rangeEndMs)
        "sincelastmeeting" -> {
            val anchor = event.meetingDateMs ?: event.lastMeetingDateMs
            if (anchor != null && anchor < nowMs) ReportRange.SinceLastMeeting(anchor)
            else ReportRange.Last30Days // honest fallback, never unbounded-by-accident
        }
        else -> ReportRange.Last30Days
    }

/** Focus for the draft. Pure. */
fun resolveEventFocus(event: ScheduledReportEvent): ReportFocus =
    ReportFocus.fromKey(event.focusKey, event.focusText)

/** Short human label for the scheduled prep moment, e.g. "Day before at 9:00 AM". */
fun prepTimingLabel(event: ScheduledReportEvent): String {
    if (event.isReminderOnly) return "Reminder only"
    val whenWord = if (event.prepTiming == "day_of") "Day of" else "Day before"
    val timeLabel = try {
        val (h, m) = event.prepTimeOfDay.split(":").map { it.toInt() }
        val amPm = if (h < 12) "AM" else "PM"
        val h12 = when (h % 12) { 0 -> 12 else -> h % 12 }
        "$h12:${m.toString().padStart(2, '0')} $amPm"
    } catch (_: Exception) { event.prepTimeOfDay }
    return "$whenWord at $timeLabel"
}

/** Human label for the event datetime in its timezone. */
fun eventDateTimeLabel(event: ScheduledReportEvent): String {
    val zone = try { ZoneId.of(event.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
    val fmt = java.time.format.DateTimeFormatter.ofPattern("EEE, MMM d, yyyy h:mm a", Locale.US).withZone(zone)
    return fmt.format(Instant.ofEpochMilli(event.dateTimeMs))
}
