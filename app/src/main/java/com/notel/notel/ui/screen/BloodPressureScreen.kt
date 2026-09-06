package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.BloodPressureRepository
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BloodPressureScreen(
    viewModel: FitbitViewModel = hiltViewModel(),
    syncManager: com.notel.notel.data.sync.SyncManager? = null,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val prefs = remember { NotelPreferences(context) }
    val repo = remember { BloodPressureRepository(viewModel.healthConnectManager, prefs, syncManager) }
    val scope = rememberCoroutineScope()

    var isRefreshing by remember { mutableStateOf(false) }
    var records by remember { mutableStateOf<List<BloodPressureUiRecord>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var showAddDialog by remember { mutableStateOf(false) }

    var systolicInput by remember { mutableStateOf("") }
    var diastolicInput by remember { mutableStateOf("") }
    var selectedTimeMs by remember { mutableStateOf(System.currentTimeMillis()) }

    val manualLogsJson by prefs.manualBloodPressureLogs.collectAsState(initial = "[]")

    fun loadData() {
        scope.launch {
            viewModel.refreshBloodPressureState()
            val fetched = repo.getRecords()
            records = fetched.sortedByDescending { it.timeEpochMs }
            isLoading = false
            isRefreshing = false
        }
    }

    LaunchedEffect(Unit) {
        loadData()
    }

    LaunchedEffect(manualLogsJson) {
        loadData()
    }

    val latestRecord = records.firstOrNull()

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
                    IconButton(onClick = {
                        isRefreshing = true
                        loadData()
                    }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = NotelTextSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    systolicInput = ""
                    diastolicInput = ""
                    selectedTimeMs = System.currentTimeMillis()
                    showAddDialog = true
                },
                containerColor = NotelPrimary,
                contentColor = Color.White,
                modifier = Modifier.padding(bottom = 80.dp, end = 8.dp)
            ) {
                Icon(Icons.Default.Add, contentDescription = "Log Blood Pressure")
            }
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
        ) {
            if (isLoading || isRefreshing) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = NotelPrimary)
                }
            } else {
                Column(modifier = Modifier.fillMaxSize()) {
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
                            } else {
                                Text(
                                    text = "-- / --",
                                    color = NotelTextSecondary,
                                    fontSize = 36.sp,
                                    fontWeight = FontWeight.Bold
                                )
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = "No readings logged yet",
                                    color = NotelTextSecondary,
                                    fontSize = 13.sp
                                )
                                Spacer(Modifier.height(8.dp))
                                Button(
                                    onClick = {
                                        systolicInput = ""
                                        diastolicInput = ""
                                        selectedTimeMs = System.currentTimeMillis()
                                        showAddDialog = true
                                    },
                                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                                ) {
                                    Text("Log Reading")
                                }
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

                    if (records.isEmpty()) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 32.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "No blood pressure records found.\nTap + below to add your first reading.",
                                color = NotelTextSecondary,
                                fontSize = 14.sp,
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center
                            )
                        }
                    } else {
                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            contentPadding = PaddingValues(bottom = 140.dp),
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
                                                val sdf = SimpleDateFormat("EEE, MMM d, yyyy · h:mm a", Locale.getDefault())
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

            if (showAddDialog) {
                var showDatePicker by remember { mutableStateOf(false) }

                val formattedDateStr = remember(selectedTimeMs) {
                    SimpleDateFormat("EEE, MMM d, yyyy · h:mm a", Locale.getDefault()).format(Date(selectedTimeMs))
                }

                if (showDatePicker) {
                    val initialUtcMillis = remember(selectedTimeMs) {
                        val localCal = Calendar.getInstance().apply { timeInMillis = selectedTimeMs }
                        val utcCal = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                            clear()
                            set(localCal.get(Calendar.YEAR), localCal.get(Calendar.MONTH), localCal.get(Calendar.DAY_OF_MONTH))
                        }
                        utcCal.timeInMillis
                    }
                    val datePickerState = rememberDatePickerState(
                        initialSelectedDateMillis = initialUtcMillis
                    )
                    DatePickerDialog(
                        onDismissRequest = { showDatePicker = false },
                        confirmButton = {
                            TextButton(onClick = {
                                val sel = datePickerState.selectedDateMillis
                                if (sel != null) {
                                    val utcCal = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = sel }
                                    val localCal = Calendar.getInstance().apply { timeInMillis = selectedTimeMs }
                                    localCal.set(utcCal.get(Calendar.YEAR), utcCal.get(Calendar.MONTH), utcCal.get(Calendar.DAY_OF_MONTH))
                                    selectedTimeMs = localCal.timeInMillis
                                }
                                showDatePicker = false
                            }) {
                                Text("OK", color = NotelPrimary)
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = { showDatePicker = false }) {
                                Text("Cancel", color = NotelTextSecondary)
                            }
                        }
                    ) {
                        DatePicker(state = datePickerState)
                    }
                }

                AlertDialog(
                    onDismissRequest = { showAddDialog = false },
                    title = { Text("Log Blood Pressure", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = systolicInput,
                                onValueChange = { systolicInput = it },
                                label = { Text("Systolic (top / high)") },
                                placeholder = { Text("120") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = NotelPrimary,
                                    focusedLabelColor = NotelPrimary,
                                    unfocusedBorderColor = NotelTextSecondary.copy(alpha = 0.5f)
                                )
                            )
                            OutlinedTextField(
                                value = diastolicInput,
                                onValueChange = { diastolicInput = it },
                                label = { Text("Diastolic (bottom / low)") },
                                placeholder = { Text("80") },
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = NotelPrimary,
                                    focusedLabelColor = NotelPrimary,
                                    unfocusedBorderColor = NotelTextSecondary.copy(alpha = 0.5f)
                                )
                            )
                            
                            Spacer(Modifier.height(4.dp))
                            Surface(
                                onClick = { showDatePicker = true },
                                shape = RoundedCornerShape(12.dp),
                                color = NotelSurfaceHigh,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Column {
                                        Text("Date & Time", fontSize = 11.sp, color = NotelTextSecondary)
                                        Text(formattedDateStr, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = NotelTextPrimary)
                                    }
                                    Text("Change", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = NotelPrimary)
                                }
                            }
                        }
                    },
                    confirmButton = {
                        Button(
                            onClick = {
                                val sys = systolicInput.toIntOrNull()
                                val dia = diastolicInput.toIntOrNull()
                                if (sys != null && dia != null && sys > 0 && dia > 0) {
                                    showAddDialog = false
                                    isLoading = true
                                    scope.launch {
                                        repo.addManualRecord(sys, dia, selectedTimeMs)
                                        loadData()
                                    }
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                        ) {
                            Text("Save")
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showAddDialog = false }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }
        }
    }
}

