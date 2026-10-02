package com.notel.notel.appointments

import android.content.Context
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.notifications.AppointmentReminderScheduler
import com.notel.notel.notifications.EventScheduler
import com.notel.notel.ui.viewmodel.EventCounterDto
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.Calendar
import java.util.UUID

/**
 * Links the Progress Reports "Prepare for an appointment" card to the app's
 * Events system (the event counters behind Settings > Event Counters and the
 * home-screen event display).
 *
 * Predictable rules:
 * - Saving an appointment links to a same-day, similar-titled event when one
 *   already exists (no duplicate entry). Otherwise the card creates a single
 *   "Doctor appointment" event and owns it.
 * - The card owns what it created: clearing the card removes its event (and
 *   cancels the day-before nudge, as before). Events the user created
 *   elsewhere are never renamed, moved, deleted, or re-alarmed by the card.
 * - If the linked event is deleted in the Events tab (or dropped by a sync
 *   merge), the card clears its saved appointment and cancels the nudge
 *   rather than resurrecting the event. Reconciled after counter deletions
 *   and on every app start.
 * - Rescheduling moves a card-owned event to the new date. A merely-linked
 *   user event is unlinked (never moved) and the new date is linked afresh.
 *
 * The event-counter model has no notes/details field, so the report type
 * stays on the appointment card only.
 */
object AppointmentEventLink {

    /** Title used when the card creates an event. The card captures no name. */
    const val APPOINTMENT_EVENT_TITLE = "Doctor appointment"

    /**
     * True when [name] looks like a doctor-appointment event. Used for
     * de-duplication: same-day events with a similar title are linked to
     * instead of creating a second entry.
     */
    fun isDoctorAppointmentLike(name: String): Boolean {
        val n = name.lowercase()
        val doctorish = n.contains("doctor") || n.contains("dr.") || n.contains("appt")
        val appointmentish = n.contains("appointment") || n.contains("appt") ||
            n.contains("visit") || n.contains("checkup") || n.contains("check-up")
        return doctorish && appointmentish
    }

