package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Adjust
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.DateRange
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
    onBack: () -> Unit
) {
    val state by viewModel.uiState.collectAsState()

    val sheetState = rememberModalBottomSheetState()
    var showTheorySheet by remember { mutableStateOf(false) }
    val todayStr = java.time.LocalDate.now().toString()
    val isToday = state.selectedDate == todayStr

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Jot",
                        fontWeight = FontWeight.Black,
                        color = NotelTextPrimary,
                        fontSize = 22.sp
                    )
                },
                navigationIcon = {},
                actions = {
                    if (isToday) {
                        IconButton(onClick = { viewModel.refresh() }, enabled = !state.isLoading) {
                            Icon(Icons.Default.Refresh, "Refresh", tint = NotelPrimary)
                        }
                    } else {
                        IconButton(onClick = { viewModel.selectDay(todayStr) }) {
                            Icon(Icons.Default.DateRange, "Back to Today", tint = NotelPrimary)
                        }
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
}
