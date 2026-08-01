package com.notel.notel.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

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

    // Explicit Edit / Reorder Mode State
    var isEditMode by remember { mutableStateOf(false) }

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

        if (!isUserCustomOrdered) {
            val counts = try { Json.decodeFromString<Map<String, Int>>(routineClickJson) } catch (e: Exception) { emptyMap() }
            val sortedRoutineIds = listOf("habits", "reminders", "lists", "notes", "project_focus")
                .sortedByDescending { counts[it] ?: 0 }
            val routineTiles = sortedRoutineIds.mapNotNull { allTilesMap[it] }
            val baseTiles = listOf("sleep", "body_info", "medications", "tips_and_tricks", "health_coach", "key_metrics", "food", "community").mapNotNull { allTilesMap[it] }
            tileList = routineTiles + baseTiles
        }
    }

    // Notify parent to disable bottom tab switching while in Edit / Reorder Mode
    LaunchedEffect(isEditMode) {
        onReorderStateChange(isEditMode)
    }

    fun saveTileOrder(newTiles: List<InfoTile>) {
        tileList = newTiles
        isUserCustomOrdered = true
        coroutineScope.launch {
            val ids = newTiles.map { it.id }
            val jsonStr = Json.encodeToString(ids)
            prefs.setInfoTileOrder(jsonStr)
        }
    }

    fun moveTileUp(index: Int) {
        if (index > 0) {
            val mutable = tileList.toMutableList()
            val item = mutable.removeAt(index)
            mutable.add(index - 1, item)
            saveTileOrder(mutable)
        }
    }

    fun moveTileDown(index: Int) {
        if (index < tileList.size - 1) {
            val mutable = tileList.toMutableList()
            val item = mutable.removeAt(index)
            mutable.add(index + 1, item)
            saveTileOrder(mutable)
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Information Center",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                actions = {
                    if (isEditMode) {
                        Button(
                            onClick = {
                                isEditMode = false
                                saveTileOrder(tileList)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                            shape = RoundedCornerShape(12.dp),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp)
                        ) {
                            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp), tint = Color.White)
                            Spacer(Modifier.width(6.dp))
                            Text("Save", fontWeight = FontWeight.Bold, color = Color.White, fontSize = 13.sp)
                        }
                    } else {
                        IconButton(onClick = { isEditMode = true }) {
                            Icon(
                                imageVector = Icons.Default.Edit,
                                contentDescription = "Edit Tile Order",
                                tint = NotelPrimary
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
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isEditMode) "Use ↑ ↓ arrows to rearrange tile order." else "Explore your health resources and deep insights.",
                    color = if (isEditMode) NotelPrimary else NotelTextSecondary,
                    fontSize = 13.sp,
                    fontWeight = if (isEditMode) FontWeight.Bold else FontWeight.Normal
                )

                if (isUserCustomOrdered && !isEditMode) {
                    TextButton(
                        onClick = {
                            isUserCustomOrdered = false
                            coroutineScope.launch {
                                prefs.setInfoTileOrder("")
                            }
                        },
                        contentPadding = PaddingValues(0.dp)
                    ) {
                        Text("Reset Order", color = NotelTextSecondary, fontSize = 12.sp)
                    }
                }
            }

            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                contentPadding = PaddingValues(bottom = 100.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                itemsIndexed(tileList, key = { _, tile -> tile.id }) { index, tile ->
                    InfoTileCard(
                        tile = tile,
                        isUnlimited = isUnlimited,
                        isEditMode = isEditMode,
                        canMoveUp = index > 0,
                        canMoveDown = index < tileList.size - 1,
                        onMoveUp = { moveTileUp(index) },
                        onMoveDown = { moveTileDown(index) },
                        onLongClickEdit = { isEditMode = true },
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

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun InfoTileCard(
    tile: InfoTile,
    isUnlimited: Boolean,
    isEditMode: Boolean = false,
    canMoveUp: Boolean = false,
    canMoveDown: Boolean = false,
    onMoveUp: () -> Unit = {},
    onMoveDown: () -> Unit = {},
    onLongClickEdit: () -> Unit = {},
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

    val pulseScale by animateFloatAsState(targetValue = if (isEditMode) 1.02f else 1.0f, label = "editModePulse")

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .graphicsLayer {
                scaleX = pulseScale
                scaleY = pulseScale
            }
            .border(
                width = if (isEditMode) 2.dp else 3.dp,
                color = if (isEditMode) NotelPrimary else NotelPrimary.copy(alpha = 0.12f),
                shape = RoundedCornerShape(26.dp)
            )
            .border(
                width = 6.dp,
                color = NotelPrimary.copy(alpha = 0.04f),
                shape = RoundedCornerShape(28.dp)
            )
            .clip(RoundedCornerShape(24.dp))
            .combinedClickable(
                onClick = {
                    if (!isEditMode) {
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
                },
                onLongClick = {
                    onLongClickEdit()
                }
            )
            .liquidGlass(
                shape = RoundedCornerShape(24.dp),
                color = NotelSurface,
                alpha = if (isLocked) 0.35f else 0.8f,
                showBorder = true
            )
            .padding(16.dp)
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
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 20.sp
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = tile.description,
                    color = NotelTextSecondary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }

        if (isEditMode) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopEnd),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                if (canMoveUp) {
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .clip(CircleShape)
                            .background(NotelPrimary)
                            .clickable { onMoveUp() },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.KeyboardArrowLeft,
                            contentDescription = "Move Left/Up",
                            tint = Color.White,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                }
                if (canMoveDown) {
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .clip(CircleShape)
                            .background(NotelPrimary)
                            .clickable { onMoveDown() },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.KeyboardArrowRight,
                            contentDescription = "Move Right/Down",
                            tint = Color.White,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                }
            }
        } else if (isLocked) {
            Box(
                modifier = Modifier
                    .fillMaxSize(),
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
