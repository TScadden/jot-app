package com.notel.notel.util

import android.content.ContentValues
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object PdfExporter {

    fun exportSpikesToPdf(context: Context, dateStr: String, heartRateData: List<Pair<Long, Int>>) {
        try {
            val formattedDate = if (dateStr == "today") {
                SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
            } else {
                dateStr
            }

            // 1. Calculate spikes
            val allEvents = mutableListOf<SpikeEvent>()
            var currentEventStart = 0L
            var currentEventPeak = 0
            var currentEventEndMs = 0L
            var inEvent = false

            heartRateData.forEach { (timeMs, bpm) ->
                if (bpm >= 100) {
                    if (!inEvent || timeMs > currentEventEndMs) {
                        if (inEvent) {
                            val dur = maxOf(1, ((currentEventEndMs - 300_000L - currentEventStart) / 60000).toInt())
                            allEvents.add(SpikeEvent(currentEventStart, currentEventPeak, dur))
                        }
                        inEvent = true
                        currentEventStart = timeMs
                        currentEventPeak = bpm
                    } else {
                        currentEventPeak = maxOf(currentEventPeak, bpm)
                    }
                    currentEventEndMs = timeMs + (5 * 60 * 1000)
                }
            }
            if (inEvent) {
                val dur = maxOf(1, ((currentEventEndMs - 300_000L - currentEventStart) / 60000).toInt())
                allEvents.add(SpikeEvent(currentEventStart, currentEventPeak, dur))
            }

            if (allEvents.isEmpty()) {
                Toast.makeText(context, "No spike events to export", Toast.LENGTH_SHORT).show()
                return
            }

            // 2. Create PDF
            val pdfDocument = PdfDocument()
            val pageInfo = PdfDocument.PageInfo.Builder(595, 842, 1).create()
            val page = pdfDocument.startPage(pageInfo)
            val canvas = page.canvas

            val paint = Paint()
            val titlePaint = Paint().apply {
                color = Color.rgb(33, 33, 33)
                textSize = 24f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            }
            val subTitlePaint = Paint().apply {
                color = Color.rgb(117, 117, 117)
                textSize = 12f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC)
            }
            val textPaint = Paint().apply {
                color = Color.rgb(33, 33, 33)
                textSize = 14f
            }
            val headerPaint = Paint().apply {
                color = Color.rgb(33, 33, 33)
                textSize = 14f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            }
            val linePaint = Paint().apply {
                color = Color.rgb(224, 224, 224)
                strokeWidth = 1f
            }

            var y = 60f

            // Report Header
            canvas.drawText("Jot HR Spikes Report", 50f, y, titlePaint)
            y += 24f
            canvas.drawText("Date: $formattedDate | Exported: ${SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date())}", 50f, y, subTitlePaint)
            y += 35f

            // Metrics Summary Section
            val readings = heartRateData.map { it.second }
            if (readings.isNotEmpty()) {
                val sorted = readings.sorted()
                val peakVal = sorted.last()
                val p10 = sorted[(sorted.size * 0.10).toInt().coerceAtLeast(0)]
                val deltaVal = peakVal - p10
                val totalEvents = allEvents.size
                
                canvas.drawText("SUMMARY", 50f, y, headerPaint)
                y += 10f
                canvas.drawLine(50f, y, 545f, y, linePaint)
                y += 20f
                
                canvas.drawText("• Peak Heart Rate: $peakVal bpm", 60f, y, textPaint)
                y += 18f
                canvas.drawText("• Total Spike Events: $totalEvents events", 60f, y, textPaint)
                y += 18f
                canvas.drawText("• Max Jump (Delta): +$deltaVal bpm (Baseline: $p10 bpm ➝ Peak: $peakVal bpm)", 60f, y, textPaint)
                y += 30f
            }

            // Table Headers
            canvas.drawText("Time", 50f, y, headerPaint)
            canvas.drawText("Duration", 250f, y, headerPaint)
            canvas.drawText("Peak BPM", 450f, y, headerPaint)
            y += 10f
            canvas.drawLine(50f, y, 545f, y, linePaint)
            y += 25f

            val timeFormatter = SimpleDateFormat("h:mm a", Locale.getDefault())
            
            allEvents.forEach { event ->
                val timeStr = timeFormatter.format(Date(event.startTimeMs))
                val durStr = if (event.durationMins > 1) "${event.durationMins} mins" else "1 min"
                val bpmStr = "${event.peakBpm} bpm"

                canvas.drawText(timeStr, 50f, y, textPaint)
                canvas.drawText(durStr, 250f, y, textPaint)
                canvas.drawText(bpmStr, 450f, y, textPaint)
                y += 20f
            }

            pdfDocument.finishPage(page)

            // 3. Save to MediaStore (Downloads Folder)
            val fileName = "Jot $formattedDate HR spikes"
            val resolver = context.contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                }
            }

            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
            if (uri != null) {
                val outputStream: OutputStream? = resolver.openOutputStream(uri)
                if (outputStream != null) {
                    pdfDocument.writeTo(outputStream)
                    outputStream.close()
                    Toast.makeText(context, "Saved PDF to Downloads!", Toast.LENGTH_LONG).show()
                } else {
                    Toast.makeText(context, "Failed to write PDF", Toast.LENGTH_SHORT).show()
                }
            } else {
                Toast.makeText(context, "Failed to create MediaStore entry", Toast.LENGTH_SHORT).show()
            }
            pdfDocument.close()
        } catch (e: Exception) {
            e.printStackTrace()
            Toast.makeText(context, "Error saving PDF: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    class SpikeEvent(val startTimeMs: Long, val peakBpm: Int, val durationMins: Int)
}
