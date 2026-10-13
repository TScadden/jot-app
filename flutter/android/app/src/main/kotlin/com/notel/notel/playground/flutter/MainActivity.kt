package com.notel.notel.playground.flutter

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.speech.RecognizerIntent
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
}
