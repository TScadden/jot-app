package com.notel.notel.ui.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.data.research.FlareForecast
import com.notel.notel.ui.theme.NotelBorder
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSuccess
import com.notel.notel.ui.theme.NotelWarning
import com.notel.notel.ui.theme.NotelError
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.viewmodel.FlareForecastUiState

/**
 * Tabs Lab: Flare Forecast home card. Morning "today's risk" score for
 * POTS/MCAS crash risk as informational risk-awareness — NEVER a diagnosis.
 * Always carries the disclaimer; tap opens the factor-by-factor detail.
 */
@Composable
fun FlareForecastCard(
    uiState: FlareForecastUiState,
    onOpenDetail: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable(onClick = onOpenDetail),
        shape = RoundedCornerShape(16.dp),
        color = NotelPrimary.copy(alpha = 0.07f),
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.22f))
    ) {
        Column(modifier = Modifier.padding(vertical = 14.dp, horizontal = 16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "Flare Forecast",
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                    color = NotelTextPrimary
                )
                Text(
                    text = "Details →",
                    fontSize = 12.sp,
                    color = NotelPrimary
                )
            }
            Spacer(Modifier.height(10.dp))
            when (uiState) {
                is FlareForecastUiState.Loading -> {
                    Text("Checking today's patterns…", fontSize = 14.sp, color = NotelTextSecondary)
                }
                is FlareForecastUiState.Error -> {
                    Text(uiState.message, fontSize = 14.sp, color = NotelTextSecondary)
                }
                is FlareForecastUiState.Ready -> {
                    val forecast = uiState.forecast
                    if (forecast.isSparse) {
                        Text(
                            text = "Still gathering data — keep logging symptoms and wearing your tracker. A forecast appears once at least two data sources are available.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary
                        )
                    } else {
                        ScoreRow(forecast)
                        Spacer(Modifier.height(8.dp))
                        val topFactor = forecast.factors.maxByOrNull { it.points }
                        if (topFactor != null && topFactor.points > 0) {
                            Text(
                                text = "Main driver: ${topFactor.explanation}",
                                fontSize = 13.sp,
                                color = NotelTextSecondary
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Informational only — not a medical prediction.",
                fontSize = 11.sp,
                color = NotelTextSecondary
            )
        }
    }
}

@Composable
private fun ScoreRow(forecast: FlareForecast.Forecast) {
    val color = when (forecast.level) {
        FlareForecast.Level.LOW -> NotelSuccess
        FlareForecast.Level.MODERATE -> NotelWarning
        FlareForecast.Level.ELEVATED -> NotelError
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(72.dp)) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawArc(
                    color = NotelBorder,
                    startAngle = -90f,
                    sweepAngle = 360f,
                    useCenter = false,
                    style = Stroke(width = 18f, cap = StrokeCap.Round)
                )
                drawArc(
                    color = color,
                    startAngle = -90f,
                    sweepAngle = 360f * forecast.score / 100f,
                    useCenter = false,
                    style = Stroke(width = 18f, cap = StrokeCap.Round)
                )
            }
            Text(
                text = forecast.score.toString(),
                fontWeight = FontWeight.Black,
                fontSize = 22.sp,
                color = NotelTextPrimary
            )
        }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(
                text = FlareForecast.levelLabel(forecast.level) + " pattern risk",
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
                color = color
            )
            Text(
                text = "Based on ${forecast.dataSources} of 4 data sources",
                fontSize = 12.sp,
                color = NotelTextSecondary
            )
        }
    }
}
