package com.notel.notel.ui.screen

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.notifications.ReminderScheduler
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.ReminderViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemindersScreen(
    onBack: () -> Unit = {},
    viewModel: ReminderViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val reminders by viewModel.reminders.collectAsState()

    // Bottom sheet state for creating a new reminder
    var showAddSheet by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Permission dialog state
    var showNotifDialog   by remember { mutableStateOf(false) }
    var showExactAlarmDialog by remember { mutableStateOf(false) }

    // POST_NOTIFICATIONS launcher (Android 13+)
    val notifPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) showAddSheet = true
    }

    // Check both permissions when FAB is tapped
    fun checkPermissionsAndAdd() {
        // Android 12+ exact alarm check
        if (!ReminderScheduler.canScheduleExactAlarms(context)) {
            showExactAlarmDialog = true
            return
        }
        // Android 13+ notification permission check
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            if (status != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                showNotifDialog = true
                return
            }
        }
        showAddSheet = true
    }

    // ── Dialogs ────────────────────────────────────────────────────────────

    if (showNotifDialog) {
        AlertDialog(
            onDismissRequest = { showNotifDialog = false },
            containerColor = NotelSurface,
            icon = {
                Icon(Icons.Default.Notifications, null, tint = NotelPrimary, modifier = Modifier.size(32.dp))
            },
            title = {
                Text("Enable Notifications", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
            },
            text = {
                Text(
                    "Jot needs notification permission to send your reminders. Tap Allow to continue.",
                    color = NotelTextSecondary,
                    fontSize = 14.sp
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showNotifDialog = false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            notifPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) { Text("Allow") }
            },
            dismissButton = {
                TextButton(onClick = { showNotifDialog = false }) {
                    Text("Not now", color = NotelTextSecondary)
                }
            }
        )
    }

    if (showExactAlarmDialog) {
        AlertDialog(
            onDismissRequest = { showExactAlarmDialog = false },
            containerColor = NotelSurface,
            icon = {
                Icon(Icons.Default.Alarm, null, tint = NotelPrimary, modifier = Modifier.size(32.dp))
            },
            title = {
                Text("Allow Exact Alarms", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
            },
            text = {
                Text(
                    "To send reminders at exactly the right time, Jot needs the Alarms & Reminders permission. Tap Open Settings, then enable it.",
                    color = NotelTextSecondary,
                    fontSize = 14.sp
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showExactAlarmDialog = false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            context.startActivity(
                                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                    data = Uri.parse("package:${context.packageName}")
                                }
                            )
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) { Text("Open Settings") }
            },
            dismissButton = {
                TextButton(onClick = { showExactAlarmDialog = false }) {
                    Text("Not now", color = NotelTextSecondary)
                }
            }
        )
    }

    // ── Main UI ────────────────────────────────────────────────────────────

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Reminders",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextPrimary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { checkPermissionsAndAdd() },
                modifier = Modifier.padding(bottom = 80.dp),
                containerColor = NotelPrimary,
                contentColor = Color.White,
                icon = { Icon(Icons.Default.Add, null) },
                text = { Text("New Reminder", fontWeight = FontWeight.SemiBold) }
            )
        }
    ) { padding ->
        if (reminders.isEmpty()) {
            // Empty state
            Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("🔔", fontSize = 48.sp)
                    Spacer(Modifier.height(16.dp))
                    Text("No reminders yet", color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Tap + New Reminder to get started.",
                        color = NotelTextSecondary,
                        fontSize = 14.sp
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(bottom = 100.dp, top = 8.dp)
            ) {
                items(reminders, key = { it.id }) { reminder ->
                    ReminderCard(
                        reminder = reminder,
                        onToggle = { viewModel.toggleEnabled(reminder) },
                        onDelete = { viewModel.deleteReminder(reminder) }
                    )
                }
            }
        }
    }

    // ── Add Reminder Bottom Sheet ─────────────────────────────────────────

    if (showAddSheet) {
        AddReminderSheet(
            sheetState = sheetState,
            onDismiss = { showAddSheet = false },
            onSave = { title, type, fixedH, fixedM, intervalH, startH, startM, endH, endM ->
                viewModel.addReminder(
                    title         = title,
                    type          = type,
                    fixedHour     = fixedH,
                    fixedMinute   = fixedM,
                    intervalHours = intervalH,
                    startHour     = startH,
                    startMinute   = startM,
                    endHour       = endH,
                    endMinute     = endM
                )
                showAddSheet = false
            }
        )
    }
}

