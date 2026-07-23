package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.MedicationsViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MedicationsScreen(
    viewModel: MedicationsViewModel = hiltViewModel(),
    onBack: () -> Unit = {}
) {
    val medications by viewModel.medications.collectAsState()
    val isExtracting by viewModel.isExtractingFromProfile.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()

    var showAddDialog by remember { mutableStateOf(false) }
    var showInfoDialog by remember { mutableStateOf(false) }

    var medName by remember { mutableStateOf("") }
    var medDose by remember { mutableStateOf("") }
    var medFrequency by remember { mutableStateOf("Once daily") }

    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(statusMessage) {
        statusMessage?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearStatusMessage()
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Medications & Side Effects",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.Default.ArrowBack,
                            contentDescription = "Back",
                            tint = NotelTextPrimary
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { showInfoDialog = true }) {
                        Icon(
                            imageVector = Icons.Default.Info,
                            contentDescription = "Medications Info",
                            tint = NotelPrimary
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(bottom = 100.dp)
        ) {
            item {
                Text(
                    text = "Manage your active prescriptions and log doses to track body side-effects in real time.",
                    color = NotelTextSecondary,
                    fontSize = 14.sp
                )
            }

            // Hero Action Card (Took All Meds & Profile Loader)
            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(24.dp))
                        .liquidGlass(
                            shape = RoundedCornerShape(24.dp),
                            color = NotelSurface,
                            alpha = 0.85f,
                            showBorder = true
                        )
                        .padding(20.dp)
                ) {
                    Column {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Text(
                                    text = "Quick Actions",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = NotelTextPrimary
                                )
                                Text(
                                    text = "${medications.size} Active Medication(s)",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = NotelTextSecondary
                                )
                            }

                            Button(
                                onClick = { viewModel.takeAllMedications() },
                                colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                                shape = RoundedCornerShape(14.dp),
                                enabled = medications.isNotEmpty()
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Check,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text("Took All Meds", fontWeight = FontWeight.Bold)
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            OutlinedButton(
                                onClick = { viewModel.loadMedicationsFromProfile() },
                                modifier = Modifier.weight(1f),
                                shape = RoundedCornerShape(12.dp),
                                enabled = !isExtracting
                            ) {
                                if (isExtracting) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                } else {
                                    Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Load from Profile", fontSize = 12.sp)
                                }
                            }

                            Button(
                                onClick = { showAddDialog = true },
                                modifier = Modifier.weight(1f),
                                colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                                shape = RoundedCornerShape(12.dp)
                            ) {
                                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp), tint = NotelTextPrimary)
                                Spacer(Modifier.width(6.dp))
                                Text("Add Custom", fontSize = 12.sp, color = NotelTextPrimary)
                            }
                        }
                    }
                }
            }

            item {
                Text(
                    text = "Your Prescriptions",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary
                )
            }

            if (medications.isEmpty()) {
                item {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Default.Medication,
                                contentDescription = null,
                                tint = NotelPrimary.copy(alpha = 0.6f),
                                modifier = Modifier.size(48.dp)
                            )
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = "No Medications Added Yet",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Tap 'Load from Profile' or 'Add Custom' to get started.",
                                style = MaterialTheme.typography.bodySmall,
                                color = NotelTextSecondary
                            )
                        }
                    }
                }
            } else {
                items(medications) { med ->
                    MedicationCard(
                        medication = med,
                        onTookMed = { viewModel.takeSingleMedication(med) },
                        onDelete = { viewModel.deleteMedication(med) }
                    )
                }
            }
        }
    }

    // Add Custom Med Dialog
    if (showAddDialog) {
        AlertDialog(
            onDismissRequest = { showAddDialog = false },
            title = { Text("Add New Medication", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = medName,
                        onValueChange = { medName = it },
                        label = { Text("Medication Name *") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = medDose,
                        onValueChange = { medDose = it },
                        label = { Text("Dose * (e.g. 50mg, 0.5ml)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = medFrequency,
                        onValueChange = { medFrequency = it },
                        label = { Text("Frequency * (e.g. Twice daily, Once weekly)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (medName.isNotBlank() && medDose.isNotBlank()) {
                            viewModel.addMedication(medName, medDose, medFrequency)
                            medName = ""
                            medDose = ""
                            medFrequency = "Once daily"
                            showAddDialog = false
                        }
                    },
                    enabled = medName.isNotBlank() && medDose.isNotBlank()
                ) {
                    Text("Save Medication")
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddDialog = false }) {
                    Text("Cancel")
                }
            },
            containerColor = NotelSurface
        )
    }

    // Info Explanation Dialog
    if (showInfoDialog) {
        AlertDialog(
            onDismissRequest = { showInfoDialog = false },
            title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Info, contentDescription = null, tint = NotelPrimary)
                    Spacer(Modifier.width(8.dp))
                    Text("How Medications Work", fontWeight = FontWeight.Bold, color = NotelTextPrimary)
                }
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "• Required Fields: Every medication must have a Name, Dose, and Frequency filled out.",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextPrimary
                    )
                    Text(
                        text = "• 'Took Med' Logging: Clicking 'Took Med' creates a log entry for your history and triggers the Body Info map to show potential side effects.",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextPrimary
                    )
                    Text(
                        text = "• 'Took All Meds': Logs 1 dose for each active medication. If a medication is taken multiple times per day (e.g. 3x daily), taking it logs a single dose, not the full day's total.",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextPrimary
                    )
                    Text(
                        text = "• Smart AI Caching: Once Gemini AI looks up side-effects and duration for a medication, it is cached locally so it never wastes your credits again!",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextPrimary
                    )
                }
            },
            confirmButton = {
                Button(onClick = { showInfoDialog = false }) {
                    Text("Got It")
                }
            },
            containerColor = NotelSurface
        )
    }
}

@Composable
fun MedicationCard(
    medication: Medication,
    onTookMed: () -> Unit,
    onDelete: () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .liquidGlass(
                shape = RoundedCornerShape(20.dp),
                color = NotelSurface,
                alpha = 0.8f,
                showBorder = true
            )
            .padding(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.weight(1f)
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .background(NotelPrimary.copy(alpha = 0.15f), CircleShape)
                        .border(1.5.dp, NotelPrimary, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Default.Medication,
                        contentDescription = null,
                        tint = NotelPrimary,
                        modifier = Modifier.size(22.dp)
                    )
                }

                Column {
                    Text(
                        text = medication.name,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = "${medication.dose}  •  ${medication.frequency}",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextSecondary
                    )
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = onTookMed,
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    shape = RoundedCornerShape(12.dp),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                ) {
                    Text("Took Med", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }

                IconButton(onClick = onDelete) {
                    Icon(
                        imageVector = Icons.Default.DeleteOutline,
                        contentDescription = "Delete",
                        tint = NotelTextSecondary
                    )
                }
            }
        }
    }
}
