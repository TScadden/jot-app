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
    suspend fun generateReport(allEntries: List<LogEntry>, categories: List<com.notel.notel.data.local.entity.Category>): File? {
        val summaryResult = logRepository.getMedicalReportSummary(categories)
        val summary = summaryResult.getOrDefault("Clinical summary unavailable. Analysis based on raw logs.")
        val catMap = categories.associate { it.id to it.name }

        val pdfDocument = PdfDocument()
        val paint = Paint()
        val titlePaint = Paint().apply {
            color = Color.rgb(33, 33, 33)
            textSize = 24f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val sectionPaint = Paint().apply {
            color = Color.rgb(0, 102, 204) // Professional Blue
            textSize = 18f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val bodyPaint = Paint().apply {
            color = Color.rgb(66, 66, 66)
            textSize = 12f
        }
        val boldBodyPaint = Paint().apply {
            color = Color.BLACK
            textSize = 12f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val italicBodyPaint = Paint().apply {
            color = Color.BLACK
            textSize = 12f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC)
        }
        val linePaint = Paint().apply {
            color = Color.LTGRAY
            strokeWidth = 1f
        }

        val pageInfo = PdfDocument.PageInfo.Builder(595, 842, 1).create() // A4 size
        var page = pdfDocument.startPage(pageInfo)
        var canvas = page.canvas

        var y = 60f
        val margin = 50f
        val contentWidth = 495f

        canvas.drawText("Jot — Clinical Longitudinal Report", margin, y, titlePaint)
        y += 12f
        canvas.drawLine(margin, y, margin + contentWidth, y, linePaint)
        y += 28f
        
        canvas.drawText("Patient Report Generated: ${SimpleDateFormat("MMM dd, yyyy", Locale.getDefault()).format(Date())}", margin, y, bodyPaint)
        y += 40f

        // Advanced Parsing Logic
        val rawLines = summary.split("\n")
        rawLines.forEach { line ->
            if (y > 780) { // New Page
                pdfDocument.finishPage(page)
                page = pdfDocument.startPage(pageInfo)
                canvas = page.canvas
                y = 60f
            }

            when {
                line.contains("[SECTION]") -> {
                    y += 15f
                    val cleanSection = line.replace("[SECTION]", "").replace("[BOLD]", "").replace("*", "").replace("#", "").trim()
                    
                    val wrappedSections = wrapText(cleanSection, contentWidth, sectionPaint)
                    wrappedSections.forEach { sectionPart ->
                        canvas.drawText(sectionPart, margin, y, sectionPaint)
                        y += 22f
                    }
                    
                    y -= 14f // Back up a bit for the underline
                    canvas.drawLine(margin, y, margin + 80f, y, sectionPaint.apply { strokeWidth = 2f })
                    y += 25f
                }
                line.contains("[BULLET]") -> {
                    val cleanBullet = line.replace("[BULLET]", "").replace("*", "").trim().removePrefix("-").trim()
                    drawFormattedLine("• $cleanBullet", margin + 15f, y, contentWidth - 15f, canvas, bodyPaint, boldBodyPaint, italicBodyPaint).let { 
                        y = it 
                    }
                    y += 8f
                }
                else -> {
                    drawFormattedLine(line, margin, y, contentWidth, canvas, bodyPaint, boldBodyPaint, italicBodyPaint).let { 
                        y = it 
                    }
                    y += 8f
                }
            }
        }

        y += 30f
        if (y < 750) {
            canvas.drawLine(margin, y, margin + contentWidth, y, linePaint)
            y += 25f
            canvas.drawText("Disclaimer: This report is generated by AI based on personal logs and should be reviewed by a medical professional.", margin, y, bodyPaint.apply { textSize = 9f; color = Color.GRAY })
        }

        pdfDocument.finishPage(page)

        // ── 2. Render Biometrics Charts Page(s) ───────────────────────────
        try {
            val insightsStr = preferences.aiInsights.first()
            val insights = if (insightsStr.isNotBlank()) {
                try { Json { ignoreUnknownKeys = true }.decodeFromString<List<AiInsight>>(insightsStr) } catch(e: Exception) { emptyList() }
            } else emptyList()

            val biometricInsights = insights
                .filter { it.type == "Biometrics" }
                .sortedWith { a, b ->
                    val getVersion = { id: String ->
                        val match = "_v(\\d+)$".toRegex().find(id)
                        match?.groupValues?.get(1)?.toIntOrNull() ?: 1
                    }
                    getVersion(a.id).compareTo(getVersion(b.id))
                }

            val sdfDate = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            val sdfOut = SimpleDateFormat("MMM d", Locale.US)
            val dateMap = mutableMapOf<String, BiometricRecord>()
            val jsonSerializer = Json { ignoreUnknownKeys = true }

            biometricInsights.forEach { insight ->
                val date = Date(insight.timestamp)
                val dateKey = sdfDate.format(date)
                val dateStr = sdfOut.format(date)
                
                var metrics: BiometricMetricsJson? = null
                try {
                    metrics = jsonSerializer.decodeFromString<BiometricMetricsJson>(insight.text)
                } catch(e: Exception) {
                    e.printStackTrace()
                }
                
                val existing = dateMap[dateKey] ?: BiometricRecord(
                    date = dateKey,
                    dateStr = dateStr,
                    rawDate = date
                )
                
                dateMap[dateKey] = existing.copy(
                    sleepMins = metrics?.sleepMins ?: existing.sleepMins,
                    deepSleepMins = metrics?.deepSleepMins ?: existing.deepSleepMins,
                    avgHr = metrics?.avgHr ?: existing.avgHr,
                    hrv = metrics?.hrv ?: existing.hrv,
                    calories = metrics?.calories ?: existing.calories,
                    spikes = metrics?.spikes ?: existing.spikes
                )
            }

            allEntries.forEach { entry ->
                val date = Date(entry.timestamp)
                val dateKey = sdfDate.format(date)
                val dateStr = sdfOut.format(date)
                
                val existing = dateMap[dateKey] ?: BiometricRecord(
                    date = dateKey,
                    dateStr = dateStr,
                    rawDate = date
                )
                existing.jots += 1
                dateMap[dateKey] = existing
            }

            val sortedRecords = dateMap.values.sortedBy { it.rawDate }.takeLast(42)

            if (sortedRecords.isNotEmpty()) {
                // Page 2: Charts (1 to 4)
                var chartPage1 = pdfDocument.startPage(pageInfo)
                var chartCanvas1 = chartPage1.canvas

                chartCanvas1.drawText("Longitudinal Biometrics & Tracker Charts", margin, 60f, titlePaint)
                chartCanvas1.drawLine(margin, 72f, margin + contentWidth, 72f, linePaint)

                // 1. Sleep Duration
                val sleepData = sortedRecords.filter { it.sleepMins > 0 }.map { it.dateStr to it.sleepMins / 60f }
                drawLineChart(chartCanvas1, "Sleep Duration", sleepData, "#42A5F5", margin, 100f, contentWidth, 140f, "h")

                // 2. Deep Sleep
                val deepSleepData = sortedRecords.filter { it.deepSleepMins > 0 }.map { it.dateStr to it.deepSleepMins / 60f }
                drawLineChart(chartCanvas1, "Deep Sleep", deepSleepData, "#7C6EFF", margin, 270f, contentWidth, 140f, "h")

                // 3. Average Heart Rate
                val hrData = sortedRecords.filter { it.avgHr > 0 }.map { it.dateStr to it.avgHr.toFloat() }
                drawLineChart(chartCanvas1, "Avg Heart Rate", hrData, "#FF5E62", margin, 440f, contentWidth, 140f, " bpm")

                // 4. HRV
                val hrvData = sortedRecords.filter { it.hrv > 0.0 }.map { it.dateStr to it.hrv.toFloat() }
                drawLineChart(chartCanvas1, "HRV (RMSSD)", hrvData, "#B388FF", margin, 610f, contentWidth, 140f, " ms")

                pdfDocument.finishPage(chartPage1)

                // Page 3: Charts (5 to 7) + Disclaimer
                var chartPage2 = pdfDocument.startPage(pageInfo)
                var chartCanvas2 = chartPage2.canvas

                chartCanvas2.drawText("Longitudinal Biometrics & Tracker Charts (Cont.)", margin, 60f, titlePaint)
                chartCanvas2.drawLine(margin, 72f, margin + contentWidth, 72f, linePaint)

                // 5. Calories Burned
                val caloriesData = sortedRecords.filter { it.calories > 0 }.map { it.dateStr to it.calories.toFloat() }
                drawLineChart(chartCanvas2, "Calories Burned", caloriesData, "#FFA726", margin, 100f, contentWidth, 140f, " kcal")

                // 6. HR Spikes
                val spikesData = sortedRecords.filter { it.spikes > 0 }.map { it.dateStr to it.spikes.toFloat() }
                drawLineChart(chartCanvas2, "HR Spikes", spikesData, "#E040FB", margin, 270f, contentWidth, 140f, "")

                // 7. Number of Jots
                val jotsData = sortedRecords.filter { it.jots > 0 }.map { it.dateStr to it.jots.toFloat() }
                drawLineChart(chartCanvas2, "Number of Jots", jotsData, "#26A69A", margin, 440f, contentWidth, 140f, "")

                // Disclaimer on bottom of the charts page
                chartCanvas2.drawLine(margin, 650f, margin + contentWidth, 650f, linePaint)
                chartCanvas2.drawText(
                    "Disclaimer: This report is generated by AI based on personal logs and should be reviewed by a medical professional.",
                    margin,
                    675f,
                    bodyPaint.apply { textSize = 9f; color = Color.GRAY }
                )

                pdfDocument.finishPage(chartPage2)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        val fileName = "Jot_Report_${SimpleDateFormat("MMM_dd_yyyy", Locale.getDefault()).format(Date())}.pdf"
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
        italicPaint: Paint
    ): Float {
        var y = currentY
        val lines = wrapText(text, width, paint)
        
        var isBold = false
        var isItalic = false

        lines.forEach { line ->
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
                    canvas.drawText(segment, currentX, y, p)
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
                canvas.drawText(remaining, currentX, y, p)
            }
            
            y += 18f
        }
        return y
    }

    /**
     * Permanent storage in Downloads folder via MediaStore
     */
    private fun saveToDownloads(file: File, fileName: String) {
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
}
