package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.SyncopeEvent
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.viewmodel.SyncopeViewModel
import kotlinx.serialization.json.Json
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val PRODROME_OPTIONS = listOf(
    "Tunnel vision", "Nausea", "Ringing ears", "Sweating",
    "Dizziness", "Pale", "Clammy", "Blackout", "Rapid heartbeat"
)

/**
 * Tabs Lab: fast syncope / near-syncope capture. One screen, big targets:
 * type toggle, prodrome multi-select chips, posture at onset, location,
 * recovery time. Saves in one tap; HR around the event auto-attaches from
 * Health Connect when available.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SyncopeScreen(
    viewModel: SyncopeViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val events by viewModel.allEvents.collectAsState()
    val justLogged by viewModel.justLogged.collectAsState()

    var type by remember { mutableStateOf("NEAR") }
    var prodromes by remember { mutableStateOf(setOf<String>()) }
    var posture by remember { mutableStateOf("STANDING") }
    var location by remember { mutableStateOf("HOME") }
    var recovery by remember { mutableStateOf(5) }
    var notes by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }

    if (justLogged) {
        LaunchedEffect(Unit) {
            viewModel.consumeJustLogged()
            saving = false
            onBack()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Log faint episode") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            contentPadding = PaddingValues(top = 8.dp, bottom = 32.dp)
        ) {
            item {
                SegmentedPair(
                    label = "What happened",
                    left = "Near-syncope" to "NEAR",
                    right = "Full syncope" to "FULL",
                    selected = type,
                    onSelect = { type = it }
                )
            }
            item {
                Text("Prodromes (tap all that apply)", fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = NotelTextPrimary)
                Spacer(Modifier.height(8.dp))
                ProdromeChips(selected = prodromes, onToggle = { label ->
                    prodromes = if (prodromes.contains(label)) prodromes - label else prodromes + label
                })
            }
            item {
                SegmentedTriple(
                    label = "Posture at onset",
                    options = listOf("Standing" to "STANDING", "Sitting" to "SITTING", "Lying" to "LYING"),
                    selected = posture,
                    onSelect = { posture = it }
                )
            }
            item {
                SegmentedPair(
                    label = "Where",
                    left = "Home" to "HOME",
                    right = "Out" to "OUT",
                    selected = location,
                    onSelect = { location = it }
                )
            }
            item {
                Text("Recovery time", fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = NotelTextPrimary)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    listOf(1, 5, 10, 15, 30).forEach { mins ->
                        SelectableChip(
                            label = "${mins}m",
                            selected = recovery == mins,
                            onClick = { recovery = mins },
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
            item {
                OutlinedTextField(
                    value = notes,
                    onValueChange = { notes = it },
                    label = { Text("Notes (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    maxLines = 2
                )
            }
            item {
                Button(
                    onClick = {
                        saving = true
                        viewModel.logEvent(type, prodromes.toList(), posture, location, recovery, notes)
                    },
                    enabled = !saving,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(68.dp),
                    shape = RoundedCornerShape(18.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) {
                    Text(if (saving) "Saving…" else "Log episode", fontSize = 19.sp, fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    "Heart rate around the event attaches automatically when Health Connect is available.",
                    fontSize = 12.sp,
                    color = NotelTextSecondary
                )
            }
            if (events.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(8.dp))
                    Text("Recent episodes", fontWeight = FontWeight.SemiBold, fontSize = 16.sp, color = NotelTextPrimary)
                }
                items(count = minOf(events.size, 5)) { i ->
                    val event = events[i]
                    SyncopeHistoryRow(event = event)
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun SyncopeHistoryRow(event: SyncopeEvent) {
    val fmt = DateTimeFormatter.ofPattern("MMM d, h:mm a")
    val whenStr = LocalDateTime.ofInstant(
        java.time.Instant.ofEpochMilli(event.timestamp), ZoneId.systemDefault()
    ).format(fmt)
    val prodromes = try { Json.decodeFromString<List<String>>(event.prodromeJson) } catch (e: Exception) { emptyList() }
    Surface(
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(14.dp)) {
            Text(
                text = (if (event.type == "FULL") "Syncope" else "Near-syncope") + " · $whenStr",
                fontWeight = FontWeight.Medium,
                fontSize = 15.sp,
                color = NotelTextPrimary
            )
            Text(
                text = "${event.postureAtOnset.lowercase()} · ${event.location.lowercase()} · recovery ~${event.recoveryMinutes}m" +
                        (if (event.heartRateAround > 0) " · HR ~${event.heartRateAround}" else "") +
                        (if (prodromes.isNotEmpty()) "\n${prodromes.joinToString(", ")}" else ""),
                fontSize = 13.sp,
                color = NotelTextSecondary
            )
        }
    }
}

@Composable
private fun SegmentedPair(
    label: String,
    left: Pair<String, String>,
    right: Pair<String, String>,
    selected: String,
    onSelect: (String) -> Unit
) {
    Text(label, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = NotelTextPrimary)
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        BigSelect(label = left.first, selected = selected == left.second, onClick = { onSelect(left.second) }, modifier = Modifier.weight(1f))
        BigSelect(label = right.first, selected = selected == right.second, onClick = { onSelect(right.second) }, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun SegmentedTriple(
    label: String,
    options: List<Pair<String, String>>,
    selected: String,
    onSelect: (String) -> Unit
) {
    Text(label, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = NotelTextPrimary)
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        options.forEach { (label, value) ->
            BigSelect(label = label, selected = selected == value, onClick = { onSelect(value) }, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun BigSelect(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.height(64.dp).clickable(onClick = onClick),
        shape = RoundedCornerShape(14.dp),
        color = if (selected) NotelPrimary.copy(alpha = 0.16f) else NotelTextSecondary.copy(alpha = 0.06f),
        border = BorderStroke(1.5.dp, if (selected) NotelPrimary else NotelTextSecondary.copy(alpha = 0.25f))
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(label, fontSize = 16.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal, color = NotelTextPrimary)
        }
    }
}

@Composable
private fun SelectableChip(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.height(52.dp).clickable(onClick = onClick),
        shape = RoundedCornerShape(26.dp),
        color = if (selected) NotelPrimary.copy(alpha = 0.16f) else NotelTextSecondary.copy(alpha = 0.06f),
        border = BorderStroke(1.dp, if (selected) NotelPrimary else NotelTextSecondary.copy(alpha = 0.25f))
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(label, fontSize = 14.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal, color = NotelTextPrimary)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProdromeChips(selected: Set<String>, onToggle: (String) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PRODROME_OPTIONS.forEach { label ->
            SelectableChip(
                label = label,
                selected = selected.contains(label),
                onClick = { onToggle(label) }
            )
        }
    }
}
