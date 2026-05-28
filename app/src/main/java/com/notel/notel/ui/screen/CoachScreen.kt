package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.CoachMessage
import com.notel.notel.ui.viewmodel.CoachViewModel
import com.notel.notel.ui.viewmodel.NoteStatus
import com.notel.notel.ui.viewmodel.FileStatus
import kotlinx.coroutines.launch
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.platform.LocalContext


import com.notel.notel.ui.viewmodel.ListStatus

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CoachScreen(
    onBack: () -> Unit = {},
    viewModel: CoachViewModel = hiltViewModel()
) {
    val messages by viewModel.messages.collectAsState()
    val pendingAttachment by viewModel.pendingAttachment.collectAsState()
    var inputText by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    val coroutineScope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val context = LocalContext.current

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.attachFile(it, context.contentResolver) }
    }

    // Auto-scroll to bottom when new messages arrive
    LaunchedEffect(messages.size, messages.lastOrNull()?.isLoading) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Surface(
                            shape = CircleShape,
                            color = NotelPrimary.copy(alpha = 0.15f),
                            modifier = Modifier.size(36.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Text("✨", fontSize = 16.sp)
                            }
                        }
                        Spacer(Modifier.width(12.dp))
                        Text(
                            "Jot Coach",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextPrimary)
                    }
                },
                actions = {
                    if (messages.size > 1) {
                        IconButton(onClick = { viewModel.deleteCurrentSession(onDeleted = onBack) }) {
                            Icon(Icons.Default.Delete, "Delete Chat", tint = Color(0xFFFF5252))
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
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                items(messages, key = { it.id }) { message ->
                    ChatBubble(
                        message = message,
                        onApprove = { viewModel.approveProposedNote(message.id, message.proposedNoteText ?: "") },
                        onDeny = { viewModel.denyProposedNote(message.id) },
                        onApproveFile = { viewModel.approveProposedFile(message.id, message.proposedFileName ?: "") },
                        onDenyFile = { viewModel.denyProposedFile(message.id) },
                        onApproveList = { viewModel.approveProposedList(message.id, message.proposedListName ?: "", message.proposedListItems) },
                        onDenyList = { viewModel.denyProposedList(message.id) }
                    )
                }
            }


            // Input Area
            val density = androidx.compose.ui.platform.LocalDensity.current
            val imeBottom = WindowInsets.ime.getBottom(density)
            val bottomPadding = maxOf(100.dp, with(density) { imeBottom.toDp() })

            Surface(
                color = NotelBackground,
                modifier = Modifier.fillMaxWidth().padding(bottom = bottomPadding),
                tonalElevation = 8.dp
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp)
                ) {
                    // ── Pending attachment chip ──────────────────────────────────
                    if (pendingAttachment != null) {
                        Surface(
                            shape = RoundedCornerShape(20.dp),
                            color = NotelPrimary.copy(alpha = 0.15f),
                            modifier = Modifier
                                .padding(bottom = 8.dp)
                                .wrapContentWidth()
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Text("📎", fontSize = 14.sp)
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = pendingAttachment!!.name,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = NotelPrimary,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.widthIn(max = 220.dp)
                                )
                                Spacer(Modifier.width(4.dp))
                                IconButton(
                                    onClick = { viewModel.clearPendingAttachment() },
                                    modifier = Modifier.size(20.dp)
                                ) {
                                    Icon(
                                        Icons.Default.Close,
                                        contentDescription = "Remove attachment",
                                        tint = NotelTextSecondary,
                                        modifier = Modifier.size(14.dp)
                                    )
                                }
                            }
                        }
                    }

                    // ── Input row ────────────────────────────────────────────────
                    val canSend = inputText.isNotBlank() || pendingAttachment != null
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Bottom
                    ) {
                        IconButton(
                            onClick = { filePicker.launch("*/*") },
                            modifier = Modifier
                                .padding(end = 6.dp, bottom = 0.dp)
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(NotelSurfaceHigh.copy(alpha = 0.1f))
                        ) {
                            Text("📎", fontSize = 20.sp)
                        }

                        OutlinedTextField(
                            value = inputText,
                            onValueChange = { inputText = it },
                            modifier = Modifier
                                .weight(1f)
                                .padding(end = 8.dp),
                            placeholder = {
                                Text(
                                    if (pendingAttachment != null) "Add a message (optional)..."
                                    else "Ask Coach anything...",
                                    color = NotelTextSecondary
                                )
                            },
                            shape = RoundedCornerShape(24.dp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = NotelPrimary.copy(alpha = 0.5f),
                                unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.2f),
                                focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.1f),
                                unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.1f),
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTextColor = NotelTextPrimary
                            ),
                            maxLines = 4,
                            keyboardOptions = KeyboardOptions(
                                capitalization = KeyboardCapitalization.Sentences,
                                imeAction = ImeAction.Send
                            ),
                            keyboardActions = KeyboardActions(
                                onSend = {
                                    if (canSend) {
                                        viewModel.sendMessage(inputText)
                                        inputText = ""
                                        focusManager.clearFocus()
                                    }
                                }
                            )
                        )

                        FilledIconButton(
                            onClick = {
                                if (canSend) {
                                    viewModel.sendMessage(inputText)
                                    inputText = ""
                                    focusManager.clearFocus()
                                }
                            },
                            modifier = Modifier.size(48.dp),
                            shape = CircleShape,
                            colors = IconButtonDefaults.filledIconButtonColors(
                                containerColor = if (canSend) NotelPrimary else NotelSurfaceHigh,
                                contentColor = if (canSend) Color.White else NotelTextSecondary
                            ),
                            enabled = canSend
                        ) {
                            Icon(Icons.AutoMirrored.Filled.Send, "Send")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatBubble(
    message: CoachMessage,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
    onApproveFile: () -> Unit,
    onDenyFile: () -> Unit,
    onApproveList: () -> Unit,
    onDenyList: () -> Unit
) {
    val clipboardManager = LocalClipboardManager.current
    val isUser = message.role == "user"
    val bubbleShape = if (isUser) {
        RoundedCornerShape(20.dp, 20.dp, 4.dp, 20.dp)
    } else {
        RoundedCornerShape(20.dp, 20.dp, 20.dp, 4.dp)
    }

    val backgroundColor = if (isUser) {
        NotelPrimary.copy(alpha = 0.15f)
    } else {
        NotelSurfaceHigh.copy(alpha = 0.2f)
    }

    val textColor = if (isUser) NotelPrimary else NotelTextPrimary

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (isUser) Alignment.End else Alignment.Start
    ) {
        if (!isUser) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 4.dp, start = 4.dp)) {
                Text("✨ Jot Coach", fontSize = 12.sp, color = NotelPrimary, fontWeight = FontWeight.SemiBold)
            }
        }

        val isFileAttachment = message.role == "user" && message.content.startsWith("📄 Uploaded file:")

        if (isFileAttachment) {
            val fileName = message.content.substringAfter("📄 Uploaded file:").substringBefore("\n").trim()
            val fileContent = message.content.substringAfter("\n\n").trim()
            var isExpanded by remember { mutableStateOf(false) }

            Surface(
                shape = bubbleShape,
                color = backgroundColor,
                modifier = Modifier.widthIn(max = 300.dp)
            ) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Surface(
                            shape = RoundedCornerShape(8.dp),
                            color = NotelPrimary.copy(alpha = 0.2f),
                            modifier = Modifier.size(36.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Text("📄", fontSize = 18.sp)
                            }
                        }
                        Column {
                            Text(
                                text = fileName,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary
                            )
                            Text(
                                text = "Document uploaded & text extracted",
                                fontSize = 11.sp,
                                color = NotelTextSecondary
                            )
                        }
                    }

                    if (fileContent.isNotEmpty()) {
                        Spacer(modifier = Modifier.height(8.dp))
                        TextButton(
                            onClick = { isExpanded = !isExpanded },
                            contentPadding = PaddingValues(0.dp),
                            modifier = Modifier.height(28.dp)
                        ) {
                            Text(
                                text = if (isExpanded) "Hide Extracted Text ↑" else "Show Extracted Text ↓",
                                fontSize = 12.sp,
                                color = NotelPrimary,
                                fontWeight = FontWeight.SemiBold
                            )
                        }

                        if (isExpanded) {
                            Spacer(modifier = Modifier.height(6.dp))
                            Surface(
                                shape = RoundedCornerShape(8.dp),
                                color = Color.Black.copy(alpha = 0.2f),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(
                                    text = fileContent,
                                    fontSize = 12.sp,
                                    color = NotelTextSecondary,
                                    lineHeight = 18.sp,
                                    modifier = Modifier
                                        .padding(10.dp)
                                        .heightIn(max = 200.dp)
                                        .verticalScroll(rememberScrollState())
                                )
                            }
                        }
                    }
                }
            }
        } else {
            Surface(
                shape = bubbleShape,
                color = backgroundColor,
                modifier = Modifier.widthIn(max = 300.dp)
            ) {
                Box(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    if (message.isLoading) {
                        TypingIndicator()
                    } else {
                        Column {
                            Text(
                                text = parseMarkdownToAnnotatedString(message.content),
                                color = textColor,
                                fontSize = 15.sp,
                                lineHeight = 22.sp
                            )
                            if (!isUser && message.content.isNotBlank()) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                                    horizontalArrangement = Arrangement.End
                                ) {
                                    IconButton(
                                        onClick = {
                                            clipboardManager.setText(AnnotatedString(message.content))
                                        },
                                        modifier = Modifier.size(24.dp)
                                    ) {
                                        Icon(
                                            Icons.Default.ContentCopy,
                                            contentDescription = "Copy message",
                                            tint = NotelTextSecondary,
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

        // Suggestion Card or Badges for notes
        if (!isUser && message.proposedNoteText != null) {
            Spacer(modifier = Modifier.height(8.dp))
            when (message.noteStatus) {
                NoteStatus.PENDING -> {
                    Surface(
                        modifier = Modifier
                            .widthIn(max = 300.dp)
                            .padding(start = 8.dp),
                        shape = RoundedCornerShape(16.dp),
                        color = Color.White.copy(alpha = 0.05f),
                        border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text("📝", fontSize = 16.sp)
                                Text(
                                    text = "Suggested Note Log",
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = NotelPrimary
                                )
                            }
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "\"${message.proposedNoteText}\"",
                                fontSize = 14.sp,
                                color = NotelTextPrimary,
                                style = androidx.compose.ui.text.TextStyle(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic),
                                lineHeight = 20.sp
                            )
                            Spacer(modifier = Modifier.height(12.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OutlinedButton(
                                    onClick = onDeny,
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(12.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        contentColor = Color(0xFFFF5252)
                                    ),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFFF5252).copy(alpha = 0.4f))
                                ) {
                                    Text("Deny", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                                }

                                Button(
                                    onClick = onApprove,
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(12.dp),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF00E676),
                                        contentColor = Color(0xFF080E1A)
                                    )
                                ) {
                                    Text("Approve", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
                NoteStatus.APPROVED -> {
                    Row(
                        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "✓ Note Saved",
                            color = Color(0xFF00E676),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
                NoteStatus.DENIED -> {
                    Row(
                        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "✗ Suggestion Dismissed",
                            color = Color(0xFFFF5252),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }
                else -> {}
            }
        }

        // Suggestion Card or Badges for files
        if (!isUser && message.proposedFileName != null) {
            Spacer(modifier = Modifier.height(8.dp))
            when (message.fileStatus) {
                FileStatus.PENDING -> {
                    Surface(
                        modifier = Modifier
                            .widthIn(max = 300.dp)
                            .padding(start = 8.dp),
                        shape = RoundedCornerShape(16.dp),
                        color = Color.White.copy(alpha = 0.05f),
                        border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text("📁", fontSize = 16.sp)
                                Text(
                                    text = "Save Document to Jot DB?",
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = NotelPrimary
                                )
                            }
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "Would you like to save \"${message.proposedFileName}\" to your permanent Jot database?",
                                fontSize = 14.sp,
                                color = NotelTextPrimary,
                                lineHeight = 20.sp
                            )
                            Spacer(modifier = Modifier.height(12.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OutlinedButton(
                                    onClick = onDenyFile,
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(12.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        contentColor = Color(0xFFFF5252)
                                    ),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFFF5252).copy(alpha = 0.4f))
                                ) {
                                    Text("Deny", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                                }

                                Button(
                                    onClick = onApproveFile,
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(12.dp),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF00E676),
                                        contentColor = Color(0xFF080E1A)
                                    )
                                ) {
                                    Text("Approve", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
                FileStatus.APPROVED -> {
                    Row(
                        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "✓ Document Saved to Jot DB",
                            color = Color(0xFF00E676),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
                FileStatus.DENIED -> {
                    Row(
                        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "✗ Save Suggestion Dismissed",
                            color = Color(0xFFFF5252),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                }
                else -> {}
            }
        }

        // Suggestion Card or Badges for lists
        if (!isUser && message.proposedListName != null) {
            Spacer(modifier = Modifier.height(8.dp))
            when (message.listStatus) {
                ListStatus.PENDING -> {
                    Surface(
                        modifier = Modifier
                            .widthIn(max = 300.dp)
                            .padding(start = 8.dp),
                        shape = RoundedCornerShape(16.dp),
                        color = Color.White.copy(alpha = 0.05f),
                        border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text("📋", fontSize = 16.sp)
                                Text(
                                    text = "Create List?",
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = NotelPrimary
                                )
                            }
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "Create list \"${message.proposedListName}\" with items:",
                                fontSize = 14.sp,
                                color = NotelTextPrimary,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.height(6.dp))
                            Column(
                                verticalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                message.proposedListItems.forEach { item ->
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        Text("•", color = NotelTextSecondary, fontSize = 14.sp)
                                        Text(text = item, color = NotelTextSecondary, fontSize = 13.sp)
                                    }
                                }
                            }
                            Spacer(modifier = Modifier.height(12.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OutlinedButton(
                                    onClick = onDenyList,
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(12.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        contentColor = Color(0xFFFF5252)
                                    ),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFFF5252).copy(alpha = 0.4f))
                                ) {
                                    Text("Deny", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                                }

                                Button(
                                    onClick = onApproveList,
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(12.dp),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF00E676),
                                        contentColor = Color(0xFF080E1A)
                                    )
                                ) {
                                    Text("Approve", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
                ListStatus.APPROVED -> {
                    Row(
                        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "✓ List Created Successfully",
                            color = Color(0xFF00E676),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
                ListStatus.DENIED -> {
                    Row(
                        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = "✗ List Suggestion Dismissed",
                            color = Color(0xFFFF5252),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }
                else -> {}
            }
        }
    }
}

@Composable
private fun TypingIndicator() {
    val infiniteTransition = rememberInfiniteTransition(label = "typing")

    @Composable
    fun Dot(delayMillis: Int) {
        val alpha by infiniteTransition.animateFloat(
            initialValue = 0.2f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 600, delayMillis = delayMillis, easing = LinearEasing),
                repeatMode = RepeatMode.Reverse
            ),
            label = "dotAlpha"
        )
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(NotelTextSecondary.copy(alpha = alpha))
        )
    }

    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.height(22.dp)
    ) {
        Dot(0)
        Dot(150)
        Dot(300)
    }
}

private fun parseMarkdownToAnnotatedString(text: String): AnnotatedString {
    return buildAnnotatedString {
        var currentIndex = 0
        // Regex to match **bold** or *italic*
        val regex = Regex("\\*\\*(.*?)\\*\\*|\\*(.*?)\\*")
        
        regex.findAll(text).forEach { matchResult ->
            // Append text before the match
            append(text.substring(currentIndex, matchResult.range.first))
            
            if (matchResult.groups[1] != null) {
                // **bold**
                withStyle(style = SpanStyle(fontWeight = FontWeight.Bold)) {
                    append(matchResult.groups[1]!!.value)
                }
            } else if (matchResult.groups[2] != null) {
                // *italic*
                withStyle(style = SpanStyle(fontStyle = FontStyle.Italic)) {
                    append(matchResult.groups[2]!!.value)
                }
            }
            currentIndex = matchResult.range.last + 1
        }
        // Append remaining text
        if (currentIndex < text.length) {
            append(text.substring(currentIndex))
        }
    }
}
