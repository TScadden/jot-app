package com.notel.notel.ui.screen

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.HistoryViewModel
import java.text.SimpleDateFormat
import java.util.*

// ── Design tokens matching the reference "System Vitals / Climate Core" tile style ──
private val TileBackground = Color(0xFF0D1428)
private val TileAccentPurple = Color(0xFF7C6EFF)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    viewModel: HistoryViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onEntryClick: (Long) -> Unit
) {
    val entries by viewModel.entries.collectAsState()
    val categories by viewModel.categories.collectAsState()
    val searchQuery by viewModel.searchQuery.collectAsState()
    val categoryFilter by viewModel.categoryFilter.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }

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
                    focusedBorderColor = TileAccentPurple,
                    unfocusedBorderColor = TileAccentPurple.copy(alpha = 0.25f),
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = TileAccentPurple,
                    unfocusedContainerColor = TileBackground,
                    focusedContainerColor = TileBackground
                )
            )

            // ── Category Filter Row ──────────────────────────────────────
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item {
                    val isAllSelected = categoryFilter == null
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (isAllSelected) TileAccentPurple else TileBackground)
                            .border(
                                width = 1.dp,
                                color = if (isAllSelected) TileAccentPurple else TileAccentPurple.copy(alpha = 0.25f),
                                shape = RoundedCornerShape(10.dp)
                            )
                            .clickable { viewModel.setCategoryFilter(null) }
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                    ) {
                        Text(
                            "ALL",
                            color = if (isAllSelected) Color(0xFF0A0A0E) else NotelTextSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.8.sp
                        )
                    }
                }
                items(categories) { cat ->
                    val isSelected = categoryFilter == cat.id
                    val catColor = remember(cat) {
                        try { Color(android.graphics.Color.parseColor(cat.colorHex)) }
                        catch (e: Exception) { TileAccentPurple }
                    }
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (isSelected) catColor else TileBackground)
                            .border(
                                width = 1.dp,
                                color = if (isSelected) catColor else catColor.copy(alpha = 0.35f),
                                shape = RoundedCornerShape(10.dp)
                            )
                            .clickable { viewModel.setCategoryFilter(if (isSelected) null else cat.id) }
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                    ) {
                        Text(
                            cat.name.uppercase(),
                            color = if (isSelected) Color(0xFF0A0A0E) else NotelTextSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.8.sp
                        )
                    }
                }
            }

            // ── Entry Count ──────────────────────────────────────────────
            Text(
                "${entries.size} ${if (entries.size == 1) "entry" else "entries"}",
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
                color = TileAccentPurple.copy(alpha = 0.6f),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                letterSpacing = 0.5.sp
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
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 100.dp),
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

    val catColor = remember(category) {
        if (category != null) {
            try { Color(android.graphics.Color.parseColor(category.colorHex)) }
            catch (e: Exception) { null }
        } else null
    }

    val accentColor = catColor ?: TileAccentPurple

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize()
            .clip(RoundedCornerShape(16.dp))
            .background(TileBackground)
            .border(
                width = 1.dp,
                color = accentColor.copy(alpha = 0.20f),
                shape = RoundedCornerShape(16.dp)
            )
            .clickable { onClick() }
    ) {
        // Left accent strip
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .width(3.dp)
                .fillMaxHeight()
                .background(
                    accentColor.copy(alpha = 0.85f),
                    RoundedCornerShape(topStart = 16.dp, bottomStart = 16.dp)
                )
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 4.dp, top = 14.dp, bottom = 14.dp)
        ) {
            // ── Header row ───────────────────────────────────────────────
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Left side: category chip + voice AI badge
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.weight(1f)
                ) {
                    if (category != null && catColor != null) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(catColor.copy(alpha = 0.15f))
                                .border(1.dp, catColor.copy(alpha = 0.45f), RoundedCornerShape(6.dp))
                                .padding(horizontal = 8.dp, vertical = 3.dp)
                        ) {
                            Text(
                                text = category.name.uppercase(),
                                color = catColor,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 0.8.sp
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                    }

                    if (entry.source == "Voice AI") {
                        Icon(
                            Icons.Default.AutoAwesome,
                            contentDescription = "Voice AI",
                            tint = TileAccentPurple,
                            modifier = Modifier.size(12.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            "VOICE AI",
                            color = TileAccentPurple.copy(alpha = 0.75f),
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.8.sp
                        )
                    }
                }

                // Delete button
                IconButton(
                    onClick = { showDeleteConfirm = true },
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        Icons.Default.Delete,
                        null,
                        tint = NotelTextSecondary.copy(alpha = 0.45f),
                        modifier = Modifier.size(16.dp)
                    )
                }
            }

            Spacer(Modifier.height(10.dp))

            // ── Entry body ───────────────────────────────────────────────
            Text(
                text = entry.body,
                color = NotelTextPrimary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                lineHeight = 22.sp,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis
            )

            Spacer(Modifier.height(10.dp))

            // ── Timestamp ────────────────────────────────────────────────
            Text(
                text = sdf.format(Date(entry.timestamp)),
                color = TileAccentPurple.copy(alpha = 0.55f),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                letterSpacing = 0.3.sp
            )
        }
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            containerColor = TileBackground,
            title = { Text("Delete entry?", color = NotelTextPrimary) },
            text = { Text("This cannot be undone.", color = NotelTextSecondary) },
            confirmButton = {
                TextButton(onClick = { onDelete(); showDeleteConfirm = false }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel", color = NotelTextSecondary) }
            }
        )
    }
}
