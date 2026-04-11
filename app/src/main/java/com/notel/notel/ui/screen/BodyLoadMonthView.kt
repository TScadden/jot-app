package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelAccent
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelSurface
import com.notel.notel.ui.theme.NotelSurfaceHigh
import com.notel.notel.ui.theme.NotelTextPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
import com.notel.notel.ui.theme.liquidGlass
import com.notel.notel.ui.viewmodel.BodyLoadUiState
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

@Composable
fun BodyLoadMonthView(
    state: BodyLoadUiState,
    onDaySelected: (String) -> Unit
) {
    var currentMonth by remember { mutableStateOf(YearMonth.now()) }
    val today = LocalDate.now()
    
    val firstDayOfMonth = currentMonth.atDay(1)
    val dayOfWeekOffset = firstDayOfMonth.dayOfWeek.value % 7 // 0=Sun, 1=Mon... if adjusted
    
    // We want Monday as start? Or Sunday? Most calendars use Sunday.
    // java.time.DayOfWeek: 1=Mon, 7=Sun.
    // Offset for Sunday start:
    val sundayOffset = if (firstDayOfMonth.dayOfWeek.value == 7) 0 else firstDayOfMonth.dayOfWeek.value

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp)
            .liquidGlass(
                shape = RoundedCornerShape(24.dp),
                color = NotelSurface,
                alpha = 0.5f,
                showBorder = true
            )
            .padding(16.dp)
    ) {
        // Header: Month Name + Nav
        Row(
            modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = currentMonth.format(DateTimeFormatter.ofPattern("MMMM yyyy")),
                color = NotelTextPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.Black
            )
            
            Row {
                IconButton(
                    onClick = { currentMonth = currentMonth.minusMonths(1) },
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(Icons.Default.KeyboardArrowLeft, null, tint = NotelTextSecondary)
                }
                
                val isNextMonthDisabled = currentMonth >= YearMonth.now()
                IconButton(
                    onClick = { if (!isNextMonthDisabled) currentMonth = currentMonth.plusMonths(1) },
                    enabled = !isNextMonthDisabled,
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(
                        Icons.Default.KeyboardArrowRight, 
                        null, 
                        tint = if (isNextMonthDisabled) NotelTextSecondary.copy(alpha = 0.3f) else NotelTextSecondary
                    )
                }
            }
        }
        
        // Days Row (S M T W T F S)
        Row(modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
            val days = listOf("S", "M", "T", "W", "T", "F", "S")
            days.forEach { day ->
                Text(
                    text = day,
                    modifier = Modifier.weight(1f),
                    color = NotelTextSecondary.copy(alpha = 0.5f),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
            }
        }
        
        // Calendar Grid
        val daysInMonth = currentMonth.lengthOfMonth()
        val totalCells = ((daysInMonth + sundayOffset + 6) / 7) * 7
        
        Column {
            for (row in 0 until totalCells / 7) {
                Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    for (col in 0 until 7) {
                        val dayIndex = row * 7 + col - sundayOffset + 1
                        
                        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
                            if (dayIndex in 1..daysInMonth) {
                                val date = currentMonth.atDay(dayIndex)
                                val dateStr = date.toString()
                                val scoreData = state.historyScores.find { it.date == dateStr }
                                val isSelected = state.selectedDate == dateStr
                                val isToday = date == today
                                val isPastToday = date > today
                                
                                val score = scoreData?.score ?: 0
                                
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .clickable(enabled = !isPastToday) { onDaySelected(dateStr) }
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .size(34.dp)
                                            .background(
                                                if (isSelected) NotelPrimary.copy(alpha = 0.2f) else Color.Transparent,
                                                CircleShape
                                            )
                                            .border(
                                                width = if (isToday) 2.dp else if (isSelected) 1.dp else 0.dp,
                                                brush = if (isToday) Brush.linearGradient(listOf(NotelPrimary, NotelAccent)) else SolidColor(NotelPrimary.copy(alpha = 0.3f)),
                                                shape = CircleShape
                                            ),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Text(
                                            text = if (score > 0) score.toString() else dayIndex.toString(),
                                            color = if (isPastToday) NotelTextSecondary.copy(alpha = 0.2f) else if (score > 0) NotelTextPrimary else NotelTextSecondary,
                                            fontSize = if (score > 0) 11.sp else 12.sp,
                                            fontWeight = if (score > 0 || isToday) FontWeight.Black else FontWeight.Medium
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        Spacer(Modifier.height(8.dp))
        
        // Small legend
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp)) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(NotelPrimary))
            Spacer(Modifier.width(6.dp))
            Text("Scores shown where available", fontSize = 10.sp, color = NotelTextSecondary)
        }
    }
}
