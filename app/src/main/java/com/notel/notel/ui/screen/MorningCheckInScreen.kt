package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.MorningCheckInViewModel

/**
 * Tabs Lab prototype: morning check-in / energy snapshot.
 * Rough by design. Local only, nothing leaves the phone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MorningCheckInScreen(
    onBack: () -> Unit = {},
    viewModel: MorningCheckInViewModel = hiltViewModel()
) {
    val state by viewModel.uiState.collectAsState()

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Morning check in",
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
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState())
        ) {
            Spacer(Modifier.height(4.dp))

            // Prototype badge
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = NotelWarning.copy(alpha = 0.15f),
                border = androidx.compose.foundation.BorderStroke(1.dp, NotelWarning.copy(alpha = 0.4f))
            ) {
                Text(
                    "Prototype",
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                    color = NotelWarning,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.5.sp
                )
            }

            Spacer(Modifier.height(12.dp))

            Text(
                "A quick morning snapshot. This is a Lab prototype and everything stays on your phone.",
                color = NotelTextSecondary,
                fontSize = 13.sp,
                lineHeight = 18.sp
            )

            if (state.savedToday && !state.justSaved) {
                Spacer(Modifier.height(12.dp))
                Text(
                    "Checked in today. You can update it below.",
                    color = NotelPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Spacer(Modifier.height(20.dp))

            Text(
                "How much energy do you have today?",
                color = NotelTextPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold
            )

            Spacer(Modifier.height(12.dp))

            MorningCheckInViewModel.ENERGY_LEVELS.forEach { (level, label) ->
                val isSelected = state.selectedLevel == level
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .background(if (isSelected) NotelPrimary else NotelSurface)
                        .border(
                            1.dp,
                            if (isSelected) NotelPrimary else NotelPrimary.copy(alpha = 0.25f),
                            RoundedCornerShape(16.dp)
                        )
                        .clickable { viewModel.selectLevel(level) }
                        .padding(horizontal = 16.dp, vertical = 14.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .clip(CircleShape)
                                .background(
                                    if (isSelected) Color.White.copy(alpha = 0.25f)
                                    else NotelPrimary.copy(alpha = 0.12f)
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                "$level",
                                color = if (isSelected) Color.White else NotelPrimary,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }
                        Text(
                            label,
                            color = if (isSelected) Color.White else NotelTextPrimary,
                            fontSize = 15.sp,
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                            modifier = Modifier.weight(1f)
                        )
                        if (isSelected) {
                            Icon(
                                Icons.Default.Check,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(20.dp)
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            OutlinedTextField(
                value = state.note,
                onValueChange = viewModel::updateNote,
                modifier = Modifier.fillMaxWidth(),
                placeholder = {
                    Text(
                        "Anything to add about this morning? (optional)",
                        color = NotelTextSecondary,
                        fontSize = 13.sp
                    )
                },
                shape = RoundedCornerShape(16.dp),
                maxLines = 4,
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

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = viewModel::saveCheckIn,
                enabled = state.selectedLevel in 1..5,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = NotelPrimary,
                    disabledContainerColor = NotelPrimary.copy(alpha = 0.35f),
                    contentColor = Color.White,
                    disabledContentColor = Color.White.copy(alpha = 0.5f)
                )
            ) {
                Text(
                    "Save morning check in",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(vertical = 6.dp)
                )
            }

            if (state.justSaved) {
                Spacer(Modifier.height(12.dp))
                Text(
                    "Saved. Have a good day.",
                    color = NotelSuccess,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}
