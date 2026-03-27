package com.notel.notel.ui.screen

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.HistoryViewModel
import com.notel.notel.ui.viewmodel.HabitViewModel
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    viewModel: HistoryViewModel = hiltViewModel(),
    habitViewModel: HabitViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onEntryClick: (Long) -> Unit
) {
    val entries by viewModel.entries.collectAsState()
    val categories by viewModel.categories.collectAsState()
    val searchQuery by viewModel.searchQuery.collectAsState()
    val categoryFilter by viewModel.categoryFilter.collectAsState()
    var isRoutineTab by remember { mutableStateOf(false) }

    val habits by habitViewModel.habits.collectAsState()
    val isHabitsLoading by habitViewModel.isLoading.collectAsState()
    val habitError by habitViewModel.error.collectAsState()
    var newHabitText by remember { mutableStateOf("") }
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(habitError) {
        if (!habitError.isNullOrBlank()) {
            snackbarHostState.showSnackbar(habitError!!)
        }
    }

    val checkedCount = habits.count { habitViewModel.isCheckedToday(it) }
    val totalCount = habits.size.coerceAtLeast(1)
    val progressRatio = checkedCount.toFloat() / totalCount.toFloat()

    Scaffold(
        containerColor = NotelBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("History", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, "Back", tint = NotelTextSecondary)
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
        ) {
            // ── Two-Tab Toggle ─────────────────────────────────────────────
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(NotelSurfaceHigh),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                TextButton(
                    onClick = { isRoutineTab = false },
                    modifier = Modifier.weight(1f).background(if (!isRoutineTab) NotelPrimary else Color.Transparent),
                    colors = ButtonDefaults.textButtonColors(contentColor = if (!isRoutineTab) Color.White else NotelTextSecondary)
                ) {
                    Text("📝 Notes", fontWeight = FontWeight.Bold)
                }
                TextButton(
                    onClick = { isRoutineTab = true },
                    modifier = Modifier.weight(1f).background(if (isRoutineTab) NotelPrimary else Color.Transparent),
                    colors = ButtonDefaults.textButtonColors(contentColor = if (isRoutineTab) Color.White else NotelTextSecondary)
                ) {
                    Text("🗓️ Routine", fontWeight = FontWeight.Bold)
                }
            }

            if (isRoutineTab) {
                // ── Routine Tab (Live Data) ─────────────────────────────────
                Column(Modifier.fillMaxSize().padding(16.dp)) {
                    Text("Daily Progress", color = NotelTextSecondary, fontSize = 14.sp)
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(progress = progressRatio, color = NotelPrimary, modifier = Modifier.size(48.dp))
                        Spacer(Modifier.width(16.dp))
                        Text("$checkedCount of ${habits.size} Habits Completed 🔥", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.height(24.dp))
                    Text("Your Daily Routine", color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                    Spacer(Modifier.height(6.dp))
                    Text("Tracking actions here explicitly trains your Jot AI context window to actively cross-reference patterns in your daily unstructured Notes against your physical streaks.", color = NotelTextSecondary, fontSize = 12.sp, lineHeight = 16.sp)
                    Spacer(Modifier.height(16.dp))

                    if (isHabitsLoading && habits.isEmpty()) {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(32.dp))
                        }
                    } else {
                        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            items(habits, key = { it.id }) { habit ->
                                val isCheckedToday = habitViewModel.isCheckedToday(habit)
                                val streak = habitViewModel.getStreak(habit)
                                GlassyCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = NotelSurface) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(16.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        // 🔥 Streak — left of checkbox
                                        Text(
                                            "🔥 $streak",
                                            color = if (streak > 0) Color(0xFFE2A123) else NotelTextSecondary,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                        Spacer(Modifier.width(4.dp))
                                        Checkbox(
                                            checked = isCheckedToday,
                                            onCheckedChange = { checked ->
                                                habitViewModel.toggleHabit(habit.id, checked)
                                            },
                                            colors = CheckboxDefaults.colors(checkedColor = NotelPrimary, uncheckedColor = NotelTextSecondary)
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        // Title + time — fills remaining space, wraps naturally
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                habit.title,
                                                color = NotelTextPrimary,
                                                fontWeight = FontWeight.Bold,
                                                softWrap = true,
                                                fontSize = 15.sp,
                                                lineHeight = 19.sp
                                            )
                                            Text(habit.target_time ?: "Anytime", color = NotelTextSecondary, fontSize = 12.sp)
                                        }
                                        Spacer(Modifier.width(8.dp))
                                        // Trash — pinned to far right
                                        IconButton(onClick = { habitViewModel.deleteHabit(habit.id) }, modifier = Modifier.size(24.dp)) {
                                            Icon(Icons.Default.Delete, "Delete", tint = NotelTextSecondary, modifier = Modifier.size(18.dp))
                                        }
                                    }
                                }
                            }

                            item {
                                Spacer(Modifier.height(8.dp))
                                OutlinedTextField(
                                    value = newHabitText,
                                    onValueChange = { newHabitText = it },
                                    placeholder = { Text("Add new habit...", color = NotelTextSecondary) },
                                    modifier = Modifier.fillMaxWidth(),
                                    trailingIcon = {
                                        if (newHabitText.isNotBlank()) {
                                            IconButton(onClick = {
                                                habitViewModel.addHabit(newHabitText)
                                                newHabitText = ""
                                            }) {
                                                Icon(Icons.Default.Add, "Add", tint = NotelPrimary)
                                            }
                                        }
                                    },
                                    shape = RoundedCornerShape(16.dp),
                                    singleLine = true,
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = NotelPrimary,
                                        unfocusedBorderColor = NotelSurfaceHigh,
                                        focusedTextColor = NotelTextPrimary,
                                        unfocusedTextColor = NotelTextPrimary,
                                        cursorColor = NotelPrimary
                                    )
                                )
                            }
                        }
                    }
                }
            } else {
            // ── Search Bar ───────────────────────────────────────────────
            OutlinedTextField(
                value = searchQuery,
                onValueChange = viewModel::setSearchQuery,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                placeholder = { Text("Search entries…", color = NotelTextSecondary) },
                leadingIcon = { Icon(Icons.Default.Search, null, tint = NotelTextSecondary) },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { viewModel.setSearchQuery("") }) {
                            Icon(Icons.Default.Clear, null, tint = NotelTextSecondary)
                        }
                    }
                },
                shape = RoundedCornerShape(14.dp),
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelSurfaceHigh,
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary,
                    unfocusedContainerColor = NotelSurface,
                    focusedContainerColor = NotelSurface
                )
            )

            // ── Category Filter Row ──────────────────────────────────────
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item {
                    Surface(
                        onClick = { viewModel.setCategoryFilter(null) },
                        modifier = Modifier.liquidGlass(
                            shape = RoundedCornerShape(12.dp),
                            color = if (categoryFilter == null) NotelPrimary else NotelSurfaceHigh,
                            alpha = if (categoryFilter == null) 0.6f else 0.3f
                        ),
                        color = Color.Transparent
                    ) {
                        Text(
                            "All",
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                            color = if (categoryFilter == null) Color.White else NotelTextSecondary,
                            fontSize = 13.sp,
                            fontWeight = if (categoryFilter == null) FontWeight.Bold else FontWeight.Medium
                        )
                    }
                }
                items(categories) { cat ->
                    val isSelected = categoryFilter == cat.id
                    Surface(
                        onClick = { viewModel.setCategoryFilter(if (isSelected) null else cat.id) },
                        modifier = Modifier.liquidGlass(
                            shape = RoundedCornerShape(12.dp),
                            color = if (isSelected) NotelPrimary else NotelSurfaceHigh,
                            alpha = if (isSelected) 0.6f else 0.3f
                        ),
                        color = Color.Transparent
                    ) {
                        Text(
                            cat.name,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                            color = if (isSelected) Color.White else NotelTextSecondary,
                            fontSize = 13.sp,
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
                        )
                    }
                }
            }

            // ── Entry Count ──────────────────────────────────────────────
            Text(
                "${entries.size} ${if (entries.size == 1) "entry" else "entries"}",
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
                color = NotelTextSecondary,
                fontSize = 12.sp
            )

            // ── Entry List ────────────────────────────────────────────────
            if (entries.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Default.NoteAlt, null, tint = NotelSurfaceHigh, modifier = Modifier.size(64.dp))
                        Spacer(Modifier.height(12.dp))
                        Text("No entries yet", color = NotelTextSecondary)
                    }
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    items(entries, key = { it.id }) { entry ->
                        EntryCard(
                            entry = entry,
                            category = categories.find { it.id == entry.categoryId },
                            onClick = { onEntryClick(entry.id) },
                            onDelete = { viewModel.deleteEntry(entry) }
                        )
                    }
                }
            }
            } // Close else block for isRoutineTab
        }
    }
}

