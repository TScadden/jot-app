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
    
    var noteTitle by remember { mutableStateOf("") }
    var noteBody by remember { mutableStateOf("") }
    
    var editingNote by remember { mutableStateOf<UserListItem?>(null) }
    var editTitle by remember { mutableStateOf("") }
    var editBody by remember { mutableStateOf("") }

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
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(NotelSurfaceHigh.copy(alpha = 0.05f), shape = RoundedCornerShape(18.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.03f), shape = RoundedCornerShape(18.dp))
                    .padding(12.dp)
            ) {
                OutlinedTextField(
                    value = noteTitle,
                    onValueChange = { noteTitle = it },
                    placeholder = { Text("Title (optional)...", color = NotelTextSecondary, fontSize = 14.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary.copy(alpha = 0.5f),
                        unfocusedBorderColor = Color.Transparent,
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary,
                        focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.04f),
                        unfocusedContainerColor = Color.Transparent
                    ),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Words,
                        imeAction = ImeAction.Next
                    )
                )
                
                Spacer(Modifier.height(6.dp))
                
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    OutlinedTextField(
                        value = noteBody,
                        onValueChange = { noteBody = it },
                        placeholder = { Text("Write a note...", color = NotelTextSecondary, fontSize = 14.sp) },
                        modifier = Modifier.weight(1f),
                        singleLine = false,
                        maxLines = 4,
                        shape = RoundedCornerShape(12.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = NotelPrimary.copy(alpha = 0.5f),
                            unfocusedBorderColor = Color.Transparent,
                            focusedTextColor = NotelTextPrimary,
                            unfocusedTextColor = NotelTextPrimary,
                            cursorColor = NotelPrimary,
                            focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.04f),
                            unfocusedContainerColor = Color.Transparent
                        ),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.Sentences,
                            imeAction = ImeAction.Default
                        )
                    )
                    Spacer(Modifier.width(8.dp))
                    FilledIconButton(
                        onClick = {
                            if (noteBody.isNotBlank() || noteTitle.isNotBlank()) {
                                viewModel.addNote(noteTitle, noteBody)
                                noteTitle = ""
                                noteBody = ""
                            }
                        },
                        enabled = noteBody.isNotBlank() || noteTitle.isNotBlank(),
                        shape = CircleShape,
                        colors = IconButtonDefaults.filledIconButtonColors(
                            containerColor = if (noteBody.isNotBlank() || noteTitle.isNotBlank()) NotelPrimary else NotelSurfaceHigh.copy(alpha = 0.3f),
                            contentColor = Color.White
                        ),
                        modifier = Modifier.size(44.dp)
                    ) {
                        Icon(Icons.Default.Add, "Add Note")
                    }
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
                        val (title, body, timestamp) = if (parts.size == 3) {
                            Triple(parts[0], parts[1], parts[2].toLongOrNull() ?: System.currentTimeMillis())
                        } else if (parts.size == 2) {
                            Triple("New Note", parts[0], parts[1].toLongOrNull() ?: System.currentTimeMillis())
                        } else {
                            Triple("New Note", item.text, System.currentTimeMillis())
                        }
                        
                        val formattedDate = SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault()).format(Date(timestamp))

                        Surface(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    editingNote = item
                                    editTitle = if (title == "New Note" && parts.size < 3) "" else title
                                    editBody = body
                                },
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
                                        text = title,
                                        color = NotelPrimary,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        text = body,
                                        color = NotelTextPrimary,
                                        fontSize = 13.sp,
                                        lineHeight = 18.sp
                                    )
                                    Spacer(Modifier.height(6.dp))
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

    // ── Edit Note Dialog ──────────────────────────────────────────────────────
    editingNote?.let { note ->
        AlertDialog(
            onDismissRequest = { editingNote = null },
            containerColor = NotelSurface,
            title = {
                Text(
                    "Edit Note",
                    color = NotelTextPrimary,
                    fontWeight = FontWeight.Bold
                )
            },
            text = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    OutlinedTextField(
                        value = editTitle,
                        onValueChange = { editTitle = it },
                        placeholder = { Text("Title (optional)...", color = NotelTextSecondary) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = NotelPrimary,
                            unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.3f),
                            focusedTextColor = NotelTextPrimary,
                            unfocusedTextColor = NotelTextPrimary,
                            cursorColor = NotelPrimary
                        )
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = editBody,
                        onValueChange = { editBody = it },
                        placeholder = { Text("Note content...", color = NotelTextSecondary) },
                        singleLine = false,
                        maxLines = 6,
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = NotelPrimary,
                            unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.3f),
                            focusedTextColor = NotelTextPrimary,
                            unfocusedTextColor = NotelTextPrimary,
                            cursorColor = NotelPrimary
                        )
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.editNote(note, editTitle, editBody)
                        editingNote = null
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { editingNote = null }) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            }
        )
    }
}
