package com.notel.notel.ui.screen

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.work.WorkInfo
import com.notel.notel.data.model.*
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.SettingsViewModel
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.*

private fun eventMsLabel(ms: Long?, zoneId: String): String {
    if (ms == null || ms <= 0L) return "—"
    return try {
        val zone = ZoneId.of(zoneId)
        val fmt = java.time.format.DateTimeFormatter.ofPattern("MMM d, yyyy h:mm a", Locale.US).withZone(zone)
        fmt.format(Instant.ofEpochMilli(ms))
    } catch (_: Exception) {
        SimpleDateFormat("MMM d, yyyy h:mm a", Locale.US).format(Date(ms))
    }
}

/**
 * WS-H: scheduled report-preparation events. Shows scheduled prep time,
 * actual data cutoff, and job status; supports add/edit/delete,
 * reschedule (edit + save re-arms), and manual generation.
 *
 * The legacy appointment card above stays untouched as the simple
 * reminder-only path; these events add automatic draft generation.
 */
@Composable
fun ReportEventsCard(viewModel: SettingsViewModel) {
    val events by viewModel.reportEvents.collectAsState()
    var editing by remember { mutableStateOf<ScheduledReportEvent?>(null) }
    var showEditor by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        modifier = Modifier.fillMaxWidth(),
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.25f))
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.EventNote, null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    "Scheduled report prep",
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "Tabs prepares a report draft automatically before a visit. You review it in the preview — sharing is always your explicit choice.",
                color = NotelTextSecondary,
                fontSize = 12.sp
            )
            Spacer(Modifier.height(12.dp))

            if (events.isEmpty()) {
                Text(
                    "No scheduled events yet.",
                    color = NotelTextSecondary.copy(alpha = 0.7f),
                    fontSize = 12.sp
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    events.sortedBy { it.dateTimeMs }.forEach { event ->
                        ReportEventRow(
                            event = event,
                            viewModel = viewModel,
                            onEdit = { editing = event; showEditor = true },
                            onDelete = { viewModel.deleteReportEvent(event.id) },
                            onGenerateNow = { viewModel.generateEventDraftNow(event.id) }
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))
            GlassyButton(
                onClick = {
                    editing = ScheduledReportEvent(
                        name = "",
                        dateTimeMs = System.currentTimeMillis() + 7L * 24 * 60 * 60 * 1000,
                        timezoneId = ZoneId.systemDefault().id
                    )
                    showEditor = true
                },
                modifier = Modifier.fillMaxWidth(),
                containerColor = NotelPrimary
            ) {
                Icon(Icons.Default.Add, null, tint = NotelTextPrimary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Schedule an event", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            }
        }
    }

    if (showEditor && editing != null) {
        ReportEventEditor(
            initial = editing!!,
            onDismiss = { showEditor = false; editing = null },
            onSave = { event ->
                viewModel.saveReportEvent(event)
                showEditor = false
                editing = null
            }
        )
    }
}

@Composable
private fun ReportEventRow(
    event: ScheduledReportEvent,
    viewModel: SettingsViewModel,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onGenerateNow: () -> Unit
) {
    val workInfo by viewModel.reportEventWorkStatus(event.id).collectAsState(initial = null)
    var confirmDelete by remember { mutableStateOf(false) }

    val statusText = remember(event, workInfo) {
        when {
            workInfo?.state == WorkInfo.State.RUNNING || workInfo?.state == WorkInfo.State.ENQUEUED ->
                "Preparing draft…"
            event.lastRunStatus == "running" -> "Preparing draft…"
            event.lastRunStatus == "ready" ->
                "Draft ready" + (event.lastDataCutoffMs?.let { " · data cutoff ${eventMsLabel(it, event.timezoneId)}" } ?: "")
            event.lastRunStatus == "failed" ->
                "Last run failed${event.lastError?.let { ": $it" } ?: ""} — will retry"
            else -> {
                val fireAt = prepFireTimeMs(event)
                if (fireAt != null) "Prep ${prepTimingLabel(event).lowercase()} · ${eventMsLabel(fireAt, event.timezoneId)}"
                else if (event.isReminderOnly) "Reminder only — no auto-draft"
                else "No prep scheduled"
            }
        }
    }
    val typeLabel = REPORT_EVENT_TYPES[event.type] ?: "Custom"
    val focusLabel = ReportFocus.fromKey(event.focusKey).label

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = NotelSurfaceHigh,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(event.name.ifBlank { "Untitled event" }, color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(
                "$typeLabel · ${eventDateTimeLabel(event)}",
                color = NotelTextSecondary, fontSize = 12.sp
            )
            Text(
                "$focusLabel report · range: ${event.rangeType}",
                color = NotelTextSecondary.copy(alpha = 0.8f), fontSize = 11.sp
            )
            Spacer(Modifier.height(4.dp))
            Text(statusText, color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = onGenerateNow) {
                    Text("Generate now", color = NotelPrimary, fontSize = 12.sp)
                }
                TextButton(onClick = onEdit) {
                    Text("Edit", color = NotelPrimary, fontSize = 12.sp)
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { confirmDelete = true }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                }
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete scheduled event?", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    "This cancels the scheduled prep for \"${event.name}\". Already-generated drafts stay in Saved reports.",
                    color = NotelTextSecondary, fontSize = 13.sp
                )
            },
            confirmButton = {
                TextButton(onClick = { onDelete(); confirmDelete = false }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("Keep", color = NotelTextSecondary) }
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportEventEditor(
    initial: ScheduledReportEvent,
    onDismiss: () -> Unit,
    onSave: (ScheduledReportEvent) -> Unit
) {
    val context = LocalContext.current
    var name by remember { mutableStateOf(initial.name) }
    var type by remember { mutableStateOf(initial.type) }
    var dateTimeMs by remember { mutableStateOf(initial.dateTimeMs) }
    var timezoneId by remember { mutableStateOf(initial.timezoneId) }
    var focusKey by remember { mutableStateOf(initial.focusKey) }
    var rangeType by remember { mutableStateOf(initial.rangeType) }
    var prepTiming by remember { mutableStateOf(initial.prepTiming) }
    var prepTimeOfDay by remember { mutableStateOf(initial.prepTimeOfDay) }
    var autoPrepare by remember { mutableStateOf(initial.autoPrepare) }
    var showDatePicker by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }
    var showPrepTimePicker by remember { mutableStateOf(false) }

    val zone = remember(timezoneId) {
        try { ZoneId.of(timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
    }
    val cal = remember(dateTimeMs, zone) {
        Calendar.getInstance(TimeZone.getTimeZone(zone)).apply { timeInMillis = dateTimeMs }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                if (initial.name.isBlank() && initial.lastRunStatus == null) "Schedule an event" else "Edit event",
                color = NotelTextPrimary, fontWeight = FontWeight.SemiBold
            )
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Event name", fontSize = 12.sp) },
                    placeholder = { Text("e.g. Dr. Richards visit", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary
                    )
                )

                Text("Event type", color = NotelTextSecondary, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    REPORT_EVENT_TYPES.forEach { (key, label) ->
                        val selected = type == key
                        FilterChip(
                            selected = selected,
                            onClick = { type = key },
                            label = { Text(label, fontSize = 11.sp) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = NotelPrimary.copy(alpha = 0.2f)
                            )
                        )
                    }
                }

                GlassyButton(
                    onClick = { showDatePicker = true },
                    modifier = Modifier.fillMaxWidth(),
                    containerColor = NotelSurfaceHigh
                ) {
                    Icon(Icons.Default.CalendarMonth, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(eventDateTimeLabel(initial.copy(dateTimeMs = dateTimeMs, timezoneId = timezoneId)), color = NotelTextPrimary, fontSize = 13.sp)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GlassyButton(
                        onClick = { showTimePicker = true },
                        modifier = Modifier.weight(1f),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Text("Time", color = NotelTextSecondary, fontSize = 12.sp)
                    }
                    OutlinedTextField(
                        value = timezoneId,
                        onValueChange = { timezoneId = it },
                        label = { Text("Timezone", fontSize = 11.sp) },
                        modifier = Modifier.weight(1.4f),
                        singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary
                        )
                    )
                }

                Text("Report focus", color = NotelTextSecondary, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ReportFocus.entries.forEach { option ->
                        val selected = focusKey == option.key
                        FilterChip(
                            selected = selected,
                            onClick = { focusKey = option.key },
                            label = { Text(option.label, fontSize = 11.sp) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = NotelPrimary.copy(alpha = 0.2f)
                            )
                        )
                    }
                }

                Text("Report range", color = NotelTextSecondary, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("last30days" to "Last 30 days", "sincelastmeeting" to "Since last meeting", "alltime" to "All time").forEach { (key, label) ->
                        val selected = rangeType == key
                        FilterChip(
                            selected = selected,
                            onClick = { rangeType = key },
                            label = { Text(label, fontSize = 11.sp) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = NotelPrimary.copy(alpha = 0.2f)
                            )
                        )
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = autoPrepare,
                        onCheckedChange = { autoPrepare = it },
                        colors = CheckboxDefaults.colors(checkedColor = NotelPrimary)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("Prepare a draft automatically", color = NotelTextPrimary, fontSize = 13.sp)
                }

                if (autoPrepare) {
                    Text("Preparation timing", color = NotelTextSecondary, fontSize = 12.sp)
                    Column {
                        REPORT_PREP_TIMINGS.forEach { (key, label) ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { prepTiming = key }
                                    .padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                RadioButton(
                                    selected = prepTiming == key,
                                    onClick = { prepTiming = key },
                                    colors = RadioButtonDefaults.colors(selectedColor = NotelPrimary)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(label, color = NotelTextPrimary, fontSize = 13.sp)
                            }
                        }
                    }
                    if (prepTiming != "reminder_only") {
                        GlassyButton(
                            onClick = { showPrepTimePicker = true },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Icon(Icons.Default.Schedule, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Prep time: $prepTimeOfDay (${zone.id})", color = NotelTextPrimary, fontSize = 13.sp)
                        }
                    }
                } else {
                    Text(
                        "Reminder-only: you will get the usual day-before nudge, but no draft is generated.",
                        color = NotelTextSecondary.copy(alpha = 0.75f), fontSize = 11.sp
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    if (name.isNotBlank()) {
                        onSave(
                            initial.copy(
                                name = name.trim(),
                                type = type,
                                dateTimeMs = dateTimeMs,
                                timezoneId = timezoneId.ifBlank { ZoneId.systemDefault().id },
                                focusKey = focusKey,
                                rangeType = rangeType,
                                autoPrepare = autoPrepare,
                                prepTiming = if (autoPrepare) prepTiming else "reminder_only",
                                prepTimeOfDay = prepTimeOfDay
                            )
                        )
                    }
                },
                enabled = name.isNotBlank()
            ) {
                Text("Save", color = NotelPrimary, fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = NotelTextSecondary)
            }
        }
    )

    if (showDatePicker) {
        val dpd = remember {
            DatePickerDialog(
                context,
                { _, y, m, d ->
                    val zdt = ZonedDateTime.ofInstant(Instant.ofEpochMilli(dateTimeMs), zone)
                        .withYear(y).withMonth(m + 1).withDayOfMonth(d)
                    dateTimeMs = zdt.toInstant().toEpochMilli()
                    showDatePicker = false
                },
                cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)
            ).apply { setOnDismissListener { showDatePicker = false } }
        }
        DisposableEffect(Unit) {
            dpd.show()
            onDispose { if (dpd.isShowing) dpd.dismiss() }
        }
    }
    if (showTimePicker) {
        val zdt0 = ZonedDateTime.ofInstant(Instant.ofEpochMilli(dateTimeMs), zone)
        val tpd = remember {
            TimePickerDialog(
                context,
                { _, h, m ->
                    val zdt = ZonedDateTime.ofInstant(Instant.ofEpochMilli(dateTimeMs), zone)
                        .withHour(h).withMinute(m).withSecond(0).withNano(0)
                    dateTimeMs = zdt.toInstant().toEpochMilli()
                    showTimePicker = false
                },
                zdt0.hour, zdt0.minute, false
            ).apply { setOnDismissListener { showTimePicker = false } }
        }
        DisposableEffect(Unit) {
            tpd.show()
            onDispose { if (tpd.isShowing) tpd.dismiss() }
        }
    }
    if (showPrepTimePicker) {
        val (ph, pm) = prepTimeOfDay.split(":").mapNotNull { it.toIntOrNull() }
            .let { parts -> if (parts.size == 2) parts[0] to parts[1] else 9 to 0 }
        val tpd = remember {
            TimePickerDialog(
                context,
                { _, h, m ->
                    prepTimeOfDay = "%02d:%02d".format(h, m)
                    showPrepTimePicker = false
                },
                ph, pm, false
            ).apply { setOnDismissListener { showPrepTimePicker = false } }
        }
        DisposableEffect(Unit) {
            tpd.show()
            onDispose { if (tpd.isShowing) tpd.dismiss() }
        }
    }
}
