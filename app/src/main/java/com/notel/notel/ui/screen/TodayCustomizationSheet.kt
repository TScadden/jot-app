package com.notel.notel.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.TodayViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayCustomizationBottomSheet(
    viewModel: TodayViewModel,
    onDismiss: () -> Unit
) {
    val uiState by viewModel.uiState.collectAsState()

    val availableSections = listOf(
        "TODAY_PLAN" to "Today's Plan",
        "HOW_IM_DOING" to "How I'm Doing",
        "WHAT_CHANGED" to "What Changed",
        "AI_INSIGHT" to "AI Insight",
        "QUICK_ACTIONS" to "Quick Actions"
    )

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = NotelBackground
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Customize Today",
                    fontWeight = FontWeight.Bold,
                    fontSize = 18.sp,
                    color = NotelTextPrimary
                )
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close customization sheet", tint = NotelTextSecondary)
                }
            }

            Spacer(Modifier.height(16.dp))

            Text("Display Mode", fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = NotelTextSecondary)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilterChip(
                    selected = uiState.mode == "SIMPLE",
                    onClick = { viewModel.setMode("SIMPLE") },
                    label = { Text("Simple Mode") }
                )
                FilterChip(
                    selected = uiState.mode == "DETAILED",
                    onClick = { viewModel.setMode("DETAILED") },
                    label = { Text("Detailed Mode") }
                )
            }

            Spacer(Modifier.height(20.dp))

            Text("Optional Sections", fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = NotelTextSecondary)
            Spacer(Modifier.height(8.dp))

            availableSections.forEach { (key, title) ->
                val isVisible = !uiState.hiddenSections.contains(key)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(text = title, color = NotelTextPrimary, fontSize = 14.sp)
                    Switch(
                        checked = isVisible,
                        onCheckedChange = { checked ->
                            val updated = uiState.hiddenSections.toMutableSet()
                            if (checked) updated.remove(key) else updated.add(key)
                            viewModel.updateHiddenSections(updated)
                        },
                        modifier = Modifier.semantics { contentDescription = "Toggle $title section visibility" }
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}
