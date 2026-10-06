package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.MigraineAttack
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.viewmodel.MigraineUiState
import com.notel.notel.ui.viewmodel.MigraineViewModel
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Tabs Lab: Migraine attack mode.
 *
 * Designed for mid-migraine use: dark background, minimal text, touch targets
 * 64dp+. One tap starts an attack (pressure auto-attached). During an attack:
 * aura phase chips, meds taken, pain 1-10, end with a relief rating.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MigraineScreen(
    viewModel: MigraineViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val startError by viewModel.error.collectAsState()

    Scaffold(
        containerColor = Color(0xFF0B0B12),
        topBar = {
            TopAppBar(
                title = { Text("Migraine attack", color = Color.White) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color(0xFF0B0B12))
            )
        }
    ) { padding ->
        Box(modifier = Modifier.padding(padding).fillMaxSize()) {
            when (val s = state) {
                is MigraineUiState.Loading -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = NotelPrimary)
                    }
                }
                is MigraineUiState.Idle -> IdleContent(
                    recentAttacks = s.recentAttacks,
                    error = startError,
                    onStart = { viewModel.clearError(); viewModel.startAttack() }
                )
                is MigraineUiState.Active -> ActiveAttackContent(
                    attack = s.attack,
                    onUpdate = { aura, meds, pain -> viewModel.updateAttack(aura, meds, pain) },
                    onEnd = { relief, pain -> viewModel.endAttack(relief, pain) }
                )
            }
        }
    }
}

