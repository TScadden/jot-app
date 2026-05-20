package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.HabitViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HabitsScreen(
    onBack: () -> Unit = {},
    habitViewModel: HabitViewModel = hiltViewModel()
) {
    val habits by habitViewModel.habits.collectAsState()
    var newHabitText by remember { mutableStateOf("") }

    val checkedCount = habits.count { habitViewModel.isCheckedToday(it) }
    val progressRatio = if (habits.isEmpty()) 0f else checkedCount.toFloat() / habits.size.toFloat()
    val overallStreak = habitViewModel.getOverallStreak()

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Daily Habits",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = NotelTextPrimary
                        )
                    }
                },
                actions = {
                    if (habits.isNotEmpty()) {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = NotelPrimary.copy(alpha = 0.1f),
                            border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.2f)),
                            modifier = Modifier.padding(end = 16.dp)
                        ) {
                            Text(
                                "$checkedCount/${habits.size} DONE",
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                color = NotelPrimary,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Black,
                                letterSpacing = 1.sp
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

            // ── Overall Streak Banner ─────────────────────────────────
            if (overallStreak > 0) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(16.dp),
                    color = Color.Transparent
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                Brush.horizontalGradient(
                                    colors = listOf(
                                        Color(0xFFE2A123).copy(alpha = 0.20f),
                                        Color(0xFFFF6B35).copy(alpha = 0.15f)
                                    )
                                ),
                                shape = RoundedCornerShape(16.dp)
                            )
                            .padding(horizontal = 16.dp, vertical = 12.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Whatshot,
                                contentDescription = null,
                                tint = Color(0xFFE2A123),
                                modifier = Modifier.size(28.dp)
                            )
                            Column {
                                Text(
                                    text = "$overallStreak day streak!",
                                    color = Color(0xFFE2A123),
                                    fontSize = 16.sp,
                                    fontWeight = FontWeight.ExtraBold
                                )
                                Text(
                                    text = "You completed every habit $overallStreak day${if (overallStreak == 1) "" else "s"} in a row",
                                    color = Color(0xFFE2A123).copy(alpha = 0.7f),
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            // ── Add Habit Input ───────────────────────────────────────
            OutlinedTextField(
                value = newHabitText,
                onValueChange = { newHabitText = it },
                placeholder = {
                    Text(
                        "Add new routine habit...",
                        color = NotelTextSecondary,
                        fontSize = 13.sp
                    )
                },
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
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary.copy(alpha = 0.5f),
                    unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.2f),
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary,
                    focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.05f),
                    unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.05f)
                )
            )

            Spacer(Modifier.height(14.dp))

            // ── Subtitle + Progress Bar ───────────────────────────────
            Text(
                text = if (habits.isEmpty()) "Add your first habit above to get started."
                       else if (checkedCount == habits.size) "All done today! Amazing work 🎉"
                       else "Keep it up — you're on a roll!",
                color = NotelTextSecondary,
                fontSize = 13.sp
            )

            Spacer(Modifier.height(8.dp))

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(CircleShape)
                    .background(NotelSurfaceHigh.copy(alpha = 0.1f))
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(progressRatio)
                        .fillMaxHeight()
                        .background(
                            if (progressRatio == 1f) Color(0xFF4CAF50) else NotelPrimary
                        )
                )
            }

            Spacer(Modifier.height(20.dp))

            // ── Habit Grid ────────────────────────────────────────────
            if (habits.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("🔥", fontSize = 40.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "No habits yet",
                            color = NotelTextPrimary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Add your first daily routine above!",
                            color = NotelTextSecondary,
                            fontSize = 13.sp
                        )
                    }
                }
            } else {
                val rows = habits.chunked(2)
                LazyColumn(
                    contentPadding = PaddingValues(bottom = 100.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    items(rows) { row ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            row.forEach { habit ->
                                val isChecked = habitViewModel.isCheckedToday(habit)
                                val streak = habitViewModel.getStreak(habit)

                                Surface(
                                    onClick = { habitViewModel.toggleHabit(habit.id, !isChecked) },
                                    modifier = Modifier
                                        .weight(1f)
                                        .heightIn(min = 100.dp),
                                    shape = RoundedCornerShape(20.dp),
                                    color = if (isChecked) NotelPrimary.copy(alpha = 0.15f)
                                            else NotelSurfaceHigh.copy(alpha = 0.1f),
                                    border = BorderStroke(
                                        1.dp,
                                        if (isChecked) NotelPrimary.copy(alpha = 0.3f)
                                        else Color.White.copy(alpha = 0.05f)
                                    )
                                ) {
                                    Column(
                                        modifier = Modifier.padding(14.dp),
                                        verticalArrangement = Arrangement.SpaceBetween
                                    ) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.Top
                                        ) {
                                            // Streak badge
                                            Surface(
                                                shape = RoundedCornerShape(8.dp),
                                                color = if (isChecked) Color(0xFF4CAF50).copy(alpha = 0.15f)
                                                        else if (streak > 0) Color(0xFFE2A123).copy(alpha = 0.15f)
                                                        else Color.Transparent
                                            ) {
                                                Text(
                                                    text = if (isChecked) "✅" else if (streak > 0) "🔥 $streak" else "—",
                                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                                    fontSize = 11.sp,
                                                    fontWeight = FontWeight.Bold,
                                                    color = if (isChecked) Color(0xFF4CAF50)
                                                            else if (streak > 0) Color(0xFFE2A123)
                                                            else NotelTextSecondary
                                                )
                                            }
                                            IconButton(
                                                onClick = { habitViewModel.deleteHabit(habit.id) },
                                                modifier = Modifier.size(18.dp)
                                            ) {
                                                Icon(
                                                    Icons.Default.Close,
                                                    null,
                                                    tint = NotelTextSecondary.copy(alpha = 0.4f),
                                                    modifier = Modifier.size(11.dp)
                                                )
                                            }
                                        }
                                        Spacer(Modifier.height(12.dp))
                                        Column {
                                            Text(
                                                habit.title,
                                                color = NotelTextPrimary,
                                                fontSize = 13.sp,
                                                fontWeight = FontWeight.Bold,
                                                lineHeight = 16.sp
                                            )
                                            Text(
                                                habit.target_time ?: "Anytime",
                                                color = NotelTextSecondary,
                                                fontSize = 10.sp
                                            )
                                        }
                                    }
                                }
                            }
                            // Fill empty slot in a partial row
                            if (row.size == 1) {
                                Spacer(modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }
            }
        }
    }
}
