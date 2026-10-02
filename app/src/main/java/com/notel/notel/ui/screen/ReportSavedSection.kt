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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.data.local.entity.SavedReport
import com.notel.notel.data.model.ClinicalReportData
import com.notel.notel.data.model.ReportFocus
import com.notel.notel.data.model.buildFindings
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.SettingsViewModel
import com.notel.notel.util.ReportSections
import java.text.SimpleDateFormat
import java.util.*

private fun savedDateLabel(ms: Long): String =
    SimpleDateFormat("MMM d, yyyy", Locale.US).format(Date(ms))

private fun savedDateTimeLabel(ms: Long): String =
    SimpleDateFormat("MMM d, h:mm a", Locale.US).format(Date(ms))

private val sectionLabels = mapOf(
    ReportSections.FINDINGS to "Key findings",
    ReportSections.CHARTS to "Charts",
    ReportSections.EVENTS to "Recorded changes",
    ReportSections.TABLES to "Medications & conditions",
    ReportSections.APPENDIX to "Appendix (methodology + logs)"
)

/**
 * WS-G preview fidelity: what the export will include, editable narrative
 * notes (overlay only — never mutate records or calculated values), the
 * deterministic findings with their evidence, and a read-only review of
 * the profile/medications feeding the report.
 */
@Composable
fun ReportCustomizeCard(
    viewModel: SettingsViewModel,
    preview: ClinicalReportData?
) {
    val config by viewModel.reportPreviewConfig.collectAsState()
    var showNotes by remember { mutableStateOf(false) }
    var showProfile by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            SectionLabel("Customize report", color = NotelPrimary)
            Spacer(Modifier.height(4.dp))
            Text(
                "Choose which sections the PDF includes. Your notes appear as labeled boxes — they never change your records or the calculated numbers.",
                color = NotelTextSecondary,
                fontSize = 12.sp
            )
            Spacer(Modifier.height(8.dp))
            sectionLabels.forEach { (key, label) ->
                val checked = key in config.includedSections
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { viewModel.toggleReportSection(key) }
                        .padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Checkbox(
                        checked = checked,
                        onCheckedChange = null,
                        colors = CheckboxDefaults.colors(checkedColor = NotelPrimary)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(label, color = NotelTextPrimary, fontSize = 14.sp)
                }
            }

            Spacer(Modifier.height(8.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showNotes = !showNotes }
                    .padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Your notes on each section", color = NotelTextSecondary, fontSize = 13.sp)
                Icon(
                    if (showNotes) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    null, tint = NotelTextSecondary, modifier = Modifier.size(18.dp)
                )
            }
            if (showNotes) {
                Spacer(Modifier.height(4.dp))
                (sectionLabels - ReportSections.APPENDIX).forEach { (key, label) ->
                    var draft by remember(config.highlightOverrides[key]) {
                        mutableStateOf(config.highlightOverrides[key] ?: "")
                    }
                    OutlinedTextField(
                        value = draft,
                        onValueChange = {
                            draft = it
                            viewModel.setReportHighlight(key, it)
                        },
                        label = { Text("Note for: $label", fontSize = 12.sp) },
                        placeholder = { Text("e.g. discuss this with Dr. Richards", fontSize = 12.sp) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = NotelPrimary,
                            focusedLabelColor = NotelPrimary,
                            cursorColor = NotelPrimary
                        )
                    )
                }
            }

            Spacer(Modifier.height(8.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showProfile = !showProfile }
                    .padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Review profile & medications", color = NotelTextSecondary, fontSize = 13.sp)
                Icon(
                    if (showProfile) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    null, tint = NotelTextSecondary, modifier = Modifier.size(18.dp)
                )
            }
            if (showProfile) {
                Spacer(Modifier.height(4.dp))
                if (preview == null) {
                    Text("Loading…", color = NotelTextSecondary, fontSize = 12.sp)
                } else {
                    val bits = listOfNotNull(
                        preview.userAge.takeIf { it > 0 }?.let { "$it y/o" },
                        preview.userGender.takeIf { it.isNotBlank() },
                        preview.conditions.takeIf { it.isNotEmpty() }?.joinToString(", ")
                            ?.let { "Conditions: $it" }
                    )
                    Text(
                        if (bits.isNotEmpty()) bits.joinToString(" · ") else "No profile details on file.",
                        color = NotelTextPrimary, fontSize = 13.sp
                    )
                    Spacer(Modifier.height(6.dp))
                    if (preview.medications.isEmpty()) {
                        Text("No medications on file.", color = NotelTextSecondary, fontSize = 12.sp)
                    } else {
                        preview.medications.forEach { m ->
                            Text(
                                "• ${m.name.ifBlank { "Unnamed" }}${m.dose.ifBlank { "" }.let { if (it.isNotBlank()) " $it" else "" }}",
                                color = NotelTextPrimary, fontSize = 13.sp
                            )
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Edit these in Settings → Profile and Medications. The report never edits your records.",
                        color = NotelTextSecondary.copy(alpha = 0.7f), fontSize = 11.sp
                    )
                }
            }

            // Deterministic findings with evidence, before export.
            val findings = remember(preview) { preview?.let { buildFindings(it) }.orEmpty() }
            if (findings.isNotEmpty() && ReportSections.FINDINGS in config.includedSections) {
                Spacer(Modifier.height(12.dp))
                Text("Findings in this report", color = NotelTextPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(6.dp))
                findings.forEachIndexed { i, f ->
                    Text("${i + 1}. ${f.text}", color = NotelTextPrimary, fontSize = 13.sp)
                    Text(
                        f.evidence, color = NotelTextSecondary.copy(alpha = 0.75f), fontSize = 11.sp,
                        modifier = Modifier.padding(start = 12.dp, bottom = 6.dp)
                    )
                }
            }
        }
    }
}

