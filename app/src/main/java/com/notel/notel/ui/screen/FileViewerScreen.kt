package com.notel.notel.ui.screen

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.AsyncImage
import com.notel.notel.ui.theme.*
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileViewerScreen(
    fileName: String,
    filePath: String,
    mimeType: String,
    extractedText: String? = null,
    onSaveEditedText: (String) -> Unit = {},
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val file = File(filePath)
    val scrollState = rememberScrollState()

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            fileName,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary,
                            fontSize = 15.sp,
                            maxLines = 1
                        )
                        if (!extractedText.isNullOrBlank()) {
                            Text(
                                "AI read · tap below to view or edit",
                                color = Color(0xFF4CAF50),
                                fontSize = 10.sp
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    IconButton(onClick = {
                        if (file.exists()) {
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                context,
                                "${context.packageName}.provider",
                                file
                            )
                            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                                type = mimeType
                                putExtra(android.content.Intent.EXTRA_STREAM, uri)
                                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            context.startActivity(android.content.Intent.createChooser(intent, "Share Document"))
                        }
                    }) {
                        Icon(Icons.Default.Share, "Share", tint = NotelPrimary)
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
                .background(NotelBackground)
                .verticalScroll(scrollState)
        ) {
            // ── File preview ──────────────────────────────────────────────
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.TopCenter
            ) {
                if (!file.exists()) {
                    Text(
                        "File not found or has been deleted.",
                        color = NotelTextSecondary,
                        modifier = Modifier.padding(16.dp)
                    )
                } else {
                    when {
                        mimeType.startsWith("image/") -> {
                            AsyncImage(
                                model = file,
                                contentDescription = fileName,
                                modifier = Modifier.fillMaxWidth().heightIn(min = 200.dp, max = 520.dp),
                                contentScale = ContentScale.Fit
                            )
                        }
                        mimeType == "application/pdf" -> {
                            PdfViewer(file)
                        }
                        mimeType == "text/plain" -> {
                            val rawText = remember(filePath) {
                                try { file.readText() } catch (e: Exception) { "Could not read file." }
                            }
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp)
                                    .background(NotelSurface, RoundedCornerShape(12.dp))
                                    .padding(16.dp)
                            ) {
                                Text(
                                    text = rawText,
                                    color = NotelTextSecondary,
                                    fontSize = 13.sp,
                                    lineHeight = 20.sp
                                )
                            }
                        }
                        else -> {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                modifier = Modifier.padding(32.dp)
                            ) {
                                Icon(
                                    Icons.Default.Share,
                                    null,
                                    Modifier.size(64.dp),
                                    tint = NotelTextSecondary
                                )
                                Spacer(Modifier.height(16.dp))
                                Text(
                                    "Preview not available for this file type.",
                                    color = NotelTextSecondary
                                )
                                Text(
                                    "Type: $mimeType",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // ── AI Extracted Content panel ─────────────────────────────────
            AiExtractionPanel(
                extractedText = extractedText,
                onSaveEditedText = onSaveEditedText
            )

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun AiExtractionPanel(
    extractedText: String?,
    onSaveEditedText: (String) -> Unit
) {
    var isExpanded by remember { mutableStateOf(true) }
    var showEditDialog by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(
            topStart = 20.dp, topEnd = 20.dp,
            bottomStart = 16.dp, bottomEnd = 16.dp
        ),
        color = NotelSurface,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
    ) {
        Column {
            // Header row — always visible
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { isExpanded = !isExpanded }
                    .padding(start = 16.dp, end = 8.dp, top = 14.dp, bottom = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(
                        Icons.Default.AutoAwesome,
                        contentDescription = null,
                        tint = NotelPrimary,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Column {
                        Text(
                            "AI Extracted Content",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 14.sp
                        )
                        Text(
                            when {
                                extractedText == null -> "Processing… check back shortly"
                                extractedText.isBlank() -> "No content could be extracted"
                                else -> "${extractedText.length} characters extracted"
                            },
                            color = if (extractedText != null && extractedText.isNotBlank())
                                Color(0xFF4CAF50) else NotelTextSecondary,
                            fontSize = 11.sp
                        )
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    // Edit button — only shown when there's text to edit
                    if (!extractedText.isNullOrBlank()) {
                        IconButton(
                            onClick = { showEditDialog = true },
                            modifier = Modifier.size(36.dp)
                        ) {
                            Icon(
                                Icons.Default.Edit,
                                contentDescription = "Edit extracted text",
                                tint = NotelPrimary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                    IconButton(
                        onClick = { isExpanded = !isExpanded },
                        modifier = Modifier.size(36.dp)
                    ) {
                        Icon(
                            if (isExpanded) Icons.Default.KeyboardArrowUp
                            else Icons.Default.KeyboardArrowDown,
                            contentDescription = "Toggle",
                            tint = NotelTextSecondary
                        )
                    }
                }
            }

            HorizontalDivider(
                color = NotelSurfaceHigh,
                thickness = 0.5.dp,
                modifier = Modifier.padding(horizontal = 16.dp)
            )

            // Collapsible content
            AnimatedVisibility(
                visible = isExpanded,
                enter = expandVertically(),
                exit = shrinkVertically()
            ) {
                when {
                    extractedText == null -> {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(20.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                color = NotelPrimary,
                                strokeWidth = 2.dp
                            )
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text(
                                    "Gemini is reading this file…",
                                    color = NotelTextPrimary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    "This happens once. Pull down to refresh after a moment.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                        }
                    }
                    extractedText.isBlank() -> {
                        Text(
                            "No readable content was found in this file.",
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(20.dp)
                        )
                    }
                    else -> {
                        FormattedExtractedText(
                            text = extractedText,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            }
        }
    }

    // ── Full-screen edit dialog ────────────────────────────────────────────
    if (showEditDialog && extractedText != null) {
        EditExtractedTextDialog(
            initialText = extractedText,
            onDismiss = { showEditDialog = false },
            onSave = { edited ->
                onSaveEditedText(edited)
                showEditDialog = false
            }
        )
    }
}

@Composable
private fun EditExtractedTextDialog(
    initialText: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit
) {
    var editText by remember { mutableStateOf(initialText) }
    val hasChanges = editText != initialText

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 24.dp)
                .imePadding()
                .navigationBarsPadding(),
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            color = NotelBackground
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // Dialog top bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, "Cancel", tint = NotelTextSecondary)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            "Edit AI Extraction",
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                        Text(
                            "Correct anything Gemini got wrong",
                            color = NotelTextSecondary,
                            fontSize = 11.sp
                        )
                    }
                    IconButton(
                        onClick = { onSave(editText) },
                        enabled = hasChanges && editText.isNotBlank()
                    ) {
                        Icon(
                            Icons.Default.Check,
                            "Save",
                            tint = if (hasChanges && editText.isNotBlank())
                                NotelPrimary else NotelTextSecondary.copy(alpha = 0.4f)
                        )
                    }
                }

                HorizontalDivider(color = NotelSurfaceHigh, thickness = 0.5.dp)

                // Info strip
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(NotelSurface)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Default.AutoAwesome,
                        null,
                        tint = NotelPrimary,
                        modifier = Modifier.size(14.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Your edits are saved locally and used in all future AI requests.",
                        color = NotelTextSecondary,
                        fontSize = 11.sp,
                        lineHeight = 16.sp
                    )
                }

                HorizontalDivider(color = NotelSurfaceHigh, thickness = 0.5.dp)

                // Editable text field
                OutlinedTextField(
                    value = editText,
                    onValueChange = { editText = it },
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(16.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary,
                        unfocusedBorderColor = NotelSurfaceHigh,
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary,
                        focusedContainerColor = NotelSurface,
                        unfocusedContainerColor = NotelSurface
                    ),
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 13.sp,
                        lineHeight = 20.sp,
                        color = NotelTextPrimary
                    ),
                    label = { Text("Extracted text", color = NotelTextSecondary, fontSize = 12.sp) },
                    shape = RoundedCornerShape(12.dp)
                )
            }
        }
    }
}

/**
 * Renders extracted text in a readable, structured format.
 */
@Composable
private fun FormattedExtractedText(text: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val lines = text.lines()
        
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val trimmed = line.trim()
            
            // Check for Markdown table block
            if (trimmed.startsWith("|") && trimmed.endsWith("|")) {
                val tableLines = mutableListOf<String>()
                while (i < lines.size && lines[i].trim().startsWith("|")) {
                    tableLines.add(lines[i].trim())
                    i++
                }
                
                // Parse rows
                val rows = tableLines.filter { !it.contains("---") }.map { rowRaw ->
                    rowRaw.split("|").drop(1).dropLast(1).map { it.trim() }
                }
                
                if (rows.isNotEmpty()) {
                    val numCols = rows.maxOfOrNull { it.size } ?: 0
                    val colWidths = IntArray(numCols) { colIndex ->
                        val maxChars = rows.maxOfOrNull { row ->
                            row.getOrNull(colIndex)?.length ?: 0
                        } ?: 0
                        (maxChars * 11).coerceIn(120, 380)
                    }

                    Card(
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(containerColor = NotelSurface.copy(alpha = 0.8f)),
                        border = androidx.compose.foundation.BorderStroke(1.dp, NotelSurfaceHigh.copy(alpha = 0.5f)),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 8.dp)
                    ) {
                        val hScroll = rememberScrollState()
                        Column(
                            modifier = Modifier
                                .horizontalScroll(hScroll)
                                .padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            rows.forEachIndexed { rowIndex, cells ->
                                val isHeader = rowIndex == 0
                                Row(
                                    modifier = Modifier
                                        .background(
                                            if (isHeader) NotelPrimary.copy(alpha = 0.15f)
                                            else if (rowIndex % 2 == 0) NotelSurfaceHigh.copy(alpha = 0.3f)
                                            else Color.Transparent,
                                            shape = RoundedCornerShape(6.dp)
                                        )
                                        .padding(horizontal = 10.dp, vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    cells.forEachIndexed { colIndex, cell ->
                                        val colWidth = colWidths.getOrNull(colIndex) ?: 130
                                        Box(
                                            modifier = Modifier
                                                .width(colWidth.dp)
                                                .padding(end = 12.dp)
                                        ) {
                                            val shouldCenter = colIndex > 0
                                            Text(
                                                text = cell,
                                                color = if (isHeader) NotelPrimary else NotelTextPrimary,
                                                fontSize = 12.sp,
                                                fontWeight = if (isHeader) FontWeight.Bold else FontWeight.Normal,
                                                lineHeight = 16.sp,
                                                textAlign = if (shouldCenter) androidx.compose.ui.text.style.TextAlign.Center else androidx.compose.ui.text.style.TextAlign.Start,
                                                modifier = Modifier.fillMaxWidth(),
                                                maxLines = 2,
                                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                continue
            }
            
            // Check for key-value pair blocks (like laboratory results, medical vital signs, patient metrics)
            val isKeyValueLine = { l: String ->
                val colonIndex = l.indexOf(':')
                colonIndex > 0 && colonIndex < 35 && l.substring(0, colonIndex).all { it.isLetterOrDigit() || it.isWhitespace() || it == '_' || it == '-' } && l.substring(colonIndex + 1).trim().isNotBlank()
            }
            
            if (isKeyValueLine(trimmed)) {
                val kvPairs = mutableListOf<Pair<String, String>>()
                while (i < lines.size && isKeyValueLine(lines[i].trim())) {
                    val currentTrimmed = lines[i].trim()
                    val colonIndex = currentTrimmed.indexOf(':')
                    val key = currentTrimmed.substring(0, colonIndex).trim()
                    val value = currentTrimmed.substring(colonIndex + 1).trim()
                    kvPairs.add(key to value)
                    i++
                }
                
                if (kvPairs.isNotEmpty()) {
                    Card(
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(containerColor = NotelSurface.copy(alpha = 0.8f)),
                        border = androidx.compose.foundation.BorderStroke(1.dp, NotelSurfaceHigh.copy(alpha = 0.5f)),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp)
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            kvPairs.forEach { (key, valStr) ->
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.Top
                                ) {
                                    Text(
                                        text = key,
                                        color = NotelTextSecondary,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.Medium,
                                        modifier = Modifier.weight(0.4f)
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Text(
                                        text = valStr,
                                        color = NotelPrimary,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        modifier = Modifier.weight(0.6f),
                                        textAlign = androidx.compose.ui.text.style.TextAlign.End
                                    )
                                }
                            }
                        }
                    }
                }
                continue
            }
            
            when {
                trimmed.isBlank() -> {
                    Spacer(Modifier.height(6.dp))
                }
                // Markdown header: #, ##, ###
                trimmed.startsWith("#") -> {
                    val level = trimmed.takeWhile { it == '#' }.length
                    val headerText = trimmed.removePrefix("#".repeat(level)).trim()
                    Spacer(Modifier.height(14.dp))
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = headerText,
                            color = NotelPrimary,
                            fontSize = when(level) {
                                1 -> 18.sp
                                2 -> 16.sp
                                else -> 14.sp
                            },
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.5.sp
                        )
                        HorizontalDivider(
                            color = NotelPrimary.copy(alpha = 0.3f),
                            thickness = 1.dp,
                            modifier = Modifier.padding(top = 4.dp, bottom = 6.dp)
                        )
                    }
                }
                // Section header (compatibility: all-caps short line)
                trimmed.length < 60 && trimmed == trimmed.uppercase() && trimmed.any { it.isLetter() } -> {
                    Spacer(Modifier.height(14.dp))
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = trimmed,
                            color = NotelPrimary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.8.sp
                        )
                        HorizontalDivider(
                            color = NotelPrimary.copy(alpha = 0.2f),
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(top = 2.dp, bottom = 4.dp)
                        )
                    }
                }
                // Sub-header: ends with ":"
                trimmed.endsWith(":") && trimmed.length < 80 -> {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = trimmed,
                        color = NotelTextPrimary,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                // Bullet point
                trimmed.startsWith("-") || trimmed.startsWith("•") || trimmed.startsWith("*") -> {
                    Row(
                        modifier = Modifier.padding(start = 8.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Text(
                            "•",
                            color = NotelPrimary,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(top = 1.dp, end = 8.dp)
                        )
                        Text(
                            text = trimmed
                                .removePrefix("-")
                                .removePrefix("•")
                                .removePrefix("*")
                                .trim(),
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            lineHeight = 19.sp
                        )
                    }
                }
                // Numbered list
                trimmed.length > 2 && trimmed[0].isDigit() &&
                        (trimmed.getOrNull(1) == '.' || trimmed.getOrNull(2) == '.') -> {
                    Row(
                        modifier = Modifier.padding(start = 4.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Text(
                            trimmed.substringBefore(".") + ".",
                            color = NotelPrimary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .width(24.dp)
                                .padding(top = 1.dp)
                        )
                        Text(
                            text = trimmed.substringAfter(".").trim(),
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            lineHeight = 19.sp
                        )
                    }
                }
                // Normal body text
                else -> {
                    Text(
                        text = trimmed,
                        color = NotelTextPrimary,
                        fontSize = 13.sp,
                        lineHeight = 20.sp
                    )
                }
            }
            i++
        }
    }
}

@Composable
fun PdfViewer(file: File) {
    val bitmaps = remember(file) { mutableStateListOf<Bitmap>() }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(file) {
        try {
            val fileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(fileDescriptor)
            val pageCount = renderer.pageCount

            for (i in 0 until pageCount) {
                val page = renderer.openPage(i)
                val bitmap = Bitmap.createBitmap(
                    page.width * 2,
                    page.height * 2,
                    Bitmap.Config.ARGB_8888
                )
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                bitmaps.add(bitmap)
                page.close()
            }
            renderer.close()
            fileDescriptor.close()
        } catch (e: Exception) {
            error = e.message ?: "Failed to render PDF"
        }
    }

    if (error != null) {
        Text(
            "Error: $error",
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(16.dp)
        )
    } else if (bitmaps.isEmpty()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(200.dp),
            contentAlignment = Alignment.Center
        ) {
            CircularProgressIndicator(color = NotelPrimary)
        }
    } else {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            bitmaps.forEach { bitmap ->
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "PDF Page",
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White, RoundedCornerShape(8.dp))
                        .padding(2.dp),
                    contentScale = ContentScale.FillWidth
                )
            }
        }
    }
}
