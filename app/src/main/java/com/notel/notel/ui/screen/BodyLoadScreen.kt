package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.rounded.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BodyLoadScreen(
    viewModel: BodyLoadViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onNavigateToConnections: () -> Unit = {}
) {
    val state by viewModel.uiState.collectAsState()

    val sheetState = rememberModalBottomSheetState()
    var showTheorySheet by remember { mutableStateOf(false) }
    var showWeatherSheet by remember { mutableStateOf(false) }
    val todayStr = java.time.LocalDate.now().toString()
    val isToday = state.selectedDate == todayStr

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Jot",
                        fontWeight = FontWeight.Black,
                        color = NotelTextPrimary,
                        fontSize = 22.sp
                    )
                },
                navigationIcon = {},
                actions = {
                    IconButton(
                        onClick = { showWeatherSheet = true },
                        modifier = Modifier.width(64.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            state.weather?.let { w ->
                                Text(
                                    text = "${w.temp}°",
                                    color = NotelTextPrimary.copy(alpha = 0.8f),
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Icon(
                                imageVector = Icons.Default.Cloud,
                                contentDescription = "Weather",
                                tint = NotelPrimary.copy(alpha = 0.7f),
                                modifier = Modifier.size(20.dp)
                            )
                        }
                    }
                    IconButton(onClick = onNavigateToConnections) {
                        Icon(
                            imageVector = Icons.Default.Watch,
                            contentDescription = "Connections",
                            tint = NotelPrimary,
                            modifier = Modifier.size(24.dp)
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NotelBackground
                )
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            BodyLoadCard(
                state = state,
                onDaySelected = { viewModel.selectDay(it) },
                onFactorSelected = { viewModel.selectFactor(it) },
                onResetSelection = { viewModel.selectFactor(null) },
                onShowTheory = { 
                    viewModel.markTheorySeen()
                    showTheorySheet = true 
                },
                onRefresh = { viewModel.refresh() },
                onBackToToday = { viewModel.selectDay(todayStr) },
                onLocationUpdate = { lat, lon, city ->
                    viewModel.updateLocation(lat, lon, city)
                }
            )

            if (state.error != null) {
                Spacer(Modifier.height(16.dp))
                Text(
                    state.error!!,
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 32.dp)
                )
            }
        }
    }

    if (showTheorySheet) {
        ModalBottomSheet(
            onDismissRequest = { showTheorySheet = false },
            sheetState = sheetState,
            containerColor = NotelSurface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
                    .padding(bottom = 40.dp)
            ) {
                Text(
                    text = "The Cup Theory",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = NotelPrimary
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "Think of your body's capacity as a cup. Every stressor—poor sleep, dehydration, high heart rate, or physical exertion—adds water to that cup.\n\n" +
                           "Your Body Load score is calculated using clinical biometric weighting:\n\n" +
                           "• 30% Autonomic Balance (HRV): Deviations from your 30-day RMSSD mean.\n" +
                           "• 25% Sleep Architecture: Accounting for your recent 'Sleep Debt'.\n" +
                           "• 20% Activity Stress: Your 7-day vs. 42-day workload ratio.\n" +
                           "• 15% Orthostatic Spikes: High HR events (>100bpm) that fill your cup.\n" +
                           "• 5% Heart Rate: Real-time RHR jumps from your baseline.\n" +
                           "• 5% Subjective Jots: AI context for pain, anxiety, and flares.\n\n" +
                           "When the cup is nearly empty, you feel resilient. When it's full, even a small drop can cause it to overflow, leading to symptom flares.",
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    lineHeight = 22.sp
                )
                Spacer(Modifier.height(24.dp))
                Button(
                    onClick = { showTheorySheet = false },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) {
                    Text("Got it")
                }
            }
        }
    }

    if (showWeatherSheet) {
        ModalBottomSheet(
            onDismissRequest = { showWeatherSheet = false },
            containerColor = NotelSurface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp)
                    .padding(bottom = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                val weather = state.weather
                if (weather != null) {
                    Text(weather.locationName, color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Black)
                    Text(weather.condition, color = NotelTextSecondary, fontSize = 14.sp)
                    
                    Spacer(Modifier.height(32.dp))
                    
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(weather.icon, fontSize = 32.sp)
                            Text("${weather.temp}°${weather.unit}", color = NotelTextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                        }
                        
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("💧", fontSize = 24.sp)
                            Text("${weather.humidity}%", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            Text("Humidity", color = NotelTextSecondary, fontSize = 10.sp)
                        }
                        
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("💨", fontSize = 24.sp)
                            Text("${String.format("%.1f", weather.windSpeed)}", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            Text(if (weather.unit == "F") "mph" else "km/h", color = NotelTextSecondary, fontSize = 10.sp)
                        }
                        
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("☀️", fontSize = 24.sp, color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary)
                            Text("${String.format("%.1f", weather.uvIndex)}", color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            Text("UV Index", color = NotelTextSecondary, fontSize = 10.sp)
                        }
                    }
                    
                    if (weather.uvIndex > 5) {
                        Spacer(Modifier.height(24.dp))
                        Surface(
                            color = NotelAccent.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(12.dp),
                            border = BorderStroke(1.dp, NotelAccent.copy(alpha = 0.3f))
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(Icons.Default.Warning, contentDescription = null, tint = NotelAccent, modifier = Modifier.size(16.dp))
                                Text("High UV levels detected. Consider sun protection.", color = NotelAccent, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                    }
                } else {
                    CircularProgressIndicator(color = NotelPrimary)
                    Spacer(Modifier.height(16.dp))
                    Text("Fetching local weather...", color = NotelTextSecondary, fontSize = 14.sp)
                }
            }
        }
    }
}
