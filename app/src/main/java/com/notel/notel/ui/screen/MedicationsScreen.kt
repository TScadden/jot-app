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
import androidx.activity.compose.BackHandler
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.MedicationsViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MedicationsScreen(
    viewModel: MedicationsViewModel = hiltViewModel(),
    onBack: () -> Unit = {}
) {
    BackHandler(onBack = onBack)

    val activeMedications by viewModel.activeMedications.collectAsState()
    val archivedMedications by viewModel.archivedMedications.collectAsState()
    val isExtracting by viewModel.isExtractingFromProfile.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()

    var showAddDialog by remember { mutableStateOf(false) }
    var editingMedication by remember { mutableStateOf<Medication?>(null) }
    var showInfoDialog by remember { mutableStateOf(false) }
    var showArchivedSection by remember { mutableStateOf(true) }

    var medName by remember { mutableStateOf("") }
    var medDose by remember { mutableStateOf("") }
    var medFrequency by remember { mutableStateOf("Once daily") }
    var medEndedDate by remember { mutableStateOf("") }

    // Animated Top Banner State
    var bannerMessage by remember { mutableStateOf<String?>(null) }
    var bannerVisible by remember { mutableStateOf(false) }

    LaunchedEffect(statusMessage) {
        statusMessage?.let { msg ->
            bannerMessage = msg
            bannerVisible = true
            viewModel.clearStatusMessage()
            kotlinx.coroutines.delay(3000)
            bannerVisible = false
        }
    }

    // Check if all active medications have valid filled-out doses
    val allActiveDosesValid = remember(activeMedications) {
        activeMedications.isNotEmpty() && activeMedications.none { 
            it.dose.isBlank() || it.dose.equals("As prescribed", ignoreCase = true) 
        }
    }

    Scaffold(
        containerColor = NotelBackground,
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
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
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
                                    text = "${activeMedications.size} Active Medication(s)",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = NotelTextSecondary
                                )
                            }

                            Button(
                                onClick = { viewModel.takeAllMedications() },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = NotelPrimary,
                                    disabledContainerColor = NotelSurfaceHigh.copy(alpha = 0.4f)
                                ),
                                shape = RoundedCornerShape(14.dp),
                                enabled = allActiveDosesValid
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Check,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                    tint = if (allActiveDosesValid) Color.White else NotelTextSecondary
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "Took All Meds", 
                                    fontWeight = FontWeight.Bold,
                                    color = if (allActiveDosesValid) Color.White else NotelTextSecondary
                                )
                            }
                        }

                        if (activeMedications.isNotEmpty() && !allActiveDosesValid) {
                            Spacer(Modifier.height(8.dp))
                            Text(
                                text = "⚠️ Fill out missing doses below to unlock 'Took Med' logging.",
                                color = NotelPrimary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold
                            )
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
                                onClick = { 
                                    editingMedication = null
                                    medName = ""
                                    medDose = ""
                                    medFrequency = "Once daily"
                                    showAddDialog = true 
                                },
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
                    text = "Active Prescriptions",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary
                )
            }

            if (activeMedications.isEmpty()) {
                item {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 24.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Default.Medication,
                                contentDescription = null,
                                tint = NotelPrimary.copy(alpha = 0.6f),
                                modifier = Modifier.size(44.dp)
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                text = "No Active Medications",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Tap 'Load from Profile' or 'Add Custom' to add your current meds.",
                                style = MaterialTheme.typography.bodySmall,
                                color = NotelTextSecondary
                            )
                        }
                    }
                }
            } else {
                items(activeMedications) { med ->
                    MedicationCard(
                        medication = med,
                        isArchived = false,
                        onClick = {
                            editingMedication = med
                            medName = med.name
                            medDose = if (med.dose == "As prescribed") "" else med.dose
                            medFrequency = med.frequency
                            showAddDialog = true
                        },
                        onTookMed = { viewModel.takeSingleMedication(med) },
                        onArchive = { viewModel.archiveMedication(med) },
                        onDelete = { viewModel.deleteMedication(med) }
                    )
                }

            // Archived Medications Section
            if (archivedMedications.isNotEmpty()) {
                item {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { showArchivedSection = !showArchivedSection }
                            .padding(top = 12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Default.Archive,
                                contentDescription = null,
                                tint = NotelTextSecondary,
                                modifier = Modifier.size(18.dp)
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "Archived Medications (${archivedMedications.size})",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = NotelTextSecondary
                            )
                        }

                        Icon(
                            imageVector = if (showArchivedSection) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                            contentDescription = null,
                            tint = NotelTextSecondary
                        )
                    }
                }

                if (showArchivedSection) {
                    items(archivedMedications) { med ->
                        MedicationCard(
                            medication = med,
                            isArchived = true,
                            onClick = {
                                editingMedication = med
                                medName = med.name
                                medDose = if (med.dose == "As prescribed") "" else med.dose
                                medFrequency = med.frequency
                                medEndedDate = med.endedDate ?: ""
                                showAddDialog = true
                            },
                            onUnarchive = { viewModel.unarchiveMedication(med) },
                            onDelete = { viewModel.deleteMedication(med) }
                        )
                    }
                }
            }
            TopSlideNotificationBanner(
                visible = bannerVisible,
                message = bannerMessage ?: "",
                onDismiss = { bannerVisible = false }
            )
        }

    // Add / Edit Custom Med Dialog
    if (showAddDialog) {
        AlertDialog(
            onDismissRequest = { showAddDialog = false },
            title = {
                Text(
                    text = if (editingMedication != null) "Edit Medication" else "Add New Medication",
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary
                )
            },
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
                        label = { Text("Dose * (e.g. 50mg, 60mg, 0.5ml)") },
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
                    if (editingMedication?.isArchived == true) {
                        OutlinedTextField(
                            value = medEndedDate,
                            onValueChange = { medEndedDate = it },
                            label = { Text("Ended Date (e.g. Jul 24, 2026)") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (medName.isNotBlank() && medDose.isNotBlank()) {
                            val currentMed = editingMedication
                            if (currentMed != null) {
                                viewModel.updateMedication(
                                    medication = currentMed,
                                    name = medName,
                                    dose = medDose,
                                    frequency = medFrequency,
                                    endedDate = if (currentMed.isArchived) medEndedDate else currentMed.endedDate
                                )
                            } else {
                                viewModel.addMedication(medName, medDose, medFrequency)
                            }
                            medName = ""
                            medDose = ""
                            medFrequency = "Once daily"
                            medEndedDate = ""
                            editingMedication = null
                            showAddDialog = false
                        }
                    },
                    enabled = medName.isNotBlank() && medDose.isNotBlank()
                ) {
                    Text("Save Medication")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { 
                        editingMedication = null
                        showAddDialog = false 
                    }
                ) {
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
                        text = "• Click to Edit: Tap any medication card to edit its name, dose, or frequency.",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextPrimary
                    )
                    Text(
                        text = "• Required Dose Locking: 'Took Med' and 'Took All Meds' require a valid dose to be filled out.",
                        style = MaterialTheme.typography.bodySmall,
                        color = NotelTextPrimary
                    )
                    Text(
                        text = "• Active & Archived: Archive medications you no longer take to keep your list clean while preserving history with their ended date.",
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
    isArchived: Boolean = false,
    onClick: () -> Unit = {},
    onTookMed: () -> Unit = {},
    onArchive: () -> Unit = {},
    onUnarchive: () -> Unit = {},
    onDelete: () -> Unit = {}
) {
    val isDoseValid = medication.dose.isNotBlank() && !medication.dose.equals("As prescribed", ignoreCase = true)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .clickable { onClick() }
            .liquidGlass(
                shape = RoundedCornerShape(20.dp),
                color = NotelSurface,
                alpha = if (isArchived) 0.45f else 0.8f,
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
                        .background(
                            if (isArchived) NotelTextSecondary.copy(alpha = 0.15f) else NotelPrimary.copy(alpha = 0.15f),
                            CircleShape
                        )
                        .border(1.5.dp, if (isArchived) NotelTextSecondary else NotelPrimary, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = if (isArchived) Icons.Default.Archive else Icons.Default.Medication,
                        contentDescription = null,
                        tint = if (isArchived) NotelTextSecondary else NotelPrimary,
                        modifier = Modifier.size(22.dp)
                    )
                }

                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = medication.name,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (isArchived) NotelTextSecondary else NotelTextPrimary
                        )
                        Spacer(Modifier.width(6.dp))
                        Icon(
                            imageVector = Icons.Default.Edit,
                            contentDescription = "Tap to edit",
                            tint = NotelTextSecondary.copy(alpha = 0.5f),
                            modifier = Modifier.size(14.dp)
                        )
                    }

                    Spacer(Modifier.height(2.dp))
                    if (isArchived && !medication.endedDate.isNullOrBlank()) {
                        Surface(
                            color = NotelTextSecondary.copy(alpha = 0.15f),
                            shape = RoundedCornerShape(6.dp)
                        ) {
                            Text(
                                text = "Ended ${medication.endedDate}",
                                color = NotelTextSecondary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    } else {
                        Text(
                            text = if (isDoseValid) "${medication.dose}  •  ${medication.frequency}" else "Tap to set dose  •  ${medication.frequency}",
                            style = MaterialTheme.typography.bodySmall,
                            color = if (isDoseValid) NotelTextSecondary else NotelPrimary
                        )
                    }
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!isArchived) {
                    Button(
                        onClick = onTookMed,
                        enabled = isDoseValid,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = NotelPrimary,
                            disabledContainerColor = NotelSurfaceHigh.copy(alpha = 0.4f)
                        ),
                        shape = RoundedCornerShape(12.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Text(
                            "Took Med",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (isDoseValid) Color.White else NotelTextSecondary
                        )
                    }

                    IconButton(onClick = onArchive) {
                        Icon(
                            imageVector = Icons.Default.Archive,
                            contentDescription = "Archive",
                            tint = NotelTextSecondary
                        )
                    }
                } else {
                    IconButton(onClick = onUnarchive) {
                        Icon(
                            imageVector = Icons.Default.Unarchive,
                            contentDescription = "Re-activate",
                            tint = NotelPrimary
                        )
                    }
                    IconButton(onClick = onDelete) {
                        Icon(
                            imageVector = Icons.Default.DeleteOutline,
                            contentDescription = "Delete permanently",
                            tint = NotelTextSecondary
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TopSlideNotificationBanner(
    visible: Boolean,
    message: String,
    onDismiss: () -> Unit
) {
    androidx.compose.animation.AnimatedVisibility(
        visible = visible,
        enter = androidx.compose.animation.slideInVertically(initialOffsetY = { -it }) + androidx.compose.animation.fadeIn(),
        exit = androidx.compose.animation.slideOutVertically(targetOffsetY = { -it }) + androidx.compose.animation.fadeOut(),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .clickable { onDismiss() },
            color = Color(0xFF1E293B),
            tonalElevation = 8.dp,
            shadowElevation = 8.dp,
            border = androidx.compose.foundation.BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.5f))
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.weight(1f)
                ) {
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(NotelPrimary.copy(alpha = 0.2f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = NotelPrimary,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = message,
                        color = NotelTextPrimary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium
                    )
                }

                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Dismiss",
                        tint = NotelTextSecondary,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
        }
    }
}
