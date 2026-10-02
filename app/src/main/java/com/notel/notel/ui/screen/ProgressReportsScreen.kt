package com.notel.notel.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.model.ReportFocus
import com.notel.notel.data.model.ReportRange
import com.notel.notel.data.model.resolveFocusCategoryIds
import com.notel.notel.ui.component.MedicalDisclaimerBanner
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.SettingsViewModel
import java.text.SimpleDateFormat
import java.util.*

/**
 * Progress Reports (Tabs Lab, playground only).
 *
 * Dedicated report screen. The report TYPE picker (Health / Training / Custom)
 * filters which log categories feed the report — focus reaches the real
 * collection pipeline (Phase 1, WS-F). Date windows: Last 30 days, All time,
 * Since last meeting, Custom range (Phase 1, WS-A). One snapshot feeds the AI
 * narrative and the PDF.
 */

private const val DAY_MS = 24 * 60 * 60 * 1000L

private fun formatIsoDate(iso: String): String = try {
    val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.parse(iso)
    if (parsed != null) SimpleDateFormat("MMM d, yyyy", Locale.US).format(parsed) else iso
} catch (_: Exception) {
    iso
}

private fun formatDateMs(ms: Long): String =
    SimpleDateFormat("MMM d, yyyy", Locale.US).format(Date(ms))

/** Parses an ISO yyyy-MM-dd date (UTC) to start-of-day millis, or null. */
private fun parseIsoToMs(iso: String): Long? = try {
    SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.parse(iso)?.time
} catch (_: Exception) {
    null
}

/** "today" / "tomorrow" / "in N days", or null when the date is past or unparsable. */
private fun appointmentCountdown(iso: String): String? = try {
    val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }
    val target = fmt.parse(iso)?.time ?: return null
    val today = fmt.parse(fmt.format(Date()))?.time ?: return null
    val days = ((target - today) / DAY_MS).toInt()
    when {
        days < 0 -> null
        days == 0 -> "today"
        days == 1 -> "tomorrow"
        else -> "in $days days"
    }
} catch (_: Exception) {
    null
}

