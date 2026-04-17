package com.notel.notel.ui.screen

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
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
import coil.compose.AsyncImage
import com.notel.notel.ui.theme.*
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileViewerScreen(
    fileName: String,
    filePath: String,
    mimeType: String,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val file = File(filePath)
    
    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text(fileName, fontWeight = FontWeight.Bold, color = NotelTextPrimary, fontSize = 16.sp, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    IconButton(onClick = {
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
                    }) {
                        Icon(Icons.Default.Share, "Share", tint = NotelPrimary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(NotelBackground),
            contentAlignment = Alignment.Center
        ) {
            if (!file.exists()) {
                Text("File not found or has been deleted.", color = NotelTextSecondary)
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
                    else -> {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(androidx.compose.material.icons.Icons.Default.InsertDriveFile, null, Modifier.size(64.dp), tint = NotelTextSecondary)
                            Spacer(Modifier.height(16.dp))
                            Text("Preview not available for this file type.", color = NotelTextSecondary)
                            Text("Mime: $mimeType", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
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
        CircularProgressIndicator(color = NotelPrimary)
    } else {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .horizontalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            bitmaps.forEach { bitmap ->
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "PDF Page",
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White, RoundedCornerShape(4.dp))
                        .padding(2.dp),
                    contentScale = ContentScale.FillWidth
                )
            }
        }
    }
}
