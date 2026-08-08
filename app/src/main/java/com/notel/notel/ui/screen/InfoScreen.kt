package com.notel.notel.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.notel.notel.ui.theme.*
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.math.hypot
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

    val allTilesMap = remember { DEFAULT_INFO_TILES.associateBy { it.id } }

    var tileList by remember { mutableStateOf(DEFAULT_INFO_TILES) }

    // Reorder / Edit Mode State
    var isEditMode by remember { mutableStateOf(false) }
    var draggedIndex by remember { mutableStateOf<Int?>(null) }
    var dragOffset by remember { mutableStateOf(Offset.Zero) }

    // Store tile center positions on screen for accurate drop calculation
    val itemBoundsMap = remember { mutableStateMapOf<Int, Offset>() }

    LaunchedEffect(savedOrderJson) {
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
                return@LaunchedEffect
            }
        }
        tileList = DEFAULT_INFO_TILES
    }

    // Lock bottom bar switching while in edit mode
    LaunchedEffect(isEditMode) {
        onReorderStateChange(isEditMode)
    }

    fun saveTileOrder(newTiles: List<InfoTile>) {
        tileList = newTiles
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
                    Text(
                        "Tools",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                actions = {
                    if (isEditMode) {
                        Surface(
                            onClick = {
                                isEditMode = false
                                saveTileOrder(tileList)
                            },
                            shape = RoundedCornerShape(12.dp),
                            color = NotelPrimary
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp), tint = Color.White)
                                Spacer(Modifier.width(6.dp))
                                Text("Done", fontWeight = FontWeight.Bold, color = Color.White, fontSize = 13.sp)
                            }
                        }
                    } else {
                        IconButton(onClick = { isEditMode = true }) {
                            Icon(
                                imageVector = Icons.Default.SwapVert,
                                contentDescription = "Reorder tiles",
                                tint = NotelTextSecondary
                            )
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
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = if (isEditMode) NotelPrimary.copy(alpha = 0.12f) else NotelSurfaceHigh.copy(alpha = 0.4f),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = if (isEditMode) Icons.Default.OpenWith else Icons.Default.TouchApp,
                        contentDescription = null,
                        tint = if (isEditMode) NotelPrimary else NotelTextSecondary,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = if (isEditMode) "Drag tiles to reorder. Tap 'Done' to save." else "Explore your health resources. Long-press to reorder.",
                        color = if (isEditMode) NotelPrimary else NotelTextSecondary,
                        fontSize = 12.sp,
                        fontWeight = if (isEditMode) FontWeight.Bold else FontWeight.Medium
                    )
                }
            }

            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                contentPadding = PaddingValues(bottom = 100.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                itemsIndexed(tileList, key = { _, tile -> tile.id }) { index, tile ->
                    val isBeingDragged = draggedIndex == index

                    val scale by animateFloatAsState(
                        targetValue = if (isBeingDragged) 1.05f else 1.0f,
                        label = "dragScale"
                    )

                    Box(
                        modifier = Modifier
                            .zIndex(if (isBeingDragged) 100f else 1f)
                            .onGloballyPositioned { coordinates ->
                                val bounds = coordinates.boundsInWindow()
                                itemBoundsMap[index] = Offset(
                                    x = bounds.left + bounds.width / 2f,
                                    y = bounds.top + bounds.height / 2f
                                )
                            }
                            .graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                shadowElevation = if (isBeingDragged) 16f else 0f
                                if (isBeingDragged) {
                                    translationX = dragOffset.x
                                    translationY = dragOffset.y
                                }
                            }
                            .pointerInput(isEditMode, tileList) {
                                detectDragGesturesAfterLongPress(
                                    onDragStart = {
                                        isEditMode = true
                                        draggedIndex = index
                                        dragOffset = Offset.Zero
                                    },
                                    onDrag = { change, dragAmount ->
                                        change.consume()
                                        dragOffset += dragAmount
                                    },
                                    onDragEnd = {
                                        val fromIdx = draggedIndex
                                        if (fromIdx != null) {
                                            val startCenter = itemBoundsMap[fromIdx]
                                            if (startCenter != null) {
                                                val currentTouchPos = startCenter + dragOffset
                                                
                                                var closestIndex = fromIdx
                                                var minDistance = Float.MAX_VALUE

                                                itemBoundsMap.forEach { (targetIdx, center) ->
                                                    val dist = hypot(currentTouchPos.x - center.x, currentTouchPos.y - center.y)
                                                    if (dist < minDistance) {
                                                        minDistance = dist
                                                        closestIndex = targetIdx
                                                    }
                                                }

                                                val sourceIdx = fromIdx
                                                val targetIdx = closestIndex
                                                if (sourceIdx != null && targetIdx != null && targetIdx != sourceIdx && targetIdx in tileList.indices) {
                                                    val mutable = tileList.toMutableList()
                                                    val item = mutable.removeAt(sourceIdx)
                                                    mutable.add(targetIdx, item)
                                                    tileList = mutable
                                                    saveTileOrder(mutable)
                                                }
                                            }
                                        }
                                        draggedIndex = null
                                        dragOffset = Offset.Zero
                                    },
                                    onDragCancel = {
                                        draggedIndex = null
                                        dragOffset = Offset.Zero
                                    }
                                )
                            }
                    ) {
                        InfoTileCard(
                            tile = tile,
                            isUnlimited = isUnlimited,
                            isEditMode = isEditMode,
                            isBeingDragged = isBeingDragged,
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
    isEditMode: Boolean = false,
    isBeingDragged: Boolean = false,
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
    val cardShape = RoundedCornerShape(20.dp)

    val borderColor = when {
        isBeingDragged -> NotelPrimary
        isEditMode -> NotelPrimary.copy(alpha = 0.45f)
        else -> NotelPrimary.copy(alpha = 0.15f)
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .clip(cardShape)
            .background(NotelSurface)
            .border(
                width = if (isBeingDragged) 2.dp else 1.dp,
                color = borderColor,
                shape = cardShape
            )
            .clickable(enabled = !isEditMode) {
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
                        "habits" -> onHabitsClick()
                        "reminders" -> onRemindersClick()
                        "lists" -> onListsClick()
                        "notes" -> onNotesClick()
                        "project_focus" -> onProjectFocusClick()
                    }
                }
            }
            .padding(14.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer(alpha = if (isLocked) 0.5f else 1f),
            verticalArrangement = Arrangement.SpaceBetween,
            horizontalAlignment = Alignment.Start
        ) {
            // Icon Badge
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(NotelPrimary.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = tile.icon,
                    contentDescription = null,
                    tint = NotelPrimary,
                    modifier = Modifier.size(22.dp)
                )
            }

            // Title & Description
            Column {
                Text(
                    text = tile.title,
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 19.sp
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    text = tile.description,
                    color = NotelTextSecondary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Normal,
                    lineHeight = 14.sp,
                    maxLines = 2
                )
            }
        }

        // Top right badges
        if (isLocked) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.TopEnd
            ) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = NotelSurfaceHigh.copy(alpha = 0.85f)
                ) {
                    Icon(
                        imageVector = Icons.Default.Lock,
                        contentDescription = "Premium Locked Feature",
                        tint = NotelPrimary,
                        modifier = Modifier
                            .size(22.dp)
                            .padding(4.dp)
                    )
                }
            }
        } else if (isEditMode) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.TopEnd
            ) {
                Icon(
                    imageVector = Icons.Default.DragHandle,
                    contentDescription = "Drag Handle",
                    tint = NotelPrimary.copy(alpha = 0.6f),
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}
