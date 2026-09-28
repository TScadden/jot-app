package com.notel.notel.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.research.ResearchEntry
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.ResearchViewModel

/** Medical disclaimer — always visible at the top of the Research screen. */
private const val RESEARCH_DISCLAIMER =
    "For educational purposes only — not medical advice. Talk to your doctor before trying anything here."

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResearchScreen(
    onBack: () -> Unit = {},
    onNavigateToProfile: () -> Unit = {},
    viewModel: ResearchViewModel = hiltViewModel()
) {
    val userConditions by viewModel.userConditions.collectAsState()
    val entries by viewModel.entries.collectAsState()

    var selectedCondition by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(userConditions) {
        if (selectedCondition !in userConditions) {
            selectedCondition = userConditions.firstOrNull()
        }
    }

    val visibleEntries = remember(selectedCondition, entries) {
        val condition = selectedCondition ?: return@remember emptyList()
        entries.filter { entry -> entry.conditionTags.contains(condition) }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Research",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
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
        ) {
            // Pinned medical disclaimer banner — always visible above the scroll region
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = NotelWarning.copy(alpha = 0.12f),
                border = androidx.compose.foundation.BorderStroke(1.dp, NotelWarning.copy(alpha = 0.4f)),
                modifier = Modifier.padding(horizontal = 16.dp)
            ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Icon(
                            imageVector = Icons.Default.Warning,
                            contentDescription = null,
                            tint = NotelWarning,
                            modifier = Modifier
                                .size(20.dp)
                                .padding(end = 2.dp)
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = RESEARCH_DISCLAIMER,
                            color = NotelTextPrimary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            lineHeight = 17.sp
                        )
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                contentPadding = PaddingValues(bottom = 32.dp)
            ) {
            if (userConditions.isEmpty()) {
                item {
                    // No saved conditions — point to Profile → Conditions
                    Surface(
                        shape = RoundedCornerShape(16.dp),
                        color = NotelSurface,
                        border = androidx.compose.foundation.BorderStroke(1.dp, NotelBorder)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(20.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(
                                imageVector = Icons.Default.PersonAdd,
                                contentDescription = null,
                                tint = NotelPrimary,
                                modifier = Modifier.size(40.dp)
                            )
                            Spacer(Modifier.height(12.dp))
                            Text(
                                "No conditions saved yet",
                                color = NotelTextPrimary,
                                fontWeight = FontWeight.Bold,
                                fontSize = 16.sp
                            )
                            Spacer(Modifier.height(6.dp))
                            Text(
                                "Research is personalized to your conditions. Add them in Profile → Conditions to see relevant entries.",
                                color = NotelTextSecondary,
                                fontSize = 13.sp,
                                lineHeight = 18.sp
                            )
                            Spacer(Modifier.height(14.dp))
                            Button(
                                onClick = onNavigateToProfile,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = NotelPrimary,
                                    contentColor = androidx.compose.ui.graphics.Color.White
                                )
                            ) {
                                Text("Go to Profile → Conditions", fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            } else {
                item {
                    // Condition selector
                    Text(
                        "Your conditions",
                        color = NotelTextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    Spacer(Modifier.height(6.dp))
                    var dropdownExpanded by remember { mutableStateOf(false) }
                    ExposedDropdownMenuBox(
                        expanded = dropdownExpanded,
                        onExpandedChange = { dropdownExpanded = !dropdownExpanded }
                    ) {
                        OutlinedTextField(
                            value = selectedCondition.orEmpty(),
                            onValueChange = {},
                            readOnly = true,
                            trailingIcon = {
                                ExposedDropdownMenuDefaults.TrailingIcon(expanded = dropdownExpanded)
                            },
                            colors = OutlinedTextFieldDefaults.colors(
                                unfocusedContainerColor = NotelSurface,
                                focusedContainerColor = NotelSurface,
                                unfocusedBorderColor = NotelBorder,
                                focusedBorderColor = NotelPrimary,
                                unfocusedTextColor = NotelTextPrimary,
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTrailingIconColor = NotelTextSecondary,
                                focusedTrailingIconColor = NotelPrimary
                            ),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .menuAnchor()
                                .fillMaxWidth()
                        )
                        ExposedDropdownMenu(
                            expanded = dropdownExpanded,
                            onDismissRequest = { dropdownExpanded = false },
                            modifier = Modifier.background(NotelSurface)
                        ) {
                            userConditions.forEach { condition ->
                                DropdownMenuItem(
                                    text = { Text(condition, color = NotelTextPrimary) },
                                    onClick = {
                                        selectedCondition = condition
                                        dropdownExpanded = false
                                    }
                                )
                            }
                        }
                    }
                }

                if (visibleEntries.isEmpty()) {
                    item {
                        Surface(
                            shape = RoundedCornerShape(16.dp),
                            color = NotelSurface,
                            border = androidx.compose.foundation.BorderStroke(1.dp, NotelBorder)
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(20.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Science,
                                    contentDescription = null,
                                    tint = NotelTextSecondary,
                                    modifier = Modifier.size(40.dp)
                                )
                                Spacer(Modifier.height(12.dp))
                                Text(
                                    "Nothing here yet",
                                    color = NotelTextPrimary,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 16.sp
                                )
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    "The founder adds new research as he finds it.",
                                    color = NotelTextSecondary,
                                    fontSize = 13.sp
                                )
                            }
                        }
                    }
                } else {
                    items(visibleEntries, key = { it.id }) { entry ->
                        ResearchEntryCard(entry = entry)
                    }
                }
            }
        }
    }
}

@Composable
private fun ResearchEntryCard(entry: ResearchEntry) {
    var expanded by remember(entry.id) { mutableStateOf(false) }
    val uriHandler = LocalUriHandler.current

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelBorder),
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded }
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = entry.title,
                        color = NotelTextPrimary,
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp,
                        lineHeight = 20.sp
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = entry.summary,
                        color = NotelTextSecondary,
                        fontSize = 13.sp,
                        lineHeight = 18.sp
                    )
                }
                Spacer(Modifier.width(8.dp))
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    tint = NotelTextSecondary
                )
            }

            Spacer(Modifier.height(10.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clickable { uriHandler.openUri(entry.sourceUrl) }
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                    contentDescription = "Open source",
                    tint = NotelPrimary,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "via ${entry.sourceHandle} on ${entry.sourcePlatform}",
                    color = NotelPrimary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }

            AnimatedVisibility(
                visible = expanded,
                enter = expandVertically(),
                exit = shrinkVertically()
            ) {
                Column {
                    Spacer(Modifier.height(12.dp))
                    HorizontalDivider(color = NotelBorder)
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = entry.detail,
                        color = NotelTextPrimary,
                        fontSize = 13.sp,
                        lineHeight = 19.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = "Source: ${entry.sourceName} · \"${entry.sourceVideoTitle}\" (${entry.videoDurationSeconds}s)",
                        color = NotelTextSecondary,
                        fontSize = 11.sp,
                        lineHeight = 15.sp
                    )
                }
            }
        }
    }
}
