package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.viewmodel.ENERGY_CHECKIN_SOURCE
import com.notel.notel.ui.viewmodel.ENERGY_CHECKIN_TAG
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject
import kotlinx.serialization.decodeFromString

// ── ViewModel ─────────────────────────────────────────────────────────────────

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@HiltViewModel
class EntryDetailViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository,
    private val logEntryDao: com.notel.notel.data.local.dao.LogEntryDao
) : ViewModel() {

    private val _entryId = MutableStateFlow<Long?>(null)

    val entry: StateFlow<LogEntry?> = _entryId
        .flatMapLatest { id ->
            if (id == null) flowOf(null)
            else logEntryDao.getEntryByIdFlow(id)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val categories = categoryRepository.getAllCategories()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun loadEntry(id: Long) {
        _entryId.value = id
    }

    fun deleteEntry(entry: LogEntry, onDone: () -> Unit) {
        viewModelScope.launch {
            logRepository.deleteEntry(entry)
            onDone()
        }
    }

    fun updateCategory(categoryId: Int) {
        val current = entry.value ?: return
        // Energy check-in entries are fully locked: category and text cannot
        // change. The entry detail UI hides both affordances; this guard is
        // belt and suspenders for any direct save-path call.
        if (current.source == ENERGY_CHECKIN_SOURCE) return
        // Prevent modifying category for entries logged from the Medications tab
        if (current.source == "Medications Tab" || current.chips.contains("Medication Tab")) {
            return
        }
        viewModelScope.launch {
            val catName = categories.value.find { it.id == categoryId }?.name ?: ""
            // Energy check-in entries keep their locked "Daily Ranking" tag no
            // matter what else changes on the entry; all other entries keep the
            // previous behavior (chips become the new category name). The early
            // return above already blocks check-in edits; this stays as
            // defense in depth so the tag can never be dropped by an edit path.
            val updatedChipsJson = if (current.source == ENERGY_CHECKIN_SOURCE) {
                dailyRankingTagJson()
            } else {
                val updatedChips = if (catName.isNotBlank()) listOf(catName) else emptyList()
                org.json.JSONArray(updatedChips).toString()
            }

            val updated = current.copy(
                categoryId = categoryId,
                chips = updatedChipsJson,
                updatedAt = System.currentTimeMillis(),
                syncState = com.notel.notel.data.local.entity.EntrySyncState.DIRTY
            )
            logRepository.updateEntry(updated)
        }
    }

    fun updateText(body: String, manualText: String) {
        val current = entry.value ?: return
        // Energy check-in entries are fully locked: text and category cannot
        // change. The entry detail UI hides both affordances; this guard is
        // belt and suspenders for any direct save-path call.
        if (current.source == ENERGY_CHECKIN_SOURCE) return
        viewModelScope.launch {
            val updated = current.copy(
                body = body,
                manualText = manualText,
                // Belt and suspenders: the locked tag can never be dropped by an
                // edit-save round trip, even if chips arrive mangled.
                chips = withCheckInTagIfNeeded(current),
                updatedAt = System.currentTimeMillis(),
                syncState = com.notel.notel.data.local.entity.EntrySyncState.DIRTY
            )
            logRepository.updateEntry(updated)
        }
    }

    // ── Locked "Daily Ranking" tag helpers ────────────────────────────────
    // Energy check-in entries (source "Energy check-in") carry the reserved
    // "Daily Ranking" tag, which the user cannot remove, replace, or edit.
    // Every save path for these entries re-applies it, so no edit flow can
    // drop it. Additive only: other entries' chips are never touched.

    private fun dailyRankingTagJson(): String =
        org.json.JSONArray(listOf(ENERGY_CHECKIN_TAG)).toString()

    private fun withCheckInTagIfNeeded(current: LogEntry): String {
        if (current.source != ENERGY_CHECKIN_SOURCE) return current.chips
        return try {
            val arr = org.json.JSONArray(current.chips)
            val labels = (0 until arr.length()).map { arr.optString(it) }
            if (ENERGY_CHECKIN_TAG in labels) current.chips
            else org.json.JSONArray(labels + ENERGY_CHECKIN_TAG).toString()
        } catch (_: Exception) {
            dailyRankingTagJson()
        }
    }
}

// ── Screen ────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EntryDetailScreen(
    entryId: Long,
    viewModel: EntryDetailViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    LaunchedEffect(entryId) { viewModel.loadEntry(entryId) }

    val entry by viewModel.entry.collectAsState()
    val categories by viewModel.categories.collectAsState()
    var showDelete by remember { mutableStateOf(false) }
    var showEditDialog by remember { mutableStateOf(false) }
    // Check-in entries are fully locked: hide both edit affordances (text and
    // category). Delete stays available. Computed here so the top bar can use it.
    val isCheckInEntry = entry?.source == ENERGY_CHECKIN_SOURCE
    val sdf = remember { SimpleDateFormat("EEEE, MMMM d, yyyy 'at' h:mm a", Locale.getDefault()) }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text("Entry", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    // Locked check-in entries offer no edit path; delete stays.
                    if (!isCheckInEntry) {
                        IconButton(onClick = { showEditDialog = true }) {
                            Icon(Icons.Default.Edit, "Edit", tint = NotelPrimary)
                        }
                    }
                    IconButton(onClick = { showDelete = true }) {
                        Icon(Icons.Default.Delete, "Delete", tint = Color.Red.copy(alpha = 0.7f))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        entry?.let { e ->
            val category = categories.find { it.id == e.categoryId }
            val chips = try {
                @Suppress("DEPRECATION")
                Json.decodeFromString<List<String>>(e.chips)
            } catch (_: Exception) { emptyList() }

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(16.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(20.dp) // More spacious
            ) {
                val isMedTabEntry = e.source == "Medications Tab" || e.chips.contains("Medication Tab")
                if (isMedTabEntry) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(NotelSurfaceHigh)
                            .border(1.dp, NotelBorder, RoundedCornerShape(12.dp))
                            .padding(horizontal = 16.dp, vertical = 12.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Medication, null, tint = NotelTextSecondary, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "Logged via Medications tab",
                                color = NotelTextSecondary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 0.8.sp
                            )
                        }
                    }
                } else if (isCheckInEntry) {
                    // Locked check-in entry: no category affordance, and a short
                    // note (same caption style as the locked-tag line below) in
                    // place of the edit UI.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Lock,
                            contentDescription = null,
                            tint = NotelTextSecondary,
                            modifier = Modifier.size(12.dp)
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "This entry was logged automatically and cannot be edited.",
                            color = NotelTextSecondary,
                            fontSize = 12.sp
                        )
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SectionLabel("Change category")
                        androidx.compose.foundation.lazy.LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            items(categories.size) { index ->
                                val cat = categories[index]
                                val isSelected = cat.id == e.categoryId
                                val color = try { Color(android.graphics.Color.parseColor(cat.colorHex)) }
                                            catch (_: Exception) { NotelTextSecondary }
                                Box(
                                    modifier = Modifier
                                        .height(40.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(if (isSelected) color else NotelSurface)
                                        .border(1.dp, if (isSelected) color else color.copy(alpha = 0.35f), RoundedCornerShape(10.dp))
                                        .clickable { viewModel.updateCategory(cat.id) }
                                        .padding(horizontal = 14.dp)
                                ) {
                                    androidx.compose.foundation.layout.Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxHeight()) {
                                        Text(
                                            cat.name.uppercase(),
                                            color = if (isSelected) Color.White else NotelTextSecondary,
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Bold,
                                            letterSpacing = 0.6.sp
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                // Timestamp Section
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        text = "Logged on ${sdf.format(Date(e.timestamp))}", 
                        color = NotelTextSecondary, 
                        fontSize = 12.sp
                    )
                    
                    if (e.source == "Voice AI") {
                        Surface(
                            shape = RoundedCornerShape(8.dp),
                            color = Color(0xFFB39DDB).copy(alpha = 0.15f)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Default.AutoAwesome,
                                    null,
                                    tint = Color(0xFFB39DDB),
                                    modifier = Modifier.size(12.dp)
                                )
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    "Processed via Voice AI",
                                    color = Color(0xFFB39DDB),
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                    }
                }

                // Body card
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelBorder, RoundedCornerShape(16.dp))
                        .padding(16.dp)
                ) {
                    Column {
                        SectionLabel("Content")
                        Spacer(Modifier.height(10.dp))
                        val combinedText = if (e.manualText.isNotBlank()) "${e.body}\n\n${e.manualText}" else e.body
                        Text(combinedText, color = NotelTextPrimary, fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.Medium)
                    }
                }

                // Chips used
                if (chips.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(NotelSurface)
                            .border(1.dp, NotelBorder, RoundedCornerShape(16.dp))
                            .padding(16.dp)
                    ) {
                        Column {
                            SectionLabel("Associated tiles")
                            Spacer(Modifier.height(12.dp))
                            @OptIn(ExperimentalLayoutApi::class)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                chips.forEach { chip ->
                                    val isLockedTag = isCheckInEntry && chip == ENERGY_CHECKIN_TAG
                                    Box(
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(20.dp))
                                            .background(NotelSurfaceHigh)
                                            .border(1.dp, NotelBorder, RoundedCornerShape(20.dp))
                                            .padding(horizontal = 12.dp, vertical = 6.dp)
                                    ) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            if (isLockedTag) {
                                                Icon(
                                                    Icons.Default.Lock,
                                                    contentDescription = null,
                                                    tint = NotelTextSecondary,
                                                    modifier = Modifier.size(12.dp)
                                                )
                                                Spacer(Modifier.width(4.dp))
                                            }
                                            Text(chip, color = NotelTextPrimary, fontSize = 13.sp)
                                        }
                                    }
                                }
                            }
                            if (isCheckInEntry) {
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    "This tag was added automatically and cannot be changed.",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp
                                )
                            }
                        }
                    }
                }



                Spacer(Modifier.weight(1f))


            }

            if (showEditDialog && !isCheckInEntry) {
                var editBody by remember { 
                    mutableStateOf(if (e.manualText.isNotBlank()) "${e.body}\n\n${e.manualText}" else e.body) 
                }
                AlertDialog(
                    onDismissRequest = { showEditDialog = false },
                    containerColor = NotelSurface,
                    title = { Text("Edit Entry Text", color = NotelTextPrimary) },
                    text = {
                        Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                            OutlinedTextField(
                                value = editBody,
                                onValueChange = { editBody = it },
                                label = { Text("Note Content") },
                                modifier = Modifier.fillMaxWidth().height(250.dp),
                                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = NotelAccent, unfocusedBorderColor = NotelAccent.copy(alpha=0.5f),
                                    focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary
                                )
                            )
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            viewModel.updateText(editBody, "")
                            showEditDialog = false
                        }) { Text("Save", color = NotelPrimary) }
                    },
                    dismissButton = {
                        TextButton(onClick = { showEditDialog = false }) { Text("Cancel", color = NotelTextSecondary) }
                    }
                )
            }

            if (showDelete) {
                AlertDialog(
                    onDismissRequest = { showDelete = false },
                    containerColor = NotelSurface,
                    title = { Text("Delete entry?", color = NotelTextPrimary) },
                    text = { Text("This cannot be undone.", color = NotelTextSecondary) },
                    confirmButton = {
                        TextButton(onClick = { viewModel.deleteEntry(e, onBack) }) {
                            Text("Delete", color = MaterialTheme.colorScheme.error)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showDelete = false }) { Text("Cancel") }
                    }
                )
            }
        } ?: Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            GlassySpinner(size = 48.dp, color = NotelPrimary)
        }
    }
}
