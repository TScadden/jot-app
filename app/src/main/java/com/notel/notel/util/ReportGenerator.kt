package com.notel.notel.util

import android.content.Context
import android.graphics.*
import android.graphics.pdf.PdfDocument
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.model.*
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.ClinicalReportDataCollector
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.*
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Result of a detailed report generation: the cache file plus the durable
 * Downloads URI (for saved-report records, WS-G).
 */
data class GeneratedReport(val file: File, val downloadsUri: String?)

/** Stable section keys for the include/exclude preview toggles (WS-G). */
object ReportSections {
    const val FINDINGS = "findings"
    const val CHARTS = "charts"
    const val EVENTS = "events"
    const val TABLES = "tables"
    const val APPENDIX = "appendix"
    val ALL = setOf(FINDINGS, CHARTS, EVENTS, TABLES, APPENDIX)
}

/**
 * Render options for the professional PDF (WS-C / WS-G).
 *
 * [highlightOverrides] maps a section key to user-edited narrative text. It
 * is rendered as a labeled "Your note" box and NEVER mutates original
 * records or calculated values.
 */
data class ReportRenderOptions(
    val includedSections: Set<String> = ReportSections.ALL,
    val highlightOverrides: Map<String, String> = emptyMap(),
    /** Lab synthetic samples: watermark every page. */
    val synthetic: Boolean = false
)

private const val DAY_MS = 24 * 60 * 60 * 1000L