/**
 * WS-G saved reports list: open / share / delete / refresh. A refresh
 * regenerates from the stored range/focus and records a NEW version —
 * nothing is ever overwritten. Missing files get an honest state.
 */
@Composable
fun SavedReportsCard(
    viewModel: SettingsViewModel,
    onShare: (SavedReport) -> Unit,
    eventNameFor: (String?) -> String? = { null }
) {
    val saved by viewModel.savedReports.collectAsState()
    var missingIds by remember { mutableStateOf(setOf<Long>()) }
    var confirmDelete by remember { mutableStateOf<SavedReport?>(null) }

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.FolderOpen, null, tint = NotelPrimary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    "Saved reports",
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "Every export is kept here. Refresh creates a new version — nothing is overwritten.",
                color = NotelTextSecondary,
                fontSize = 12.sp
            )
            Spacer(Modifier.height(8.dp))

            if (saved.isEmpty()) {
                Text(
                    "No saved reports yet. Export a PDF above and it will appear here.",
                    color = NotelTextSecondary.copy(alpha = 0.7f),
                    fontSize = 12.sp
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    saved.forEach { report ->
                        val missing = report.pdfUri.isNullOrBlank() || report.id in missingIds
                        val focusLabel = ReportFocus.fromKey(report.focusKey).label
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = NotelSurfaceHigh,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(modifier = Modifier.padding(12.dp)) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            "${report.title} · v${report.version}",
                                            color = NotelTextPrimary,
                                            fontSize = 14.sp,
                                            fontWeight = FontWeight.Medium
                                        )
                                        Text(
                                            "$focusLabel · ${savedDateLabel(report.rangeStartMs)} – ${savedDateLabel(report.rangeEndMs)}",
                                            color = NotelTextSecondary,
                                            fontSize = 12.sp
                                        )
                                        Text(
                                            "Generated ${savedDateTimeLabel(report.generatedAtMs)}" +
                                                (eventNameFor(report.eventId)?.let { " · for $it" } ?: "") +
                                                (if (report.isRawFallback) " · raw data" else "") +
                                                (if (report.isSynthetic) " · SYNTHETIC" else ""),
                                            color = NotelTextSecondary.copy(alpha = 0.7f),
                                            fontSize = 11.sp
                                        )
                                    }
                                }
                                if (missing) {
                                    Spacer(Modifier.height(6.dp))
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(
                                            Icons.Default.WarningAmber, null,
                                            tint = NotelWarning, modifier = Modifier.size(16.dp)
                                        )
                                        Spacer(Modifier.width(6.dp))
                                        Text(
                                            "File unavailable — the PDF is no longer in Downloads.",
                                            color = NotelWarning, fontSize = 12.sp
                                        )
                                    }
                                }
                                Spacer(Modifier.height(8.dp))
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    TextButton(
                                        onClick = {
                                            viewModel.openSavedReport(report) {
                                                missingIds = missingIds + report.id
                                            }
                                        },
                                        enabled = !missing
                                    ) {
                                        Text("Open", color = if (missing) NotelTextSecondary else NotelPrimary, fontSize = 12.sp)
                                    }
                                    TextButton(
                                        onClick = { onShare(report) },
                                        enabled = !missing
                                    ) {
                                        Text("Share", color = if (missing) NotelTextSecondary else NotelPrimary, fontSize = 12.sp)
                                    }
                                    TextButton(onClick = { viewModel.refreshSavedReport(report) }) {
                                        Text("Refresh", color = NotelPrimary, fontSize = 12.sp)
                                    }
                                    Spacer(Modifier.weight(1f))
                                    TextButton(onClick = { confirmDelete = report }) {
                                        Text("Delete", color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    val doomed = confirmDelete
    if (doomed != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete saved report?", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    "This removes \"${doomed.title} · v${doomed.version}\" from the list. The PDF file itself stays in your Downloads.",
                    color = NotelTextSecondary, fontSize = 13.sp
                )
            },
            confirmButton = {
                TextButton(onClick = { viewModel.deleteSavedReport(doomed); confirmDelete = null }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = null }) {
                    Text("Keep", color = NotelTextSecondary)
                }
            }
        )
    }
}

/**
 * Lab-only (TABS_LAB builds): generates clearly-marked SYNTHETIC sample
 * PDFs (Health / Training / Custom sparse / 2-year history) into Downloads
 * for on-device layout review. Never touches real data.
 */
@Composable
fun LabSamplePdfsCard(viewModel: SettingsViewModel) {
    val result by viewModel.labSampleResult.collectAsState()
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(result) {
        if (result != null && !result!!.startsWith("Generating")) busy = false
    }

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        modifier = Modifier.fillMaxWidth(),
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelWarning.copy(alpha = 0.4f))
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Science, null, tint = NotelWarning, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    "Lab: synthetic sample PDFs",
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "Generates 4 clearly-watermarked SYNTHETIC sample PDFs (Health 30d, Training 30d, Custom sparse, Health 2-year) into Downloads. Fabricated data only — no real health data is used.",
                color = NotelTextSecondary,
                fontSize = 12.sp
            )
            Spacer(Modifier.height(12.dp))
            GlassyButton(
                onClick = {
                    busy = true
                    viewModel.generateLabSamplePdfs()
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !busy,
                containerColor = NotelWarning.copy(alpha = 0.25f)
            ) {
                if (busy) {
                    GlassySpinner(size = 18.dp)
                } else {
                    Icon(Icons.Default.PictureAsPdf, null, tint = NotelWarning, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Generate synthetic samples", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
            }
            if (result != null) {
                Spacer(Modifier.height(8.dp))
                Text(result!!, color = NotelTextSecondary, fontSize = 12.sp)
            }
        }
    }
}
