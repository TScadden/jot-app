package com.notel.notel.ui.screen

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
import com.notel.notel.data.local.entity.Category
import com.notel.notel.ui.component.MedicalDisclaimerBanner
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.SettingsViewModel
import java.text.SimpleDateFormat
import java.util.*

/**
 * Progress Reports (Tabs Lab, playground only).
 *
 * Dedicated report screen that replaces the old AI Settings 30 day / all time
 * toggle. The report TYPE picker (Health / Training / Custom) only changes
 * which log categories feed the report; the underlying 30 day and all time
 * generators and the AI prompt are reused exactly as they are.
 */
enum class ReportFocus(val key: String, val label: String) {
    HEALTH("health", "Health"),
    TRAINING("training", "Training"),
    CUSTOM("custom", "Custom")
}

/** Category slugs bundled into each preset focus. */
private val HEALTH_SLUGS = setOf("symptoms", "medication", "sleep", "mood", "heart_rate")
private val TRAINING_SLUGS = setOf("personal", "heart_rate", "calories")

private fun resolveReportCategories(
    allCategories: List<Category>,
    focus: ReportFocus,
    customIds: Set<Int>
): List<Category> = when (focus) {
    ReportFocus.HEALTH -> allCategories.filter { it.slug in HEALTH_SLUGS }
    ReportFocus.TRAINING -> allCategories.filter { it.slug in TRAINING_SLUGS }
    ReportFocus.CUSTOM -> allCategories.filter { it.id in customIds }
}

