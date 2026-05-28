package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.NotesViewModel
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesScreen(
    onBack: () -> Unit = {},
    viewModel: NotesViewModel = hiltViewModel()
) {
    val notes by viewModel.notes.collectAsState()
    var noteText by remember { mutableStateOf("") }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Notes",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextPrimary)
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
                .padding(bottom = 80.dp)
                .padding(horizontal = 16.dp)
        ) {
            // ── Input area to add a new note ────────────────────────────────────
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = noteText,
                    onValueChange = { noteText = it },
                    placeholder = { Text("Write a note...", color = NotelTextSecondary, fontSize = 14.sp) },
                    modifier = Modifier.weight(1f),
                    singleLine = false,
                    maxLines = 4,
                    shape = RoundedCornerShape(14.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary.copy(alpha = 0.6f),
                        unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.2f),
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary,
                        focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.08f),
                        unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.04f)
                    ),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                        imeAction = ImeAction.Default
                    )
                )
                Spacer(Modifier.width(8.dp))
                FilledIconButton(
                    onClick = {
                        if (noteText.isNotBlank()) {
                            viewModel.addNote(noteText)
                            noteText = ""
                        }
                    },
                    enabled = noteText.isNotBlank(),
                    shape = CircleShape,
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = if (noteText.isNotBlank()) NotelPrimary else NotelSurfaceHigh.copy(alpha = 0.3f),
                        contentColor = Color.White
                    ),
                    modifier = Modifier.size(48.dp)
                ) {
                    Icon(Icons.Default.Add, "Add Note")
                }
            }

            Spacer(Modifier.height(20.dp))

            // ── Notes list ────────────────────────────────────────────────────────
            if (notes.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("📝", fontSize = 48.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "No notes yet",
                            color = NotelTextPrimary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Write your first note above",
                            color = NotelTextSecondary,
                            fontSize = 13.sp
                        )
                    }
                }
            } else {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(bottom = 20.dp)
                ) {
                    items(notes, key = { it.id }) { item ->
                        val parts = item.text.split("_||_")
                        val text = parts.getOrNull(0) ?: item.text
                        val timestamp = parts.getOrNull(1)?.toLongOrNull() ?: System.currentTimeMillis()
                        val formattedDate = SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault()).format(Date(timestamp))

                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(14.dp),
                            color = NotelSurfaceHigh.copy(alpha = 0.08f),
                            border = androidx.compose.foundation.BorderStroke(
                                1.dp,
                                Color.White.copy(alpha = 0.05f)
                            )
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = text,
                                        color = NotelTextPrimary,
                                        fontSize = 14.sp,
                                        lineHeight = 20.sp
                                    )
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        text = formattedDate,
                                        color = NotelTextSecondary.copy(alpha = 0.6f),
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Normal
                                    )
                                }
                                Spacer(Modifier.width(8.dp))
                                IconButton(
                                    onClick = { viewModel.deleteNote(item) },
                                    modifier = Modifier.size(28.dp)
                                ) {
                                    Icon(
                                        Icons.Default.Close,
                                        "Delete Note",
                                        tint = NotelTextSecondary.copy(alpha = 0.4f),
                                        modifier = Modifier.size(14.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