@Composable
private fun EntryCard(
    entry: LogEntry,
    category: Category?,
    onClick: () -> Unit,
    onDelete: () -> Unit
) {
    var showDeleteConfirm by remember { mutableStateOf(false) }
    val sdf = remember { SimpleDateFormat("MMM d, yyyy · h:mm a", Locale.getDefault()) }

    GlassyCard(
        modifier = Modifier.fillMaxWidth().animateContentSize(),
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface
    ) {
        Column(modifier = Modifier.clickable { onClick() }) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Category tag
                if (category != null) {
                    val catColor = try { Color(android.graphics.Color.parseColor(category.colorHex)) }
                    catch (e: Exception) { NotelPrimary }
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = catColor.copy(alpha = 0.2f)
                    ) {
                        Text(
                            category.name,
                            color = catColor,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                        )
                    }
                }
                IconButton(
                    onClick = { showDeleteConfirm = true },
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(Icons.Default.Delete, null, tint = NotelTextSecondary, modifier = Modifier.size(18.dp))
                }
            }

            Spacer(Modifier.height(8.dp))
            Text(entry.body, color = NotelTextPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(6.dp))
            Text(sdf.format(Date(entry.timestamp)), color = NotelTextSecondary, fontSize = 12.sp)
        }
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            containerColor = NotelSurface,
            title = { Text("Delete entry?", color = NotelTextPrimary) },
            text = { Text("This cannot be undone.", color = NotelTextSecondary) },
            confirmButton = {
                TextButton(onClick = { onDelete(); showDeleteConfirm = false }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") }
            }
        )
    }
}
