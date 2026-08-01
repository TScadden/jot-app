package com.notel.notel.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.math.roundToInt

data class InfoTile(
    val id: String,
    val title: String,
    val icon: ImageVector,
    val description: String
)

val DEFAULT_INFO_TILES = listOf(
    InfoTile("habits", "Habits", Icons.Default.CheckCircle, "Daily routine tracking"),
    InfoTile("reminders", "Reminders", Icons.Default.Notifications, "Scheduled alerts"),
    InfoTile("lists", "Lists", Icons.Default.List, "Checklists & Tasks"),
    InfoTile("notes", "Notes", Icons.Default.Edit, "Quick notes & thoughts"),
    InfoTile("project_focus", "Project Focus", Icons.Default.Science, "Track experiments"),
    InfoTile("sleep", "Sleep", Icons.Default.Bedtime, "Analysis & Debt"),
    InfoTile("body_info", "Body Info", Icons.Default.AccessibilityNew, "Impact & Side Effects"),
    InfoTile("medications", "Medications", Icons.Default.Medication, "Prescriptions & Doses"),
    InfoTile("tips_and_tricks", "Tips and Tricks", Icons.Default.Lightbulb, "Master your data"),
    InfoTile("health_coach", "Health Coach", Icons.Default.QuestionMark, "Personalized Advice"),
    InfoTile("key_metrics", "Key Metrics", Icons.Default.BarChart, "Your Body Data"),
    InfoTile("food", "Food", Icons.Default.Restaurant, "Sensitivity Checker"),
    InfoTile("community", "Community", Icons.Default.People, "Friends & Leaderboard")
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InfoScreen(
    onBack: () -> Unit = {},
    onSleepClick: () -> Unit = {},
    onBodyInfoClick: () -> Unit = {},
    onMedicationsClick: () -> Unit = {},
    onKeyMetricsClick: () -> Unit = {},
    onCoachClick: () -> Unit = {},
    onTipsAndTricksClick: () -> Unit = {},
    onFoodClick: () -> Unit = {},
    onCommunityClick: () -> Unit = {},
    onHabitsClick: () -> Unit = {},
    onRemindersClick: () -> Unit = {},
    onListsClick: () -> Unit = {},
    onNotesClick: () -> Unit = {},
    onProjectFocusClick: () -> Unit = {},
    onNavigateToMembership: () -> Unit = {},
    isUnlimited: Boolean = false,
    onReorderStateChange: (Boolean) -> Unit = {}
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember { com.notel.notel.data.preferences.NotelPreferences(context) }
    val coroutineScope = rememberCoroutineScope()

    val savedOrderJson by prefs.infoTileOrder.collectAsState(initial = "")
    val routineClickJson by prefs.routineClickCounts.collectAsState(initial = "{}")

    val allTilesMap = remember { DEFAULT_INFO_TILES.associateBy { it.id } }

    var tileList by remember { mutableStateOf(DEFAULT_INFO_TILES) }
    var isUserCustomOrdered by remember { mutableStateOf(false) }

    LaunchedEffect(savedOrderJson, routineClickJson) {
        if (savedOrderJson.isNotBlank()) {
            val parsedIds = try {
                Json.decodeFromString<List<String>>(savedOrderJson)
            } catch (e: Exception) {
                emptyList()
            }
            if (parsedIds.isNotEmpty()) {
                val customTiles = parsedIds.mapNotNull { allTilesMap[it] }
                val missingTiles = DEFAULT_INFO_TILES.filter { it.id !in parsedIds }
                tileList = customTiles + missingTiles
                isUserCustomOrdered = true
                return@LaunchedEffect
            }
        }

        // If no custom order is saved, sort top 5 routine tiles dynamically by click count
        if (!isUserCustomOrdered) {
            val counts = try { Json.decodeFromString<Map<String, Int>>(routineClickJson) } catch (e: Exception) { emptyMap() }
            val sortedRoutineIds = listOf("habits", "reminders", "lists", "notes", "project_focus")
                .sortedByDescending { counts[it] ?: 0 }
            val routineTiles = sortedRoutineIds.mapNotNull { allTilesMap[it] }
            val baseTiles = listOf("sleep", "body_info", "medications", "tips_and_tricks", "health_coach", "key_metrics", "food", "community").mapNotNull { allTilesMap[it] }
            tileList = routineTiles + baseTiles
        }
    }

    var draggingIndex by remember { mutableStateOf<Int?>(null) }
    var dragOffset by remember { mutableStateOf(Offset.Zero) }

    // Notify parent tab lock
    LaunchedEffect(draggingIndex) {
        onReorderStateChange(draggingIndex != null)
    }

    // Persist tile order to preference
    fun saveTileOrder(newTiles: List<InfoTile>) {
        tileList = newTiles
        isUserCustomOrdered = true
        coroutineScope.launch {
            val ids = newTiles.map { it.id }
            val jsonStr = Json.encodeToString(ids)
            prefs.setInfoTileOrder(jsonStr)
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            "Information Center",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                        if (draggingIndex != null) {
                            Text(
                                "Reordering tiles... release to drop",
                                fontSize = 11.sp,
                                color = NotelPrimary,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                },
                actions = {
                    if (isUserCustomOrdered) {
                        TextButton(onClick = {
                            isUserCustomOrdered = false
                            coroutineScope.launch {
                                prefs.setInfoTileOrder("")
                            }
                        }) {
                            Text("Reset Order", color = NotelTextSecondary, fontSize = 12.sp)
                        }
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
            Text(
                text = "Hold & drag any tile to reorder your Information Center.",
                color = NotelTextSecondary,
                fontSize = 13.sp,
                modifier = Modifier.padding(bottom = 16.dp)
            )

            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                contentPadding = PaddingValues(bottom = 100.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                items(tileList.size, key = { tileList[it].id }) { index ->
                    val tile = tileList[index]
                    val isDragging = draggingIndex == index

                    val scale by animateFloatAsState(targetValue = if (isDragging) 1.08f else 1.0f, label = "dragScale")
                    val elevation by animateFloatAsState(targetValue = if (isDragging) 16f else 0f, label = "dragElevation")

                    Box(
                        modifier = Modifier
                            .zIndex(if (isDragging) 10f else 1f)
                            .graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                shadowElevation = elevation
                                if (isDragging) {
                                    translationX = dragOffset.x
                                    translationY = dragOffset.y
                                }
                            }
                            .pointerInput(tileList) {
                                detectDragGesturesAfterLongPress(
                                    onDragStart = {
                                        draggingIndex = index
                                        dragOffset = Offset.Zero
                                    },
                                    onDrag = { change, dragAmount ->
                                        change.consume()
                                        dragOffset += dragAmount

                                        val currentIdx = draggingIndex ?: return@detectDragGesturesAfterLongPress
                                        // Approximate grid cell step sizes for standard 2-column layout
                                        val colDelta = (dragOffset.x / 300f).roundToInt()
                                        val rowDelta = (dragOffset.y / 350f).roundToInt()
                                        val targetIdx = (currentIdx + colDelta + rowDelta * 2).coerceIn(0, tileList.size - 1)

                                        if (targetIdx != currentIdx) {
                                            val mutable = tileList.toMutableList()
                                            val item = mutable.removeAt(currentIdx)
                                            mutable.add(targetIdx, item)
                                            tileList = mutable
                                            draggingIndex = targetIdx
                                            dragOffset = Offset.Zero
                                        }
                                    },
                                    onDragEnd = {
                                        draggingIndex = null
                                        dragOffset = Offset.Zero
                                        saveTileOrder(tileList)
                                    },
                                    onDragCancel = {
                                        draggingIndex = null
                                        dragOffset = Offset.Zero
                                        saveTileOrder(tileList)
                                    }
                                )
                            }
                    ) {
                        InfoTileCard(
                            tile = tile,
                            isUnlimited = isUnlimited,
                            isReordering = draggingIndex != null,
                            onNavigateToMembership = onNavigateToMembership,
                            onSleepClick = onSleepClick,
                            onBodyInfoClick = onBodyInfoClick,
                            onMedicationsClick = onMedicationsClick,
                            onKeyMetricsClick = onKeyMetricsClick,
                            onCoachClick = onCoachClick,
                            onTipsAndTricksClick = onTipsAndTricksClick,
                            onFoodClick = onFoodClick,
                            onCommunityClick = onCommunityClick,
                            onHabitsClick = onHabitsClick,
                            onRemindersClick = onRemindersClick,
                            onListsClick = onListsClick,
                            onNotesClick = onNotesClick,
                            onProjectFocusClick = onProjectFocusClick,
                            recordClick = { key ->
                                coroutineScope.launch {
                                    prefs.recordRoutineClick(key)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun InfoTileCard(
    tile: InfoTile,
    isUnlimited: Boolean,
    isReordering: Boolean = false,
    onNavigateToMembership: () -> Unit,
    onSleepClick: () -> Unit,
    onBodyInfoClick: () -> Unit,
    onMedicationsClick: () -> Unit,
    onKeyMetricsClick: () -> Unit,
    onCoachClick: () -> Unit,
    onTipsAndTricksClick: () -> Unit,
    onFoodClick: () -> Unit,
    onCommunityClick: () -> Unit,
    onHabitsClick: () -> Unit = {},
    onRemindersClick: () -> Unit = {},
    onListsClick: () -> Unit = {},
    onNotesClick: () -> Unit = {},
    onProjectFocusClick: () -> Unit = {},
    recordClick: (String) -> Unit = {}
) {
    val isAiGated = tile.id == "health_coach" || tile.id == "tips_and_tricks"
    val isLocked = isAiGated && !isUnlimited

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .border(
                width = 3.dp,
                color = NotelPrimary.copy(alpha = 0.12f),
                shape = RoundedCornerShape(26.dp)
            )
            .border(
                width = 6.dp,
                color = NotelPrimary.copy(alpha = 0.04f),
                shape = RoundedCornerShape(28.dp)
            )
            .clip(RoundedCornerShape(24.dp))
            .clickable(enabled = !isReordering) {
                if (isLocked) {
                    onNavigateToMembership()
                } else {
                    when (tile.id) {
                        "sleep" -> onSleepClick()
                        "body_info" -> onBodyInfoClick()
                        "medications" -> onMedicationsClick()
                        "key_metrics" -> onKeyMetricsClick()
                        "health_coach" -> onCoachClick()
                        "tips_and_tricks" -> onTipsAndTricksClick()
                        "food" -> onFoodClick()
                        "community" -> onCommunityClick()
                        "habits" -> { recordClick("habits"); onHabitsClick() }
                        "reminders" -> { recordClick("reminders"); onRemindersClick() }
                        "lists" -> { recordClick("lists"); onListsClick() }
                        "notes" -> { recordClick("notes"); onNotesClick() }
                        "project_focus" -> { recordClick("project_focus"); onProjectFocusClick() }
                    }
                }
            }
            .liquidGlass(
                shape = RoundedCornerShape(24.dp),
                color = NotelSurface,
                alpha = if (isLocked) 0.35f else 0.8f,
                showBorder = true
            )
            .padding(20.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer(alpha = if (isLocked) 0.5f else 1f),
            verticalArrangement = Arrangement.SpaceBetween,
            horizontalAlignment = Alignment.Start
        ) {
            Icon(
                imageVector = tile.icon,
                contentDescription = null,
                tint = NotelPrimary,
                modifier = Modifier.size(32.dp)
            )

            Column {
                Text(
                    text = tile.title,
                    color = NotelTextPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 22.sp
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = tile.description,
                    color = NotelTextSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }

        if (isLocked) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(8.dp),
                contentAlignment = Alignment.TopEnd
            ) {
                Icon(
                    imageVector = Icons.Default.Lock,
                    contentDescription = "Premium Locked Feature",
                    tint = NotelPrimary,
                    modifier = Modifier
                        .size(24.dp)
                        .background(NotelSurfaceHigh.copy(alpha = 0.8f), RoundedCornerShape(8.dp))
                        .padding(4.dp)
                )
            }
        }
    }
}