    /**
     * "yyyy-MM-dd" -> start-of-day millis in the device timezone, matching how
     * the Events date picker stores counter dates (local midnight).
     */
    fun appointmentLocalMidnight(dateIso: String): Long? {
        val parts = dateIso.split("-")
        if (parts.size != 3) return null
        val year = parts[0].toIntOrNull() ?: return null
        val month = parts[1].toIntOrNull() ?: return null
        val day = parts[2].toIntOrNull() ?: return null
        if (month !in 1..12 || day !in 1..31) return null
        return Calendar.getInstance().apply {
            set(year, month - 1, day, 0, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    /** True when both timestamps fall on the same calendar day (device tz). */
    fun sameLocalDay(aMillis: Long, bMillis: Long): Boolean {
        val a = Calendar.getInstance().apply { timeInMillis = aMillis }
        val b = Calendar.getInstance().apply { timeInMillis = bMillis }
        return a.get(Calendar.YEAR) == b.get(Calendar.YEAR) &&
            a.get(Calendar.MONTH) == b.get(Calendar.MONTH) &&
            a.get(Calendar.DAY_OF_MONTH) == b.get(Calendar.DAY_OF_MONTH)
    }

    private suspend fun readCounters(preferences: NotelPreferences): MutableList<EventCounterDto> {
        val json = preferences.eventCounters.first()
        return try {
            if (json.isNotBlank()) Json.decodeFromString(ListSerializer(EventCounterDto.serializer()), json).toMutableList()
            else mutableListOf()
        } catch (e: Exception) {
            mutableListOf()
        }
    }

    private suspend fun writeCounters(preferences: NotelPreferences, counters: List<EventCounterDto>) {
        preferences.setEventCounters(Json.encodeToString(ListSerializer(EventCounterDto.serializer()), counters))
    }

    /**
     * Called when the appointment card saves (or re-saves) a date.
     * [pushProfile] syncs the counters afterwards, like other counter writes.
     */
    suspend fun onAppointmentSaved(
        preferences: NotelPreferences,
        context: Context,
        pushProfile: suspend () -> Unit,
        dateIso: String
    ) {
        val newDayMs = appointmentLocalMidnight(dateIso) ?: return
        val linkId = preferences.appointmentEventId.first()
        if (linkId != null) {
            val counters = readCounters(preferences)
            val linked = counters.firstOrNull { it.id == linkId }
            if (linked != null && sameLocalDay(linked.targetDate, newDayMs)) {
                // Link still valid for this date: nothing to do. A card-owned
                // event keeps its date; a user-created event is never touched.
                return
            }
            if (linked != null && preferences.appointmentEventOwned.first()) {
                // Reschedule: the card owns this event, so move it to the new date.
                writeCounters(preferences, counters.map { c ->
                    if (c.id == linkId) c.copy(targetDate = newDayMs) else c
                })
                pushProfile()
                // Keep the event's day-of 9 AM ping in sync with the new date.
                EventScheduler.cancelEventNotification(context, linkId)
                EventScheduler.scheduleEventNotification(context, linkId, linked.name, newDayMs)
                return
            }
            // Stale link, or a user-created event that lived on the old date:
            // drop the link and re-link below. The user's event is never moved.
            preferences.setAppointmentEventId(null)
            preferences.setAppointmentEventOwned(false)
        }
        linkOrCreate(preferences, context, pushProfile, newDayMs)
    }

    /**
     * Link to a same-day, similar-titled event when one exists; otherwise
     * create a single card-owned "Doctor appointment" event.
     */
    private suspend fun linkOrCreate(
        preferences: NotelPreferences,
        context: Context,
        pushProfile: suspend () -> Unit,
        dayMs: Long
    ) {
        val counters = readCounters(preferences)
        val match = counters
            .filter { sameLocalDay(it.targetDate, dayMs) && isDoctorAppointmentLike(it.name) }
            .minWithOrNull(
                compareBy(
                    { !it.name.equals(APPOINTMENT_EVENT_TITLE, ignoreCase = true) },
                    { it.targetDate }
                )
            )
        if (match != null) {
            // De-dupe: link to the existing event instead of creating a second
            // entry. User-created events are never renamed, moved, or re-alarmed.
            preferences.setAppointmentEventId(match.id)
            preferences.setAppointmentEventOwned(false)
            return
        }
        val id = UUID.randomUUID().toString()
        val created = EventCounterDto(
            id = id,
            name = APPOINTMENT_EVENT_TITLE,
            targetDate = dayMs,
            isUp = false,
            autoUp = true,
            isFavorite = false,
            isArchived = false
        )
        writeCounters(preferences, counters + created)
        pushProfile()
        // Standard Events-system behavior: every upcoming event pings at 9 AM
        // on the day. Re-armed on boot by BootReceiver for surviving counters.
        EventScheduler.scheduleEventNotification(context, id, APPOINTMENT_EVENT_TITLE, dayMs)
        preferences.setAppointmentEventId(id)
        preferences.setAppointmentEventOwned(true)
    }

    /**
     * Called when the appointment card is cleared. Removes the card-owned
     * event; a merely-linked user event is left exactly as the user made it.
     * The caller cancels the day-before nudge, as before.
     */
    suspend fun onAppointmentCleared(
        preferences: NotelPreferences,
        context: Context,
        pushProfile: suspend () -> Unit
    ) {
        val linkId = preferences.appointmentEventId.first()
        if (linkId != null && preferences.appointmentEventOwned.first()) {
            val counters = readCounters(preferences)
            if (counters.any { it.id == linkId }) {
                writeCounters(preferences, counters.filterNot { it.id == linkId })
                pushProfile()
            }
            EventScheduler.cancelEventNotification(context, linkId)
        }
        preferences.setAppointmentEventId(null)
        preferences.setAppointmentEventOwned(false)
    }

    /**
     * Reconciliation: when a saved appointment's linked event no longer exists
     * (deleted in the Events tab, or dropped by a sync merge), clear the stale
     * appointment and cancel its nudge instead of resurrecting the event.
     * Called after counter deletions and on every app start.
     */
    suspend fun reconcileAppointmentLink(preferences: NotelPreferences, context: Context) {
        val dateIso = preferences.appointmentDate.first()
        val linkId = preferences.appointmentEventId.first()
        if (dateIso == null || linkId == null) {
            // Tidy any half-written link state (appointment gone, link left).
            if (dateIso == null && linkId != null) {
                preferences.setAppointmentEventId(null)
                preferences.setAppointmentEventOwned(false)
            }
            return
        }
        val counters = readCounters(preferences)
        if (counters.none { it.id == linkId }) {
            preferences.setAppointmentDate(null)
            preferences.setAppointmentReportType("health")
            preferences.setAppointmentEventId(null)
            preferences.setAppointmentEventOwned(false)
            AppointmentReminderScheduler.cancel(context)
        }
    }
}
