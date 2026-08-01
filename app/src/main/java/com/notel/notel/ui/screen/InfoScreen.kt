package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import com.notel.notel.ui.theme.*

data class InfoTile(
    val title: String,
    val icon: ImageVector,
    val description: String
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
    isUnlimited: Boolean = false
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val prefs = androidx.compose.runtime.remember { com.notel.notel.data.preferences.NotelPreferences(context) }
    val routineClickJson by prefs.routineClickCounts.collectAsState(initial = "{}")
    val routineClickCounts = androidx.compose.runtime.remember(routineClickJson) {
        try {
            kotlinx.serialization.json.Json.decodeFromString<Map<String, Int>>(routineClickJson)
        } catch (e: Exception) {
            emptyMap()
        }
    }

    val routineTilesMap = remember {
        mapOf(
            "habits" to InfoTile("Habits", Icons.Default.CheckCircle, "Daily routine tracking"),
            "reminders" to InfoTile("Reminders", Icons.Default.Notifications, "Scheduled alerts"),
            "lists" to InfoTile("Lists", Icons.Default.List, "Checklists & Tasks"),
            "notes" to InfoTile("Notes", Icons.Default.Edit, "Quick notes & thoughts"),
            "project_focus" to InfoTile("Project Focus", Icons.Default.Science, "Track experiments")
        )
    }

    val sortedRoutineTiles = androidx.compose.runtime.remember(routineClickCounts) {
        listOf("habits", "reminders", "lists", "notes", "project_focus")
            .sortedByDescending { routineClickCounts[it] ?: 0 }
            .take(5)
            .mapNotNull { routineTilesMap[it] }
    }

    val baseTiles = listOf(
        InfoTile("Sleep", Icons.Default.Bedtime, "Analysis & Debt"),
        InfoTile("Body Info", Icons.Default.AccessibilityNew, "Impact & Side Effects"),
        InfoTile("Medications", Icons.Default.Medication, "Prescriptions & Doses"),
        InfoTile("Tips and Tricks", Icons.Default.Lightbulb, "Master your data"),
        InfoTile("Health Coach", Icons.Default.QuestionMark, "Personalized Advice"),
        InfoTile("Key Metrics", Icons.Default.BarChart, "Your Body Data"),
        InfoTile("Food", Icons.Default.Restaurant, "Sensitivity Checker"),
        InfoTile("Community", Icons.Default.People, "Friends & Leaderboard")
    )

    val tiles = sortedRoutineTiles + baseTiles

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
                text = "Explore your health resources and deep insights.",
                color = NotelTextSecondary,
                fontSize = 14.sp,
                modifier = Modifier.padding(bottom = 24.dp)
            )

            val coroutineScope = rememberCoroutineScope()

            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                contentPadding = PaddingValues(bottom = 100.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                items(tiles.size) { index ->
                    val tile = tiles[index]
                    InfoTileCard(
                        tile = tile,
                        isUnlimited = isUnlimited,
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

@Composable
fun InfoTileCard(
    tile: InfoTile,
    isUnlimited: Boolean,
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
    val isAiGated = tile.title == "Health Coach" || tile.title == "Tips and Tricks"
    val isLocked = isAiGated && !isUnlimited

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f) // Square tiles
            // Neon Glow layers
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
            .clickable { 
                if (isLocked) {
                    onNavigateToMembership()
                } else {
                    when (tile.title) {
                        "Sleep" -> onSleepClick()
                        "Body Info" -> onBodyInfoClick()
                        "Medications" -> onMedicationsClick()
                        "Key Metrics" -> onKeyMetricsClick()
                        "Health Coach" -> onCoachClick()
                        "Tips and Tricks" -> onTipsAndTricksClick()
                        "Food" -> onFoodClick()
                        "Community" -> onCommunityClick()
                        "Habits" -> { recordClick("habits"); onHabitsClick() }
                        "Reminders" -> { recordClick("reminders"); onRemindersClick() }
                        "Lists" -> { recordClick("lists"); onListsClick() }
                        "Notes" -> { recordClick("notes"); onNotesClick() }
                        "Project Focus" -> { recordClick("project_focus"); onProjectFocusClick() }
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
            modifier = Modifier.fillMaxSize().graphicsLayer(alpha = if (isLocked) 0.5f else 1f),
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