// ── Reminder Card ──────────────────────────────────────────────────────────

@Composable
private fun ReminderCard(
    reminder: Reminder,
    onToggle: () -> Unit,
    onDelete: () -> Unit
) {
    val timeLabel = if (reminder.type == "FIXED") {
        formatTime(reminder.fixedHour, reminder.fixedMinute)
    } else {
        "Every ${reminder.intervalHours}h  •  ${formatTime(reminder.startHour, reminder.startMinute)} – ${formatTime(reminder.endHour, reminder.endMinute)}"
    }

    Surface(
        shape = RoundedCornerShape(20.dp),
        color = if (reminder.isEnabled) NotelSurfaceHigh.copy(alpha = 0.12f) else NotelSurfaceHigh.copy(alpha = 0.05f),
        border = BorderStroke(
            1.dp,
            if (reminder.isEnabled) NotelPrimary.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.04f)
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = if (reminder.type == "FIXED") Icons.Default.Alarm else Icons.Default.Repeat,
                contentDescription = null,
                tint = if (reminder.isEnabled) NotelPrimary else NotelTextSecondary,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = reminder.title,
                    color = if (reminder.isEnabled) NotelTextPrimary else NotelTextSecondary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = timeLabel,
                    color = NotelTextSecondary.copy(alpha = 0.7f),
                    fontSize = 12.sp
                )
            }
            Switch(
                checked = reminder.isEnabled,
                onCheckedChange = { onToggle() },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = NotelPrimary,
                    uncheckedThumbColor = NotelTextSecondary,
                    uncheckedTrackColor = NotelSurfaceHigh.copy(alpha = 0.2f)
                )
            )
            Spacer(Modifier.width(4.dp))
            IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.Default.Close, null,
                    tint = NotelTextSecondary.copy(alpha = 0.4f),
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

