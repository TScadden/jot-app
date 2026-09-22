package com.notel.notel.util

import android.content.Context
import android.graphics.*
import android.graphics.pdf.PdfDocument
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.local.entity.AiInsight
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.Serializable
import kotlinx.coroutines.flow.first
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*
import android.provider.MediaStore
import android.content.ContentValues
import android.os.Environment
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
private data class BiometricMetricsJson(
    val sleepMins: Int? = null,
    val deepSleepMins: Int? = null,
    val avgHr: Int? = null,
    val hrv: Double? = null,
    val calories: Int? = null,
    val spikes: Int? = null
)

private data class BiometricRecord(
    val date: String,
    val dateStr: String,
    val rawDate: Date,
    var sleepMins: Int = 0,
    var deepSleepMins: Int = 0,
    var avgHr: Int = 0,
    var hrv: Double = 0.0,
    var calories: Int = 0,
    var spikes: Int = 0,
    var jots: Int = 0
)

@Singleton
class ReportGenerator @Inject constructor(
    @ApplicationContext private val context: Context,
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences
) {

    /**
     * Generates a professional health report as a PDF.
     * Consolidates logs and asks Gemini for a natural language summary first.
     */
    @Inject lateinit var dataCollector: com.notel.notel.data.repository.ClinicalReportDataCollector

    /**
     * Backward-compatible overload for generateReport
     */
    suspend fun generateReport(
        allEntries: List<LogEntry>,
        categories: List<com.notel.notel.data.local.entity.Category>,
        last30DaysOnly: Boolean = false
    ): File? {
        val snapshot = dataCollector.collectReportData(categories, last30DaysOnly)
        val summaryResult = logRepository.getMedicalReportSummary(categories, last30DaysOnly = last30DaysOnly)
        val summary = summaryResult.getOrNull()
        return generateReport(snapshot, summary, isRawFallback = (summary == null))
    }

    /**
     * Generates a professional clinical health report as a PDF using an immutable snapshot.
     */
    suspend fun generateReport(
        snapshot: com.notel.notel.data.model.ClinicalReportData,
        aiSummary: String? = null,
        isRawFallback: Boolean = false
    ): File? {
        if (!snapshot.hasAnyData) {
            android.util.Log.w("ReportGenerator", "Snapshot contains no data. Refusing to generate empty report PDF.")
            return null
        }

        val effectiveSummary = when {
            !aiSummary.isNullOrBlank() -> aiSummary
            isRawFallback -> "[SECTION] RAW CLINICAL LOG SUMMARY\n[BOLD]Notice:[BOLD] AI summary generation was unavailable or non-responsive. The following report compiles raw longitudinal patient entries and measured biometrics snapshot directly.\n\n[SECTION] PATIENT OVERVIEW\n• Total Recorded Entries: ${snapshot.logEntries.size}\n• Active Conditions: ${if (snapshot.conditions.isNotEmpty()) snapshot.conditions.joinToString(", ") else "None listed"}\n• Active Medications: ${if (snapshot.medications.isNotEmpty()) snapshot.medications.joinToString(", ") { "${it.name} ${it.dose}" } else "None listed"}"
            else -> "Clinical summary unavailable. Analysis based on raw snapshot data."
        }

        val pdfDocument = PdfDocument()
        val titlePaint = Paint().apply {
            color = Color.rgb(33, 33, 33)
            textSize = 22f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val sectionPaint = Paint().apply {
            color = Color.rgb(0, 102, 204)
            textSize = 16f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val bodyPaint = Paint().apply {
            color = Color.rgb(66, 66, 66)
            textSize = 11f
            isAntiAlias = true
        }
        val boldBodyPaint = Paint().apply {
            color = Color.BLACK
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val italicBodyPaint = Paint().apply {
            color = Color.BLACK
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC)
            isAntiAlias = true
        }
        val linePaint = Paint().apply {
            color = Color.LTGRAY
            strokeWidth = 1f
            isAntiAlias = true
        }
        val metaPaint = Paint().apply {
            color = Color.GRAY
            textSize = 9f
            isAntiAlias = true
        }

        val pageInfo = PdfDocument.PageInfo.Builder(595, 842, 1).create() // A4
        var page = pdfDocument.startPage(pageInfo)
        var canvas = page.canvas

        var y = 50f
        val margin = 45f
        val contentWidth = 505f

        // Header
        canvas.drawText("Tabs — Clinical Audit Report", margin, y, titlePaint)
        y += 12f
        canvas.drawLine(margin, y, margin + contentWidth, y, linePaint)
        y += 20f
        
        val rangeLabel = if (snapshot.range.type == com.notel.notel.data.model.ClinicalReportRangeType.LAST_30_DAYS) "30-Day Audit" else "Full Audit"
        val genTimeStr = SimpleDateFormat("MMM dd, yyyy - hh:mm a", Locale.getDefault()).format(Date(snapshot.generationTimestamp))
        canvas.drawText("Report Range: $rangeLabel (${snapshot.range.durationDays} Days) • Generated: $genTimeStr", margin, y, metaPaint)
        y += 16f

        if (isRawFallback) {
            val alertPaint = Paint().apply {
                color = Color.rgb(200, 50, 50)
                textSize = 10f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                isAntiAlias = true
            }
            canvas.drawText("⚠️ RAW DATA REPORT — AI ANALYSIS UNAVAILABLE AT GENERATION TIME", margin, y, alertPaint)
            y += 18f
        }

        // Profile & Summary Text Rendering
        val rawLines = effectiveSummary.split("\n")
        rawLines.forEach { line ->
            if (y > 780f) {
                pdfDocument.finishPage(page)
                page = pdfDocument.startPage(pageInfo)
                canvas = page.canvas
                y = 50f
            }

            when {
                line.contains("[SECTION]") -> {
                    y += 12f
                    val cleanSection = line.replace("[SECTION]", "").replace("[BOLD]", "").replace("*", "").replace("#", "").trim()
                    val wrappedSections = wrapText(cleanSection, contentWidth, sectionPaint)
                    wrappedSections.forEach { sectionPart ->
                        if (y > 780f) {
                            pdfDocument.finishPage(page)
                            page = pdfDocument.startPage(pageInfo)
                            canvas = page.canvas
                            y = 50f
                        }
                        canvas.drawText(sectionPart, margin, y, sectionPaint)
                        y += 20f
                    }
                    canvas.drawLine(margin, y - 6f, margin + 60f, y - 6f, Paint(sectionPaint).apply { strokeWidth = 2f })
                    y += 16f
                }
                line.contains("[BULLET]") -> {
                    val cleanBullet = line.replace("[BULLET]", "").replace("*", "").trim().removePrefix("-").trim()
                    y = drawFormattedLine("• $cleanBullet", margin + 15f, y, contentWidth - 15f, canvas, bodyPaint, boldBodyPaint, italicBodyPaint) {
                        pdfDocument.finishPage(page)
                        page = pdfDocument.startPage(pageInfo)
                        canvas = page.canvas
                        canvas
                    }
                    y += 6f
                }
                else -> {
                    y = drawFormattedLine(line, margin, y, contentWidth, canvas, bodyPaint, boldBodyPaint, italicBodyPaint) {
                        pdfDocument.finishPage(page)
                        page = pdfDocument.startPage(pageInfo)
                        canvas = page.canvas
                        canvas
                    }
                    y += 6f
                }
            }
        }

        // Section: Data Availability & Freshness Summary
        y += 20f
        if (y > 720f) {
            pdfDocument.finishPage(page)
            page = pdfDocument.startPage(pageInfo)
            canvas = page.canvas
            y = 50f
        }

        canvas.drawText("Data Availability & Source Freshness", margin, y, sectionPaint)
        y += 18f
        canvas.drawLine(margin, y - 6f, margin + contentWidth, y - 6f, linePaint)
        y += 12f

        snapshot.sectionMetadata.forEach { (key, meta) ->
            if (y > 780f) {
                pdfDocument.finishPage(page)
                page = pdfDocument.startPage(pageInfo)
                canvas = page.canvas
                y = 50f
            }
            val statusText = when (meta.status) {
                com.notel.notel.data.model.DataSourceStatus.SUCCESS -> "Available (${meta.recordCount} records)"
                com.notel.notel.data.model.DataSourceStatus.NO_DATA -> "No records found in range"
                com.notel.notel.data.model.DataSourceStatus.PERMISSION_DENIED -> "Permission missing"
                com.notel.notel.data.model.DataSourceStatus.UNAVAILABLE -> "Health Connect unavailable"
                com.notel.notel.data.model.DataSourceStatus.TIMED_OUT -> "Timed out"
                com.notel.notel.data.model.DataSourceStatus.ERROR -> "Error: ${meta.message ?: "Unknown"}"
            }
            canvas.drawText("• ${key.replaceFirstChar { it.uppercase() }}: $statusText", margin + 10f, y, bodyPaint)
            y += 15f
        }

        pdfDocument.finishPage(page)

        // ── 2. Render Biometrics Charts Pages ───────────────────────────────
        try {
            val sdfDate = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            val sdfOut = SimpleDateFormat("MMM d", Locale.US)
            val formatKeyToLabel = { key: String ->
                try {
                    val d = sdfDate.parse(key)
                    if (d != null) sdfOut.format(d) else key
                } catch (e: Exception) { key }
            }

            // Build chart series directly from snapshot
            val sleepData = snapshot.sleepSeries.filter { it.second > 0 }.map { formatKeyToLabel(it.first) to (it.second / 60f) }
            val hrData = snapshot.heartRateSeries.filter { it.second > 0 }.map { formatKeyToLabel(it.first) to it.second.toFloat() }
            val hrvData = snapshot.hrvSeries.filter { it.second > 0.0 }.map { formatKeyToLabel(it.first) to it.second.toFloat() }
            val caloriesData = snapshot.caloriesSeries.filter { it.second > 0 }.map { formatKeyToLabel(it.first) to it.second.toFloat() }
            val spikesData = snapshot.heartRateSpikes.filter { it.spikeCount > 0 }.map { formatKeyToLabel(it.date) to it.spikeCount.toFloat() }
            
            val jotsByDate = snapshot.logEntries.groupBy { sdfDate.format(Date(it.timestamp)) }
            val jotsData = jotsByDate.map { formatKeyToLabel(it.key) to it.value.size.toFloat() }

            val bpData = snapshot.bloodPressureSeries.map { formatKeyToLabel(sdfDate.format(Date(it.timeEpochMs))) to it.systolic.toFloat() }

            // Page 2: Charts (1 to 4)
            val chartPage1 = pdfDocument.startPage(pageInfo)
            val chartCanvas1 = chartPage1.canvas

            chartCanvas1.drawText("Longitudinal Health Metrics & Charts", margin, 50f, titlePaint)
            chartCanvas1.drawLine(margin, 62f, margin + contentWidth, 62f, linePaint)

            drawLineChart(chartCanvas1, "Sleep Duration", sleepData, "#42A5F5", margin, 85f, contentWidth, 140f, "h")
            drawLineChart(chartCanvas1, "Avg Heart Rate", hrData, "#FF5E62", margin, 255f, contentWidth, 140f, " bpm")
            drawLineChart(chartCanvas1, "HRV (RMSSD)", hrvData, "#B388FF", margin, 425f, contentWidth, 140f, " ms")
            drawLineChart(chartCanvas1, "Systolic Blood Pressure", bpData, "#E53935", margin, 595f, contentWidth, 140f, " mmHg")

            pdfDocument.finishPage(chartPage1)

            // Page 3: Charts (5 to 7) + Disclaimer
            val chartPage2 = pdfDocument.startPage(pageInfo)
            val chartCanvas2 = chartPage2.canvas

            chartCanvas2.drawText("Longitudinal Health Metrics & Charts (Cont.)", margin, 50f, titlePaint)
            chartCanvas2.drawLine(margin, 62f, margin + contentWidth, 62f, linePaint)

            drawLineChart(chartCanvas2, "Calories Burned", caloriesData, "#FFA726", margin, 85f, contentWidth, 140f, " kcal")
            drawLineChart(chartCanvas2, "HR Spikes (>=100 BPM)", spikesData, "#E040FB", margin, 255f, contentWidth, 140f, "")
            drawLineChart(chartCanvas2, "Recorded Patient Notes", jotsData, "#26A69A", margin, 425f, contentWidth, 140f, "")

            chartCanvas2.drawLine(margin, 650f, margin + contentWidth, 650f, linePaint)
            chartCanvas2.drawText(
                "Disclaimer: This report is generated by AI based on personal logs and should be reviewed by a medical professional.",
                margin,
                675f,
                metaPaint
            )

            pdfDocument.finishPage(chartPage2)
        } catch (e: Exception) {
            android.util.Log.e("ReportGenerator", "Failed rendering biometrics chart pages: ${e.message}", e)
        }

        val fileName = "Tabs_Report_${SimpleDateFormat("MMM_dd_yyyy", Locale.getDefault()).format(Date())}.pdf"
        val cacheFile = File(context.cacheDir, fileName)
        try {
            pdfDocument.writeTo(FileOutputStream(cacheFile))
            // Separate Downloads save failure from cache returning
            try {
                saveToDownloads(cacheFile, fileName)
            } catch (e: Exception) {
                android.util.Log.w("ReportGenerator", "Could not copy PDF to Downloads: ${e.message}")
            }
        } catch (e: Exception) {
            android.util.Log.e("ReportGenerator", "Failed writing PDF cache file: ${e.message}", e)
            return null
        } finally {
            pdfDocument.close()
        }

        return cacheFile
    }

    private fun drawLineChart(
        canvas: Canvas,
        title: String,
        data: List<Pair<String, Float>>,
        colorHex: String,
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        unit: String
    ) {
        val paintColor = Color.parseColor(colorHex)
        
        // 1. Draw Title
        val titlePaint = Paint().apply {
            color = Color.rgb(33, 33, 33)
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        canvas.drawText(title, x, y + 15f, titlePaint)

        val chartX = x + 35f
        val chartY = y + 25f
        val chartW = width - 45f
        val chartH = height - 40f

        // If data is empty or has < 2 points, draw "No data available" message
        if (data.size < 2) {
            val noDataPaint = Paint().apply {
                color = Color.GRAY
                textSize = 9f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC)
                isAntiAlias = true
            }
            canvas.drawText("Not enough data to display chart", chartX + 20f, chartY + chartH / 2f, noDataPaint)
            return
        }

        val vals = data.map { it.second }
        val maxVal = vals.maxOrNull() ?: 0f
        val minVal = vals.minOrNull() ?: 0f
        
        val minY = if (title.contains("Heart Rate") || title.contains("HRV")) {
            (minVal - 5f).coerceAtLeast(0f)
        } else {
            0f
        }
        val maxY = (maxVal + 5f).coerceAtLeast(minY + 1f)
        val yRange = maxY - minY

        val gridPaint = Paint().apply {
            color = Color.rgb(235, 235, 235)
            strokeWidth = 1f
            style = Paint.Style.STROKE
        }
        val labelPaint = Paint().apply {
            color = Color.GRAY
            textSize = 8f
            isAntiAlias = true
        }

        // Draw 3 horizontal grid lines & labels
        for (i in 0..2) {
            val ratio = i / 2f
            val gy = chartY + chartH * (1f - ratio)
            canvas.drawLine(chartX, gy, chartX + chartW, gy, gridPaint)
            
            val valLabel = String.format(Locale.US, "%.0f", minY + ratio * yRange) + unit
            canvas.drawText(valLabel, x, gy + 3f, labelPaint)
        }

        // Calculate points
        val points = mutableListOf<PointF>()
        for (i in data.indices) {
            val ratioX = if (data.size > 1) i.toFloat() / (data.size - 1) else 0f
            val px = chartX + ratioX * chartW
            val py = chartY + chartH * (1f - (data[i].second - minY) / yRange)
            points.add(PointF(px, py))
        }

        // Draw Area under the line (Gradient/Fill)
        val fillPath = Path()
        fillPath.moveTo(points[0].x, chartY + chartH)
        for (p in points) {
            fillPath.lineTo(p.x, p.y)
        }
        fillPath.lineTo(points.last().x, chartY + chartH)
        fillPath.close()

        val fillPaint = Paint().apply {
            color = paintColor
            alpha = 25
            style = Paint.Style.FILL
            isAntiAlias = true
        }
        canvas.drawPath(fillPath, fillPaint)

        // Draw Line
        val linePaint = Paint().apply {
            color = paintColor
            strokeWidth = 1.5f
            style = Paint.Style.STROKE
            isAntiAlias = true
        }
        val path = Path()
        path.moveTo(points[0].x, points[0].y)
        for (i in 1 until points.size) {
            path.lineTo(points[i].x, points[i].y)
        }
        canvas.drawPath(path, linePaint)

        // Draw Circles at data points
        val pointPaint = Paint().apply {
            color = paintColor
            style = Paint.Style.FILL
            isAntiAlias = true
        }
        val pointBorderPaint = Paint().apply {
            color = Color.WHITE
            style = Paint.Style.FILL
            isAntiAlias = true
        }
        
        if (data.size <= 42) {
            for (p in points) {
                canvas.drawCircle(p.x, p.y, 2.5f, pointBorderPaint)
                canvas.drawCircle(p.x, p.y, 1.5f, pointPaint)
            }
        }

        // Draw X-axis Date Labels (max 6 labels)
        val xLabelPaint = Paint().apply {
            color = Color.GRAY
            textSize = 7f
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
        val step = (data.size / 5).coerceAtLeast(1)
        for (i in data.indices step step) {
            val p = points[i]
            canvas.drawText(data[i].first, p.x, chartY + chartH + 12f, xLabelPaint)
        }
        if ((data.size - 1) % step != 0) {
            val p = points.last()
            canvas.drawText(data.last().first, p.x, chartY + chartH + 12f, xLabelPaint)
        }
    }

    private fun drawFormattedLine(
        text: String, 
        x: Float, 
        currentY: Float, 
        width: Float, 
        canvas: Canvas, 
        paint: Paint, 
        boldPaint: Paint,
        italicPaint: Paint,
        onNewPage: () -> Canvas
    ): Float {
        var y = currentY
        val lines = wrapText(text, width, paint)
        
        var isBold = false
        var isItalic = false
        var activeCanvas = canvas

        lines.forEach { line ->
            if (y > 780f) {
                activeCanvas = onNewPage()
                y = 60f
            }
            var currentX = x
            // Regex to match markers or text
            val regex = "\\[BOLD\\]|\\[ITALIC\\]".toRegex()
            var lastMatchEnd = 0
            
            // We need to process the line and update states
            regex.findAll(line).forEach { match ->
                // Draw text before marker
                val segment = line.substring(lastMatchEnd, match.range.first)
                if (segment.isNotEmpty()) {
                    val p = when {
                        isBold -> boldPaint
                        isItalic -> italicPaint
                        else -> paint
                    }
                    activeCanvas.drawText(segment, currentX, y, p)
                    currentX += p.measureText(segment)
                }
                
                // Toggle state
                if (match.value == "[BOLD]") isBold = !isBold
                if (match.value == "[ITALIC]") isItalic = !isItalic
                
                lastMatchEnd = match.range.last + 1
            }
            
            // Draw remaining text
            val remaining = line.substring(lastMatchEnd)
            if (remaining.isNotEmpty()) {
                val p = when {
                    isBold -> boldPaint
                    isItalic -> italicPaint
                    else -> paint
                }
                activeCanvas.drawText(remaining, currentX, y, p)
            }
            
            y += 18f
        }
        return y
    }

    /**
     * Permanent storage in Downloads folder via MediaStore
     */
    private fun saveToDownloads(file: File, fileName: String) {
        try {
            val resolver = context.contentResolver
            val contentValues = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS)
            }

            val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
            uri?.let {
                resolver.openOutputStream(it)?.use { outputStream ->
                    file.inputStream().use { inputStream ->
                        inputStream.copyTo(outputStream)
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun wrapText(text: String, width: Float, paint: Paint): List<String> {
        val words = text.split(" ")
        val lines = mutableListOf<String>()
        var currentLine = StringBuilder()

        for (word in words) {
            val testLine = if (currentLine.isEmpty()) word else "${currentLine} $word"
            val widthWithWord = paint.measureText(testLine)
            
            if (widthWithWord <= width) {
                currentLine.append(if (currentLine.isEmpty()) word else " $word")
            } else {
                // If the word itself is too long for the page, we must break it
                if (paint.measureText(word) > width) {
                    if (currentLine.isNotEmpty()) {
                        lines.add(currentLine.toString())
                        currentLine = StringBuilder()
                    }
                    
                    var remainingWord = word
                    while (paint.measureText(remainingWord) > width) {
                        var subCount = paint.breakText(remainingWord, true, width, null)
                        lines.add(remainingWord.substring(0, subCount))
                        remainingWord = remainingWord.substring(subCount)
                    }
                    currentLine = StringBuilder(remainingWord)
                } else {
                    lines.add(currentLine.toString())
                    currentLine = StringBuilder(word)
                }
            }
        }
        if (currentLine.isNotEmpty()) lines.add(currentLine.toString())
        return lines
    }

    /**
     * Generates an AI Biometric Graph Analysis Report as a styled PDF document
     * and saves it to the device's Downloads folder.
     */
    suspend fun generateGraphPdfReport(title: String, bodyText: String): File? {
        val pdfDocument = PdfDocument()
        val brandColor = Color.rgb(79, 70, 229) // #4f46e5
        val darkTextColor = Color.rgb(30, 41, 59) // #1e293b
        val bodyTextColor = Color.rgb(51, 65, 85) // #334155
        val mutedTextColor = Color.rgb(100, 116, 139) // #64748b

        val brandPaint = Paint().apply {
            color = brandColor
            textSize = 20f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val titlePaint = Paint().apply {
            color = darkTextColor
            textSize = 14f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val sectionHeaderPaint = Paint().apply {
            color = brandColor
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val headingPaint = Paint().apply {
            color = darkTextColor
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isAntiAlias = true
        }
        val bodyPaint = Paint().apply {
            color = bodyTextColor
            textSize = 10f
            isAntiAlias = true
        }
        val metaPaint = Paint().apply {
            color = mutedTextColor
            textSize = 9.5f
            isAntiAlias = true
        }
        val linePaint = Paint().apply {
            color = Color.rgb(99, 102, 241)
            strokeWidth = 1.5f
            isAntiAlias = true
        }

        val pageInfo = PdfDocument.PageInfo.Builder(595, 842, 1).create() // A4 size
        val pages = mutableListOf<PdfDocument.Page>()
        var pageNum = 1
        var currentPage = pdfDocument.startPage(pageInfo)
        pages.add(currentPage)
        var canvas = currentPage.canvas

        var y = 48f
        val margin = 48f
        val contentWidth = 499f
        val pageBottomMax = 780f

        fun drawHeader(isContinuation: Boolean) {
            canvas.drawText("Tabs", margin, y, brandPaint)
            y += 18f
            canvas.drawText(title, margin, y, titlePaint)
            if (!isContinuation) {
                y += 14f
                val todayStr = SimpleDateFormat("MMMM dd, yyyy - hh:mm a", Locale.getDefault()).format(Date())
                canvas.drawText("Clinical Graph Pattern Summary • Generated $todayStr", margin, y, metaPaint)
            }
            y += 12f
            canvas.drawLine(margin, y, margin + contentWidth, y, linePaint)
            y += 20f
        }

        fun checkPageBreak(neededHeight: Float, isHeading: Boolean = false): Boolean {
            if (y + neededHeight > pageBottomMax) {
                pdfDocument.finishPage(currentPage)
                pageNum++
                currentPage = pdfDocument.startPage(pageInfo)
                pages.add(currentPage)
                canvas = currentPage.canvas
                y = 48f
                drawHeader(true)
                return true
            }
            return false
        }

        // Draw initial header
        drawHeader(false)

        // Parse and clean raw input
        val cleanBody = bodyText
            .replace(Regex("<[^>]*>"), "")
            .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            .replace("**", "").replace("*", "").replace("`", "")

        val paragraphs = cleanBody.split(Regex("\\n\\s*\\n")).map { it.trim() }.filter { it.isNotEmpty() }

        var currentFindingNum = 0
        val findingHeaderRegex = Regex("^(?:■\\s*)?(?:Tip|Finding)?\\s*(\\d+)[\\.\\)\\:\\-]\\s*(?:\\*\\*)?([^:\\n]+?)(?:\\*\\*)?(?:\\:|\\s*-\\s*|\\n|$)([\\s\\S]*)", RegexOption.IGNORE_CASE)

        // Render Intro / Overview
        canvas.drawText("Overview", margin, y, sectionHeaderPaint)
        y += 14f

        paragraphs.forEach { p ->
            val match = findingHeaderRegex.find(p)
            if (match != null) {
                val num = match.groupValues[1].toIntOrNull() ?: 0
                val headingText = match.groupValues[2].trim()
                val restText = match.groupValues[3].trim()

                checkPageBreak(70f, isHeading = true)

                currentFindingNum = if (num > 0) num else currentFindingNum + 1

                canvas.drawText("Finding $currentFindingNum", margin, y, sectionHeaderPaint)
                y += 14f

                val wrappedHeading = wrapText(headingText, contentWidth, headingPaint)
                wrappedHeading.forEach { hLine ->
                    checkPageBreak(14f)
                    canvas.drawText(hLine, margin, y, headingPaint)
                    y += 14f
                }
                y += 4f

                val wrappedBody = wrapText(restText, contentWidth, bodyPaint)
                wrappedBody.forEach { bLine ->
                    checkPageBreak(14f)
                    canvas.drawText(bLine, margin, y, bodyPaint)
                    y += 14f
                }
                y += 16f
            } else {
                val wrappedP = wrapText(p, contentWidth, bodyPaint)
                wrappedP.forEach { line ->
                    checkPageBreak(14f)
                    canvas.drawText(line, margin, y, bodyPaint)
                    y += 14f
                }
                y += 12f
            }
        }

        // Draw Disclaimer / Footer Line
        checkPageBreak(40f)
        y += 10f
        canvas.drawLine(margin, y, margin + contentWidth, y, linePaint.apply { strokeWidth = 1f; color = Color.LTGRAY })
        y += 16f
        val disclaimerText = "Important note: This AI-generated analysis is informational and is not a diagnosis. Review important findings with a qualified healthcare professional."
        val wrappedDisclaimer = wrapText(disclaimerText, contentWidth, metaPaint.apply { textSize = 8.5f })
        wrappedDisclaimer.forEach { line ->
            canvas.drawText(line, margin, y, metaPaint)
            y += 12f
        }

        pdfDocument.finishPage(currentPage)

        val totalPages = pages.size
        pages.forEachIndexed { idx, page ->
            val pCanvas = page.canvas
            val pageNumText = "Page ${idx + 1} of $totalPages"
            pCanvas.drawText(pageNumText, 595f - margin - metaPaint.measureText(pageNumText), 820f, metaPaint)
        }

        val timeStamp = SimpleDateFormat("MMM_dd_yyyy_HHmm", Locale.getDefault()).format(Date())
        val fileName = "Tabs_AI_Graph_Report_$timeStamp.pdf"
        val cacheFile = File(context.cacheDir, fileName)

        try {
            pdfDocument.writeTo(FileOutputStream(cacheFile))
            saveToDownloads(cacheFile, fileName)
        } catch (e: Exception) {
            e.printStackTrace()
            return null
        } finally {
            pdfDocument.close()
        }

        return cacheFile
    }
}
