package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.healthconnect.BloodPressureSource
import com.notel.notel.data.healthconnect.BloodPressureUiRecord
import com.notel.notel.data.repository.HealthConnectStatus
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BloodPressureViewModel
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BloodPressureScreen(
    viewModel: BloodPressureViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val uiState by viewModel.uiState.collectAsState()

    var showAddDialog by remember { mutableStateOf(false) }
    var systolicInput by remember { mutableStateOf("") }
    var diastolicInput by remember { mutableStateOf("") }
    var selectedTimeMs by remember { mutableStateOf(System.currentTimeMillis()) }
    var validationError by remember { mutableStateOf<String?>(null) }

    val latestRecord = uiState.records.firstOrNull()

    var recordToDelete by remember { mutableStateOf<BloodPressureUiRecord?>(null) }

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
                    IconButton(onClick = { viewModel.loadData(isRefresh = true) }) {
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
                    validationError = null
                    viewModel.clearSaveError()
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
            if (uiState.isLoading && uiState.records.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = NotelPrimary)
                }
            } else {
                Column(modifier = Modifier.fillMaxSize()) {
                    Spacer(Modifier.height(8.dp))

                    // Diagnostic status notice for Health Connect
                    when (uiState.hcStatus) {
                        is HealthConnectStatus.PermissionRequired -> {
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = NotelSurfaceHigh,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(bottom = 12.dp)
                            ) {
                                Row(
                                    modifier = Modifier.padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFFFB74D), modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        "Health Connect permission needed to sync automatic device readings.",
                                        fontSize = 12.sp,
                                        color = NotelTextSecondary
                                    )
                                }
                            }
                        }
                        is HealthConnectStatus.Error -> {
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = NotelSurfaceHigh,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(bottom = 12.dp)
                            ) {
                                Row(
                                    modifier = Modifier.padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFE57373), modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        "Health Connect query issue. Showing manual readings.",
                                        fontSize = 12.sp,
                                        color = NotelTextSecondary
                                    )
                                }
                            }
                        }
                        else -> {}
                    }

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
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = dateStr,
                                        color = NotelTextSecondary.copy(alpha = 0.8f),
                                        fontSize = 12.sp
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    SourceChip(source = latestRecord.source)
                                }
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
                                        validationError = null
                                        viewModel.clearSaveError()
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

                    if (uiState.records.isEmpty()) {
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
                            items(uiState.records, key = { it.id }) { item ->
                                val isManual = item.source == BloodPressureSource.MANUAL
                                Surface(
                                    shape = RoundedCornerShape(16.dp),
                                    color = NotelSurface,
                                    onClick = {
                                        if (isManual) {
                                            recordToDelete = item
                                        }
                                    },
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
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            SourceChip(source = item.source)
                                            if (isManual) {
                                                Spacer(Modifier.width(8.dp))
                                                IconButton(
                                                    onClick = { recordToDelete = item },
                                                    modifier = Modifier.size(24.dp)
                                                ) {
                                                    Icon(
                                                        imageVector = androidx.compose.material.icons.Icons.Default.Delete,
                                                        contentDescription = "Delete record",
                                                        tint = NotelTextSecondary
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

            if (recordToDelete != null) {
                val item = recordToDelete!!
                AlertDialog(
                    onDismissRequest = { recordToDelete = null },
                    title = { Text("Delete Manual Reading?", color = NotelTextPrimary) },
                    text = {
                        Text(
                            "Are you sure you want to delete this reading (${item.systolic}/${item.diastolic} mmHg)? This action cannot be undone.",
                            color = NotelTextSecondary
                        )
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                viewModel.deleteManualRecord(item.id)
                                recordToDelete = null
                            }
                        ) {
                            Text("Delete", color = Color(0xFFE57373), fontWeight = FontWeight.Bold)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { recordToDelete = null }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
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
                    onDismissRequest = { if (!uiState.isSaving) showAddDialog = false },
                    title = { Text("Log Blood Pressure", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            if (validationError != null || uiState.saveErrorMessage != null) {
                                Text(
                                    text = validationError ?: uiState.saveErrorMessage ?: "",
                                    color = Color(0xFFE57373),
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                            OutlinedTextField(
                                value = systolicInput,
                                onValueChange = {
                                    systolicInput = it
                                    validationError = null
                                },
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
                                onValueChange = {
                                    diastolicInput = it
                                    validationError = null
                                },
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
                                if (sys == null || sys <= 0 || dia == null || dia <= 0) {
                                    validationError = "Please enter valid systolic and diastolic values"
                                } else {
                                    validationError = null
                                    viewModel.saveManualRecord(sys, dia, selectedTimeMs) {
                                        showAddDialog = false
                                    }
                                }
                            },
                            enabled = !uiState.isSaving,
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                        ) {
                            if (uiState.isSaving) {
                                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            } else {
                                Text("Save")
                            }
                        }
                    },
                    dismissButton = {
                        TextButton(
                            onClick = { showAddDialog = false },
                            enabled = !uiState.isSaving
                        ) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }
        }
    }
}

@Composable
private fun SourceChip(source: BloodPressureSource) {
    val (label, bgColor, textColor) = when (source) {
        BloodPressureSource.HEALTH_CONNECT -> Triple("Health Connect", Color(0xFF1E3A8A), Color(0xFF93C5FD))
        BloodPressureSource.MANUAL -> Triple("Manual", Color(0xFF064E3B), Color(0xFF6EE7B7))
    }
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = bgColor
    ) {
        Text(
            text = label,
            color = textColor,
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
        )
    }
}