// ── Add Reminder Bottom Sheet ──────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddReminderSheet(
    sheetState: SheetState,
    onDismiss: () -> Unit,
    onSave: (String, String, Int, Int, Int, Int, Int, Int, Int) -> Unit
) {
    var title         by remember { mutableStateOf("") }
    var type          by remember { mutableStateOf("FIXED") }   // "FIXED" | "INTERVAL"
    var fixedHour     by remember { mutableIntStateOf(8) }
    var fixedMinute   by remember { mutableIntStateOf(0) }
    var intervalHours by remember { mutableIntStateOf(2) }
    var startHour     by remember { mutableIntStateOf(8) }
    var startMinute   by remember { mutableIntStateOf(0) }
    var endHour       by remember { mutableIntStateOf(21) }
    var endMinute     by remember { mutableIntStateOf(0) }

    val canSave = title.isNotBlank()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = NotelSurface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = NotelTextSecondary.copy(alpha = 0.3f)) }
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 40.dp)
        ) {
            Text(
                "New Reminder",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                color = NotelTextPrimary
            )
            Spacer(Modifier.height(20.dp))

            // Title
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("What do you want to be reminded of?") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                colors = reminderFieldColors()
            )

            Spacer(Modifier.height(20.dp))

            // Type selector
            Text("Reminder type", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TypeChip(label = "Set Time", icon = Icons.Default.Alarm,   selected = type == "FIXED")    { type = "FIXED" }
                TypeChip(label = "Repeating", icon = Icons.Default.Repeat, selected = type == "INTERVAL") { type = "INTERVAL" }
            }

            Spacer(Modifier.height(20.dp))

            AnimatedContent(targetState = type, label = "type_fields") { currentType ->
                when (currentType) {
                    "FIXED" -> {
                        Column {
                            Text("Time", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                            Spacer(Modifier.height(8.dp))
                            TimePickerRow(
                                hour = fixedHour, minute = fixedMinute,
                                onHourChange = { fixedHour = it },
                                onMinuteChange = { fixedMinute = it }
                            )
                        }
                    }
                    "INTERVAL" -> {
                        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            // Interval
                            Column {
                                Text("Repeat every", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                                Spacer(Modifier.height(8.dp))
                                IntervalPicker(hours = intervalHours, onHoursChange = { intervalHours = it })
                            }
                            // Start time
                            Column {
                                Text("Start time", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                                Spacer(Modifier.height(8.dp))
                                TimePickerRow(
                                    hour = startHour, minute = startMinute,
                                    onHourChange = { startHour = it },
                                    onMinuteChange = { startMinute = it }
                                )
                            }
                            // End time
                            Column {
                                Text("End time", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                                Spacer(Modifier.height(8.dp))
                                TimePickerRow(
                                    hour = endHour, minute = endMinute,
                                    onHourChange = { endHour = it },
                                    onMinuteChange = { endMinute = it }
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(28.dp))

            Button(
                onClick = {
                    onSave(title, type, fixedHour, fixedMinute, intervalHours, startHour, startMinute, endHour, endMinute)
                },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(16.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = NotelPrimary,
                    disabledContainerColor = NotelSurfaceHigh.copy(alpha = 0.2f)
                )
            ) {
                Icon(Icons.Default.Check, null)
                Spacer(Modifier.width(8.dp))
                Text("Save Reminder", fontWeight = FontWeight.Bold, fontSize = 16.sp)
            }
        }
    }
}

// ── Sub-components ─────────────────────────────────────────────────────────

@Composable
private fun TypeChip(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, selected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = if (selected) NotelPrimary.copy(alpha = 0.15f) else NotelSurfaceHigh.copy(alpha = 0.08f),
        border = BorderStroke(1.dp, if (selected) NotelPrimary.copy(alpha = 0.4f) else Color.White.copy(alpha = 0.06f)),
        modifier = Modifier.height(42.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 14.dp)
        ) {
            Icon(icon, null, tint = if (selected) NotelPrimary else NotelTextSecondary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(label, color = if (selected) NotelPrimary else NotelTextSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun TimePickerRow(
    hour: Int, minute: Int,
    onHourChange: (Int) -> Unit, onMinuteChange: (Int) -> Unit
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Hour dropdown
        TimeDropdown(
            value = hour,
            options = (0..23).toList(),
            label = "Hour",
            display = { h ->
                val amPm = if (h < 12) "AM" else "PM"
                val h12 = when (h % 12) { 0 -> 12; else -> h % 12 }
                "$h12 $amPm"
            },
            onSelect = onHourChange,
            modifier = Modifier.weight(1f)
        )
        Text(":", color = NotelTextSecondary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        // Minute dropdown
        TimeDropdown(
            value = minute,
            options = listOf(0, 15, 30, 45),
            label = "Min",
            display = { m -> "%02d".format(m) },
            onSelect = onMinuteChange,
            modifier = Modifier.weight(0.7f)
        )
    }
}

@Composable
private fun IntervalPicker(hours: Int, onHoursChange: (Int) -> Unit) {
    TimeDropdown(
        value = hours,
        options = listOf(1, 2, 3, 4, 6, 8, 12),
        label = "Every",
        display = { h -> if (h == 1) "1 hour" else "$h hours" },
        onSelect = onHoursChange,
        modifier = Modifier.fillMaxWidth(0.55f)
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeDropdown(
    value: Int,
    options: List<Int>,
    label: String,
    display: (Int) -> String,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = !expanded }, modifier = modifier) {
        OutlinedTextField(
            value = display(value),
            onValueChange = {},
            readOnly = true,
            label = { Text(label, fontSize = 11.sp) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.menuAnchor().fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = reminderFieldColors()
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            containerColor = NotelSurface
        ) {
            options.forEach { opt ->
                DropdownMenuItem(
                    text = { Text(display(opt), color = if (opt == value) NotelPrimary else NotelTextPrimary) },
                    onClick = { onSelect(opt); expanded = false },
                    leadingIcon = if (opt == value) { { Icon(Icons.Default.Check, null, tint = NotelPrimary, modifier = Modifier.size(16.dp)) } } else null
                )
            }
        }
    }
}

@Composable
private fun reminderFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor    = NotelPrimary.copy(alpha = 0.5f),
    unfocusedBorderColor  = NotelSurfaceHigh.copy(alpha = 0.2f),
    focusedTextColor      = NotelTextPrimary,
    unfocusedTextColor    = NotelTextPrimary,
    focusedLabelColor     = NotelPrimary,
    unfocusedLabelColor   = NotelTextSecondary,
    cursorColor           = NotelPrimary,
    focusedContainerColor   = NotelSurfaceHigh.copy(alpha = 0.05f),
    unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.05f)
)

private fun formatTime(hour: Int, minute: Int): String {
    val amPm = if (hour < 12) "AM" else "PM"
    val h12  = when (hour % 12) { 0 -> 12; else -> hour % 12 }
    return "$h12:%02d $amPm".format(minute)
}
