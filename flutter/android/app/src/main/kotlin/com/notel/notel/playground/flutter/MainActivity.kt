package com.notel.notel.playground.flutter

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.os.SystemClock
import android.speech.RecognizerIntent
import androidx.core.content.ContextCompat
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.BasalMetabolicRateRecord
import androidx.health.connect.client.records.BloodPressureRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.HeightRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.PowerRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.AggregateGroupByDurationRequest
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/// Round 12: Health Connect bridge for the connections screen (and future
/// onboarding connections step).
///
/// NOTE: extends FlutterFragmentActivity (not FlutterActivity) because the
/// permission launcher needs ComponentActivity's ActivityResultRegistry —
/// plain FlutterActivity extends android.app.Activity, which has none.
///
/// Team-lessons applied (see ~/workspace/team/memory/LESSONS.md):
/// - Permission launcher registered in onCreate() via activityResultRegistry
///   (NOT in configureFlutterEngine — the fragment transaction timing there
///   can throw or silently never fire).
/// - Runtime request set = the 14 record-type reads + HISTORY, exactly like
///   the native app. READ_HEALTH_DATA_IN_BACKGROUND is never in this set.
/// - No silent failures: every error path returns a visible error code.
/// - Stuck-request guard: an in-flight request older than the timeout is
///   superseded, never stacked; Dart can also explicitly cancel.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        const val HC_CHANNEL = "com.notel.notel.playground.flutter/health_connect"
        const val VOICE_CHANNEL = "com.notel.notel.playground.flutter/voice"
        const val FILE_PICKER_CHANNEL = "com.notel.notel.playground.flutter/file_picker"
        const val CALENDAR_CHANNEL = "com.notel.notel.playground.flutter/calendar"
        // Round 48: BP CSV import cap, same as native MAX_CSV_FILE_BYTES.
        private const val MAX_CSV_FILE_BYTES = 5 * 1024 * 1024
        const val HC_PROVIDER_PACKAGE = "com.google.android.apps.healthdata"
        const val SETTINGS_ACTION = "android.health.connect.action.HEALTH_HOME_SETTINGS"
        private const val REQUEST_TIMEOUT_MS = 5 * 60 * 1000L
    }

    // Must stay in sync with HealthConnectService.requiredPermissions (Dart).
    private val hcPermissions: Set<String> by lazy {
        setOf(
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class),
            HealthPermission.getReadPermission(StepsRecord::class),
            HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(TotalCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(BasalMetabolicRateRecord::class),
            HealthPermission.getReadPermission(WeightRecord::class),
            HealthPermission.getReadPermission(HeightRecord::class),
            HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
            HealthPermission.getReadPermission(RespiratoryRateRecord::class),
            HealthPermission.getReadPermission(OxygenSaturationRecord::class),
            HealthPermission.getReadPermission(RestingHeartRateRecord::class),
            HealthPermission.getReadPermission(PowerRecord::class),
            HealthPermission.getReadPermission(BloodPressureRecord::class),
            "android.permission.health.READ_HEALTH_DATA_HISTORY"
        )
    }

    private lateinit var permissionLauncher: ActivityResultLauncher<Set<String>>
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSince: Long = 0L

    // Round 19: voice-input launcher for the Quick Log mic button.
    // Registered in onCreate (same rule as the HC permission launcher —
    // never in configureFlutterEngine). Intent-based recognition needs
    // no RECORD_AUDIO permission.
    private lateinit var voiceLauncher: ActivityResultLauncher<Intent>
    private var pendingVoiceResult: MethodChannel.Result? = null

    // Round 48: CSV file picker for the Blood Pressure import flow.
    // GetContent mirrors native BloodPressureScreen's SAF picker
    // ("*/*" so exports the system doesn't label as CSV are still
    // pickable; the Dart-side parser validates the content).
    private lateinit var csvPickerLauncher: ActivityResultLauncher<String>
    private var pendingCsvResult: MethodChannel.Result? = null

    // Round 54: calendar permission launcher for the Health Coach
    // (native CoachScreen.kt:89-113 requests READ+WRITE together at
    // first approve). Registered in onCreate like the HC launcher.
    private lateinit var calendarPermissionLauncher: ActivityResultLauncher<Array<String>>
    private var pendingCalendarResult: MethodChannel.Result? = null
    private var pendingCalendarSince: Long = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Registered here in onCreate — never in configureFlutterEngine()
        // (the fragment-transaction timing there can throw or silently never
        // fire). Same semantics as Compose's rememberLauncherForActivityResult.
        permissionLauncher = activityResultRegistry.register(
            "hc_permission_launcher",
            PermissionController.createRequestPermissionResultContract()
        ) { granted: Set<String> ->
            val r = pendingResult
            pendingResult = null
            if (r == null) return@register // stale (timed out / cancelled / superseded)
            try {
                r.success(granted.toList())
            } catch (_: Exception) {
                // Result already consumed — nothing to do.
            }
        }
        voiceLauncher = activityResultRegistry.register(
            "voice_input_launcher",
            ActivityResultContracts.StartActivityForResult()
        ) { result ->
            val r = pendingVoiceResult
            pendingVoiceResult = null
            if (r == null) return@register // stale (superseded)
            try {
                if (result.resultCode == RESULT_OK) {
                    val text = result.data
                        ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                        ?.firstOrNull()
                    if (!text.isNullOrBlank()) {
                        r.success(text)
                    } else {
                        r.error("VOICE_EMPTY", "No speech was recognized", null)
                    }
                } else {
                    r.error("VOICE_CANCELLED", "Voice input cancelled", null)
                }
            } catch (_: Exception) {
                // Result already consumed — nothing to do.
            }
        }
        csvPickerLauncher = activityResultRegistry.register(
            "csv_picker_launcher",
            ActivityResultContracts.GetContent()
        ) { uri ->
            val r = pendingCsvResult
            pendingCsvResult = null
            if (r == null) return@register // stale (superseded)
            if (uri == null) {
                // User cancelled the picker — a null success, not an
                // error (Dart treats null as "no file chosen").
                try { r.success(null) } catch (_: Exception) { }
                return@register
            }
            // Read off the main thread with the native 5 MB cap
            // (native readCsvTextCapped semantics: TooLarge / Failed
            // / Ok-with-BOM-stripped).
            Thread {
                var failureCode: String? = null
                var failureMessage: String? = null
                var text: String? = null
                try {
                    val stream = contentResolver.openInputStream(uri)
                    if (stream == null) {
                        failureCode = "READ_FAILED"
                        failureMessage = "Couldn't read this file. Please try a different CSV."
                    } else {
                        stream.use { input ->
                            val buf = ByteArray(8192)
                            var total = 0
                            val out = java.io.ByteArrayOutputStream()
                            var tooLarge = false
                            while (true) {
                                val n = input.read(buf)
                                if (n == -1) break
                                total += n
                                if (total > MAX_CSV_FILE_BYTES) {
                                    tooLarge = true
                                    break
                                }
                                out.write(buf, 0, n)
                            }
                            if (tooLarge) {
                                failureCode = "TOO_LARGE"
                                failureMessage = "This file is too large to import. The limit is 5 MB."
                            } else {
                                text = out.toString(Charsets.UTF_8.name()).removePrefix("\uFEFF")
                            }
                        }
                    }
                } catch (e: Exception) {
                    failureCode = "READ_FAILED"
                    failureMessage = "Couldn't read this file. Please try a different CSV."
                }
                runOnUiThread {
                    // Snapshot: failureCode is mutated in this (capturing)
                    // scope, so a smart cast on it cannot hold here.
                    val code = failureCode
                    try {
                        if (code != null) {
                            r.error(code, failureMessage, null)
                        } else {
                            r.success(text)
                        }
                    } catch (_: Exception) {
                        // Result already consumed — nothing to do.
                    }
                }
            }.start()
        }
        calendarPermissionLauncher = activityResultRegistry.register(
            "calendar_permission_launcher",
            ActivityResultContracts.RequestMultiplePermissions()
        ) { _ ->
            val r = pendingCalendarResult
            pendingCalendarResult = null
            if (r == null) return@register // stale (timed out / cancelled / superseded)
            try {
                r.success(calendarPermissionStatusMap())
            } catch (_: Exception) {
                // Result already consumed — nothing to do.
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HC_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> checkAvailability(result)
                    "requestPermissions" -> requestHcPermissions(result)
                    "cancelRequest" -> cancelPendingRequest(result)
                    "getGrantedPermissions" -> getGrantedPermissions(result)
                    "openHealthConnectSettings" -> openSettings(result)
                    // Round 13: typed Health Connect reads.
                    "readHeartRateSamples" -> readHeartRateSamples(call.argument<String>("dateStr"), result)
                    "readActiveCalories" -> readActiveCalories(call.argument<String>("dateStr"), result)
                    "readSleepMinutes" -> readSleepMinutes(call.argument<String>("dateStr"), result)
                    "readSleepStages" -> readSleepStages(call.argument<String>("dateStr"), result)
                    "readRestingHeartRate" -> readRestingHeartRate(call.argument<String>("dateStr"), result)
                    "readRestingHrHistory" -> readRestingHrHistory(call.argument<Int>("days"), result)
                    "readCaloriesHistory" -> readCaloriesHistory(call.argument<Int>("days"), result)
                    "readBloodPressure" -> readBloodPressure(call.argument<Int>("days"), result)
                    "readSteps" -> readSteps(call.argument<String>("dateStr"), result)
                    // Round 30: profile Auto-Fill reads (native
                    // HealthConnectManager.readLatestWeight/readLatestHeight).
                    "readLatestWeightKg" -> readLatestWeightKg(result)
                    "readLatestHeightCm" -> readLatestHeightCm(result)
                    // Round 48: Key Metrics reads (native
                    // HealthConnectManager.readRespiratoryRate /
                    // readOxygenSaturation / readHeartRateVariability),
                    // range reads for the Sleep picker + CSV export
                    // (readHistoricalSleepWithDeep /
                    // readHistoricalHeartRateWithSpikes), and the CSV
                    // export file hand-off (native exportMetricsCsvAsync:
                    // Downloads copy + share sheet).
                    "readRespiratoryRate" -> readRespiratoryRate(call.argument<String>("dateStr"), result)
                    "readOxygenSaturation" -> readOxygenSaturation(call.argument<String>("dateStr"), result)
                    "readHrvRmssd" -> readHrvRmssd(call.argument<String>("dateStr"), result)
                    "readSleepHistory" -> readSleepHistory(call.argument<Int>("days"), result)
                    "readSpikeCounts" -> readSpikeCounts(call.argument<Int>("days"), result)
                    "exportCsvFile" -> exportCsvFile(
                        call.argument<String>("fileName"),
                        call.argument<String>("content"),
                        result
                    )
                    else -> result.notImplemented()
                }
            }
        // Round 19: voice input for the Quick Log mic button.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVoiceInput" -> startVoiceInput(result)
                    else -> result.notImplemented()
                }
            }
        // Round 48: SAF text-file picker for the Blood Pressure CSV
        // import (native BloodPressureScreen launches "*/*" too).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PICKER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickCsvText" -> pickCsvText(result)
                    else -> result.notImplemented()
                }
            }
        // Round 54: device calendar bridge for the Health Coach
        // (native CoachViewModel calendar paths, ported below).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALENDAR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPermissionStatus" -> result.success(calendarPermissionStatusMap())
                    "requestPermissions" -> requestCalendarPermissions(result)
                    "cancelRequest" -> cancelPendingCalendarRequest(result)
                    "listWritableCalendars" -> listWritableCalendars(result)
                    "insertEvent" -> insertCalendarEvent(
                        call.argument<String>("title"),
                        call.argument<String>("date"),
                        call.argument<String>("time"),
                        call.argument<String>("description"),
                        call.argument<String>("connectedEmail"),
                        result
                    )
                    "deleteEvents" -> deleteCalendarEvents(
                        call.argument<String>("title"),
                        call.argument<String>("date"),
                        result
                    )
                    "getUpcomingEvents" -> getUpcomingCalendarEvents(result)
                    else -> result.notImplemented()
                }
            }
    }

    /// Round 48: launches the system file picker and returns the
    /// picked file's text to Dart (null when the user cancels).
    /// Every failure path returns a visible error code — never a
    /// silent no-op.
    private fun pickCsvText(result: MethodChannel.Result) {
        if (pendingCsvResult != null) {
            result.error("IN_FLIGHT", "A file pick is already in progress", null)
            return
        }
        pendingCsvResult = result
        try {
            csvPickerLauncher.launch("*/*")
        } catch (e: Exception) {
            pendingCsvResult = null
            result.error("LAUNCH_FAILED", "Couldn't open the file picker.", null)
        }
    }

    /// Round 19: launches the system speech recognizer and returns the top
    /// result to Dart. Every failure path returns a visible error code —
    /// never a silent no-op (team lesson: silent channel failures).
    private fun startVoiceInput(result: MethodChannel.Result) {
        if (pendingVoiceResult != null) {
            result.error("IN_FLIGHT", "Voice input already in progress", null)
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak your note")
        }
        if (intent.resolveActivity(packageManager) == null) {
            result.error("NO_VOICE_APP", "No voice input app found on this device", null)
            return
        }
        pendingVoiceResult = result
        try {
            voiceLauncher.launch(intent)
        } catch (e: Exception) {
            pendingVoiceResult = null
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    private fun checkAvailability(result: MethodChannel.Result) {
        try {
            val status = HealthConnectClient.getSdkStatus(this, HC_PROVIDER_PACKAGE)
            result.success(status == HealthConnectClient.SDK_AVAILABLE)
        } catch (e: Exception) {
            result.error("AVAILABILITY_CHECK_FAILED", e.message, null)
        }
    }

    private fun requestHcPermissions(result: MethodChannel.Result) {
        val now = SystemClock.elapsedRealtime()
        val pending = pendingResult
        if (pending != null) {
            if (now - pendingSince < REQUEST_TIMEOUT_MS) {
                result.error(
                    "IN_FLIGHT",
                    "A Health Connect permission request is already in progress.",
                    null
                )
                return
            }
            // Stale: supersede so a wedged request never blocks future ones.
            try {
                pending.error("SUPERSEDED", "Superseded by a newer request.", null)
            } catch (_: Exception) {
            }
            pendingResult = null
        }
        if (!::permissionLauncher.isInitialized) {
            result.error("NO_LAUNCHER", "Permission launcher is not registered.", null)
            return
        }
        // Round 12b: never launch with an empty set — Health Connect closes
        // immediately with an empty result, which is indistinguishable from a
        // user deny. Fail visibly instead.
        if (hcPermissions.isEmpty()) {
            result.error(
                "EMPTY_PERMISSION_SET",
                "No Health Connect permissions configured to request.",
                null
            )
            return
        }
        try {
            val status = HealthConnectClient.getSdkStatus(this, HC_PROVIDER_PACKAGE)
            if (status != HealthConnectClient.SDK_AVAILABLE) {
                result.error(
                    "HC_UNAVAILABLE",
                    "Health Connect is not available on this device.",
                    null
                )
                return
            }
        } catch (e: Exception) {
            result.error("AVAILABILITY_CHECK_FAILED", e.message, null)
            return
        }
        pendingResult = result
        pendingSince = now
        try {
            permissionLauncher.launch(hcPermissions)
        } catch (e: Exception) {
            pendingResult = null
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    private fun cancelPendingRequest(result: MethodChannel.Result) {
        val pending = pendingResult
        pendingResult = null
        if (pending != null) {
            try {
                pending.error("CANCELLED", "Request cancelled.", null)
            } catch (_: Exception) {
            }
        }
        result.success(true)
    }

    private fun getGrantedPermissions(result: MethodChannel.Result) {
        val client = try {
            HealthConnectClient.getOrCreate(this)
        } catch (e: Exception) {
            result.error("CLIENT_UNAVAILABLE", e.message, null)
            return
        }
        lifecycleScope.launch {
            try {
                val granted = client.permissionController.getGrantedPermissions()
                result.success(granted.toList())
            } catch (e: Exception) {
                result.error("GRANTED_CHECK_FAILED", e.message, null)
            }
        }
    }

    private fun openSettings(result: MethodChannel.Result) {
        try {
            startActivity(Intent(SETTINGS_ACTION))
            result.success(true)
        } catch (e: Exception) {
            result.error("NO_SETTINGS", e.message, null)
        }
    }

    // ── Round 13: typed Health Connect reads ──────────────────────────────────
    // Ports of the native app's `data/healthconnect/HealthConnectManager.kt`
    // query patterns, exposed to Dart on the same channel.
    //
    // Rules (same as round 12 + the founder's data rules):
    // - Every suspend call runs in lifecycleScope.launch.
    // - Every failure returns result.error with a distinct visible code.
    // - "No data" is a successful null/empty result — never a fabricated
    //   number. Health VALUES are never logged.
    // - Mock/self records (package priority ≤ -100) are dropped everywhere,
    //   verbatim from the native app.

    private fun hcClientOrError(result: MethodChannel.Result): HealthConnectClient? {
        return try {
            HealthConnectClient.getOrCreate(this)
        } catch (e: Exception) {
            result.error("CLIENT_UNAVAILABLE", e.message, null)
            null
        }
    }

    private fun packagePriority(packageName: String): Int = when (packageName) {
        "com.fitbit.FitbitMobile" -> 100
        "com.ouraring.oura" -> 90
        "com.google.android.apps.fitness" -> 80
        "com.sec.android.app.shealth" -> 80
        "com.urbandroid.sleep" -> 70
        "com.sleepcycle.android" -> 70
        "com.notel.notel" -> -100
        else -> 0
    }

    private fun <T : Record> nonMock(records: List<T>): List<T> =
        records.filter { packagePriority(it.metadata.dataOrigin.packageName) > -100 }

    private fun localDateOf(dateStr: String?): LocalDate = try {
        if (dateStr == "today" || dateStr.isNullOrBlank()) LocalDate.now()
        else LocalDate.parse(dateStr)
    } catch (_: Exception) {
        LocalDate.now()
    }

    private fun dayRange(dateStr: String?): Pair<Instant, Instant> {
        val start = localDateOf(dateStr).atStartOfDay(ZoneId.systemDefault()).toInstant()
        return start to start.plus(1, ChronoUnit.DAYS)
    }

    private fun mergeIntervals(intervals: List<Pair<Instant, Instant>>): List<Pair<Instant, Instant>> {
        if (intervals.isEmpty()) return emptyList()
        val sorted = intervals.sortedBy { it.first }
        val result = mutableListOf<Pair<Instant, Instant>>()
        var current = sorted[0]
        for (i in 1 until sorted.size) {
            val next = sorted[i]
            if (next.first.isBefore(current.second) || next.first == current.second) {
                if (next.second.isAfter(current.second)) {
                    current = current.first to next.second
                }
            } else {
                result.add(current)
                current = next
            }
        }
        result.add(current)
        return result
    }

    /// Paginated intraday HR read; samples flattened, distinct by time,
    /// sorted ascending. Dart shape: [{t: epochMs, bpm}].
    private fun readHeartRateSamples(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (start, end) = dayRange(dateStr)
                val records = mutableListOf<HeartRateRecord>()
                var pageToken: String? = null
                do {
                    val response = client.readRecords(
                        ReadRecordsRequest(
                            recordType = HeartRateRecord::class,
                            timeRangeFilter = TimeRangeFilter.between(start, end),
                            pageToken = pageToken
                        )
                    )
                    records.addAll(response.records)
                    pageToken = response.pageToken
                } while (pageToken != null)
                val samples = nonMock(records)
                    .flatMap { record ->
                        record.samples.map { sample ->
                            sample.time.toEpochMilli() to sample.beatsPerMinute.toInt()
                        }
                    }
                    .distinctBy { it.first }
                    .sortedBy { it.first }
                result.success(samples.map { mapOf("t" to it.first, "bpm" to it.second) })
            } catch (_: Exception) {
                result.error("HR_SAMPLES_READ_FAILED", "Could not read heart rate samples.", null)
            }
        }
    }

    /// `active ?: total` kcal (native rule); null when both are null.
    private fun readActiveCalories(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (start, end) = dayRange(dateStr)
                val response = client.aggregate(
                    AggregateRequest(
                        metrics = setOf(
                            ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL,
                            TotalCaloriesBurnedRecord.ENERGY_TOTAL
                        ),
                        timeRangeFilter = TimeRangeFilter.between(start, end)
                    )
                )
                val active = response[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories?.toInt()
                val total = response[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories?.toInt()
                result.success(active ?: total)
            } catch (_: Exception) {
                result.error("CALORIES_READ_FAILED", "Could not read active calories.", null)
            }
        }
    }

    /// Sessions in [start-1day, end]; pick the session with endTime in
    /// [startOfDay, endOfDay+12h], highest package priority then longest
    /// duration; minutesAsleep = durationMinutes − merged awake-stage
    /// minutes (AWAKE, AWAKE_IN_BED, OUT_OF_BED). Null when no session.
    private fun readSleepMinutes(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (startOfDay, endOfDay) = dayRange(dateStr)
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = SleepSessionRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            startOfDay.minus(1, ChronoUnit.DAYS), endOfDay
                        )
                    )
                )
                var target: SleepSessionRecord? = null
                var maxPriority = -999
                var maxDuration = -1L
                for (session in nonMock(response.records)) {
                    if (session.endTime.isAfter(startOfDay) &&
                        session.endTime.isBefore(endOfDay.plus(12, ChronoUnit.HOURS))
                    ) {
                        val priority = packagePriority(session.metadata.dataOrigin.packageName)
                        val duration = ChronoUnit.MINUTES.between(session.startTime, session.endTime)
                        if (priority > maxPriority || (priority == maxPriority && duration > maxDuration)) {
                            maxPriority = priority
                            maxDuration = duration
                            target = session
                        }
                    }
                }
                val session = target
                if (session == null) {
                    result.success(null)
                    return@launch
                }
                val awakeIntervals = session.stages
                    .filter {
                        it.stage == SleepSessionRecord.STAGE_TYPE_AWAKE ||
                            it.stage == SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED ||
                            it.stage == SleepSessionRecord.STAGE_TYPE_OUT_OF_BED
                    }
                    .map { it.startTime to it.endTime }
                val awake = mergeIntervals(awakeIntervals)
                    .sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
                val minutesAsleep =
                    ChronoUnit.MINUTES.between(session.startTime, session.endTime).toInt() - awake
                result.success(minutesAsleep)
            } catch (_: Exception) {
                result.error("SLEEP_READ_FAILED", "Could not read sleep session.", null)
            }
        }
    }

    /// Round 18b — per-stage sleep breakdown for the Sleep Profile screen.
    /// Ports native `HealthConnectManager.readSleepSession` stage logic:
    /// best session (priority + duration), per-type merged intervals,
    /// `efficiency = totalAsleep / timeInBed * 100`.
    /// Returns a map {minutesAsleep, deepMinutes, lightMinutes,
    /// remMinutes, efficiency}, or null when no session. Never throws
    /// across the channel.
    private fun readSleepStages(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (startOfDay, endOfDay) = dayRange(dateStr)
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = SleepSessionRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            startOfDay.minus(1, ChronoUnit.DAYS), endOfDay
                        )
                    )
                )
                var target: SleepSessionRecord? = null
                var maxPriority = -999
                var maxDuration = -1L
                for (session in nonMock(response.records)) {
                    if (session.endTime.isAfter(startOfDay) &&
                        session.endTime.isBefore(endOfDay.plus(12, ChronoUnit.HOURS))
                    ) {
                        val priority = packagePriority(session.metadata.dataOrigin.packageName)
                        val duration = ChronoUnit.MINUTES.between(session.startTime, session.endTime)
                        if (priority > maxPriority || (priority == maxPriority && duration > maxDuration)) {
                            maxPriority = priority
                            maxDuration = duration
                            target = session
                        }
                    }
                }
                val session = target
                if (session == null) {
                    result.success(null)
                    return@launch
                }
                fun stageMinutes(vararg types: Int): Int {
                    val intervals = session.stages
                        .filter { it.stage in types }
                        .map { it.startTime to it.endTime }
                    return mergeIntervals(intervals)
                        .sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
                }
                val deep = stageMinutes(SleepSessionRecord.STAGE_TYPE_DEEP)
                val light = stageMinutes(SleepSessionRecord.STAGE_TYPE_LIGHT)
                val rem = stageMinutes(SleepSessionRecord.STAGE_TYPE_REM)
                val awake = stageMinutes(
                    SleepSessionRecord.STAGE_TYPE_AWAKE,
                    SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
                    SleepSessionRecord.STAGE_TYPE_OUT_OF_BED
                )
                val timeInBed =
                    ChronoUnit.MINUTES.between(session.startTime, session.endTime).toInt()
                val totalAsleep = timeInBed - awake
                val efficiency =
                    if (timeInBed > 0) ((totalAsleep.toFloat() / timeInBed.toFloat()) * 100).toInt() else 0
                result.success(
                    mapOf(
                        "minutesAsleep" to totalAsleep,
                        "deepMinutes" to deep,
                        "lightMinutes" to light,
                        "remMinutes" to rem,
                        "efficiency" to efficiency
                    )
                )
            } catch (_: Exception) {
                result.error("SLEEP_STAGES_READ_FAILED", "Could not read sleep stages.", null)
            }
        }
    }

    /// Non-mock records of the day, highest package priority, latest by
    /// time. Null when none.
    private fun readRestingHeartRate(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (start, end) = dayRange(dateStr)
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = RestingHeartRateRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(start, end)
                    )
                )
                val candidates = nonMock(response.records)
                if (candidates.isEmpty()) {
                    result.success(null)
                    return@launch
                }
                val maxPriority = candidates.maxOf { packagePriority(it.metadata.dataOrigin.packageName) }
                val best = candidates
                    .filter { packagePriority(it.metadata.dataOrigin.packageName) == maxPriority }
                    .maxByOrNull { it.time }
                result.success(best?.beatsPerMinute?.toInt())
            } catch (_: Exception) {
                result.error("RHR_READ_FAILED", "Could not read resting heart rate.", null)
            }
        }
    }

    /// Per-day resting HR over [now-days, tomorrow start): per-day
    /// priority-filtered, distinct by date. Days with no record fall back
    /// to the aggregate BPM_AVG slice when avg > 0 (native rule).
    /// Dart shape: [{date: "YYYY-MM-DD", bpm}].
    private fun readRestingHrHistory(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 7).coerceIn(1, 180)
        lifecycleScope.launch {
            try {
                val zone = ZoneId.systemDefault()
                val end = ZonedDateTime.now(zone).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
                val start = end.minus(n.toLong(), ChronoUnit.DAYS)
                val records = mutableListOf<RestingHeartRateRecord>()
                var pageToken: String? = null
                do {
                    val response = client.readRecords(
                        ReadRecordsRequest(
                            recordType = RestingHeartRateRecord::class,
                            timeRangeFilter = TimeRangeFilter.between(start, end),
                            pageToken = pageToken
                        )
                    )
                    records.addAll(response.records)
                    pageToken = response.pageToken
                } while (pageToken != null)

                fun dateOf(instant: Instant): String =
                    ZonedDateTime.ofInstant(instant, zone).toLocalDate().toString()

                val bpmByDate = mutableMapOf<String, Int>()
                nonMock(records)
                    .groupBy { dateOf(it.time) }
                    .forEach { (date, dateRecords) ->
                        val maxPriority = dateRecords.maxOf {
                            packagePriority(it.metadata.dataOrigin.packageName)
                        }
                        val best = dateRecords
                            .filter { packagePriority(it.metadata.dataOrigin.packageName) == maxPriority }
                            .minByOrNull { it.time }
                        if (best != null) bpmByDate[date] = best.beatsPerMinute.toInt()
                    }

                // Per-day BPM_AVG fallback for days with no record.
                if (bpmByDate.size < n) {
                    val agg = client.aggregateGroupByDuration(
                        AggregateGroupByDurationRequest(
                            metrics = setOf(HeartRateRecord.BPM_AVG),
                            timeRangeFilter = TimeRangeFilter.between(start, end),
                            timeRangeSlicer = Duration.ofDays(1)
                        )
                    )
                    val avgByDate = mutableMapOf<String, Double>()
                    agg.forEach { bucket ->
                        val avg = bucket.result[HeartRateRecord.BPM_AVG]
                        if (avg != null && avg > 0) {
                            avgByDate[dateOf(bucket.startTime)] = avg.toDouble()
                        }
                    }
                    val windowDates = (0 until n).map { i ->
                        LocalDate.now().minusDays((n - 1 - i).toLong()).toString()
                    }
                    windowDates.forEach { date ->
                        if (!bpmByDate.containsKey(date)) {
                            avgByDate[date]?.let { bpmByDate[date] = it.toInt() }
                        }
                    }
                }

                result.success(
                    bpmByDate.entries
                        .sortedBy { it.key }
                        .map { mapOf("date" to it.key, "bpm" to it.value) }
                )
            } catch (_: Exception) {
                result.error("RHR_HISTORY_READ_FAILED", "Could not read resting heart rate history.", null)
            }
        }
    }

    /// Per-day calories over [now-days, tomorrow start): `active ?: total`
    /// per day (native rule, 0 when both null — Dart treats 0 as missing).
    /// Dart shape: [{date: "YYYY-MM-DD", kcal}].
    private fun readCaloriesHistory(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 7).coerceIn(1, 180)
        lifecycleScope.launch {
            try {
                val zone = ZoneId.systemDefault()
                val end = ZonedDateTime.now(zone).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
                val start = end.minus(n.toLong(), ChronoUnit.DAYS)
                val agg = client.aggregateGroupByDuration(
                    AggregateGroupByDurationRequest(
                        metrics = setOf(
                            ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL,
                            TotalCaloriesBurnedRecord.ENERGY_TOTAL
                        ),
                        timeRangeFilter = TimeRangeFilter.between(start, end),
                        timeRangeSlicer = Duration.ofDays(1)
                    )
                )
                result.success(
                    agg.map { bucket ->
                        val date = ZonedDateTime.ofInstant(bucket.startTime, zone).toLocalDate().toString()
                        val active = bucket.result[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories?.toInt()
                        val total = bucket.result[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories?.toInt()
                        mapOf("date" to date, "kcal" to (active ?: total ?: 0))
                    }
                )
            } catch (_: Exception) {
                result.error("CALORIES_HISTORY_READ_FAILED", "Could not read calorie history.", null)
            }
        }
    }

    /// BP records over [now-days, now), mock-filtered, sorted desc.
    /// Dart shape: [{t: epochMs, sys, dia}].
    private fun readBloodPressure(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 7).coerceIn(1, 180)
        lifecycleScope.launch {
            try {
                val end = Instant.now()
                val start = end.minus(n.toLong(), ChronoUnit.DAYS)
                val records = mutableListOf<BloodPressureRecord>()
                var pageToken: String? = null
                do {
                    val response = client.readRecords(
                        ReadRecordsRequest(
                            recordType = BloodPressureRecord::class,
                            timeRangeFilter = TimeRangeFilter.between(start, end),
                            pageToken = pageToken
                        )
                    )
                    records.addAll(response.records)
                    pageToken = response.pageToken
                } while (pageToken != null)
                result.success(
                    nonMock(records)
                        .map {
                            mapOf(
                                "t" to it.time.toEpochMilli(),
                                "sys" to it.systolic.inMillimetersOfMercury.toInt(),
                                "dia" to it.diastolic.inMillimetersOfMercury.toInt()
                            )
                        }
                        .sortedByDescending { (it["t"] as Long) }
                )
            } catch (_: Exception) {
                result.error("BP_READ_FAILED", "Could not read blood pressure records.", null)
            }
        }
    }

    /// Native `selectBestRecord` (HealthConnectManager.kt:88-97):
    /// mock records dropped, highest package-priority tier wins,
    /// latest by time inside the tier. Null when nothing qualifies.
    private fun <T : Record> bestRecord(records: List<T>, time: (T) -> Instant): T? {
        val candidates = nonMock(records)
        if (candidates.isEmpty()) return null
        val maxPriority = candidates.maxOf { packagePriority(it.metadata.dataOrigin.packageName) }
        return candidates
            .filter { packagePriority(it.metadata.dataOrigin.packageName) == maxPriority }
            .maxByOrNull(time)
    }

    /// Round 30 — latest weight, native `readLatestWeight`
    /// (HealthConnectManager.kt:796-810): WeightRecords in
    /// [today − 90 days, end of today], best record wins. Returns
    /// kilograms (native returns pounds for its imperial DataStore;
    /// the Flutter profile is metric end-to-end). Null when none.
    private fun readLatestWeightKg(result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (startOfDay, endOfDay) = dayRange("today")
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = WeightRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            startOfDay.minus(90, ChronoUnit.DAYS), endOfDay
                        )
                    )
                )
                val best = bestRecord(response.records) { it.time }
                result.success(best?.weight?.inKilograms)
            } catch (_: Exception) {
                result.error("WEIGHT_READ_FAILED", "Could not read weight records.", null)
            }
        }
    }

    /// Round 30 — latest height, native `readLatestHeight`
    /// (HealthConnectManager.kt:812-824): HeightRecords in the last
    /// 365 days, best record wins. Returns centimetres. Null when none.
    private fun readLatestHeightCm(result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val end = Instant.now()
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = HeightRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            end.minus(365, ChronoUnit.DAYS), end
                        )
                    )
                )
                val best = bestRecord(response.records) { it.time }
                result.success(best?.height?.inMeters?.times(100.0))
            } catch (_: Exception) {
                result.error("HEIGHT_READ_FAILED", "Could not read height records.", null)
            }
        }
    }

    /// Step count for the day. Null when unavailable.
    private fun readSteps(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (start, end) = dayRange(dateStr)
                val response = client.aggregate(
                    AggregateRequest(
                        metrics = setOf(StepsRecord.COUNT_TOTAL),
                        timeRangeFilter = TimeRangeFilter.between(start, end)
                    )
                )
                result.success(response[StepsRecord.COUNT_TOTAL]?.toInt())
            } catch (_: Exception) {
                result.error("STEPS_READ_FAILED", "Could not read steps.", null)
            }
        }
    }

    // ── Round 48: Key Metrics + range reads + CSV export ─────────────────
    // Ports of native `HealthConnectManager.readRespiratoryRate`
    // (:872), `readOxygenSaturation` (:888), `readHeartRateVariability`
    // (:823), `readHistoricalSleepWithDeep` (:926) and the spike half of
    // `readHistoricalHeartRateWithSpikes` (:463), plus native
    // `FitbitViewModel.exportMetricsCsvAsync`'s file hand-off. Same
    // rules as the Round 13 reads: best-record = non-mock, highest
    // package priority, latest by time; failures return a visible error
    // code; "no data" is a successful null/empty — never fabricated.

    /// Respiratory rate: records in [startOfDay − 30 days, endOfDay],
    /// best record wins (native looks back 30 days for the "last daily
    /// reading"). Null when none.
    private fun readRespiratoryRate(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (startOfDay, endOfDay) = dayRange(dateStr)
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = RespiratoryRateRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            startOfDay.minus(30, ChronoUnit.DAYS), endOfDay
                        )
                    )
                )
                val best = bestRecord(response.records) { it.time }
                result.success(best?.rate)
            } catch (_: Exception) {
                result.error("RESPIRATORY_READ_FAILED", "Could not read respiratory rate.", null)
            }
        }
    }

    /// Oxygen saturation: same 30-day lookback + best record as native.
    /// A raw value ≤ 1.0 is a fraction and is scaled to percent (native
    /// rule). Null when none.
    private fun readOxygenSaturation(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (startOfDay, endOfDay) = dayRange(dateStr)
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = OxygenSaturationRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            startOfDay.minus(30, ChronoUnit.DAYS), endOfDay
                        )
                    )
                )
                val best = bestRecord(response.records) { it.time }
                val raw = best?.percentage?.value
                result.success(if (raw != null && raw <= 1.0) raw * 100.0 else raw)
            } catch (_: Exception) {
                result.error("OXYGEN_READ_FAILED", "Could not read oxygen saturation.", null)
            }
        }
    }

    /// HRV (RMSSD) for one day: paginated read, mock records dropped,
    /// only the highest package-priority tier for the day counts, and
    /// the value is that tier's average — native
    /// `readHeartRateVariability(days = 1, targetDateStr = date)`
    /// daily-average rule. Null when no record.
    private fun readHrvRmssd(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        lifecycleScope.launch {
            try {
                val (start, end) = dayRange(dateStr)
                val records = mutableListOf<HeartRateVariabilityRmssdRecord>()
                var pageToken: String? = null
                do {
                    val response = client.readRecords(
                        ReadRecordsRequest(
                            recordType = HeartRateVariabilityRmssdRecord::class,
                            timeRangeFilter = TimeRangeFilter.between(start, end),
                            pageToken = pageToken
                        )
                    )
                    records.addAll(response.records)
                    pageToken = response.pageToken
                } while (pageToken != null)
                val candidates = nonMock(records)
                if (candidates.isEmpty()) {
                    result.success(null)
                    return@launch
                }
                val maxPriority = candidates.maxOf {
                    packagePriority(it.metadata.dataOrigin.packageName)
                }
                val tier = candidates.filter {
                    packagePriority(it.metadata.dataOrigin.packageName) == maxPriority
                }
                result.success(tier.map { it.heartRateVariabilityMillis }.average())
            } catch (_: Exception) {
                result.error("HRV_READ_FAILED", "Could not read heart rate variability.", null)
            }
        }
    }

    /// Per-day sleep totals over [tomorrowStart − days, tomorrowStart):
    /// sessions grouped by their end (wake-up) date, per date the best
    /// session (highest package priority, then longest) wins;
    /// minutesAsleep = duration − merged awake-stage minutes, deep =
    /// merged deep-stage minutes. Dart shape:
    /// [{date: "YYYY-MM-DD", mins, deep}] sorted ascending. Mirrors
    /// native `readHistoricalSleepWithDeep`.
    private fun readSleepHistory(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 30).coerceIn(1, 3650)
        lifecycleScope.launch {
            try {
                val zone = ZoneId.systemDefault()
                val end = ZonedDateTime.now(zone).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
                val start = end.minus(n.toLong(), ChronoUnit.DAYS)
                val records = mutableListOf<SleepSessionRecord>()
                var pageToken: String? = null
                do {
                    val response = client.readRecords(
                        ReadRecordsRequest(
                            recordType = SleepSessionRecord::class,
                            timeRangeFilter = TimeRangeFilter.between(start, end),
                            pageToken = pageToken
                        )
                    )
                    records.addAll(response.records)
                    pageToken = response.pageToken
                } while (pageToken != null)

                fun dateOf(instant: Instant): String =
                    ZonedDateTime.ofInstant(instant, zone).toLocalDate().toString()

                val bestByDate = mutableMapOf<String, SleepSessionRecord>()
                for (session in nonMock(records)) {
                    val date = dateOf(session.endTime)
                    val existing = bestByDate[date]
                    if (existing == null) {
                        bestByDate[date] = session
                    } else {
                        val pNew = packagePriority(session.metadata.dataOrigin.packageName)
                        val pOld = packagePriority(existing.metadata.dataOrigin.packageName)
                        val dNew = Duration.between(session.startTime, session.endTime)
                        val dOld = Duration.between(existing.startTime, existing.endTime)
                        if (pNew > pOld || (pNew == pOld && dNew > dOld)) {
                            bestByDate[date] = session
                        }
                    }
                }

                val out = bestByDate.entries.sortedBy { it.key }.map { (date, session) ->
                    fun stageMinutes(vararg types: Int): Int {
                        val intervals = session.stages
                            .filter { it.stage in types }
                            .map { it.startTime to it.endTime }
                        return mergeIntervals(intervals)
                            .sumOf { Duration.between(it.first, it.second).toMinutes().toInt() }
                    }
                    val awake = stageMinutes(
                        SleepSessionRecord.STAGE_TYPE_AWAKE,
                        SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
                        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED
                    )
                    val deep = stageMinutes(SleepSessionRecord.STAGE_TYPE_DEEP)
                    val duration = ChronoUnit.MINUTES.between(session.startTime, session.endTime).toInt()
                    mapOf(
                        "date" to date,
                        "mins" to (duration - awake).coerceAtLeast(0),
                        "deep" to deep
                    )
                }
                result.success(out)
            } catch (_: Exception) {
                result.error("SLEEP_HISTORY_READ_FAILED", "Could not read sleep history.", null)
            }
        }
    }

    /// Per-day HR spike counts over [tomorrowStart − days,
    /// tomorrowStart), read in 30-day chunks like native
    /// `readHistoricalHeartRateWithSpikes`. A spike event starts at the
    /// first sample ≥ 100 bpm and absorbs subsequent ≥ 100 samples
    /// within 5 minutes of the previous one (native
    /// `computeDailyHeartRateSummary`). Zero-bpm samples are dropped
    /// first (founder rule: 0 is a failed read). Only days with at
    /// least one usable sample appear; a day's count may be 0 (real).
    /// Dart shape: [{date: "YYYY-MM-DD", count}] sorted ascending.
    private fun readSpikeCounts(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 30).coerceIn(1, 365)
        lifecycleScope.launch {
            try {
                val zone = ZoneId.systemDefault()
                val end = ZonedDateTime.now(zone).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
                val start = end.minus(n.toLong(), ChronoUnit.DAYS)
                val counts = mutableMapOf<String, Int>()
                var chunkStart = start
                while (chunkStart.isBefore(end)) {
                    val chunkEnd = minOf(chunkStart.plus(30, ChronoUnit.DAYS), end)
                    val byDay = mutableMapOf<String, MutableList<Pair<Long, Int>>>()
                    var pageToken: String? = null
                    do {
                        val response = client.readRecords(
                            ReadRecordsRequest(
                                recordType = HeartRateRecord::class,
                                timeRangeFilter = TimeRangeFilter.between(chunkStart, chunkEnd),
                                pageToken = pageToken
                            )
                        )
                        for (record in nonMock(response.records)) {
                            for (sample in record.samples) {
                                val bpm = sample.beatsPerMinute.toInt()
                                if (bpm <= 0) continue
                                val date = ZonedDateTime.ofInstant(sample.time, zone)
                                    .toLocalDate().toString()
                                byDay.getOrPut(date) { mutableListOf() }
                                    .add(sample.time.toEpochMilli() to bpm)
                            }
                        }
                        pageToken = response.pageToken
                    } while (pageToken != null)
                    for ((date, samples) in byDay) {
                        val sorted = samples.sortedBy { it.first }
                        var count = 0
                        var inEvent = false
                        var eventEndMs = 0L
                        for ((t, bpm) in sorted) {
                            if (bpm >= 100) {
                                if (!inEvent || t > eventEndMs) {
                                    count++
                                    inEvent = true
                                }
                                eventEndMs = t + 300000L
                            }
                        }
                        counts[date] = count
                    }
                    chunkStart = chunkEnd
                }
                result.success(
                    counts.entries.sortedBy { it.key }
                        .map { mapOf("date" to it.key, "count" to it.value) }
                )
            } catch (_: Exception) {
                result.error("SPIKE_COUNTS_READ_FAILED", "Could not read heart rate spikes.", null)
            }
        }
    }

    /// Native `exportMetricsCsvAsync` file hand-off: writes the CSV to
    /// the cache dir, copies it into Downloads via MediaStore, then
    /// opens the share sheet (ACTION_SEND chooser, FileProvider URI,
    /// "Share Biometrics CSV"). Success = the chooser was launched.
    private fun exportCsvFile(fileName: String?, content: String?, result: MethodChannel.Result) {
        try {
            val name = fileName?.takeIf { it.isNotBlank() } ?: "jot_metrics.csv"
            val bytes = (content ?: "").toByteArray(Charsets.UTF_8)
            val cacheFile = java.io.File(cacheDir, name)
            cacheFile.writeBytes(bytes)

            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/csv")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            if (uri != null) {
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
            }

            val shareUri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.provider", cacheFile
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, shareUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share Biometrics CSV"))
            result.success(true)
        } catch (_: Exception) {
            result.error("CSV_EXPORT_FAILED", "Could not export the CSV file.", null)
        }
    }
    // ── Round 54: calendar bridge (native CoachViewModel ports) ─────────
    // Every failure path returns a visible error code — never a silent
    // no-op and never a fabricated success (team lesson). ContentResolver
    // work runs off the main thread; results are delivered on it.

    private fun calendarPermissionStatusMap(): Map<String, Boolean> {
        val read = ContextCompat.checkSelfPermission(
            this, Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED
        val write = ContextCompat.checkSelfPermission(
            this, Manifest.permission.WRITE_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED
        return mapOf("read" to read, "write" to write)
    }

    /// Native CoachScreen.kt:89-113: at first approve, request
    /// WRITE_CALENDAR + READ_CALENDAR together; the result replays
    /// the pending approve on the Dart side. Same stuck-request
    /// discipline as the HC launcher: a stale in-flight request is
    /// superseded, never stacked.
    private fun requestCalendarPermissions(result: MethodChannel.Result) {
        val now = SystemClock.elapsedRealtime()
        val pending = pendingCalendarResult
        if (pending != null) {
            if (now - pendingCalendarSince < REQUEST_TIMEOUT_MS) {
                result.error(
                    "IN_FLIGHT",
                    "A calendar permission request is already in progress.",
                    null
                )
                return
            }
            try {
                pending.error("SUPERSEDED", "Superseded by a newer request.", null)
            } catch (_: Exception) {
            }
            pendingCalendarResult = null
        }
        if (!::calendarPermissionLauncher.isInitialized) {
            result.error("NO_LAUNCHER", "Permission launcher is not registered.", null)
            return
        }
        pendingCalendarResult = result
        pendingCalendarSince = now
        try {
            calendarPermissionLauncher.launch(
                arrayOf(
                    Manifest.permission.WRITE_CALENDAR,
                    Manifest.permission.READ_CALENDAR
                )
            )
        } catch (e: Exception) {
            pendingCalendarResult = null
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    private fun cancelPendingCalendarRequest(result: MethodChannel.Result) {
        val pending = pendingCalendarResult
        pendingCalendarResult = null
        if (pending != null) {
            try {
                pending.error("CANCELLED", "Request cancelled.", null)
            } catch (_: Exception) {
            }
        }
        result.success(true)
    }

    /// Writable calendars (CALENDAR_ACCESS_LEVEL >= 500), provider
    /// order — the candidate set native's insert selection considers
    /// (CoachViewModel.kt:782-818).
    private fun listWritableCalendars(result: MethodChannel.Result) {
        Thread {
            try {
                val calendars = queryWritableCalendars()
                runOnUiThread {
                    try {
                        result.success(calendars.map {
                            mapOf(
                                "id" to it.id,
                                "accountName" to it.accountName,
                                "accountType" to it.accountType,
                                "accessLevel" to it.accessLevel
                            )
                        })
                    } catch (_: Exception) {
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    try {
                        result.error("CALENDAR_LIST_FAILED", e.message, null)
                    } catch (_: Exception) {
                    }
                }
            }
        }.start()
    }

    private data class CalInfo(
        val id: Long,
        val accountName: String,
        val accountType: String,
        val accessLevel: Int
    )

    /// Native's inline calendar query (CoachViewModel.kt:789-815):
    /// query failures are caught and logged natively, leaving an
    /// empty candidate list (which then aborts as "no writable
    /// calendar"); mirrored here.
    private fun queryWritableCalendars(): List<CalInfo> {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
        )
        val candidates = mutableListOf<CalInfo>()
        try {
            contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection, null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(CalendarContract.Calendars._ID)
                val accNameCol = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
                val accTypeCol = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_TYPE)
                val accessCol = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
                while (cursor.moveToNext()) {
                    val id = if (idCol != -1) cursor.getLong(idCol) else continue
                    val accName = if (accNameCol != -1) cursor.getString(accNameCol) ?: "" else ""
                    val accType = if (accTypeCol != -1) cursor.getString(accTypeCol) ?: "" else ""
                    val access = if (accessCol != -1) cursor.getInt(accessCol) else 0
                    if (access >= 500) candidates.add(CalInfo(id, accName, accType, access))
                }
            }
        } catch (_: Exception) {
            // Native logs and continues with no candidates.
        }
        return candidates
    }

    /// Port of native `approveProposedCalendarEvent`
    /// (CoachViewModel.kt:778-908), minus its UI/persistence: returns
    /// "inserted", "noWritableCalendar", or "nullUri" so Dart can
    /// post native's exact outcome messages; a thrown failure comes
    /// back as CALENDAR_INSERT_FAILED (native's outer catch posts
    /// FriendlyErrors.coachCalendarAddFailure, which Dart mirrors).
    private fun insertCalendarEvent(
        title: String?,
        date: String?,
        timeStr: String?,
        desc: String?,
        connectedEmail: String?,
        result: MethodChannel.Result
    ) {
        // Vera R54: a null/blank title must refuse, never insert an
        // untitled event and report "inserted".
        if (title.isNullOrBlank()) {
            result.error(
                "INVALID_ARGS",
                "Calendar event title must not be null or blank.",
                null
            )
            return
        }
        Thread {
            var failure: Exception? = null
            var outcome = "inserted"
            try {
                val targetEmail = connectedEmail ?: ""

                // 1. Best writable calendar (native inline logic —
                //    NOT the dead getBestWritableCalendarId helper).
                val candidates = queryWritableCalendars()
                val best = candidates.firstOrNull {
                    it.accountName.equals(targetEmail, ignoreCase = true)
                } ?: candidates.firstOrNull()

                if (best == null) {
                    outcome = "noWritableCalendar"
                } else {
                    // 2. Parse date+time to epoch milliseconds
                    //    (native :830-851).
                    var startMillis = System.currentTimeMillis()
                    if (!date.isNullOrBlank() && !timeStr.isNullOrBlank()) {
                        try {
                            val parsed = try {
                                val format12 = java.text.SimpleDateFormat(
                                    "yyyy-MM-dd hh:mm a", java.util.Locale.US
                                ).apply {
                                    timeZone = java.util.TimeZone.getDefault()
                                }
                                format12.parse("$date $timeStr")
                            } catch (_: Exception) {
                                val format24 = java.text.SimpleDateFormat(
                                    "yyyy-MM-dd HH:mm", java.util.Locale.US
                                ).apply {
                                    timeZone = java.util.TimeZone.getDefault()
                                }
                                format24.parse("$date $timeStr")
                            }
                            if (parsed != null) {
                                startMillis = parsed.time
                            }
                        } catch (_: Exception) {
                            // Native logs and keeps the "now" default.
                        }
                    }
                    val endMillis = startMillis + 60 * 60 * 1000

                    // 3. Insert with native's field mapping and the
                    //    sync-adapter URI parameters (native :852-872).
                    val eventValues = ContentValues().apply {
                        put(CalendarContract.Events.DTSTART, startMillis)
                        put(CalendarContract.Events.DTEND, endMillis)
                        put(CalendarContract.Events.TITLE, title)
                        put(CalendarContract.Events.DESCRIPTION, desc ?: "")
                        put(CalendarContract.Events.CALENDAR_ID, best.id)
                        put(
                            CalendarContract.Events.EVENT_TIMEZONE,
                            java.util.TimeZone.getDefault().id
                        )
                    }
                    val eventUri = contentResolver.insert(
                        CalendarContract.Events.CONTENT_URI
                            .buildUpon()
                            .appendQueryParameter(
                                CalendarContract.CALLER_IS_SYNCADAPTER, "false"
                            )
                            .appendQueryParameter(
                                CalendarContract.Calendars.ACCOUNT_NAME,
                                best.accountName
                            )
                            .appendQueryParameter(
                                CalendarContract.Calendars.ACCOUNT_TYPE,
                                best.accountType
                            )
                            .build(),
                        eventValues
                    )
                    if (eventUri == null) outcome = "nullUri"
                }
            } catch (e: Exception) {
                failure = e
            }
            runOnUiThread {
                try {
                    val f = failure
                    if (f != null) {
                        result.error("CALENDAR_INSERT_FAILED", f.message, null)
                    } else {
                        result.success(outcome)
                    }
                } catch (_: Exception) {
                }
            }
        }.start()
    }

    /// Port of native `approveProposedCalendarDeleteEvent`
    /// (CoachViewModel.kt:941-1003), minus UI/persistence: TITLE = ?
    /// across ALL calendars, plus the parsed date's day window when
    /// the date parses. Returns the number of rows deleted.
    private fun deleteCalendarEvents(
        title: String?,
        date: String?,
        result: MethodChannel.Result
    ) {
        // Vera R54: a null/blank title must refuse, never widen to a
        // delete for TITLE = '' (every empty-title event).
        if (title.isNullOrBlank()) {
            result.error(
                "INVALID_ARGS",
                "Calendar event title must not be null or blank.",
                null
            )
            return
        }
        Thread {
            var failure: Exception? = null
            var rowsDeleted = 0
            try {
                var selection = "${CalendarContract.Events.TITLE} = ?"
                val selectionArgs = mutableListOf(title ?: "")
                if (!date.isNullOrBlank()) {
                    try {
                        val format = java.text.SimpleDateFormat(
                            "yyyy-MM-dd", java.util.Locale.US
                        ).apply {
                            timeZone = java.util.TimeZone.getDefault()
                        }
                        val parsed = format.parse(date)
                        if (parsed != null) {
                            val startOfDay = parsed.time
                            val endOfDay = startOfDay + 24 * 60 * 60 * 1000
                            selection += " AND ${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} < ?"
                            selectionArgs.add(startOfDay.toString())
                            selectionArgs.add(endOfDay.toString())
                        }
                    } catch (_: Exception) {
                        // Native logs and deletes by title alone.
                    }
                }
                rowsDeleted = contentResolver.delete(
                    CalendarContract.Events.CONTENT_URI,
                    selection,
                    selectionArgs.toTypedArray()
                )
            } catch (e: Exception) {
                failure = e
            }
            runOnUiThread {
                try {
                    val f = failure
                    if (f != null) {
                        result.error("CALENDAR_DELETE_FAILED", f.message, null)
                    } else {
                        result.success(rowsDeleted)
                    }
                } catch (_: Exception) {
                }
            }
        }.start()
    }

    /// Port of native `getUpcomingCalendarEvents`' query
    /// (CoachViewModel.kt:1461-1546): all calendars, not-deleted,
    /// from the earlier of local/UTC midnight today through local
    /// midnight + 15 days, DTSTART ascending. Dart formats the rows
    /// into native's exact context string. A query failure is
    /// caught natively and yields an empty list; mirrored here.
    private fun getUpcomingCalendarEvents(result: MethodChannel.Result) {
        Thread {
            val events = mutableListOf<Map<String, Any?>>()
            try {
                val localMidnight = java.util.Calendar.getInstance().apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 0)
                    set(java.util.Calendar.MINUTE, 0)
                    set(java.util.Calendar.SECOND, 0)
                    set(java.util.Calendar.MILLISECOND, 0)
                }.timeInMillis
                val utcMidnight =
                    java.util.Calendar.getInstance(
                        java.util.TimeZone.getTimeZone("UTC")
                    ).apply {
                        set(java.util.Calendar.HOUR_OF_DAY, 0)
                        set(java.util.Calendar.MINUTE, 0)
                        set(java.util.Calendar.SECOND, 0)
                        set(java.util.Calendar.MILLISECOND, 0)
                    }.timeInMillis
                val queryStart = minOf(localMidnight, utcMidnight)
                val queryEnd = localMidnight + 15 * 24 * 60 * 60 * 1000L

                val eventProjection = arrayOf(
                    CalendarContract.Events.TITLE,
                    CalendarContract.Events.DTSTART,
                    CalendarContract.Events.ALL_DAY
                )
                val selection =
                    "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ? AND ${CalendarContract.Events.DELETED} != 1"
                val selectionArgs = arrayOf(queryStart.toString(), queryEnd.toString())
                try {
                    contentResolver.query(
                        CalendarContract.Events.CONTENT_URI,
                        eventProjection,
                        selection,
                        selectionArgs,
                        "${CalendarContract.Events.DTSTART} ASC"
                    )?.use { cursor ->
                        val titleCol = cursor.getColumnIndex(CalendarContract.Events.TITLE)
                        val startCol = cursor.getColumnIndex(CalendarContract.Events.DTSTART)
                        val allDayCol = cursor.getColumnIndex(CalendarContract.Events.ALL_DAY)
                        if (titleCol != -1 && startCol != -1) {
                            while (cursor.moveToNext()) {
                                events.add(
                                    mapOf(
                                        "title" to cursor.getString(titleCol),
                                        "dtstart" to cursor.getLong(startCol),
                                        "allDay" to (allDayCol != -1 && cursor.getInt(allDayCol) == 1)
                                    )
                                )
                            }
                        }
                    }
                } catch (_: Exception) {
                    // Native logs and continues with an empty list.
                }
            } catch (_: Exception) {
                // Native's outer catch returns the "unavailable"
                // string; the bridge signals that with an error code
                // and Dart substitutes native's exact string.
                runOnUiThread {
                    try {
                        result.error(
                            "CALENDAR_READ_FAILED",
                            "Could not read calendar events.",
                            null
                        )
                    } catch (_: Exception) {
                    }
                }
                return@Thread
            }
            runOnUiThread {
                try {
                    result.success(events)
                } catch (_: Exception) {
                }
            }
        }.start()
    }
}
