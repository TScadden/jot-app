package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.CommonConditionsList
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject

@HiltViewModel
class ConditionsViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val syncManager: SyncManager
) : ViewModel() {

    val selectedConditions = mutableStateListOf<String>()

    init {
        viewModelScope.launch {
            val jsonStr = preferences.userConditions.first()
            if (jsonStr.isNotBlank()) {
                try {
                    val list = Json.decodeFromString<List<String>>(jsonStr)
                    selectedConditions.clear()
                    selectedConditions.addAll(list)
                } catch (e: Exception) {
                    // Ignore parse error
                }
            }
        }
    }

    fun addCondition(condition: String) {
        if (!selectedConditions.contains(condition)) {
            selectedConditions.add(condition)
            saveAndSync()
        }
    }

    fun removeCondition(condition: String) {
        selectedConditions.remove(condition)
        saveAndSync()
    }

    private fun saveAndSync() {
        viewModelScope.launch {
            val jsonStr = Json.encodeToString(selectedConditions.toList())
            preferences.setUserConditions(jsonStr)
            syncManager.pushProfileData()
        }
    }
}

@Composable
fun ConditionsScreen(
    viewModel: ConditionsViewModel = hiltViewModel(),
    onBack: () -> Unit = {},
    onNavigateNext: () -> Unit,
    onSkip: () -> Unit
) {
    var searchQuery by remember { mutableStateOf("") }
    var isSearching by remember { mutableStateOf(false) }

    val filteredConditions = remember(searchQuery) {
        if (searchQuery.isBlank()) {
            CommonConditionsList.list
        } else {
            CommonConditionsList.list.filter {
                it.contains(searchQuery, ignoreCase = true)
            }
        }
    }

    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        if (isSearching) {
            // FULL SCREEN SEARCH OVERLAY
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(16.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    IconButton(
                        onClick = { isSearching = false },
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(NotelSurfaceHigh)
                    ) {
                        Icon(Icons.Default.Close, "Close search", tint = NotelTextPrimary, modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "Search conditions",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                }

                Spacer(Modifier.height(16.dp))

                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = { Text("Search all conditions", color = NotelTextSecondary) },
                    leadingIcon = { Icon(Icons.Default.Search, null, tint = NotelTextSecondary) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(Icons.Default.Close, null, tint = NotelTextSecondary)
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary,
                        unfocusedBorderColor = NotelTextSecondary,
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary
                    ),
                    singleLine = true
                )

                Spacer(Modifier.height(16.dp))

                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    items(filteredConditions) { condition ->
                        val isSelected = viewModel.selectedConditions.contains(condition)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .clickable {
                                    if (isSelected) {
                                        viewModel.removeCondition(condition)
                                    } else {
                                        viewModel.addCondition(condition)
                                    }
                                    isSearching = false
                                }
                                .padding(vertical = 12.dp, horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text(
                                text = condition,
                                fontSize = 14.sp,
                                color = NotelTextPrimary,
                                modifier = Modifier.weight(1f)
                            )
                            if (isSelected) {
                                Icon(
                                    imageVector = Icons.Default.Check,
                                    contentDescription = "Selected",
                                    tint = NotelPrimary,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        }
                        HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.5f))
                    }
                }
            }
        } else {
            // MAIN ADD CONDITIONS SCREEN
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 24.dp, vertical = 16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.SpaceBetween
                ) {
                    TopLogoHeader(
                        onBack = onBack,
                        onSkip = onSkip,
                        modifier = Modifier.padding(top = 8.dp)
                    )

                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Spacer(Modifier.height(12.dp))

                        Text(
                            text = "Add conditions",
                            fontSize = 28.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelPrimary,
                            textAlign = TextAlign.Center
                        )

                        Spacer(Modifier.height(12.dp))

                        Text(
                            text = "This helps us personalize your experience by suggesting the most relevant symptoms to track.",
                            fontSize = 14.sp,
                            color = NotelTextSecondary,
                            textAlign = TextAlign.Center,
                            lineHeight = 20.sp
                        )

                        Spacer(Modifier.height(20.dp))

                        // STANDALONE SEARCH BAR (OPTION 4)
                        Surface(
                            onClick = { isSearching = true },
                            shape = RoundedCornerShape(16.dp),
                            color = NotelSurface,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .padding(horizontal = 16.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Search,
                                    contentDescription = "Search",
                                    tint = NotelPrimary,
                                    modifier = Modifier.size(20.dp)
                                )
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    text = "Search conditions...",
                                    color = NotelTextSecondary,
                                    fontSize = 14.sp
                                )
                            }
                        }

                        Spacer(Modifier.height(20.dp))

                        // YOUR CONDITIONS LIST CARD
                        GlassyCard(
                            shape = RoundedCornerShape(20.dp),
                            color = NotelSurface,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp)
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Box(
                                        modifier = Modifier
                                            .size(40.dp)
                                            .clip(CircleShape)
                                            .background(NotelPrimary.copy(alpha = 0.2f)),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Icon(Icons.Default.MedicalServices, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(20.dp))
                                    }
                                    Spacer(Modifier.width(12.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text("Your conditions", color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                        Text("Diagnosed or suspected conditions.", color = NotelTextSecondary, fontSize = 12.sp)
                                    }
                                }

                                if (viewModel.selectedConditions.isNotEmpty()) {
                                    Spacer(Modifier.height(16.dp))
                                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                        viewModel.selectedConditions.forEach { condition ->
                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .background(NotelSurfaceHigh.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.SpaceBetween
                                            ) {
                                                Text(
                                                    text = condition,
                                                    color = NotelTextPrimary,
                                                    fontSize = 14.sp,
                                                    fontWeight = FontWeight.Medium,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                IconButton(
                                                    onClick = { viewModel.removeCondition(condition) },
                                                    modifier = Modifier.size(24.dp)
                                                ) {
                                                    Icon(
                                                        imageVector = Icons.Default.Delete,
                                                        contentDescription = "Delete condition",
                                                        tint = MaterialTheme.colorScheme.error.copy(alpha = 0.8f),
                                                        modifier = Modifier.size(18.dp)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // NEXT BUTTON
                    Button(
                        onClick = onNavigateNext,
                        colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                        shape = RoundedCornerShape(24.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(54.dp)
                    ) {
                        Text(
                            text = "Next",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                    }
                }
            }
        }
    }
}
