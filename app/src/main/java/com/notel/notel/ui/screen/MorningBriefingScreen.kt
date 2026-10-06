package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.component.MedicalDisclaimerBanner
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.viewmodel.MorningBriefing
import com.notel.notel.ui.viewmodel.MorningBriefingUiState
import com.notel.notel.ui.viewmodel.MorningBriefingViewModel
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/**
 * Tabs Lab: AI morning briefing detail. Yesterday's key numbers, today's
 * weather + pressure outlook, medication reminders, one AI insight, one
 * energy suggestion. Concise — a briefing, not a dashboard.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MorningBriefingScreen(
    viewModel: MorningBriefingViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val uiState by viewModel.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Morning briefing") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.refresh() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh briefing")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            when (val s = uiState) {
                is MorningBriefingUiState.Loading -> {
                    Text("Putting together your morning…", color = NotelTextSecondary)
                }
                is MorningBriefingUiState.Error -> {
                    Text(s.message, color = NotelTextSecondary)
                }
                is MorningBriefingUiState.Ready -> {
                    BriefingBody(briefing = s.briefing)
                }
            }
            MedicalDisclaimerBanner()
        }
    }
}

@Composable
private fun BriefingBody(briefing: MorningBriefing) {
    val dateLabel = try {
        LocalDate.parse(briefing.date).format(DateTimeFormatter.ofPattern("EEEE, MMM d"))
    } catch (e: Exception) { briefing.date }
    Text(dateLabel, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)

    if (briefing.yesterdayLines.isNotEmpty()) {
        BriefingSection(title = "Yesterday") {
            briefing.yesterdayLines.forEach { line ->
                BulletLine(line)
            }
        }
    }

    if (briefing.weatherLine.isNotBlank() || briefing.pressureLine.isNotBlank()) {
        BriefingSection(title = "Today's outlook") {
            if (briefing.weatherLine.isNotBlank()) BulletLine(briefing.weatherLine)
            if (briefing.pressureLine.isNotBlank()) BulletLine(briefing.pressureLine)
        }
    }

    if (briefing.medLines.isNotEmpty()) {
        BriefingSection(title = "Medications") {
            briefing.medLines.take(8).forEach { line ->
                BulletLine(line)
            }
        }
    }

    if (briefing.aiInsight.isNotBlank()) {
        BriefingSection(title = "AI insight") {
            Text(briefing.aiInsight, fontSize = 14.sp, color = NotelTextPrimary)
        }
    }

    if (briefing.energySuggestion.isNotBlank()) {
        BriefingSection(title = "Energy suggestion") {
            Text(briefing.energySuggestion, fontSize = 14.sp, color = NotelTextPrimary)
        }
    }
}

@Composable
private fun BriefingSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = NotelPrimary)
            Spacer(Modifier.height(6.dp))
            content()
        }
    }
}

@Composable
private fun ColumnScope.BulletLine(text: String) {
    Text("•  $text", fontSize = 14.sp, color = NotelTextPrimary, modifier = Modifier.padding(vertical = 2.dp))
}