/** Which date the single DatePickerDialog is currently editing. */
private enum class ReportDateTarget { APPOINTMENT, MEETING, CUSTOM_START, CUSTOM_END }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProgressReportsScreen(
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val context = LocalContext.current

    // Otto's feature: restore the last-used report type and range.
    val savedLastType by viewModel.lastReportType.collectAsState(initial = "health")
    val savedLastRangeKey by viewModel.lastReportRangeKey.collectAsState(initial = "last30days")
    val savedRangeStart by viewModel.lastReportRangeStart.collectAsState(initial = 0L)
    val savedRangeEnd by viewModel.lastReportRangeEnd.collectAsState(initial = 0L)
    val savedFocusText by viewModel.lastReportFocusText.collectAsState(initial = "")
    var userTouchedPrefs by remember { mutableStateOf(false) }

    var focusKey by remember { mutableStateOf("health") }
    var customFocusText by remember { mutableStateOf("") }
    var range by remember { mutableStateOf<ReportRange>(ReportRange.Last30Days) }
    var customIds by remember { mutableStateOf<Set<Int>>(emptySet()) }

    // Concrete dates behind the Since-last-meeting / Custom ranges.
    var meetingDateMs by remember { mutableStateOf<Long?>(null) }
    var customStartMs by remember { mutableStateOf<Long?>(null) }
    var customEndMs by remember { mutableStateOf<Long?>(null) }

    val focus = remember(focusKey, customFocusText) {
        ReportFocus.fromKey(focusKey, customFocusText)
    }

    val allLogs by viewModel.allLogs.collectAsState()
    val allCategories by viewModel.categories.collectAsState()
    val reportState by viewModel.reportGenerationState.collectAsState()
    val isDeepBusy by viewModel.isGeneratingDeepResearch.collectAsState()
    val isProtocolBusy by viewModel.isGeneratingWeeklyRecap.collectAsState()

    val savedAppointmentDate by viewModel.appointmentDate.collectAsState(initial = null)
    val savedAppointmentType by viewModel.appointmentReportType.collectAsState(initial = "health")

    // "Since last meeting" defaults to the saved appointment date when set.
    val defaultMeetingMs = remember(savedAppointmentDate) {
        savedAppointmentDate?.let { parseIsoToMs(it) } ?: (System.currentTimeMillis() - 30L * DAY_MS)
    }

    fun restoreRange(): ReportRange = when (savedLastRangeKey) {
        "alltime" -> ReportRange.AllTime
        "sincelastmeeting" -> ReportRange.SinceLastMeeting(
            if (savedRangeStart > 0L) savedRangeStart else defaultMeetingMs
        )
        "custom" -> if (savedRangeStart > 0L && savedRangeEnd >= savedRangeStart) {
            ReportRange.Custom(savedRangeStart, savedRangeEnd)
        } else {
            ReportRange.Custom(System.currentTimeMillis() - 30L * DAY_MS, System.currentTimeMillis())
        }
        else -> ReportRange.Last30Days
    }

    LaunchedEffect(savedLastType, savedLastRangeKey, savedRangeStart, savedRangeEnd, savedFocusText, savedAppointmentDate) {
        if (!userTouchedPrefs) {
            focusKey = savedLastType
            customFocusText = savedFocusText
            range = restoreRange()
            // Seed the date states from the restored range so the pickers show it.
            when (val r = range) {
                is ReportRange.SinceLastMeeting -> meetingDateMs = r.meetingDateEpochMs
                is ReportRange.Custom -> {
                    customStartMs = r.startEpochMs
                    customEndMs = r.endEpochMs
                }
                else -> Unit
            }
        }
    }
    LaunchedEffect(focusKey, range, customFocusText, userTouchedPrefs) {
        if (userTouchedPrefs) viewModel.saveLastReportPrefs(focusKey, range, customFocusText)
    }
    fun pickFocus(next: ReportFocus) {
        userTouchedPrefs = true
        focusKey = next.key
    }
    fun pickRange(next: ReportRange) {
        userTouchedPrefs = true
        range = next
    }
    fun pickRangeKind(kind: String) {
        val next = when (kind) {
            "alltime" -> ReportRange.AllTime
            "sincelastmeeting" -> ReportRange.SinceLastMeeting(meetingDateMs ?: defaultMeetingMs)
            "custom" -> ReportRange.Custom(
                customStartMs ?: (System.currentTimeMillis() - 30L * DAY_MS),
                customEndMs ?: System.currentTimeMillis()
            )
            else -> ReportRange.Last30Days
        }
        pickRange(next)
    }

    var activeRange by remember { mutableStateOf<ReportRange?>(null) }
    var datePickerTarget by remember { mutableStateOf<ReportDateTarget?>(null) }
    var pickedDateIso by remember { mutableStateOf<String?>(null) }
    var appointmentFocus by remember { mutableStateOf<ReportFocus>(ReportFocus.Health) }
    // Vera's feature: confirm before the share sheet; the PDF holds health data.
    var pendingShareFile by remember { mutableStateOf<java.io.File?>(null) }
    // Juno's feature: expandable data-source disclosure.
    var showSources by remember { mutableStateOf(false) }
    // Mira's feature: staggered card entrance.
    var cardsVisible by remember { mutableStateOf(false) }

    // Mason's feature: last successful export timestamp.
    val lastExportTime by viewModel.lastReportExportTime.collectAsState(initial = 0L)

    fun sharePdf(file: java.io.File) {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.provider",
            file
        )
        val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(android.content.Intent.EXTRA_STREAM, uri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(android.content.Intent.createChooser(intent, "Share Progress Report"))
        viewModel.markReportExported()
    }

    val clinicalRange = remember(range) { range.toClinicalReportRange(System.currentTimeMillis()) }
    val selectedCategories = remember(allCategories, focus, customIds) {
        val ids = resolveFocusCategoryIds(allCategories, focus, customIds)
        allCategories.filter { it.id in ids }
    }
    val selectedIds = remember(selectedCategories) { selectedCategories.map { it.id }.toSet() }
    val logsInRange = remember(allLogs, clinicalRange, selectedIds) {
        allLogs.filter {
            it.timestamp >= clinicalRange.startEpochMs &&
                it.timestamp <= clinicalRange.endEpochMs &&
                it.categoryId in selectedIds
        }
    }
    val hourlyData = remember(logsInRange) {
        val cal = Calendar.getInstance()
        logsInRange.groupingBy {
            cal.timeInMillis = it.timestamp
            cal.get(Calendar.HOUR_OF_DAY)
        }.eachCount()
    }
    var selectedHour by remember { mutableStateOf<Int?>(null) }

    // Tess's feature: honest data coverage. Distinct days with entries in
    // range, over the days the range covers. Phase 1 (WS-A): the denominator
    // is the actual range span — the old 180-day cap is gone, and All time
    // uses the real span of stored history.
    val distinctDaysLogged = remember(logsInRange) {
        logsInRange.map { it.timestamp / DAY_MS }.toSet().size
    }
    val coverageDenominator = remember(allLogs, range, clinicalRange) {
        when (range) {
            ReportRange.Last30Days -> 30
            ReportRange.AllTime -> {
                val oldest = allLogs.minOfOrNull { it.timestamp } ?: System.currentTimeMillis()
                (((System.currentTimeMillis() - oldest) / DAY_MS) + 1).toInt().coerceAtLeast(1)
            }
            else -> clinicalRange.durationDays
        }
    }
    val daysCoveredLabel = when (range) {
        ReportRange.Last30Days -> "30"
        ReportRange.AllTime -> "All"
        else -> clinicalRange.durationDays.toString()
    }

    val hasAnyLogs = allLogs.isNotEmpty()
    val isGenerating = reportState.isProcessing
    val isAnyBusy = isGenerating || isDeepBusy || isProtocolBusy

    // Pre select all categories for Custom the first time it is opened.
    LaunchedEffect(focusKey, allCategories) {
        if (focusKey == "custom" && customIds.isEmpty() && allCategories.isNotEmpty()) {
            customIds = allCategories.map { it.id }.toSet()
        }
    }

    LaunchedEffect(reportState) {
        val currentState = reportState
        if (currentState is com.notel.notel.ui.state.ReportGenerationState.Ready) {
            // Vera's feature: hold the file for an explicit share confirmation
            // instead of opening the share sheet unprompted.
            pendingShareFile = currentState.file
            viewModel.resetReportGenerationState()
            activeRange = null
        } else if (!currentState.isProcessing) {
            activeRange = null
        }
    }

    // Mira's feature: cards fade and rise in, staggered.
    LaunchedEffect(Unit) { cardsVisible = true }

    // Renders inside the shared Settings scroll column; the outer Settings
    // top bar shows "Progress Reports" and its back button returns to
    // AI & Clinical Advocate.
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
            // ---------- One page overview ----------
            ReportCard(visible = cardsVisible, delayMillis = 0) {
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    SectionLabel("Report type", color = NotelPrimary)
                    Spacer(Modifier.height(8.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        ReportFocus.entries.forEach { option ->
                            val selected = focusKey == option.key
                            GlassyButton(
                                onClick = { pickFocus(option) },
                                modifier = Modifier.weight(1f),
                                containerColor = if (selected) NotelPrimary.copy(alpha = 0.18f) else NotelSurfaceHigh
                            ) {
                                Text(
                                    option.label,
                                    color = if (selected) NotelPrimary else NotelTextSecondary,
                                    fontSize = 13.sp,
                                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                    maxLines = 1
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        focus.description,
                        color = NotelTextSecondary.copy(alpha = 0.75f),
                        fontSize = 11.sp
                    )

                    if (focusKey == "custom") {
                        Spacer(Modifier.height(8.dp))
                        OutlinedTextField(
                            value = customFocusText,
                            onValueChange = {
                                customFocusText = it
                                userTouchedPrefs = true
                            },
                            label = { Text("Describe your focus (optional)", fontSize = 12.sp) },
                            placeholder = { Text("e.g. migraine triggers and sleep", fontSize = 12.sp) },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = NotelPrimary,
                                focusedLabelColor = NotelPrimary,
                                cursorColor = NotelPrimary
                            )
                        )
                        Spacer(Modifier.height(12.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Include these categories", color = NotelTextSecondary, fontSize = 12.sp)
                            Row {
                                TextButton(onClick = { customIds = allCategories.map { it.id }.toSet() }) {
                                    Text("Select all", color = NotelPrimary, fontSize = 12.sp)
                                }
                                TextButton(onClick = { customIds = emptySet() }) {
                                    Text("Clear", color = NotelTextSecondary, fontSize = 12.sp)
                                }
                            }
                        }
                        Spacer(Modifier.height(4.dp))
                        allCategories.forEach { category ->
                            val checked = category.id in customIds
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        customIds = if (checked) customIds - category.id else customIds + category.id
                                    }
                                    .padding(vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Checkbox(
                                    checked = checked,
                                    onCheckedChange = null,
                                    colors = CheckboxDefaults.colors(checkedColor = NotelPrimary)
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(category.name, color = NotelTextPrimary, fontSize = 14.sp)
                            }
                        }
                    }

                    Spacer(Modifier.height(12.dp))
                    SectionLabel("Time range", color = NotelPrimary)
                    Spacer(Modifier.height(8.dp))
                    // Phase 1 (WS-A): Last 30 days / All time / Since last
                    // meeting / Custom range. "This Month" was renamed — it
                    // was always rolling-30 semantics.
                    val rangeKinds = listOf(
                        "last30days" to "Last 30 days",
                        "alltime" to "All time",
                        "sincelastmeeting" to "Since last meeting",
                        "custom" to "Custom"
                    )
                    val currentKind = range.prefsKey
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        rangeKinds.chunked(2).forEach { rowKinds ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                rowKinds.forEach { (kind, label) ->
                                    val selected = currentKind == kind
                                    GlassyButton(
                                        onClick = { pickRangeKind(kind) },
                                        modifier = Modifier.weight(1f),
                                        containerColor = if (selected) NotelPrimary.copy(alpha = 0.18f) else NotelSurfaceHigh
                                    ) {
                                        Text(
                                            label,
                                            color = if (selected) NotelPrimary else NotelTextSecondary,
                                            fontSize = 13.sp,
                                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                            maxLines = 1
                                        )
                                    }
                                }
                                if (rowKinds.size == 1) Spacer(Modifier.weight(1f))
                            }
                        }
                    }

                    // Date controls for the meeting/custom ranges.
                    val meetingRange = range as? ReportRange.SinceLastMeeting
                    if (meetingRange != null) {
                        Spacer(Modifier.height(8.dp))
                        GlassyButton(
                            onClick = { datePickerTarget = ReportDateTarget.MEETING },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Icon(Icons.Default.CalendarMonth, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "Last meeting: ${formatDateMs(meetingDateMs ?: meetingRange.meetingDateEpochMs)}",
                                color = NotelTextPrimary,
                                fontSize = 13.sp
                            )
                        }
                    }
                    val customRange = range as? ReportRange.Custom
                    if (customRange != null) {
                        Spacer(Modifier.height(8.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            GlassyButton(
                                onClick = { datePickerTarget = ReportDateTarget.CUSTOM_START },
                                modifier = Modifier.weight(1f),
                                containerColor = NotelSurfaceHigh
                            ) {
                                Text(
                                    "Start: ${formatDateMs(customStartMs ?: customRange.startEpochMs)}",
                                    color = NotelTextPrimary,
                                    fontSize = 12.sp,
                                    maxLines = 1
                                )
                            }
                            GlassyButton(
                                onClick = { datePickerTarget = ReportDateTarget.CUSTOM_END },
                                modifier = Modifier.weight(1f),
                                containerColor = NotelSurfaceHigh
                            ) {
                                Text(
                                    "End: ${formatDateMs(customEndMs ?: customRange.endEpochMs)}",
                                    color = NotelTextPrimary,
                                    fontSize = 12.sp,
                                    maxLines = 1
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(16.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly
                    ) {
                        OverviewStat(
                            value = logsInRange.size.toString(),
                            label = "Entries",
                            modifier = Modifier.weight(1f)
                        )
                        OverviewStat(
                            value = selectedCategories.size.toString(),
                            label = "Categories",
                            modifier = Modifier.weight(1f)
                        )
                        OverviewStat(
                            value = daysCoveredLabel,
                            label = "Days covered",
                            modifier = Modifier.weight(1f)
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Logged $distinctDaysLogged of $coverageDenominator days",
                        color = NotelTextSecondary.copy(alpha = 0.75f),
                        fontSize = 11.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )

                    Spacer(Modifier.height(12.dp))
                    MedicalDisclaimerBanner()
                }
            }
            }

            // ---------- Preview ----------
            ReportCard(visible = cardsVisible, delayMillis = 90) {
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    SectionLabel("Preview", color = NotelPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "${focus.label} report, ${range.label.replaceFirstChar { it.lowercase() }}. " +
                            "${logsInRange.size} entries across ${selectedCategories.size} categories.",
                        color = NotelTextSecondary,
                        fontSize = 13.sp
                    )

                    if (logsInRange.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        Text("Log activity by hour", color = NotelTextPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        Box(modifier = Modifier.fillMaxWidth().height(210.dp)) {
                            HourlyDensityChart(
                                data = hourlyData,
                                selectedHour = selectedHour,
                                onHourSelected = { selectedHour = if (selectedHour == it) null else it }
                            )
                        }
                    } else {
                        Spacer(Modifier.height(12.dp))
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(
                                Icons.Default.BarChart,
                                null,
                                tint = NotelTextSecondary.copy(alpha = 0.5f),
                                modifier = Modifier.size(40.dp)
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                if (selectedCategories.isEmpty()) "No categories selected"
                                else "Nothing to preview yet",
                                color = NotelTextPrimary,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                if (selectedCategories.isEmpty()) "Pick at least one category above to see a preview."
                                else "Log symptoms, meds, or sleep and your activity will show up here.",
                                color = NotelTextSecondary.copy(alpha = 0.7f),
                                fontSize = 12.sp,
                                textAlign = TextAlign.Center
                            )
                        }
                    }

                    Spacer(Modifier.height(12.dp))

                    if (reportState.isProcessing) {
                        val stageLabel = when (val s = reportState) {
                            is com.notel.notel.ui.state.ReportGenerationState.CollectingData -> s.stageLabel
                            is com.notel.notel.ui.state.ReportGenerationState.RefreshingHealthData -> s.stageLabel
                            is com.notel.notel.ui.state.ReportGenerationState.BuildingSummary -> s.stageLabel
                            is com.notel.notel.ui.state.ReportGenerationState.RenderingPdf -> s.stageLabel
                            is com.notel.notel.ui.state.ReportGenerationState.SavingFile -> s.stageLabel
                            else -> "Generating report..."
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            GlassySpinner(size = 18.dp)
                            Spacer(Modifier.width(10.dp))
                            Text(stageLabel, color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                        }
                        Spacer(Modifier.height(8.dp))
                        TextButton(
                            onClick = { viewModel.cancelReportGeneration() },
                            modifier = Modifier.align(Alignment.CenterHorizontally)
                        ) {
                            Text("Cancel Report Generation", color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
                        }
                    }

                    if (reportState is com.notel.notel.ui.state.ReportGenerationState.Failed) {
                        val failedState = reportState as com.notel.notel.ui.state.ReportGenerationState.Failed
                        Text(failedState.message, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                        if (failedState.allowRawFallback) {
                            TextButton(
                                onClick = {
                                    activeRange = range
                                    viewModel.generateProfessionalReport(
                                        range = range,
                                        focus = focus,
                                        customCategoryIds = customIds,
                                        forceRawFallback = true
                                    )
                                }
                            ) {
                                Text("Generate Raw Data Report (Without AI)", color = NotelPrimary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                    }

                    val isThisGenerating = isGenerating && activeRange == range
                    GlassyButton(
                        onClick = {
                            activeRange = range
                            viewModel.generateProfessionalReport(
                                range = range,
                                focus = focus,
                                customCategoryIds = customIds
                            )
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !isAnyBusy && hasAnyLogs && selectedCategories.isNotEmpty(),
                        containerColor = NotelPrimary
                    ) {
                        if (isThisGenerating) {
                            GlassySpinner(size = 18.dp)
                        } else {
                            Icon(Icons.Default.PictureAsPdf, null, tint = NotelTextPrimary, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Export PDF Report", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    if (!hasAnyLogs) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Add some notes first to generate a report.",
                            color = NotelTextSecondary.copy(alpha = 0.5f),
                            fontSize = 11.sp
                        )
                    }

                    // Mason's feature: when the last report was exported.
                    if (lastExportTime > 0L) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Last exported ${SimpleDateFormat("MMM d, h:mm a", Locale.US).format(Date(lastExportTime))}",
                            color = NotelTextSecondary.copy(alpha = 0.6f),
                            fontSize = 11.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }

                    // Juno's feature: honest disclosure of what feeds the report.
                    Spacer(Modifier.height(8.dp))
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { showSources = !showSources }
                            .padding(vertical = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("What's in this report", color = NotelTextSecondary, fontSize = 12.sp)
                        Icon(
                            if (showSources) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                            null,
                            tint = NotelTextSecondary,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                    if (showSources) {
                        Spacer(Modifier.height(4.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            ReportSourceRow(
                                "Your logged entries",
                                "Symptoms, meds, sleep, and notes you recorded"
                            )
                            ReportSourceRow(
                                "Health Connect biometrics",
                                "Heart rate, sleep, and activity from your device"
                            )
                            ReportSourceRow(
                                "AI generated summary",
                                "Written by AI from your data. Informational only, not medical advice."
                            )
                            if (focusKey == "training") {
                                ReportSourceRow(
                                    "Training data gap",
                                    "Tabs has no distance, pace, or duration sensors. Training details come from what you logged; the report says so when volume can't be determined."
                                )
                            }
                        }
                    }
                }
            }
            }

            // ---------- Details ----------
            if (selectedCategories.isNotEmpty()) {
                ReportCard(visible = cardsVisible, delayMillis = 180) {
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        SectionLabel("Details", color = NotelPrimary)
                        Spacer(Modifier.height(12.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            val total = logsInRange.size.coerceAtLeast(1)
                            selectedCategories.forEach { category ->
                                val count = logsInRange.count { it.categoryId == category.id }
                                CategoryProgressRow(
                                    name = category.name,
                                    count = count,
                                    total = total,
                                    colorHex = category.colorHex
                                )
                            }
                        }
                    }
                }
                }
            }

            // ---------- Prepare for an appointment ----------
            ReportCard(visible = cardsVisible, delayMillis = 270) {
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
                        Text("Prepare for an appointment", color = NotelTextPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Save the date and the report type you want ready for your visit. We will remind you the day before to export it.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    Spacer(Modifier.height(12.dp))

                    if (savedAppointmentDate != null) {
                        val typeLabel = ReportFocus.entries.firstOrNull { it.key == savedAppointmentType }?.label ?: "Health"
                        val countdown = appointmentCountdown(savedAppointmentDate!!)
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = NotelPrimary.copy(alpha = 0.12f),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        "Appointment: ${formatIsoDate(savedAppointmentDate!!)}" +
                                            (countdown?.let { " ($it)" } ?: ""),
                                        color = NotelTextPrimary,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        "$typeLabel report saved",
                                        color = NotelTextSecondary,
                                        fontSize = 12.sp
                                    )
                                }
                                Column(horizontalAlignment = Alignment.End) {
                                    TextButton(
                                        onClick = {
                                            ReportFocus.entries.firstOrNull { it.key == savedAppointmentType }
                                                ?.let { pickFocus(it) }
                                        }
                                    ) {
                                        Text("Use this type", color = NotelPrimary, fontSize = 12.sp)
                                    }
                                    TextButton(onClick = { viewModel.clearAppointment() }) {
                                        Text("Clear", color = NotelTextSecondary, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                        Spacer(Modifier.height(12.dp))
                    }

                    GlassyButton(
                        onClick = { datePickerTarget = ReportDateTarget.APPOINTMENT },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Icon(Icons.Default.CalendarMonth, null, tint = NotelPrimary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            pickedDateIso?.let { "Visit on ${formatIsoDate(it)}" } ?: "Pick a date",
                            color = NotelTextPrimary,
                            fontSize = 13.sp
                        )
                    }

                    Spacer(Modifier.height(10.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        ReportFocus.entries.forEach { option ->
                            val selected = appointmentFocus.key == option.key
                            GlassyButton(
                                onClick = { appointmentFocus = option },
                                modifier = Modifier.weight(1f),
                                containerColor = if (selected) NotelPrimary.copy(alpha = 0.18f) else NotelSurfaceHigh
                            ) {
                                Text(
                                    option.label,
                                    color = if (selected) NotelPrimary else NotelTextSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                    maxLines = 1
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(12.dp))
                    GlassyButton(
                        onClick = {
                            val date = pickedDateIso
                            if (date != null) {
                                viewModel.saveAppointment(date, appointmentFocus.key)
                                pickedDateIso = null
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = pickedDateIso != null,
                        containerColor = NotelPrimary
                    ) {
                        Text("Save appointment", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            }

            Spacer(Modifier.height(8.dp))
    } // end content column

    // One DatePickerDialog serving the appointment, meeting-date, and custom
    // start/end pickers (Phase 1, WS-A).
    val target = datePickerTarget
    if (target != null) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = System.currentTimeMillis()
        )
        DatePickerDialog(
            onDismissRequest = { datePickerTarget = null },
            confirmButton = {
                TextButton(
                    onClick = {
                        datePickerState.selectedDateMillis?.let { millis ->
                            when (target) {
                                ReportDateTarget.APPOINTMENT -> {
                                    pickedDateIso = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                                        timeZone = TimeZone.getTimeZone("UTC")
                                    }.format(Date(millis))
                                }
                                ReportDateTarget.MEETING -> {
                                    meetingDateMs = millis
                                    pickRange(ReportRange.SinceLastMeeting(millis))
                                }
                                ReportDateTarget.CUSTOM_START -> {
                                    customStartMs = millis
                                    pickRange(
                                        ReportRange.Custom(
                                            millis,
                                            customEndMs ?: System.currentTimeMillis()
                                        )
                                    )
                                }
                                ReportDateTarget.CUSTOM_END -> {
                                    // End of the picked day so the range covers it fully.
                                    val endMs = millis + DAY_MS - 1
                                    customEndMs = endMs
                                    pickRange(
                                        ReportRange.Custom(
                                            customStartMs ?: (System.currentTimeMillis() - 30L * DAY_MS),
                                            endMs
                                        )
                                    )
                                }
                            }
                        }
                        datePickerTarget = null
                    }
                ) { Text("OK", color = NotelPrimary) }
            },
            dismissButton = {
                TextButton(onClick = { datePickerTarget = null }) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }

    // Vera's feature: explicit confirmation before the share sheet. The PDF
    // holds health data, so it never opens the share sheet unprompted.
    if (pendingShareFile != null) {
        val file = pendingShareFile!!
        AlertDialog(
            onDismissRequest = { pendingShareFile = null },
            title = {
                Text("Share health report", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold)
            },
            text = {
                Column {
                    Text(
                        "This PDF contains your health data. Only share it with people you trust.",
                        color = NotelTextSecondary,
                        fontSize = 13.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(file.name, color = NotelTextPrimary, fontSize = 12.sp)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "For informational purposes only. Not medical advice.",
                        color = NotelTextSecondary.copy(alpha = 0.7f),
                        fontSize = 11.sp
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { sharePdf(file); pendingShareFile = null }) {
                    Text("Share", color = NotelPrimary, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingShareFile = null }) {
                    Text("Not now", color = NotelTextSecondary)
                }
            }
        )
    }
}

@Composable
private fun OverviewStat(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = NotelPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(label, color = NotelTextSecondary, fontSize = 11.sp, textAlign = TextAlign.Center)
    }
}

/**
 * Mira's feature: staggered card entrance. Fade plus a short rise, each card
 * delayed after the previous. Motion only; the purple system is untouched.
 */
@Composable
private fun ReportCard(
    visible: Boolean,
    delayMillis: Int,
    content: @Composable () -> Unit
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(animationSpec = tween(450, delayMillis = delayMillis)) +
            slideInVertically(
                animationSpec = tween(450, delayMillis = delayMillis),
                initialOffsetY = { it / 5 }
            )
    ) {
        Box(modifier = Modifier.fillMaxWidth()) { content() }
    }
}

/** Juno's feature: one row of the "What's in this report" disclosure. */
@Composable
private fun ReportSourceRow(title: String, detail: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            Icons.Default.CheckCircle,
            null,
            tint = NotelPrimary.copy(alpha = 0.7f),
            modifier = Modifier.size(16.dp).padding(top = 2.dp)
        )
        Spacer(Modifier.width(8.dp))
        Column {
            Text(title, color = NotelTextPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Text(detail, color = NotelTextSecondary, fontSize = 12.sp)
        }
    }
}