@Composable
private fun IdleContent(recentAttacks: List<MigraineAttack>, error: String?, onStart: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.height(24.dp))
        Button(
            onClick = onStart,
            modifier = Modifier
                .fillMaxWidth()
                .height(88.dp),
            shape = RoundedCornerShape(20.dp),
            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
        ) {
            Text("Start attack", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(8.dp))
        error?.let { err ->
            Text(err, color = Color(0xFFE57373), fontSize = 14.sp)
            Spacer(Modifier.height(8.dp))
        }
        Text(
            "One tap. Pressure attaches automatically.",
            color = Color(0xFF9A9AA5),
            fontSize = 13.sp
        )
        Spacer(Modifier.height(28.dp))
        if (recentAttacks.isNotEmpty()) {
            Text(
                "Recent attacks",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
                modifier = Modifier.align(Alignment.Start)
            )
            Spacer(Modifier.height(8.dp))
            recentAttacks.take(10).forEach { attack ->
                AttackHistoryRow(attack = attack)
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun AttackHistoryRow(attack: MigraineAttack) {
    val fmt = DateTimeFormatter.ofPattern("MMM d, h:mm a")
    val start = LocalDateTime.ofInstant(
        java.time.Instant.ofEpochMilli(attack.startTimestamp), ZoneId.systemDefault()
    ).format(fmt)
    val dur = attack.endTimestamp?.let { "${(it - attack.startTimestamp) / 60000} min" } ?: "ongoing"
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = Color(0xFF16161F),
        border = BorderStroke(1.dp, Color(0xFF2A2A38)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(14.dp)) {
            Text(start, color = Color.White, fontWeight = FontWeight.Medium, fontSize = 15.sp)
            Text(
                "$dur · peak pain ${attack.painPeak}/10 · relief ${attack.reliefRating}/5",
                color = Color(0xFF9A9AA5),
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun ActiveAttackContent(
    attack: MigraineAttack,
    onUpdate: (aura: String?, meds: String?, pain: Int?) -> Unit,
    onEnd: (relief: Int, pain: Int?) -> Unit
) {
    var aura by remember(attack.id) { mutableStateOf(attack.auraPhase) }
    var meds by remember(attack.id) { mutableStateOf(attack.medsTaken) }
    var pain by remember(attack.id) { mutableStateOf(attack.painPeak.takeIf { it > 0 } ?: 5) }
    var showEndSheet by remember { mutableStateOf(false) }
    var relief by remember { mutableStateOf(3) }

    // Live elapsed timer
    var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(attack.id) {
        while (true) {
            kotlinx.coroutines.delay(30_000)
            nowMs = System.currentTimeMillis()
        }
    }
    val elapsedMin = ((nowMs - attack.startTimestamp) / 60000).toInt()

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(top = 8.dp, bottom = 32.dp)
    ) {
        item {
            Text(
                text = if (elapsedMin < 60) "$elapsedMin min" else "${elapsedMin / 60}h ${elapsedMin % 60}m",
                color = Color.White,
                fontSize = 44.sp,
                fontWeight = FontWeight.Black
            )
            Text(
                text = if (attack.pressureAtStartHpa > 0)
                    "Started at ${"%.0f".format(attack.pressureAtStartHpa)} hPa"
                else "Started — logging",
                color = Color(0xFF9A9AA5),
                fontSize = 14.sp
            )
        }
        item {
            SectionLabel("Aura phase")
            ChipRow(
                options = listOf("NONE" to "None", "VISUAL" to "Visual", "SENSORY" to "Sensory", "SPEECH" to "Speech", "MOTOR" to "Motor"),
                selected = aura,
                onSelect = { aura = it; onUpdate(it, null, null) }
            )
        }
        item {
            SectionLabel("Meds taken")
            OutlinedTextField(
                value = meds,
                onValueChange = { meds = it; onUpdate(null, it, null) },
                placeholder = { Text("e.g. sumatriptan", color = Color(0xFF6E6E7A)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = Color(0xFF2A2A38)
                )
            )
        }
        item {
            SectionLabel("Pain right now: $pain / 10")
            Slider(
                value = pain.toFloat(),
                onValueChange = { pain = it.toInt() },
                onValueChangeFinished = { onUpdate(null, null, pain) },
                valueRange = 1f..10f,
                steps = 8,
                modifier = Modifier.fillMaxWidth().height(64.dp),
                colors = SliderDefaults.colors(thumbColor = NotelPrimary, activeTrackColor = NotelPrimary)
            )
        }
        item {
            Button(
                onClick = { showEndSheet = true },
                modifier = Modifier.fillMaxWidth().height(80.dp),
                shape = RoundedCornerShape(20.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1F7A5C))
            ) {
                Text("End attack", fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
        }
    }

    if (showEndSheet) {
        AlertDialog(
            onDismissRequest = { showEndSheet = false },
            containerColor = Color(0xFF16161F),
            title = { Text("Relief rating", color = Color.White, fontWeight = FontWeight.Bold) },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("How much relief do you feel now?", color = Color(0xFF9A9AA5), fontSize = 14.sp)
                    Spacer(Modifier.height(12.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly
                    ) {
                        (1..5).forEach { v ->
                            Surface(
                                modifier = Modifier.size(56.dp).clickable { relief = v },
                                shape = RoundedCornerShape(12.dp),
                                color = if (relief == v) NotelPrimary else Color(0xFF23232E),
                                border = BorderStroke(1.dp, if (relief == v) NotelPrimary else Color(0xFF3A3A48))
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text("$v", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text("$relief / 5", color = Color(0xFF9A9AA5), fontSize = 13.sp)
                }
            },
            confirmButton = {
                Button(
                    onClick = { showEndSheet = false; onEnd(relief, pain) },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    modifier = Modifier.height(56.dp)
                ) { Text("Save", fontSize = 17.sp) }
            },
            dismissButton = {
                TextButton(onClick = { showEndSheet = false }, modifier = Modifier.height(56.dp)) {
                    Text("Back", color = Color(0xFF9A9AA5), fontSize = 17.sp)
                }
            }
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, color = Color(0xFF9A9AA5), fontSize = 14.sp, fontWeight = FontWeight.Medium)
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun ChipRow(
    options: List<Pair<String, String>>,
    selected: String,
    onSelect: (String) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        options.forEach { (value, label) ->
            val isSel = selected == value
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .height(64.dp)
                    .clickable { onSelect(value) },
                shape = RoundedCornerShape(14.dp),
                color = if (isSel) NotelPrimary.copy(alpha = 0.28f) else Color(0xFF16161F),
                border = BorderStroke(1.dp, if (isSel) NotelPrimary else Color(0xFF2A2A38))
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        label,
                        color = if (isSel) Color.White else Color(0xFFCFCFDA),
                        fontSize = 14.sp,
                        fontWeight = if (isSel) FontWeight.Bold else FontWeight.Normal
                    )
                }
            }
        }
    }
}
