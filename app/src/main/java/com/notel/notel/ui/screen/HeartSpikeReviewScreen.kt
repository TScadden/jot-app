package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HeartSpikeReviewScreen(
    viewModel: FitbitViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val heartRateData = state.heartRateData
    var selectedSpikeIndex by remember { mutableStateOf<Int?>(null) }

    // Detect spikes (>100 BPM) with timestamp, peak BPM, jump delta, and duration
    val spikesList = remember(heartRateData) {
        if (heartRateData.isEmpty()) emptyList()
        else {
            val sortedReadings = heartRateData.map { it.second }.sorted()
            val baselineP10 = if (sortedReadings.isNotEmpty()) sortedReadings[(sortedReadings.size * 0.10).toInt().coerceAtLeast(0)] else 60

            val detected = mutableListOf<SpikeEventInfo>()
            var currentSpikeStartMs = 0L
            var currentSpikePeakBpm = 0
            var currentSpikeEndMs = 0L
            var inEvent = false

            for ((tMs, bpm) in heartRateData) {
                if (bpm >= 100) {
                    if (!inEvent || tMs > currentSpikeEndMs + (3 * 60 * 1000L)) {
                        if (inEvent) {
                            val jump = currentSpikePeakBpm - baselineP10
                            detected.add(
                                SpikeEventInfo(
                                    startTimeMs = currentSpikeStartMs,
                                    endTimeMs = currentSpikeEndMs,
                                    peakBpm = currentSpikePeakBpm,
                                    jumpDelta = maxOf(0, jump),
                                    source = "Health Connect"
                                )
                            )
                        }
                        inEvent = true
                        currentSpikeStartMs = tMs
                        currentSpikePeakBpm = bpm
                    } else {
                        currentSpikePeakBpm = maxOf(currentSpikePeakBpm, bpm)
                    }
                    currentSpikeEndMs = tMs
                }
            }
            if (inEvent) {
                val jump = currentSpikePeakBpm - baselineP10
                detected.add(
                    SpikeEventInfo(
                        startTimeMs = currentSpikeStartMs,
                        endTimeMs = currentSpikeEndMs,
                        peakBpm = currentSpikePeakBpm,
                        jumpDelta = maxOf(0, jump),
                        source = "Health Connect"
                    )
                )
            }
            detected.sortedByDescending { it.peakBpm }
        }
    }

    val timeFormatter = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Spike Review",
                        fontWeight = FontWeight.Bold,
                        fontSize = 20.sp,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    val context = LocalContext.current
                    IconButton(
                        onClick = {
                            com.notel.notel.util.PdfExporter.exportSpikesToPdf(
                                context,
                                state.selectedHeartRateDate,
                                state.heartRateData
                            )
                        }
                    ) {
                        Icon(
                            imageVector = Icons.Default.Download,
                            contentDescription = "Download spike report",
                            tint = NotelPrimary
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Summary Header Card
            GlassyCard(
                modifier = Modifier.fillMaxWidth(),
                color = if (spikesList.isNotEmpty()) Color(0xFF2A121A) else NotelSurface
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .background(Color(0xFF4A1820), CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Default.Whatshot,
                            contentDescription = null,
                            tint = Color(0xFFFF5252),
                            modifier = Modifier.size(24.dp)
                        )
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "${spikesList.size} Significant Spikes Detected",
                            color = NotelTextPrimary,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = if (spikesList.isNotEmpty()) "Showing heart rate spikes ≥100 BPM for today" else "No spikes ≥100 BPM recorded for this time range",
                            color = NotelTextSecondary,
                            fontSize = 12.sp
                        )
                    }
                }
            }

            if (spikesList.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 40.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = Color(0xFF4CAF50),
                            modifier = Modifier.size(48.dp)
                        )
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "Normal Physiological Load",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 18.sp
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "All heart rate readings stayed within normal resting and active ranges.",
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center
                        )
                    }
                }
            } else {
                Text(
                    "Detected Events",
                    color = NotelTextSecondary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold
                )

                spikesList.forEachIndexed { index, spike ->
                    val isExpanded = selectedSpikeIndex == index
                    val startTimeStr = timeFormatter.format(Date(spike.startTimeMs))
                    val endTimeStr = timeFormatter.format(Date(spike.endTimeMs))
                    val durationMins = maxOf(1, ((spike.endTimeMs - spike.startTimeMs) / 60000L).toInt())

                    // Context readings around the spike (±10 minutes)
                    val contextReadings = remember(heartRateData, spike) {
                        heartRateData.filter { (tMs, _) ->
                            tMs in (spike.startTimeMs - 10 * 60 * 1000L)..(spike.endTimeMs + 10 * 60 * 1000L)
                        }
                    }

                    GlassyCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { selectedSpikeIndex = if (isExpanded) null else index },
                        color = NotelSurface
                    ) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Surface(
                                    color = Color(0xFF4A1820),
                                    shape = RoundedCornerShape(8.dp)
                                ) {
                                    Text(
                                        "#${index + 1}",
                                        color = Color(0xFFFF5252),
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Black,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                    )
                                }
                                Spacer(Modifier.width(10.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        if (spike.startTimeMs == spike.endTimeMs) startTimeStr else "$startTimeStr - $endTimeStr",
                                        color = NotelTextPrimary,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 14.sp,
                                        maxLines = 1,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                    )
                                    Spacer(Modifier.height(2.dp))
                                    Text(
                                        "${durationMins}m duration  •  ${spike.source}",
                                        color = NotelTextSecondary,
                                        fontSize = 11.sp,
                                        maxLines = 1,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                    )
                                }
                                Spacer(Modifier.width(12.dp))
                                Column(horizontalAlignment = Alignment.End) {
                                    Text(
                                        "${spike.peakBpm} bpm",
                                        color = Color(0xFFFF5252),
                                        fontWeight = FontWeight.Black,
                                        fontSize = 15.sp,
                                        maxLines = 1
                                    )
                                    Spacer(Modifier.height(2.dp))
                                    Text(
                                        "+${spike.jumpDelta} jump",
                                        color = NotelTextSecondary,
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1
                                    )
                                }
                            }

                            if (isExpanded) {
                                Spacer(Modifier.height(14.dp))
                                HorizontalDivider(color = NotelSurfaceHigh)
                                Spacer(Modifier.height(12.dp))

                                Text(
                                    "Surrounding Context (${contextReadings.size} data points):",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Spacer(Modifier.height(8.dp))

                                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    contextReadings.take(8).forEach { (tMs, bpm) ->
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween
                                        ) {
                                            Text(
                                                timeFormatter.format(Date(tMs)),
                                                color = NotelTextSecondary,
                                                fontSize = 12.sp
                                            )
                                            Text(
                                                "$bpm bpm",
                                                color = if (bpm >= 100) Color(0xFFFF5252) else NotelTextPrimary,
                                                fontSize = 12.sp,
                                                fontWeight = if (bpm >= 100) FontWeight.Bold else FontWeight.Normal
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

data class SpikeEventInfo(
    val startTimeMs: Long,
    val endTimeMs: Long,
    val peakBpm: Int,
    val jumpDelta: Int,
    val source: String
)
