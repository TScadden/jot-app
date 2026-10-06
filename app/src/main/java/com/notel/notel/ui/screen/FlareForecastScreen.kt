package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.research.FlareForecast
import com.notel.notel.ui.component.MedicalDisclaimerBanner
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSuccess
import com.notel.notel.ui.theme.NotelWarning
import com.notel.notel.ui.theme.NotelError
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.viewmodel.FlareForecastUiState
import com.notel.notel.ui.viewmodel.FlareForecastViewModel

/**
 * Tabs Lab: Flare Forecast detail. The score with every contributing factor
 * visible — explainable, never a black box. Mandatory visible disclaimer:
 * informational risk-awareness, never diagnosis or medical advice.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlareForecastScreen(
    viewModel: FlareForecastViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val uiState by viewModel.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Flare Forecast") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
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
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            when (val s = uiState) {
                is FlareForecastUiState.Loading -> {
                    Text("Checking today's patterns…", color = NotelTextSecondary)
                }
                is FlareForecastUiState.Error -> {
                    Text(s.message, color = NotelTextSecondary)
                }
                is FlareForecastUiState.Ready -> {
                    val forecast = s.forecast
                    if (forecast.isSparse) {
                        Surface(
                            shape = RoundedCornerShape(14.dp),
                            border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.25f)),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = "Not enough data yet. Keep logging symptoms and keep your tracker connected — the forecast appears once at least two data sources are available.",
                                modifier = Modifier.padding(16.dp),
                                color = NotelTextSecondary,
                                fontSize = 14.sp
                            )
                        }
                    } else {
                        val color = when (forecast.level) {
                            FlareForecast.Level.LOW -> NotelSuccess
                            FlareForecast.Level.MODERATE -> NotelWarning
                            FlareForecast.Level.ELEVATED -> NotelError
                        }
                        Text(
                            text = "${forecast.score} / 100",
                            fontSize = 40.sp,
                            fontWeight = FontWeight.Black,
                            color = NotelTextPrimary
                        )
                        Text(
                            text = FlareForecast.levelLabel(forecast.level) + " pattern risk today",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = color
                        )
                        Text(
                            text = "Why this score — each factor is worth up to 25 points:",
                            fontSize = 13.sp,
                            color = NotelTextSecondary
                        )
                        forecast.factors.forEach { factor ->
                            FactorRow(factor = factor)
                        }
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
            Text(
                text = FlareForecast.DISCLAIMER,
                fontSize = 12.sp,
                color = NotelTextSecondary
            )
            MedicalDisclaimerBanner()
        }
    }
}

@Composable
private fun FactorRow(factor: FlareForecast.Factor) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(factor.name, fontWeight = FontWeight.SemiBold, color = NotelTextPrimary, fontSize = 15.sp)
                Text("+${factor.points}", fontWeight = FontWeight.Bold, color = NotelTextPrimary, fontSize = 15.sp)
            }
            Spacer(Modifier.height(4.dp))
            LinearProgressIndicator(
                progress = { factor.points / 25f },
                modifier = Modifier.fillMaxWidth(),
                color = NotelPrimary,
                trackColor = NotelPrimary.copy(alpha = 0.12f)
            )
            Spacer(Modifier.height(6.dp))
            Text(factor.explanation, fontSize = 13.sp, color = NotelTextSecondary)
        }
    }
}
