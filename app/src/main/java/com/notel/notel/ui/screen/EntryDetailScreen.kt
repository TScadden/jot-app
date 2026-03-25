package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
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

@HiltViewModel
class EntryDetailViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository
) : ViewModel() {

    private val _entry = MutableStateFlow<LogEntry?>(null)
    val entry: StateFlow<LogEntry?> = _entry

    val categories = categoryRepository.getAllCategories()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun loadEntry(id: Long) {
        viewModelScope.launch {
            _entry.value = logRepository.getEntryById(id)
        }
    }

    fun deleteEntry(entry: LogEntry, onDone: () -> Unit) {
        viewModelScope.launch {
            logRepository.deleteEntry(entry)
            onDone()
        }
    }

    fun updateCategory(categoryId: Int) {
        val current = _entry.value ?: return
        viewModelScope.launch {
            val updated = current.copy(categoryId = categoryId)
            logRepository.insertEntry(updated) // Room insert + PrimaryKey handles conflict as Update
            _entry.value = updated
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
                // Category Picker Section
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Change Category", style = MaterialTheme.typography.labelSmall, color = NotelTextSecondary)
                    androidx.compose.foundation.lazy.LazyRow(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        items(categories.size) { index ->
                            val cat = categories[index]
                            val isSelected = cat.id == e.categoryId
                            val color = try { Color(android.graphics.Color.parseColor(cat.colorHex)) }
                                        catch (_: Exception) { NotelPrimary }
                                        
                            Surface(
                                onClick = { viewModel.updateCategory(cat.id) },
                                shape = RoundedCornerShape(12.dp),
                                color = Color.Transparent,
                                modifier = Modifier
                                    .height(40.dp)
                                    .liquidGlass(
                                        shape = RoundedCornerShape(12.dp),
                                        color = if (isSelected) color else NotelSurface,
                                        alpha = if (isSelected) 0.6f else 0.3f,
                                        borderWidth = if (isSelected) 2.dp else 1.dp
                                    )
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        cat.name, 
                                        color = if (isSelected) Color.White else NotelTextPrimary,
                                        fontSize = 13.sp,
                                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
                                    )
                                }
                            }
                        }
                    }
                }

                // Timestamp Section
                Text(
                    text = "Logged on ${sdf.format(Date(e.timestamp))}", 
                    color = NotelTextSecondary, 
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 4.dp)
                )

                // Body card
                GlassyCard(
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Content", style = MaterialTheme.typography.labelSmall, color = NotelTextSecondary)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        e.body, 
                        color = NotelTextPrimary, 
                        fontSize = 17.sp, 
                        lineHeight = 24.sp,
                        fontWeight = FontWeight.Medium
                    )
                }

                // Chips used
                if (chips.isNotEmpty()) {
                    GlassyCard(modifier = Modifier.fillMaxWidth()) {
                        Text("Associated Tiles", style = MaterialTheme.typography.labelSmall, color = NotelTextSecondary)
                        Spacer(Modifier.height(12.dp))
                        @OptIn(ExperimentalLayoutApi::class)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            chips.forEach { chip ->
                                Surface(
                                    shape = RoundedCornerShape(20.dp),
                                    color = Color.Transparent,
                                    modifier = Modifier.liquidGlass(shape = RoundedCornerShape(20.dp), color = NotelSurfaceHigh, alpha = 0.5f)
                                ) {
                                    Text(chip, color = NotelTextPrimary, fontSize = 13.sp,
                                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
                                }
                            }
                        }
                    }
                }

                // Manual note split out
                if (e.manualText.isNotBlank()) {
                    GlassyCard(modifier = Modifier.fillMaxWidth()) {
                        Text("Additional Annotation", style = MaterialTheme.typography.labelSmall, color = NotelTextSecondary)
                        Spacer(Modifier.height(8.dp))
                        Text(e.manualText, color = NotelTextPrimary, fontSize = 15.sp, fontStyle = androidx.compose.ui.text.font.FontStyle.Italic)
                    }
                }

                Spacer(Modifier.weight(1f))

                // Delete
                TextButton(
                    onClick = { showDelete = true },
                    modifier = Modifier.align(Alignment.CenterHorizontally)
                ) {
                    Text("Delete this entry", color = Color.Red.copy(alpha = 0.7f), fontSize = 14.sp)
                }
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
