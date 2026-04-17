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
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
                                "AI read · tap below to view",
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
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 200.dp, max = 520.dp),
                contentAlignment = Alignment.Center
            ) {
                if (!file.exists()) {
                    Text("File not found or has been deleted.", color = NotelTextSecondary, modifier = Modifier.padding(16.dp))
                } else {
                    when {
                        mimeType.startsWith("image/") -> {
                            AsyncImage(
                                model = file,
                                contentDescription = fileName,
                                modifier = Modifier.fillMaxSize(),
                                contentScale = ContentScale.Fit
                            )
                        }
                        mimeType == "application/pdf" -> {
                            PdfViewer(file)
                        }
                        mimeType == "text/plain" -> {
                            // For text files show raw content inline since we have formatted extraction below
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
                                Icon(Icons.Default.Share, null, Modifier.size(64.dp), tint = NotelTextSecondary)
                                Spacer(Modifier.height(16.dp))
                                Text("Preview not available for this file type.", color = NotelTextSecondary)
                                Text("Type: $mimeType", color = NotelTextSecondary, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // ── AI Extracted Content panel ─────────────────────────────────
            AiExtractionPanel(extractedText = extractedText)

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun AiExtractionPanel(extractedText: String?) {
    var isExpanded by remember { mutableStateOf(true) }

    Surface(
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp, bottomStart = 16.dp, bottomEnd = 16.dp),
        color = NotelSurface,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
    ) {
        Column {
            // Header row — always visible, toggles expansion
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { isExpanded = !isExpanded }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
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
                Icon(
                    if (isExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                    contentDescription = "Toggle",
                    tint = NotelTextSecondary
                )
            }

            // Divider
            HorizontalDivider(
                color = NotelSurfaceHigh,
                thickness = 0.5.dp,
                modifier = Modifier.padding(horizontal = 16.dp)
            )

            // Content
            AnimatedVisibility(
                visible = isExpanded,
                enter = expandVertically(),
                exit = shrinkVertically()
            ) {
                when {
                    extractedText == null -> {
                        // Still processing
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
}

/**
 * Renders extracted text in a readable, structured format.
 * - Lines starting with ALL CAPS or ending in ":" are treated as section headers
 * - Bullet-like lines (starting with -, •, *) are indented
 * - Blank lines become visual spacers
 * - Everything else is body text
 */
@Composable
private fun FormattedExtractedText(text: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        val lines = text.lines()
        lines.forEach { line ->
            val trimmed = line.trim()
            when {
                trimmed.isBlank() -> {
                    Spacer(Modifier.height(6.dp))
                }
                // Section header: all-caps line, or ends with colon, or short line in caps
                trimmed.length < 60 && (trimmed == trimmed.uppercase() && trimmed.any { it.isLetter() }) -> {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = trimmed,
                        color = NotelPrimary,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.8.sp
                    )
                    HorizontalDivider(
                        color = NotelPrimary.copy(alpha = 0.2f),
                        thickness = 0.5.dp,
                        modifier = Modifier.padding(top = 2.dp, bottom = 4.dp)
                    )
                }
                // Sub-header: line ending in ":"
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
                            text = trimmed.removePrefix("-").removePrefix("•").removePrefix("*").trim(),
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            lineHeight = 19.sp
                        )
                    }
                }
                // Numbered list (1. 2. etc.)
                trimmed.length > 2 && trimmed[0].isDigit() && (trimmed.getOrNull(1) == '.' || trimmed.getOrNull(2) == '.') -> {
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
                val bitmap = Bitmap.createBitmap(page.width * 2, page.height * 2, Bitmap.Config.ARGB_8888)
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
        Text("Error: $error", color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
    } else if (bitmaps.isEmpty()) {
        Box(modifier = Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
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
