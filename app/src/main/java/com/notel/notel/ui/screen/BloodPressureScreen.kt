package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.repository.BloodPressureTileState
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BloodPressureScreen(
    viewModel: FitbitViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val scope = rememberCoroutineScope()

    var isRefreshing by remember { mutableStateOf(false) }
    var records by remember { mutableStateOf<List<BloodPressureUiRecord>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        viewModel.refreshBloodPressureState()
        val repo = com.notel.notel.data.repository.BloodPressureRepository(viewModel.healthConnectManager)
        val fetched = repo.getRecords()
        records = fetched.sortedByDescending { it.timeEpochMs }
        isLoading = false
    }

    fun refresh() {
        isRefreshing = true
        viewModel.refreshBloodPressureState()
        scope.launch {
            val repo = com.notel.notel.data.repository.BloodPressureRepository(viewModel.healthConnectManager)
            val fetched = repo.getRecords()
            if (fetched.isNotEmpty() || state.bloodPressureState !is BloodPressureTileState.Available) {
                records = fetched.sortedByDescending { it.timeEpochMs }
            }
            isRefreshing = false
        }
    }

    val latestRecord = records.firstOrNull() ?: (state.bloodPressureState as? BloodPressureTileState.Available)?.latestReading

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text("Blood Pressure", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    IconButton(onClick = { refresh() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = NotelTextSecondary)
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
                .padding(horizontal = 16.dp)
        ) {
            if (isLoading) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = NotelPrimary)
                }
            } else when (val bpState = state.bloodPressureState) {
                is BloodPressureTileState.Checking -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(text = "Checking Health Connect status...", color = NotelTextSecondary, fontSize = 16.sp)
                    }
                }
                is BloodPressureTileState.HealthConnectUnavailable -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(text = "Health Connect unavailable on this device", color = NotelTextSecondary, fontSize = 16.sp)
                    }
                }
                is BloodPressureTileState.PermissionRequired -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(text = "Blood Pressure read permission required in Health Connect settings", color = NotelTextSecondary, fontSize = 16.sp)
                    }
                }
                is BloodPressureTileState.Error -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(text = "Unable to load blood pressure records", color = MaterialTheme.colorScheme.error, fontSize = 16.sp)
                    }
                }
                is BloodPressureTileState.NoData -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(text = "No readings found", color = NotelTextSecondary, fontSize = 16.sp)
                    }
                }
                is BloodPressureTileState.Available -> {
                    if (records.isEmpty() && latestRecord == null) {
                        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text(text = "No readings found", color = NotelTextSecondary, fontSize = 16.sp)
                        }
                    } else {
                        Spacer(Modifier.height(8.dp))
                        // Spotlight Card for latest reading
                        Surface(
                            shape = RoundedCornerShape(20.dp),
                            color = NotelSurface,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(
                                modifier = Modifier.padding(20.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Favorite, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(20.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text("Latest Reading", color = NotelTextSecondary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                }
                                Spacer(Modifier.height(12.dp))
                                if (latestRecord != null) {
                                    Text(
                                        text = "${latestRecord.systolic} / ${latestRecord.diastolic}",
                                        color = NotelTextPrimary,
                                        fontSize = 42.sp,
                                        fontWeight = FontWeight.Black
                                    )
                                    Text(
                                        text = "mmHg",
                                        color = NotelTextSecondary,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    Spacer(Modifier.height(8.dp))
                                    val dateStr = remember(latestRecord.timeEpochMs) {
                                        val sdf = SimpleDateFormat("MMM d, yyyy · h:mm a", Locale.getDefault())
                                        sdf.format(Date(latestRecord.timeEpochMs))
                                    }
                                    Text(
                                        text = dateStr,
                                        color = NotelTextSecondary.copy(alpha = 0.8f),
                                        fontSize = 12.sp
                                    )
                                }
                            }
                        }

                        Spacer(Modifier.height(24.dp))
                        Text(
                            text = "History",
                            color = NotelTextPrimary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(bottom = 12.dp)
                        )

                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            contentPadding = PaddingValues(bottom = 100.dp),
                            modifier = Modifier.fillMaxSize()
                        ) {
                            items(records) { item ->
                                Surface(
                                    shape = RoundedCornerShape(16.dp),
                                    color = NotelSurface,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(16.dp),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column {
                                            Text(
                                                text = "${item.systolic} / ${item.diastolic} mmHg",
                                                color = NotelTextPrimary,
                                                fontSize = 16.sp,
                                                fontWeight = FontWeight.Bold
                                            )
                                            Spacer(Modifier.height(4.dp))
                                            val timeFormatted = remember(item.timeEpochMs) {
                                                val sdf = SimpleDateFormat("EEE, MMM d · h:mm a", Locale.getDefault())
                                                sdf.format(Date(item.timeEpochMs))
                                            }
                                            Text(
                                                text = timeFormatted,
                                                color = NotelTextSecondary,
                                                fontSize = 12.sp
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