private fun formatIsoDate(iso: String): String = try {
    val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.parse(iso)
    if (parsed != null) SimpleDateFormat("MMM d, yyyy", Locale.US).format(parsed) else iso
} catch (_: Exception) {
    iso
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProgressReportsScreen(
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val context = LocalContext.current

    var focus by remember { mutableStateOf(ReportFocus.HEALTH) }
    var last30Days by remember { mutableStateOf(true) }
    var customIds by remember { mutableStateOf<Set<Int>>(emptySet()) }

    val allLogs by viewModel.allLogs.collectAsState()
    val allCategories by viewModel.categories.collectAsState()
    val reportState by viewModel.reportGenerationState.collectAsState()
    val isDeepBusy by viewModel.isGeneratingDeepResearch.collectAsState()
    val isProtocolBusy by viewModel.isGeneratingWeeklyRecap.collectAsState()

    val savedAppointmentDate by viewModel.appointmentDate.collectAsState(initial = null)
    val savedAppointmentType by viewModel.appointmentReportType.collectAsState(initial = "health")

    var activeRange by remember { mutableStateOf<Boolean?>(null) }
    var showDatePicker by remember { mutableStateOf(false) }
    var pickedDateIso by remember { mutableStateOf<String?>(null) }
    var appointmentFocus by remember { mutableStateOf(ReportFocus.HEALTH) }

    val selectedCategories = remember(allCategories, focus, customIds) {
        resolveReportCategories(allCategories, focus, customIds)
    }
    val selectedIds = remember(selectedCategories) { selectedCategories.map { it.id }.toSet() }
    val cutoff = if (last30Days) System.currentTimeMillis() - 30L * 24 * 60 * 60 * 1000 else 0L
    val logsInRange = remember(allLogs, cutoff, selectedIds) {
        allLogs.filter { it.timestamp >= cutoff && it.categoryId in selectedIds }
    }
    val hourlyData = remember(logsInRange) {
        val cal = Calendar.getInstance()
        logsInRange.groupingBy {
            cal.timeInMillis = it.timestamp
            cal.get(Calendar.HOUR_OF_DAY)
        }.eachCount()
    }
    var selectedHour by remember { mutableStateOf<Int?>(null) }

    val hasAnyLogs = allLogs.isNotEmpty()
    val isGenerating = reportState.isProcessing
    val isAnyBusy = isGenerating || isDeepBusy || isProtocolBusy

    // Pre select all categories for Custom the first time it is opened.
    LaunchedEffect(focus, allCategories) {
        if (focus == ReportFocus.CUSTOM && customIds.isEmpty() && allCategories.isNotEmpty()) {
            customIds = allCategories.map { it.id }.toSet()
        }
    }

    LaunchedEffect(reportState) {
        val currentState = reportState
        if (currentState is com.notel.notel.ui.state.ReportGenerationState.Ready) {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                context,
                "${context.packageName}.provider",
                currentState.file
            )
            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = "application/pdf"
                putExtra(android.content.Intent.EXTRA_STREAM, uri)
                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(android.content.Intent.createChooser(intent, "Share Progress Report"))
            viewModel.resetReportGenerationState()
            activeRange = null
        } else if (!currentState.isProcessing) {
            activeRange = null
        }
    }

    // Renders inside the shared Settings scroll column; the outer Settings
    // top bar shows "Progress Reports" and its back button returns to
    // AI & Clinical Advocate.
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
            // ---------- One page overview ----------
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
                            val selected = focus == option
                            GlassyButton(
                                onClick = { focus = option },
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

                    if (focus == ReportFocus.CUSTOM) {
                        Spacer(Modifier.height(12.dp))
                        Text("Include these categories", color = NotelTextSecondary, fontSize = 12.sp)
                        Spacer(Modifier.height(8.dp))
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
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        listOf(true to "This Month", false to "All Time").forEach { (isMonth, label) ->
                            val selected = last30Days == isMonth
                            GlassyButton(
                                onClick = { last30Days = isMonth },
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
                            value = if (last30Days) "30" else "All",
                            label = "Days covered",
                            modifier = Modifier.weight(1f)
                        )
                    }

                    Spacer(Modifier.height(12.dp))
                    MedicalDisclaimerBanner()
                }
            }

            // ---------- Preview ----------
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    SectionLabel("Preview", color = NotelPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "${focus.label} report, ${if (last30Days) "this month" else "all time"}. " +
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
                                    activeRange = last30Days
                                    viewModel.generateProfessionalReport(
                                        last30DaysOnly = last30Days,
                                        forceRawFallback = true,
                                        categoriesOverride = selectedCategories
                                    )
                                }
                            ) {
                                Text("Generate Raw Data Report (Without AI)", color = NotelPrimary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                    }

                    val isThisGenerating = isGenerating && activeRange == last30Days
                    GlassyButton(
                        onClick = {
                            activeRange = last30Days
                            viewModel.generateProfessionalReport(
                                last30DaysOnly = last30Days,
                                categoriesOverride = selectedCategories
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
                }
            }

            // ---------- Details ----------
            if (selectedCategories.isNotEmpty()) {
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

            // ---------- Prepare for an appointment ----------
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
                        "Save the date and the report type you want ready for your visit.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    Spacer(Modifier.height(12.dp))

                    if (savedAppointmentDate != null) {
                        val typeLabel = ReportFocus.entries.firstOrNull { it.key == savedAppointmentType }?.label ?: "Health"
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
                                Column {
                                    Text(
                                        "Appointment: ${formatIsoDate(savedAppointmentDate!!)}",
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
                                TextButton(onClick = { viewModel.clearAppointment() }) {
                                    Text("Clear", color = NotelPrimary, fontSize = 12.sp)
                                }
                            }
                        }
                        Spacer(Modifier.height(12.dp))
                    }

                    GlassyButton(
                        onClick = { showDatePicker = true },
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
                            val selected = appointmentFocus == option
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

            Spacer(Modifier.height(8.dp))
    } // end content column

    if (showDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = System.currentTimeMillis()
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        datePickerState.selectedDateMillis?.let { millis ->
                            pickedDateIso = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                                timeZone = TimeZone.getTimeZone("UTC")
                            }.format(Date(millis))
                        }
                        showDatePicker = false
                    }
                ) { Text("OK", color = NotelPrimary) }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }
}

@Composable
private fun OverviewStat(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = NotelPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(label, color = NotelTextSecondary, fontSize = 11.sp, textAlign = TextAlign.Center)
    }
}
