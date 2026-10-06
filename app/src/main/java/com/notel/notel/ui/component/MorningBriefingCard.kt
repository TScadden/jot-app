package com.notel.notel.ui.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.viewmodel.MorningBriefing
import com.notel.notel.ui.viewmodel.MorningBriefingUiState

/**
 * Tabs Lab: AI morning briefing home card. A concise digest — yesterday's
 * key numbers, weather/pressure, med reminders, one AI insight, one energy
 * suggestion. Tap opens the full briefing. Concise by design.
 */
@Composable
fun MorningBriefingCard(
    uiState: MorningBriefingUiState,
    onOpenDetail: () -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable(onClick = onOpenDetail),
        shape = RoundedCornerShape(16.dp),
        color = NotelPrimary.copy(alpha = 0.05f),
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.18f))
    ) {
        Column(modifier = Modifier.padding(vertical = 14.dp, horizontal = 16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "Morning Briefing",
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                    color = NotelTextPrimary
                )
                Text(
                    text = "Full briefing →",
                    fontSize = 12.sp,
                    color = NotelPrimary
                )
            }
            Spacer(Modifier.height(8.dp))
            when (uiState) {
                is MorningBriefingUiState.Loading -> {
                    Text("Putting together your morning…", fontSize = 14.sp, color = NotelTextSecondary)
                }
                is MorningBriefingUiState.Error -> {
                    Text(uiState.message, fontSize = 14.sp, color = NotelTextSecondary)
                }
                is MorningBriefingUiState.Ready -> {
                    BriefingDigest(briefing = uiState.briefing)
                }
            }
        }
    }
}

@Composable
private fun BriefingDigest(briefing: MorningBriefing) {
    val firstLines = briefing.yesterdayLines.take(2).joinToString(" · ")
    if (firstLines.isNotBlank()) {
        Text(text = "Yesterday: $firstLines", fontSize = 13.sp, color = NotelTextSecondary)
    }
    if (briefing.weatherLine.isNotBlank()) {
        Text(text = briefing.weatherLine, fontSize = 13.sp, color = NotelTextSecondary)
    }
    if (briefing.pressureLine.isNotBlank()) {
        Text(text = briefing.pressureLine, fontSize = 13.sp, color = NotelTextSecondary)
    }
    if (briefing.energySuggestion.isNotBlank()) {
        Spacer(Modifier.height(6.dp))
        Text(
            text = briefing.energySuggestion,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = NotelTextPrimary
        )
    }
    if (briefing.aiInsight.isNotBlank()) {
        Spacer(Modifier.height(6.dp))
        Text(
            text = briefing.aiInsight,
            fontSize = 13.sp,
            color = NotelTextSecondary
        )
    }
}