@Singleton
class ReportGenerator @Inject constructor(
    @ApplicationContext private val context: Context,
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences
) {

    companion object {
        private const val TAG = "ReportGenerator"
    }

    @Inject lateinit var dataCollector: ClinicalReportDataCollector

    // ── Palette: white pages, readable dark text, restrained Tabs purple ──
    private val purple = Color.rgb(79, 70, 229)          // Tabs purple accent
    private val purpleDark = Color.rgb(67, 56, 202)
    private val ink = Color.rgb(17, 24, 39)             // near-black body
    private val inkSoft = Color.rgb(55, 65, 81)
    private val gray = Color.rgb(107, 114, 128)
    private val hairline = Color.rgb(229, 231, 235)

    private fun paint(color: Int, size: Float, bold: Boolean = false, italic: Boolean = false): Paint =
        Paint().apply {
            this.color = color
            textSize = size
            typeface = Typeface.create(
                Typeface.DEFAULT,
                when {
                    bold -> Typeface.BOLD
                    italic -> Typeface.ITALIC
                    else -> Typeface.NORMAL
                }
            )
            isAntiAlias = true
        }

    /**
     * Backward-compatible overload for generateReport.
     */
    suspend fun generateReport(
        allEntries: List<LogEntry>,
        categories: List<com.notel.notel.data.local.entity.Category>,
        last30DaysOnly: Boolean = false
    ): File? {
        val snapshot = dataCollector.collectReportData(
            allCategories = categories,
            range = if (last30DaysOnly) ReportRange.Last30Days else ReportRange.AllTime,
            focus = ReportFocus.Custom(""),
            customCategoryIds = categories.map { it.id }.toSet()
        )
        val summaryResult = logRepository.getMedicalReportSummary(categories, last30DaysOnly = last30DaysOnly)
        val summary = summaryResult.getOrNull()
        return generateReport(snapshot, summary, isRawFallback = (summary == null))?.file
    }

    /**
     * Generates a professional clinical health report as a PDF using an immutable snapshot.
     * Returns the cache file (compat path; prefer [generateReportDetailed]).
     */
    suspend fun generateReport(
        snapshot: ClinicalReportData,
        aiSummary: String? = null,
        isRawFallback: Boolean = false
    ): GeneratedReport? = generateReportDetailed(snapshot, aiSummary, isRawFallback, ReportRenderOptions())

    /**
     * Full professional PDF rebuild (Phase 2, WS-C).
     *
     * White pages, dark readable text, restrained purple accents, no
     * decorative cover. Page 1: focus, user identifier, profile context,
     * 3–5 evidence-supported findings, headline metrics with units/coverage,
     * compact overall timeline. Following pages: large graphs with factual
     * captions, event comparisons, tables, notes. Appendix: methodology +
     * detailed logs. Sparse sections are skipped, never padded; long
     * histories are aggregated and labeled. Text stays searchable
     * (PdfDocument canvas text); repeating discreet header + page numbers.
     */
    suspend fun generateReportDetailed(
        snapshot: ClinicalReportData,
        aiSummary: String? = null,
        isRawFallback: Boolean = false,
        options: ReportRenderOptions = ReportRenderOptions(),
        userIdentifier: String? = null
    ): GeneratedReport? {
        if (!snapshot.hasAnyData) {
            android.util.Log.w(TAG, "Snapshot contains no data. Refusing to generate empty report PDF.")
            return null
        }

        val zone = try { ZoneId.of(snapshot.range.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
        val dateFmt = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US).withZone(zone)
        val dateTimeFmt = DateTimeFormatter.ofPattern("MMM d, yyyy h:mm a", Locale.US).withZone(zone)
        val startMs = snapshot.range.startEpochMs.coerceAtLeast(0L)
        val endMs = snapshot.range.endEpochMs
        val rangeLabel = "${dateFmt.format(Instant.ofEpochMilli(startMs))} to ${dateFmt.format(Instant.ofEpochMilli(endMs))}"
        val focusLabel = ReportFocus.fromKey(snapshot.focusKey).label
        val genLabel = "${dateTimeFmt.format(Instant.ofEpochMilli(snapshot.generationTimestamp))} (${snapshot.range.timezoneId})"

        // "Chosen user identifier": the account email when on file, else a
        // plain placeholder. (No chooser UI in this phase — noted.)
        val identifier = userIdentifier ?: run {
            val email = try { preferences.userEmail.first() } catch (_: Exception) { "" }
            email.ifBlank { "Tabs user" }
        }

        val effectiveSummary = when {
            !aiSummary.isNullOrBlank() -> aiSummary
            isRawFallback -> "[SECTION] RAW CLINICAL LOG SUMMARY\n[BOLD]Notice:[BOLD] AI summary generation was unavailable or non-responsive. The following report compiles raw longitudinal patient entries and measured biometrics snapshot directly.\n\n[SECTION] PATIENT OVERVIEW\n• Total Recorded Entries: ${snapshot.logEntries.size}\n• Active Conditions: ${if (snapshot.conditions.isNotEmpty()) snapshot.conditions.joinToString(", ") else "None listed"}\n• Active Medications: ${if (snapshot.medications.isNotEmpty()) snapshot.medications.joinToString(", ") { "${it.name} ${it.dose}" } else "None listed"}"
            else -> "Clinical summary unavailable. Analysis based on raw snapshot data."
        }

        val w = PdfReportWriter(
            headerText = "Tabs · Progress Report · $focusLabel · $rangeLabel",
            synthetic = options.synthetic
        )
        val B = paint(ink, 10.5f)
        val BB = paint(ink, 10.5f, bold = true)
        val BI = paint(ink, 10.5f, italic = true)
        val sec = paint(purpleDark, 12f, bold = true)
        val title = paint(ink, 20f, bold = true)
        val meta = paint(gray, 9f)
        val caption = paint(gray, 9f, italic = true)

        fun userNote(key: String) = userNoteBox(w, options, key, BB, B, BI)

        // ══ PAGE 1 — no decorative cover, straight into content ══
        w.canvas.drawText("Progress Report", w.margin, w.y, title)
        w.y += 8f
        w.canvas.drawText("$focusLabel focus", w.margin, w.y, paint(purpleDark, 12f, bold = true))
        w.y += 18f
        drawWrapped("Covering $rangeLabel · Generated $genLabel", w.margin, w.contentWidth, w, meta, BB, BI)
        drawWrapped("Prepared for: $identifier", w.margin, w.contentWidth, w, meta, BB, BI)
        w.y += 6f

        if (isRawFallback) {
            w.ensureSpace(30f)
            w.canvas.drawText(
                "RAW DATA REPORT: AI analysis was unavailable at generation time.",
                w.margin, w.y, paint(Color.rgb(153, 27, 27), 10f, bold = true)
            )
            w.y += 18f
        }

        // Relevant profile context (only what is on file — never padded).
        val profileBits = mutableListOf<String>()
        if (snapshot.userAge > 0) profileBits.add("${snapshot.userAge} y/o")
        if (snapshot.userGender.isNotBlank()) profileBits.add(snapshot.userGender)
        if (snapshot.userHeight > 0) profileBits.add("height ${snapshot.userHeight}")
        if (snapshot.userWeight > 0) profileBits.add("weight ${snapshot.userWeight}")
        if (snapshot.userContext.isNotBlank()) profileBits.add(snapshot.userContext.take(160))
        if (profileBits.isNotEmpty() || snapshot.conditions.isNotEmpty()) {
            w.ensureSpace(50f)
            w.canvas.drawText("Profile", w.margin, w.y, sec); w.y += 15f
            if (profileBits.isNotEmpty()) {
                drawWrapped(profileBits.joinToString(" · "), w.margin, w.contentWidth, w, B, BB, BI)
            }
            if (snapshot.conditions.isNotEmpty()) {
                drawWrapped(
                    "Recorded conditions: ${snapshot.conditions.joinToString(", ")}",
                    w.margin, w.contentWidth, w, B, BB, BI
                )
            }
            w.y += 8f
        }

        // 3–5 evidence-supported findings (deterministic, on-device).
        if (ReportSections.FINDINGS in options.includedSections) {
            val findings = buildFindings(snapshot)
            w.ensureSpace(60f)
            w.canvas.drawText("Key findings", w.margin, w.y, sec); w.y += 15f
            if (findings.isEmpty()) {
                drawWrapped(
                    "No findings could be computed from the data in this range.",
                    w.margin, w.contentWidth, w, B, BB, BI
                )
            } else {
                findings.forEachIndexed { i, f ->
                    w.ensureSpace(44f)
                    drawWrapped("${i + 1}. ${f.text}", w.margin, w.contentWidth, w, BB, B, BI)
                    drawWrapped("Evidence: ${f.evidence}", w.margin + 14f, w.contentWidth - 14f, w, caption, BB, BI)
                    w.y += 4f
                }
            }
            userNote(ReportSections.FINDINGS)
            w.y += 8f
        }

        // Headline metrics with units + coverage.
        val metrics = headlineMetrics(snapshot)
        if (metrics.isNotEmpty()) {
            w.ensureSpace(80f)
            w.canvas.drawText("At a glance", w.margin, w.y, sec); w.y += 15f
            val colW = w.contentWidth / 3f
            var col = 0
            var rowTop = w.y
            metrics.forEach { m ->
                if (col == 3) {
                    col = 0; w.y += 34f; rowTop = w.y
                    w.ensureSpace(44f)
                }
                val x = w.margin + col * colW
                w.canvas.drawText(m.label, x, rowTop, meta)
                w.canvas.drawText("${m.value} ${m.unit}", x, rowTop + 13f, BB)
                w.canvas.drawText(m.coverage, x, rowTop + 25f, caption)
                col++
            }
            w.y += 40f
        }

        // Compact overall timeline (where useful: any logged entries).
        if (snapshot.logEntries.isNotEmpty()) {
            w.ensureSpace(110f)
            w.canvas.drawText("Overall timeline", w.margin, w.y, sec); w.y += 15f
            val timeline = overallTimeline(snapshot.logEntries, startMs, endMs)
            drawTimelineStrip(w, timeline)
            w.y += 6f
            val bucketWord = if (((endMs - startMs) / DAY_MS) <= 120) "week" else "month"
            w.canvas.drawText(
                "Logged entries per $bucketWord across the full range.",
                w.margin, w.y, caption
            )
            w.y += 16f
        }

        // AI narrative (kept: it explains the deterministic numbers above).
        w.ensureSpace(60f)
        w.canvas.drawText("Analysis", w.margin, w.y, sec); w.y += 15f
        renderAiSummary(w, effectiveSummary, B, BB, BI, sec, caption)

        // ══ CHARTS ══
        if (ReportSections.CHARTS in options.includedSections) {
            renderCharts(w, snapshot, options, zone, startMs, endMs, B, BB, BI, caption)
        }

        // ══ EVENT COMPARISONS (WS-E) ══
        if (ReportSections.EVENTS in options.includedSections) {
            renderEvents(w, snapshot, zone, startMs, endMs, B, BB, BI, sec, caption)
            userNote(ReportSections.EVENTS)
        }

        // ══ TABLES ══
        if (ReportSections.TABLES in options.includedSections) {
            renderTables(w, snapshot, B, BB, BI, sec, caption)
            userNote(ReportSections.TABLES)
        }

        // ══ APPENDIX: methodology + detailed logs ══
        if (ReportSections.APPENDIX in options.includedSections) {
            renderAppendix(w, snapshot, effectiveSummary, zone, B, BB, BI, sec, caption, meta)
        }

        // Repeating discreet header + page numbers + disclaimer footer.
        val pages = w.finish()
        val total = pages.size
        val headerPaint = paint(gray, 8f)
        val footerPaint = paint(gray, 8f)
        val synthPaint = paint(Color.rgb(153, 27, 27), 9f, bold = true)
        pages.forEachIndexed { idx, pg ->
            val c = pg.canvas
            c.drawText(w.headerText, w.margin, 34f, headerPaint)
            val pageLabel = "Page ${idx + 1} of $total"
            c.drawText(pageLabel, 595f - w.margin - footerPaint.measureText(pageLabel), 822f, footerPaint)
            val disc = "Informational only. Not medical advice."
            c.drawText(disc, (595f - footerPaint.measureText(disc)) / 2f, 822f, footerPaint)
            if (options.synthetic) {
                val sw = "SYNTHETIC SAMPLE — NOT REAL DATA"
                c.drawText(sw, (595f - synthPaint.measureText(sw)) / 2f, 48f, synthPaint)
            }
        }

        // ── Write out: cache file + Downloads copy ──
        val stamp = SimpleDateFormat("MMM_dd_yyyy_HHmmss", Locale.getDefault()).format(Date())
        val prefix = if (options.synthetic) "Tabs_SYNTHETIC_Sample_${focusLabel}" else "Tabs_Report"
        val fileName = "${prefix}_${stamp}.pdf"
        val cacheFile = File(context.cacheDir, fileName)
        return try {
            w.document.writeTo(FileOutputStream(cacheFile))
            val uri = try { saveToDownloads(cacheFile, fileName) } catch (e: Exception) {
                android.util.Log.w(TAG, "Could not copy PDF to Downloads: ${e.message}")
                null
            }
            GeneratedReport(cacheFile, uri)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed writing PDF cache file: ${e.message}", e)
            null
        } finally {
            w.document.close()
        }
    }

    // ── Page writer: pagination state shared by every section ──

    private inner class PdfReportWriter(val headerText: String, val synthetic: Boolean) {
        val document = PdfDocument()
        private val finished = mutableListOf<PdfDocument.Page>()
        private val pageInfo = PdfDocument.PageInfo.Builder(595, 842, 1).create()
        var page: PdfDocument.Page = document.startPage(pageInfo)
        var canvas: Canvas = page.canvas
        var y = 62f
        val margin = 48f
        val contentWidth = 595f - margin * 2
        private val topMargin = 62f
        private val bottomLimit = 768f

        fun newPage() {
            document.finishPage(page)
            finished.add(page)
            page = document.startPage(pageInfo)
            canvas = page.canvas
            y = topMargin
        }

        fun finish(): List<PdfDocument.Page> {
            document.finishPage(page)
            finished.add(page)
            return finished
        }

        fun ensureSpace(needed: Float) {
            if (y + needed > bottomLimit) newPage()
        }
    }

    // ── CHARTS section ──

    /**
     * "Your note" overlay box (WS-G): the translucent purple fill is drawn
     * FIRST, under the glyphs, then the border. Used by every section that
     * supports a note, including the CHARTS note at the end of renderCharts.
     */
    private fun userNoteBox(
        w: PdfReportWriter,
        options: ReportRenderOptions,
        key: String,
        base: Paint,
        body: Paint,
        italic: Paint
    ) {
        val note = options.highlightOverrides[key]
        if (!note.isNullOrBlank()) {
            w.ensureSpace(60f)
            w.y += 6f
            val boxTop = w.y - 12f
            // Pre-measure so the fill renders before (under) the text.
            val textHeight = wrapText("Your note: $note", w.contentWidth - 16f, base).size * 15f
            val boxBottom = boxTop + 12f + textHeight + 6f
            w.canvas.drawRect(w.margin, boxTop, w.margin + w.contentWidth, boxBottom, Paint().apply {
                color = purple; alpha = 18; style = Paint.Style.FILL
            })
            w.canvas.drawRect(w.margin, boxTop, w.margin + w.contentWidth, boxBottom, Paint().apply {
                color = purple; alpha = 90; style = Paint.Style.STROKE; strokeWidth = 1f
            })
            drawWrapped("Your note: $note", w.margin + 8f, w.contentWidth - 16f, w, base, body, italic)
            w.y += 8f
        }
    }

    private fun renderCharts(
        w: PdfReportWriter,
        snapshot: ClinicalReportData,
        options: ReportRenderOptions,
        zone: ZoneId,
        startMs: Long,
        endMs: Long,
        body: Paint, bold: Paint, italic: Paint, caption: Paint
    ) {
        val spanDays = ((endMs - startMs) / DAY_MS).coerceAtLeast(1)
        val bucketSize = bucketSizeForSpan(spanDays)
        val aggWord = bucketSize.label // "daily" | "weekly" | "monthly"
        val tz = snapshot.range.timezoneId

        val events = extractMedicationEvents(snapshot.medications, snapshot.logEntries, snapshot.categoriesMap)
            .filter { it.dateMs != null && it.dateMs in startMs..endMs }

        fun sleepHours(): List<Pair<Long, Double>> =
            seriesToPoints(snapshot.sleepSeries.map { it.first to it.second.toDouble() })
                .map { (ms, mins) -> ms to mins / 60.0 }
        fun hrPoints(): List<Pair<Long, Double>> =
            seriesToPoints(snapshot.heartRateSeries.map { it.first to it.second.toDouble() })
        fun hrvPoints(): List<Pair<Long, Double>> =
            seriesToPoints(snapshot.hrvSeries.map { it.first to it.second.toDouble() })
        fun bpPoints(): List<Pair<Long, Double>> =
            snapshot.bloodPressureSeries.sortedBy { it.timeEpochMs }
                .map { it.timeEpochMs to it.systolic.toDouble() }

        val lineCharts = listOf(
            Triple("Sleep duration", sleepHours(), "h") to "sleep",
            Triple("Heart rate", hrPoints(), "bpm") to "heartRate",
            Triple("Heart-rate variability (RMSSD)", hrvPoints(), "ms") to "hrv",
            Triple("Systolic blood pressure", bpPoints(), "mmHg") to "bloodPressure"
        )
        val lineColors = listOf("#4F46E5", "#B91C1C", "#6D28D9", "#374151")

        lineCharts.forEachIndexed { i, (chart, metaKey) ->
            val (title, points, unit) = chart
            val buckets = bucketizeSeries(points, startMs, endMs, tz, bucketSize)
            if (buckets.none { it.hasData }) return@forEachIndexed // sparse: skip, never pad
            w.newPage()
            drawPdfLineChart(
                w, title, buckets, lineColors[i % lineColors.size],
                events, unit,
                "$aggWord averages · Source: ${coverageLabel(snapshot, metaKey)}. " +
                    "Gaps are missing data, not zero. Dashed markers show recorded medication changes."
            )
        }

        // Symptom-frequency bars (health/custom focus, when symptom data exists).
        val symptomIds = symptomCategoryIds(snapshot)
        val symptomEntries = snapshot.logEntries.filter { it.categoryId in symptomIds }
        if (symptomEntries.isNotEmpty() && snapshot.focusKey != "training") {
            w.newPage()
            val buckets = bucketizeCounts(symptomEntries, startMs, endMs, tz, bucketSize)
            drawPdfBarChart(
                w, "Symptom frequency", buckets, "#4F46E5", events, "entries",
                "Logged symptom entries per ${bucketSize.singularLabel()}. Top symptoms by distinct days are listed below."
            )
            w.y += 10f
            val sec = paint(purpleDark, 12f, bold = true)
            w.canvas.drawText("Most recorded symptoms", w.margin, w.y, sec); w.y += 15f
            val top = topSymptomsByDistinctDays(snapshot.logEntries, snapshot.categoriesMap, symptomIds, 5)
            val rows = top.map { (name, days, count) ->
                listOf(name, "$days days", "$count entries")
            }
            drawTable(w, listOf("Symptom", "Distinct days", "Entries"), rows, body, bold)
            w.y += 4f
            w.canvas.drawText(
                "Ranked by distinct recorded days. A day with no entry is not a symptom-free day.",
                w.margin, w.y, caption
            )
            w.y += 14f
        }

        // Training-volume bars (training/custom focus, or whenever calorie data exists).
        val calPoints = seriesToPoints(snapshot.caloriesSeries.map { it.first to it.second.toDouble() })
        if ((snapshot.focusKey == "training" || snapshot.focusKey == "custom") &&
            (calPoints.isNotEmpty() || snapshot.logEntries.isNotEmpty())
        ) {
            w.newPage()
            if (calPoints.isNotEmpty()) {
                val perBucket = bucketizeSeries(calPoints, startMs, endMs, tz, bucketSize)
                val summed = perBucket.map { b ->
                    val sum = calPoints.filter { (ms, _) -> ms in b.startMs..b.endMs }.sumOf { it.second }
                    CountBucket(b.startMs, b.endMs, b.label, sum.toInt())
                }
                drawPdfBarChart(
                    w, "Training volume", summed, "#6D28D9", events, "kcal",
                    "Calorie totals per ${bucketSize.singularLabel()}. Tabs has no distance/pace sensors. Volume comes from logged activity only."
                )
            } else {
                val buckets = bucketizeCounts(snapshot.logEntries, startMs, endMs, tz, bucketSize)
                drawPdfBarChart(
                    w, "Training volume", buckets, "#6D28D9", events, "entries",
                    "Logged entries per ${bucketSize.singularLabel()}. Tabs has no distance/pace sensors. Volume comes from logged activity only."
                )
            }
        }

        val note = options.highlightOverrides[ReportSections.CHARTS]
        if (!note.isNullOrBlank()) {
            userNoteBox(w, options, ReportSections.CHARTS, bold, body, italic)
        }
    }

    /** Compact overall-timeline strip: mini bars across the full range. */
    private fun drawTimelineStrip(w: PdfReportWriter, buckets: List<CountBucket>) {
        val stripH = 44f
        val stripW = w.contentWidth
        val maxC = buckets.maxOfOrNull { it.count }?.coerceAtLeast(1) ?: 1
        val slot = stripW / buckets.size.coerceAtLeast(1)
        val barW = (slot * 0.7f).coerceAtLeast(1.5f)
        val baseY = w.y + stripH
        val barPaint = Paint().apply { color = purple; alpha = 200; style = Paint.Style.FILL }
        val axisPaint = Paint().apply { color = hairline; strokeWidth = 1f }
        w.canvas.drawLine(w.margin, baseY, w.margin + stripW, baseY, axisPaint)
        buckets.forEachIndexed { i, b ->
            val bh = (b.count.toFloat() / maxC) * (stripH - 6f)
            if (bh > 0.5f) {
                val cx = w.margin + slot * i + slot / 2f
                w.canvas.drawRect(cx - barW / 2f, baseY - bh, cx + barW / 2f, baseY, barPaint)
            }
        }
        w.y = baseY + 4f
    }

    // ── EVENTS section (WS-E): recorded changes + before/after ──

    private fun renderEvents(
        w: PdfReportWriter,
        snapshot: ClinicalReportData,
        zone: ZoneId,
        startMs: Long,
        endMs: Long,
        body: Paint, bold: Paint, italic: Paint, sec: Paint, caption: Paint
    ) {
        val events = extractMedicationEvents(snapshot.medications, snapshot.logEntries, snapshot.categoriesMap)
        if (events.isEmpty()) return // sparse: skip, never pad

        w.newPage()
        w.canvas.drawText("Recorded changes", w.margin, w.y, sec); w.y += 6f
        drawWrapped(
            "Changes recorded in your medication list or mentioned in your logs. " +
                "Dose changes are keyword mentions from log text — doses, dates, and adherence are never invented.",
            w.margin, w.contentWidth, w, caption, bold, italic
        )
        w.y += 6f

        val rows = events.map { e ->
            val change = when (e.kind) {
                MedicationChangeKind.STARTED -> "Started"
                MedicationChangeKind.STOPPED -> "Stopped"
                MedicationChangeKind.DOSE_MENTION -> "Mentioned in logs"
            }
            listOf(e.medicationName, change, e.dateLabel.ifBlank { "date as written: n/a" }, e.evidence)
        }
        drawTable(w, listOf("Medication", "Change", "Date", "Evidence"), rows, body, bold)
        w.y += 10f

        // Before/after comparisons: deterministic 14-day windows, sleep + heart
        // rate, correlation language only. Cap at 4 events so long histories
        // don't pad the report.
        val dated = events.filter { it.dateMs != null }.take(4)
        if (dated.isEmpty()) {
            drawWrapped(
                "No recorded change had a usable date, so before/after windows could not be computed.",
                w.margin, w.contentWidth, w, body, bold, italic
            )
            return
        }
        val sleepPts = seriesToPoints(snapshot.sleepSeries.map { it.first to it.second.toDouble() })
            .map { (ms, m) -> ms to m / 60.0 }
        val hrPts = seriesToPoints(snapshot.heartRateSeries.map { it.first to it.second.toDouble() })

        w.canvas.drawText("Before / after comparisons", w.margin, w.y, sec); w.y += 6f
        drawWrapped(
            "Each comparison shows the 14 days before vs the 14 days after a recorded change " +
                "(the change day itself is excluded). These are observed associations, not evidence of cause.",
            w.margin, w.contentWidth, w, caption, bold, italic
        )
        w.y += 6f

        val dateFmt = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US).withZone(zone)
        dated.forEach { event ->
            val others = events.filter { it != event }
            val label = "${event.medicationName} ${event.kind.label}"
            val dateText = dateFmt.format(Instant.ofEpochMilli(event.dateMs!!))
            val comparisons = listOfNotNull(
                sleepPts.takeIf { it.isNotEmpty() }?.let {
                    compareBeforeAfter(event.dateMs, label, dateText, "sleep", "h", it, 14, others)
                },
                hrPts.takeIf { it.isNotEmpty() }?.let {
                    compareBeforeAfter(event.dateMs, label, dateText, "heart rate", "bpm", it, 14, others)
                }
            )
            if (comparisons.isEmpty()) return@forEach
            w.ensureSpace(80f)
            w.canvas.drawText(label, w.margin, w.y, bold); w.y += 14f
            comparisons.forEach { c ->
                drawWrapped(describeComparison(c), w.margin, w.contentWidth, w, body, bold, italic)
                w.y += 4f
            }
            w.y += 8f
        }
    }

    // ── TABLES section ──

    private fun renderTables(
        w: PdfReportWriter,
        snapshot: ClinicalReportData,
        body: Paint, bold: Paint, italic: Paint, sec: Paint, caption: Paint
    ) {
        if (snapshot.medications.isEmpty() && snapshot.conditions.isEmpty()) return
        w.newPage()
        w.canvas.drawText("Medications & conditions", w.margin, w.y, sec); w.y += 6f

        if (snapshot.medications.isNotEmpty()) {
            w.canvas.drawText("Current medication list (as recorded)", w.margin, w.y, bold); w.y += 14f
            val rows = snapshot.medications.map { m ->
                listOf(
                    m.name.ifBlank { "—" },
                    m.dose.ifBlank { "—" },
                    m.frequency.ifBlank { "—" },
                    m.startedDate ?: "—",
                    m.endedDate ?: "present"
                )
            }
            drawTable(
                w, listOf("Medication", "Dose", "Frequency", "Started", "Ended"),
                rows, body, bold
            )
            w.y += 4f
            drawWrapped(
                "Start/end dates are shown exactly as recorded. Dose history is not tracked — " +
                    "dose changes appear only as recorded mentions in logs (see Recorded changes).",
                w.margin, w.contentWidth, w, caption, bold, italic
            )
            w.y += 8f
        }

        if (snapshot.conditions.isNotEmpty()) {
            w.ensureSpace(60f)
            w.canvas.drawText("Recorded conditions", w.margin, w.y, bold); w.y += 14f
            snapshot.conditions.forEach { c ->
                w.ensureSpace(20f)
                w.canvas.drawText("• $c", w.margin + 8f, w.y, body); w.y += 15f
            }
            w.y += 6f
        }
    }

    // ── APPENDIX: methodology + detailed logs ──

    private fun renderAppendix(
        w: PdfReportWriter,
        snapshot: ClinicalReportData,
        effectiveSummary: String,
        zone: ZoneId,
        body: Paint, bold: Paint, italic: Paint, sec: Paint, caption: Paint, meta: Paint
    ) {
        w.newPage()
        w.canvas.drawText("Appendix A — Methodology", w.margin, w.y, sec); w.y += 6f
        val methodology = listOf(
            "One immutable snapshot feeds the preview, the statistics, the AI narrative, and this PDF, " +
                "so every number in this report was computed from the same data.",
            "Focus '${snapshot.focusKey}' filtered log entries to " +
                "${snapshot.logEntries.size} entries across the selected categories.",
            "Long histories are aggregated into daily, weekly, or monthly buckets (labeled on each chart); " +
                "individual entries are never silently dropped to fit.",
            "Missing data is shown as gaps, never as zero. A day with no symptom entry is not a symptom-free day.",
            "Medication dose changes are extracted from log text by keyword matching and labeled " +
                "'recorded mention in logs'. Doses, dates, and adherence are never invented.",
            "Before/after comparisons use fixed 14-day windows and describe observed associations only — " +
                "never causation. Heart-rate rises are never labeled orthostatic from a rise alone.",
            "All chart values and statistics are computed in deterministic on-device code; " +
                "the AI narrative explains them without inventing values."
        )
        methodology.forEach { line ->
            w.ensureSpace(40f)
            drawWrapped("• $line", w.margin, w.contentWidth, w, body, bold, italic)
            w.y += 3f
        }
        w.y += 8f

        w.canvas.drawText("Data availability by source", w.margin, w.y, sec); w.y += 15f
        if (snapshot.sectionMetadata.isEmpty()) {
            drawWrapped("No source metadata recorded.", w.margin, w.contentWidth, w, body, bold, italic)
        } else {
            val rows = snapshot.sectionMetadata
                .filter { (k, _) -> k != "previewMode" }
                .map { (key, m) ->
                    val statusText = when (m.status) {
                        DataSourceStatus.SUCCESS -> "Available (${m.recordCount} records)"
                        DataSourceStatus.NO_DATA -> "No data recorded"
                        DataSourceStatus.PERMISSION_DENIED -> "Unavailable — permission not granted"
                        DataSourceStatus.UNAVAILABLE -> "Unavailable — could not be retrieved"
                        DataSourceStatus.TIMED_OUT -> "Unavailable — could not be retrieved"
                        DataSourceStatus.ERROR -> "Unavailable — could not be retrieved"
                    }
                    val note = m.message?.take(140)?.let { " — $it" } ?: ""
                    listOf(key.replaceFirstChar { it.uppercase() }, statusText + note)
                }
            drawTable(w, listOf("Source", "Status"), rows, body, bold, colWeights = floatArrayOf(0.28f, 0.72f))
        }
        w.y += 10f

        // Detailed logs: most recent 150, never padded, never crammed.
        w.canvas.drawText("Appendix B — Detailed log entries", w.margin, w.y, sec); w.y += 6f
        val sorted = snapshot.logEntries.sortedByDescending { it.timestamp }
        if (sorted.isEmpty()) {
            drawWrapped("No log entries in this range.", w.margin, w.contentWidth, w, body, bold, italic)
            return
        }
        val shown = sorted.take(150)
        drawWrapped(
            "Showing the ${shown.size} most recent of ${sorted.size} entries in range " +
                "(newest first). Body text truncated to 200 characters.",
            w.margin, w.contentWidth, w, caption, bold, italic
        )
        w.y += 6f
        val entryFmt = DateTimeFormatter.ofPattern("MMM d, yyyy h:mm a", Locale.US).withZone(zone)
        shown.forEach { e ->
            w.ensureSpace(34f)
            val catName = snapshot.categoriesMap[e.categoryId] ?: "Category ${e.categoryId}"
            val whenStr = entryFmt.format(Instant.ofEpochMilli(e.timestamp))
            val text = "$whenStr — $catName: ${(e.body.ifBlank { e.manualText }).take(200)}"
            drawWrapped(text, w.margin, w.contentWidth, w, body, bold, italic)
            w.y += 3f
            w.canvas.drawLine(w.margin, w.y, w.margin + w.contentWidth, w.y, Paint().apply {
                color = hairline; strokeWidth = 0.75f
            })
            w.y += 9f
        }
    }

    // ── AI summary renderer (kept markup: [SECTION]/[BULLET]/[BOLD]/[ITALIC]) ──

    private fun renderAiSummary(
        w: PdfReportWriter,
        effectiveSummary: String,
        body: Paint, bold: Paint, italic: Paint, sec: Paint, caption: Paint
    ) {
        effectiveSummary.split("\n").forEach { rawLine ->
            val line = rawLine.trimEnd()
            if (line.isBlank()) {
                w.y += 6f
                return@forEach
            }
            w.ensureSpace(40f)
            when {
                line.contains("[SECTION]") -> {
                    w.y += 8f
                    val clean = line.replace("[SECTION]", "").replace("[BOLD]", "")
                        .replace("*", "").replace("#", "").trim()
                    wrapText(clean, w.contentWidth, sec).forEach { part ->
                        w.ensureSpace(22f)
                        w.canvas.drawText(part, w.margin, w.y, sec)
                        w.y += 17f
                    }
                    w.canvas.drawLine(w.margin, w.y - 4f, w.margin + 60f, w.y - 4f,
                        Paint(sec).apply { strokeWidth = 2f })
                    w.y += 10f
                }
                line.contains("[BULLET]") -> {
                    val clean = line.replace("[BULLET]", "").replace("*", "")
                        .replace("#", "").trim().removePrefix("-").trim()
                    drawWrapped("• $clean", w.margin + 12f, w.contentWidth - 12f, w, body, bold, italic)
                    w.y += 4f
                }
                else -> {
                    drawWrapped(line.replace("#", ""), w.margin, w.contentWidth, w, body, bold, italic)
                    w.y += 4f
                }
            }
        }
        w.y += 6f
    }

    // ── Drawing primitives ──

    /** Wrapped body text with [BOLD]/[ITALIC] inline markers; advances w.y. */
    private fun drawWrapped(
        text: String,
        x: Float,
        width: Float,
        w: PdfReportWriter,
        paint: Paint,
        boldPaint: Paint,
        italicPaint: Paint,
        lineHeight: Float = 15f
    ) {
        wrapText(text, width, paint).forEach { line ->
            w.ensureSpace(lineHeight + 6f)
            var cx = x
            var isBold = false
            var isItalic = false
            var lastEnd = 0
            val regex = "\\[BOLD\\]|\\[ITALIC\\]".toRegex()
            regex.findAll(line).forEach { m ->
                val segment = line.substring(lastEnd, m.range.first)
                if (segment.isNotEmpty()) {
                    val p = if (isBold) boldPaint else if (isItalic) italicPaint else paint
                    w.canvas.drawText(segment, cx, w.y, p)
                    cx += p.measureText(segment)
                }
                if (m.value == "[BOLD]") isBold = !isBold else isItalic = !isItalic
                lastEnd = m.range.last + 1
            }
            val rest = line.substring(lastEnd)
            if (rest.isNotEmpty()) {
                val p = if (isBold) boldPaint else if (isItalic) italicPaint else paint
                w.canvas.drawText(rest, cx, w.y, p)
            }
            w.y += lineHeight
        }
    }

    /** Truncates [text] to fit [maxWidth] at a word boundary; never mid-word. */
    private fun truncateToWords(text: String, paint: Paint, maxWidth: Float): String {
        if (paint.measureText(text) <= maxWidth) return text
        val ellipsisW = paint.measureText("…")
        var acc = ""
        for (word in text.split(' ')) {
            val trial = if (acc.isEmpty()) word else "$acc $word"
            if (paint.measureText(trial) + ellipsisW > maxWidth) break
            acc = trial
        }
        return (acc.ifBlank { text.take(18) }) + "…"
    }

    /**
     * Bucketed line chart: the polyline BREAKS at gap buckets (missing data
     * is never interpolated). Event markers are dashed verticals with short
     * labels; x labels are collision-checked.
     */
    private fun drawPdfLineChart(
        w: PdfReportWriter,
        title: String,
        buckets: List<ChartBucket>,
        colorHex: String,
        events: List<MedicationChangeEvent>,
        unit: String,
        captionText: String
    ) {
        val titlePaint = paint(ink, 13f, bold = true)
        val labelPaint = paint(gray, 8f)
        val capPaint = paint(gray, 9f, italic = true)
        w.canvas.drawText(title, w.margin, w.y, titlePaint)
        w.y += 6f

        val chartX = w.margin + 38f
        val chartY = w.y + 14f
        val chartW = w.contentWidth - 48f
        val chartH = 150f
        val color = Color.parseColor(colorHex)

        val withData = buckets.filter { it.hasData }
        if (withData.size < 2) {
            w.canvas.drawText("Not enough data to display.", chartX, chartY + 40f, paint(gray, 10f, italic = true))
            w.y = chartY + chartH + 30f
            return
        }

        val vals = withData.map { it.mean!! }
        val pad = (vals.maxOrNull()!! - vals.minOrNull()!!).coerceAtLeast(1.0) * 0.12
        val lo = vals.minOrNull()!! - pad
        val hi = vals.maxOrNull()!! + pad
        val span = (buckets.last().endMs - buckets.first().startMs).coerceAtLeast(1L)
        fun xFor(ms: Long) = chartX + ((ms - buckets.first().startMs).toFloat() / span) * chartW
        fun yFor(v: Double) = (chartY + chartH - ((v - lo) / (hi - lo)).toFloat() * chartH)

        val grid = Paint().apply { color = hairline; strokeWidth = 1f }
        for (i in 0..3) {
            val ratio = i / 3f
            val gy = chartY + chartH * (1f - ratio)
            w.canvas.drawLine(chartX, gy, chartX + chartW, gy, grid)
            w.canvas.drawText(String.format(Locale.US, "%.0f", lo + ratio * (hi - lo)), w.margin, gy + 3f, labelPaint)
        }
        w.canvas.drawText(unit, w.margin, chartY - 6f, labelPaint)

        // Event markers.
        val dash = android.graphics.DashPathEffect(floatArrayOf(5f, 4f), 0f)
        val markerPaint = Paint().apply {
            color = Color.rgb(160, 110, 20); strokeWidth = 1.25f; style = Paint.Style.STROKE
            pathEffect = dash
        }
        val markerLabel = paint(Color.rgb(160, 110, 20), 7.5f)
        // Event-marker labels: staggered on two rows so neighbors never
        // collide, each row collision-checked; truncated at word boundaries,
        // never mid-word.
        var row0Right = -Float.MAX_VALUE
        var row1Right = -Float.MAX_VALUE
        events.forEach { e ->
            val ms = e.dateMs ?: return@forEach
            if (ms < buckets.first().startMs || ms > buckets.last().endMs) return@forEach
            val ex = xFor(ms)
            val p = Path().apply { moveTo(ex, chartY - 12f); lineTo(ex, chartY + chartH) }
            w.canvas.drawPath(p, markerPaint)
            val label = truncateToWords(eventMarkerLabel(e), markerLabel, 120f)
            val lx = (ex + 3f).coerceAtMost(chartX + chartW - 120f)
            val right = lx + markerLabel.measureText(label)
            val baseline = if (lx > row0Right + 3f) {
                row0Right = right
                chartY - 4f
            } else if (lx > row1Right + 3f) {
                row1Right = right
                chartY - 14f
            } else {
                // Both rows occupied here: skip the label rather than draw it
                // on top of a neighbor.
                null
            }
            if (baseline != null) {
                w.canvas.drawText(label, lx, baseline, markerLabel)
            }
        }

        // X labels: up to 6, collision-checked (never overlapping).
        val xPaint = paint(gray, 7.5f).apply { textAlign = Paint.Align.CENTER }
        val step = (buckets.size / 5).coerceAtLeast(1)
        var lastRight = -Float.MAX_VALUE
        fun xLabel(i: Int) {
            val b = buckets[i]
            val cx = xFor((b.startMs + b.endMs) / 2)
            val half = xPaint.measureText(b.label) / 2f
            if (cx - half > lastRight + 3f) {
                w.canvas.drawText(b.label, cx, chartY + chartH + 11f, xPaint)
                lastRight = cx + half
            }
        }
        for (i in buckets.indices step step) xLabel(i)
        if ((buckets.size - 1) % step != 0) xLabel(buckets.size - 1)

        // Polyline segments (broken at gaps) + points.
        val linePaint = Paint().apply { color = color; strokeWidth = 2f; style = Paint.Style.STROKE; isAntiAlias = true }
        val fillPaint = Paint().apply { color = color; alpha = 22; style = Paint.Style.FILL; isAntiAlias = true }
        var seg = mutableListOf<PointF>()
        fun flush() {
            if (seg.size >= 2) {
                val path = Path().apply {
                    moveTo(seg[0].x, seg[0].y); seg.drop(1).forEach { lineTo(it.x, it.y) }
                }
                val fill = Path(path).apply {
                    lineTo(seg.last().x, chartY + chartH); lineTo(seg[0].x, chartY + chartH); close()
                }
                w.canvas.drawPath(fill, fillPaint)
                w.canvas.drawPath(path, linePaint)
            }
            seg = mutableListOf()
        }
        buckets.forEach { b ->
            if (b.hasData) seg.add(PointF(xFor((b.startMs + b.endMs) / 2), yFor(b.mean!!))) else flush()
        }
        flush()
        val dotPaint = Paint().apply { color = color; style = Paint.Style.FILL; isAntiAlias = true }
        val dotBorder = Paint().apply { color = Color.WHITE; style = Paint.Style.FILL; isAntiAlias = true }
        if (withData.size <= 60) {
            withData.forEach { b ->
                val p = PointF(xFor((b.startMs + b.endMs) / 2), yFor(b.mean!!))
                w.canvas.drawCircle(p.x, p.y, 3f, dotBorder)
                w.canvas.drawCircle(p.x, p.y, 1.8f, dotPaint)
            }
        }

        w.y = chartY + chartH + 26f
        drawWrapped(captionText, w.margin, w.contentWidth, w, capPaint, paint(ink, 9f, bold = true), capPaint, 13f)
        w.y += 10f
    }

    /** Bucketed bar chart for counts; zero buckets are honest zeros. */
    private fun drawPdfBarChart(
        w: PdfReportWriter,
        title: String,
        buckets: List<CountBucket>,
        colorHex: String,
        events: List<MedicationChangeEvent>,
        unit: String,
        captionText: String
    ) {
        val titlePaint = paint(ink, 13f, bold = true)
        val labelPaint = paint(gray, 8f)
        val capPaint = paint(gray, 9f, italic = true)
        w.canvas.drawText(title, w.margin, w.y, titlePaint)
        w.y += 6f

        val chartX = w.margin + 34f
        val chartY = w.y + 14f
        val chartW = w.contentWidth - 44f
        val chartH = 150f
        val color = Color.parseColor(colorHex)

        val maxC = buckets.maxOfOrNull { it.count }?.coerceAtLeast(1) ?: 1
        val slot = chartW / buckets.size.coerceAtLeast(1)
        val barW = (slot * 0.62f).coerceAtLeast(2f)

        val grid = Paint().apply { color = hairline; strokeWidth = 1f }
        w.canvas.drawLine(chartX, chartY, chartX + chartW, chartY, grid)
        w.canvas.drawText(maxC.toString(), w.margin, chartY + 3f, labelPaint)
        w.canvas.drawLine(chartX, chartY + chartH, chartX + chartW, chartY + chartH, grid)
        w.canvas.drawText("0", w.margin, chartY + chartH + 3f, labelPaint)
        w.canvas.drawText(unit, w.margin, chartY - 6f, labelPaint)

        val span = (buckets.last().endMs - buckets.first().startMs).coerceAtLeast(1L)
        val dash = android.graphics.DashPathEffect(floatArrayOf(5f, 4f), 0f)
        val markerPaint = Paint().apply {
            color = Color.rgb(160, 110, 20); strokeWidth = 1.25f; style = Paint.Style.STROKE
            pathEffect = dash
        }
        events.forEach { e ->
            val ms = e.dateMs ?: return@forEach
            if (ms < buckets.first().startMs || ms > buckets.last().endMs) return@forEach
            val ex = chartX + ((ms - buckets.first().startMs).toFloat() / span) * chartW
            val p = Path().apply { moveTo(ex, chartY - 12f); lineTo(ex, chartY + chartH) }
            w.canvas.drawPath(p, markerPaint)
        }

        val barPaint = Paint().apply { color = color; alpha = 215; style = Paint.Style.FILL }
        buckets.forEachIndexed { i, b ->
            val bh = (b.count.toFloat() / maxC) * chartH
            if (bh > 0.5f) {
                val cx = chartX + slot * i + slot / 2f
                w.canvas.drawRect(cx - barW / 2f, chartY + chartH - bh, cx + barW / 2f, chartY + chartH, barPaint)
            }
        }

        val xPaint = paint(gray, 7.5f).apply { textAlign = Paint.Align.CENTER }
        val step = (buckets.size / 5).coerceAtLeast(1)
        var lastRight = -Float.MAX_VALUE
        fun xLabel(i: Int) {
            val cx = chartX + slot * i + slot / 2f
            val label = buckets[i].label
            val half = xPaint.measureText(label) / 2f
            if (cx - half > lastRight + 3f) {
                w.canvas.drawText(label, cx, chartY + chartH + 11f, xPaint)
                lastRight = cx + half
            }
        }
        for (i in buckets.indices step step) xLabel(i)
        if ((buckets.size - 1) % step != 0) xLabel(buckets.size - 1)

        w.y = chartY + chartH + 26f
        drawWrapped(captionText, w.margin, w.contentWidth, w, capPaint, paint(ink, 9f, bold = true), capPaint, 13f)
        w.y += 10f
    }

    /**
     * Simple wrapped table: header row with purple fill, hairline row
     * separators, cells wrapped to their column. Reused by events, symptoms,
     * medications, and appendix tables.
     */
    private fun drawTable(
        w: PdfReportWriter,
        headers: List<String>,
        rows: List<List<String>>,
        body: Paint,
        bold: Paint,
        colWeights: FloatArray? = null
    ) {
        if (rows.isEmpty()) return
        val n = headers.size
        val weights = colWeights ?: FloatArray(n) { 1f / n }
        val colW = FloatArray(n) { i -> w.contentWidth * weights[i] }
        val pad = 6f
        val lineH = 14f

        fun rowHeight(cells: List<String>, p: Paint): Float {
            var max = 1
            cells.forEachIndexed { i, c ->
                max = maxOf(max, wrapText(c, colW[i] - pad * 2, p).size)
            }
            return max * lineH + pad
        }

        // Header
        w.ensureSpace(rowHeight(headers, bold) + 8f)
        val headerBg = Paint().apply { color = purple; style = Paint.Style.FILL }
        val headerH = rowHeight(headers, bold)
        w.canvas.drawRect(w.margin, w.y - 11f, w.margin + w.contentWidth, w.y - 11f + headerH, headerBg)
        val whiteBold = paint(Color.WHITE, 10f, bold = true)
        var hxx = w.margin
        headers.forEachIndexed { i, h ->
            // Header labels are short; single baseline each.
            w.canvas.drawText(h, hxx + pad, w.y, whiteBold)
            hxx += colW[i]
        }
        w.y += headerH - 2f

        // Rows
        val sep = Paint().apply { color = hairline; strokeWidth = 0.75f }
        rows.forEach { cells ->
            val rh = rowHeight(cells, body)
            w.ensureSpace(rh + 4f)
            var cx = w.margin
            cells.forEachIndexed { i, c ->
                var cy = w.y
                wrapText(c, colW[i] - pad * 2, body).forEach { part ->
                    w.canvas.drawText(part, cx + pad, cy, body)
                    cy += lineH
                }
                cx += colW[i]
            }
            w.y += rh
            w.canvas.drawLine(w.margin, w.y - 4f, w.margin + w.contentWidth, w.y - 4f, sep)
            w.y += 4f
        }
        w.y += 6f
    }

    private fun wrapText(text: String, width: Float, paint: Paint): List<String> {
        val words = text.split(" ")
        val lines = mutableListOf<String>()
        var currentLine = StringBuilder()

        for (word in words) {
            val testLine = if (currentLine.isEmpty()) word else "${currentLine} $word"
            if (paint.measureText(testLine) <= width) {
                currentLine.append(if (currentLine.isEmpty()) word else " $word")
            } else {
                if (paint.measureText(word) > width) {
                    if (currentLine.isNotEmpty()) {
                        lines.add(currentLine.toString())
                        currentLine = StringBuilder()
                    }
                    var remainingWord = word
                    while (paint.measureText(remainingWord) > width) {
                        val subCount = paint.breakText(remainingWord, true, width, null)
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
     * Permanent storage in Downloads folder via MediaStore. Returns the
     * content URI string for durable saved-report references (WS-G).
     */
    private fun saveToDownloads(file: File, fileName: String): String? {
        return try {
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
                it.toString()
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "saveToDownloads failed", e)
            null
        }
    }

    /**
     * Generates an AI Biometric Graph Analysis Report as a styled PDF document
     * and saves it to the device's Downloads folder. (Kept as-is.)
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
            android.util.Log.e(TAG, "checkPageBreak failed", e)
            return null
        } finally {
            pdfDocument.close()
        }

        return cacheFile
    }
}
