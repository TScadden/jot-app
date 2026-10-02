package com.notel.notel.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.data.model.*
import com.notel.notel.ui.theme.*

/**
 * Trend preview for Progress Reports (Phase 2, WS-D).
 *
 * Replaces the hourly logging chart as the PRIMARY preview: actual metric
 * trends (sleep / heart-rate / HRV lines, symptom-frequency and
 * training-volume bars) computed from the same range/focus as the export.
 * The hourly chart stays on screen as a secondary "when do you log" view.
 *
 * Every chart here is aggregated with the SAME pure functions
 * (ReportCharts.kt) the PDF uses, from the SAME preview snapshot — so the
 * numbers on screen and in the export agree for identical inputs.
 */

private const val DAY_MS = 24 * 60 * 60 * 1000L

/** One vertical event marker: epoch millis + short label. */
data class PreviewEventMarker(val dateMs: Long, val label: String)

@Composable
fun ReportTrendPreview(
    snapshot: ClinicalReportData,
    modifier: Modifier = Modifier
) {
    val zone = snapshot.range.timezoneId
    val start = snapshot.range.startEpochMs.coerceAtLeast(0L)
    val end = snapshot.range.endEpochMs
    val spanDays = ((end - start) / DAY_MS).coerceAtLeast(1)
    val bucketSize = remember(start, end) { bucketSizeForSpan(spanDays) }
    val aggLabel = remember(bucketSize) { "${bucketSize.label} averages" }

    // Recorded medication changes, aligned across every time-based chart.
    val events = remember(snapshot) {
        extractMedicationEvents(snapshot.medications, snapshot.logEntries, snapshot.categoriesMap)
            .filter { it.dateMs != null && it.dateMs in start..end }
            .map { PreviewEventMarker(it.dateMs!!, eventMarkerLabel(it).take(18)) }
    }

    val sleepBuckets = remember(snapshot) {
        bucketizeSeries(seriesToPoints(snapshot.sleepSeries.map { it.first to it.second.toDouble() })
            .map { (ms, mins) -> ms to mins / 60.0 }, start, end, zone, bucketSize)
    }
    val hrBuckets = remember(snapshot) {
        bucketizeSeries(seriesToPoints(snapshot.heartRateSeries.map { it.first to it.second.toDouble() }),
            start, end, zone, bucketSize)
    }
    val hrvBuckets = remember(snapshot) {
        bucketizeSeries(seriesToPoints(snapshot.hrvSeries.map { it.first to it.second.toDouble() }),
            start, end, zone, bucketSize)
    }

    val symptomIds = remember(snapshot) { symptomCategoryIds(snapshot) }
    val symptomEntries = remember(snapshot) { snapshot.logEntries.filter { it.categoryId in symptomIds } }
    val symptomBuckets = remember(snapshot, symptomEntries) {
        if (symptomEntries.isEmpty()) emptyList()
        else bucketizeCounts(symptomEntries, start, end, zone, bucketSize)
    }
    val topSymptoms = remember(snapshot, symptomEntries) {
        topSymptomsByDistinctDays(snapshot.logEntries, snapshot.categoriesMap, symptomIds, limit = 5)
    }

    val trainingBuckets = remember(snapshot) {
        val calPoints = seriesToPoints(snapshot.caloriesSeries.map { it.first to it.second.toDouble() })
        if (calPoints.isNotEmpty()) {
            // Calories are already daily totals: sum per bucket, not mean.
            val perBucket = bucketizeSeries(calPoints, start, end, zone, bucketSize)
            perBucket.map { b ->
                val sum = calPoints.filter { (ms, _) -> ms in b.startMs..b.endMs }.sumOf { it.second }
                CountBucket(b.startMs, b.endMs, b.label, sum.toInt())
            }
        } else if (snapshot.logEntries.isNotEmpty()) {
            bucketizeCounts(snapshot.logEntries, start, end, zone, bucketSize)
        } else emptyList()
    }
    val trainingSourceNote = remember(snapshot) {
        if (snapshot.caloriesSeries.isNotEmpty()) "daily calorie totals"
        else "logged entries per ${bucketSize.singularLabel()}"
    }

    var anyChart = false

    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (sleepBuckets.any { it.hasData }) {
            anyChart = true
            PreviewLineChart(
                title = "Sleep duration",
                unit = "h",
                buckets = sleepBuckets,
                color = NotelPrimary,
                events = events,
                caption = "$aggLabel · Source: ${coverageLabel(snapshot, "sleep")} · Gaps are missing data, not zero."
            )
        }
        if (hrBuckets.any { it.hasData }) {
            anyChart = true
            PreviewLineChart(
                title = "Heart rate",
                unit = "bpm",
                buckets = hrBuckets,
                color = NotelError,
                events = events,
                caption = "$aggLabel · Source: ${coverageLabel(snapshot, "heartRate")} · Gaps are missing data, not zero."
            )
        }
        if (hrvBuckets.any { it.hasData }) {
            anyChart = true
            PreviewLineChart(
                title = "Heart-rate variability (RMSSD)",
                unit = "ms",
                buckets = hrvBuckets,
                color = NotelAccent,
                events = events,
                caption = "$aggLabel · Source: ${coverageLabel(snapshot, "hrv")} · Gaps are missing data, not zero."
            )
        }
        if (symptomBuckets.isNotEmpty() && (snapshot.focusKey == "health" || snapshot.focusKey == "custom")) {
            anyChart = true
            PreviewBarChart(
                title = "Symptom frequency",
                unit = "entries",
                buckets = symptomBuckets,
                color = NotelPrimary,
                events = events,
                caption = "Logged symptom entries per ${bucketSize.singularLabel()} · Top symptoms ranked by distinct days below."
            )
            if (topSymptoms.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    topSymptoms.forEachIndexed { i, (name, days, count) ->
                        Text(
                            "${i + 1}. $name, $days days, $count entries",
                            color = NotelTextSecondary,
                            fontSize = 12.sp
                        )
                    }
                }
            }
        }
        if (trainingBuckets.isNotEmpty() && (snapshot.focusKey == "training" || snapshot.focusKey == "custom")) {
            anyChart = true
            PreviewBarChart(
                title = "Training volume",
                unit = if (snapshot.caloriesSeries.isNotEmpty()) "kcal" else "entries",
                buckets = trainingBuckets,
                color = NotelAccent,
                events = events,
                caption = "Totals per ${bucketSize.singularLabel()} ($trainingSourceNote). Tabs has no distance/pace sensors. Volume comes from logged activity only."
            )
        }
        if (!anyChart) {
            Text(
                "No trend data in this range yet. Log entries or connect Health Connect and the trends will appear here.",
                color = NotelTextSecondary,
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun ChartHeader(title: String, unit: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(title, color = NotelTextPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        Text(unit, color = NotelTextSecondary, fontSize = 11.sp)
    }
}

@Composable
private fun ChartCaption(text: String) {
    Text(text, color = NotelTextSecondary.copy(alpha = 0.75f), fontSize = 10.sp, lineHeight = 13.sp)
}

/**
 * Chart axis/marker label paint. [sizeSp] is true sp, scaled by the draw
 * scope density: Paint.textSize is raw px, so passing sp straight in renders
 * ~3dp-tall glyphs on a 3x screen.
 */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.labelPaint(
    sizeSp: Float,
    color: Int
): android.graphics.Paint =
    android.graphics.Paint().apply {
        this.color = color
        textSize = with(density) { sizeSp.sp.toPx() }
        isAntiAlias = true
    }

/**
 * Canvas line chart with true gaps (the polyline breaks where buckets have
 * no data), up to ~5 x labels, and vertical event markers.
 */
@Composable
fun PreviewLineChart(
    title: String,
    unit: String,
    buckets: List<ChartBucket>,
    color: Color,
    events: List<PreviewEventMarker>,
    caption: String,
    modifier: Modifier = Modifier
) {
    val withData = remember(buckets) { buckets.filter { it.hasData } }
    Column(modifier = modifier) {
        ChartHeader(title, unit)
        Spacer(Modifier.height(6.dp))
        if (withData.size < 2) {
            Text("Not enough data points to draw a trend.", color = NotelTextSecondary, fontSize = 12.sp)
        } else {
            val gridColor = NotelTextSecondary.copy(alpha = 0.25f)
            val labelColorInt = android.graphics.Color.GRAY
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(170.dp)
            ) {
                val w = size.width
                val h = size.height
                val padL = 44f
                val padR = 8f
                val padT = 20f
                val padB = 22f
                val cw = w - padL - padR
                val ch = h - padT - padB
                if (cw <= 0 || ch <= 0) return@Canvas

                val start = buckets.first().startMs
                val end = buckets.last().endMs
                val span = (end - start).coerceAtLeast(1)
                fun xFor(ms: Long): Float = padL + ((ms - start).toFloat() / span) * cw

                val vals = withData.map { it.mean!! }
                val minV = vals.minOrNull() ?: 0.0
                val maxV = vals.maxOrNull() ?: 1.0
                val pad = (maxV - minV).coerceAtLeast(1.0) * 0.12
                val lo = minV - pad
                val hi = maxV + pad
                fun yFor(v: Double): Float = (padT + ch - ((v - lo) / (hi - lo)).toFloat() * ch)

                // Gridlines + y labels (3).
                val textPaint = labelPaint(10f, labelColorInt)
                for (i in 0..2) {
                    val ratio = i / 2f
                    val gy = padT + ch * (1f - ratio)
                    drawLine(gridColor, Offset(padL, gy), Offset(padL + cw, gy), strokeWidth = 1f)
                    val vLabel = String.format("%.0f", lo + ratio * (hi - lo))
                    drawContext.canvas.nativeCanvas.drawText(vLabel, 4f, gy + 3.5f, textPaint)
                }

                // Event markers (dashed verticals + short labels at top).
                val dash = PathEffect.dashPathEffect(floatArrayOf(6f, 5f), 0f)
                val markerColor = NotelWarning
                events.forEach { ev ->
                    if (ev.dateMs in start..end) {
                        val ex = xFor(ev.dateMs)
                        drawLine(
                            markerColor, Offset(ex, padT - 14f), Offset(ex, padT + ch),
                            strokeWidth = 1.5f, pathEffect = dash
                        )
                        drawContext.canvas.nativeCanvas.drawText(
                            ev.label, (ex + 3f).coerceAtMost(w - 90f), padT - 6f,
                            labelPaint(9f, android.graphics.Color.rgb(160, 110, 20))
                        )
                    }
                }

                // X labels: up to 5, collision-checked.
                val xPaint = labelPaint(9f, labelColorInt).apply {
                    textAlign = android.graphics.Paint.Align.CENTER
                }
                val step = (buckets.size / 4).coerceAtLeast(1)
                var lastRight = -Float.MAX_VALUE
                for (i in buckets.indices step step) {
                    val b = buckets[i]
                    val cx = xFor((b.startMs + b.endMs) / 2)
                    val label = b.label
                    val half = xPaint.measureText(label) / 2f
                    if (cx - half > lastRight + 4f) {
                        drawContext.canvas.nativeCanvas.drawText(label, cx, h - 6f, xPaint)
                        lastRight = cx + half
                    }
                }

                // Polyline, broken at gaps.
                var segment = mutableListOf<Offset>()
                fun flush() {
                    if (segment.size >= 2) {
                        val path = Path().apply {
                            moveTo(segment[0].x, segment[0].y)
                            segment.drop(1).forEach { lineTo(it.x, it.y) }
                        }
                        drawPath(path, color, style = Stroke(width = 2.5f))
                    }
                    segment = mutableListOf()
                }
                buckets.forEach { b ->
                    if (b.hasData) {
                        segment.add(Offset(xFor((b.startMs + b.endMs) / 2), yFor(b.mean!!)))
                    } else flush()
                }
                flush()
                withData.forEach { b ->
                    val c = Offset(xFor((b.startMs + b.endMs) / 2), yFor(b.mean!!))
                    drawCircle(Color.White, radius = 4f, center = c)
                    drawCircle(color, radius = 2.6f, center = c)
                }
            }
        }
        Spacer(Modifier.height(4.dp))
        ChartCaption(caption)
    }
}

/**
 * Canvas bar chart for counts (symptom frequency / training volume).
 * Zero-count buckets draw as honest zeros; event markers align with the
 * line charts above.
 */
@Composable
fun PreviewBarChart(
    title: String,
    unit: String,
    buckets: List<CountBucket>,
    color: Color,
    events: List<PreviewEventMarker>,
    caption: String,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier) {
        ChartHeader(title, unit)
        Spacer(Modifier.height(6.dp))
        if (buckets.isEmpty() || buckets.all { it.count == 0 }) {
            Text("Nothing recorded in this range.", color = NotelTextSecondary, fontSize = 12.sp)
        } else {
            val gridColor = NotelTextSecondary.copy(alpha = 0.25f)
            val labelColorInt = android.graphics.Color.GRAY
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(170.dp)
            ) {
                val w = size.width
                val h = size.height
                val padL = 34f
                val padR = 8f
                val padT = 20f
                val padB = 22f
                val cw = w - padL - padR
                val ch = h - padT - padB
                if (cw <= 0 || ch <= 0 || buckets.isEmpty()) return@Canvas

                val maxC = (buckets.maxOf { it.count }).coerceAtLeast(1).toFloat()
                val slot = cw / buckets.size
                val barW = (slot * 0.62f).coerceAtLeast(3f)

                val textPaint = labelPaint(10f, labelColorInt)
                drawLine(gridColor, Offset(padL, padT), Offset(padL + cw, padT), strokeWidth = 1f)
                drawContext.canvas.nativeCanvas.drawText(
                    maxC.toInt().toString(), 4f, padT + 3.5f, textPaint
                )
                drawLine(gridColor, Offset(padL, padT + ch), Offset(padL + cw, padT + ch), strokeWidth = 1f)
                drawContext.canvas.nativeCanvas.drawText("0", 4f, padT + ch + 3.5f, textPaint)

                // Event markers.
                val start = buckets.first().startMs
                val end = buckets.last().endMs
                val span = (end - start).coerceAtLeast(1)
                val dash = PathEffect.dashPathEffect(floatArrayOf(6f, 5f), 0f)
                events.forEach { ev ->
                    if (ev.dateMs in start..end) {
                        val ex = padL + ((ev.dateMs - start).toFloat() / span) * cw
                        drawLine(
                            NotelWarning, Offset(ex, padT - 14f), Offset(ex, padT + ch),
                            strokeWidth = 1.5f, pathEffect = dash
                        )
                    }
                }

                buckets.forEachIndexed { i, b ->
                    val cx = padL + slot * i + slot / 2f
                    val bh = (b.count / maxC) * ch
                    if (bh > 0.5f) {
                        drawRect(
                            color = color.copy(alpha = 0.85f),
                            topLeft = Offset(cx - barW / 2f, padT + ch - bh),
                            size = androidx.compose.ui.geometry.Size(barW, bh)
                        )
                    }
                }

                // X labels: up to 5, collision-checked.
                val xPaint = labelPaint(9f, labelColorInt).apply {
                    textAlign = android.graphics.Paint.Align.CENTER
                }
                val step = (buckets.size / 4).coerceAtLeast(1)
                var lastRight = -Float.MAX_VALUE
                for (i in buckets.indices step step) {
                    val cx = padL + slot * i + slot / 2f
                    val label = buckets[i].label
                    val half = xPaint.measureText(label) / 2f
                    if (cx - half > lastRight + 4f) {
                        drawContext.canvas.nativeCanvas.drawText(label, cx, h - 6f, xPaint)
                        lastRight = cx + half
                    }
                }
            }
        }
        Spacer(Modifier.height(4.dp))
        ChartCaption(caption)
    }
}
