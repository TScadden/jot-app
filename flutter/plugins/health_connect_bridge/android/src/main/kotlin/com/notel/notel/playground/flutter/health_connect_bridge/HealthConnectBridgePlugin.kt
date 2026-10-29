package com.notel.notel.playground.flutter.health_connect_bridge

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Environment
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import android.provider.MediaStore
import androidx.activity.result.ActivityResultLauncher
import androidx.health.connect.client.HealthConnectClient
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
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/// Health Connect bridge as a proper FlutterPlugin (extracted from
/// MainActivity, where it previously lived as a hand-wired
/// MethodChannel).
///
/// Why a plugin: GeneratedPluginRegistrant registers this plugin on
/// EVERY FlutterEngine created in the app process — the main engine
/// AND the WorkManager background engine (the same mechanism that
/// registers WorkmanagerPlugin itself). The Daily Score background
/// runner (daily_score_background.dart) calls this exact channel
/// from the background isolate; before the extraction those calls hit
/// MissingPluginException because the handlers existed only in
/// MainActivity's engine. The channel name, method names, argument
/// shapes, result shapes, error codes/details, permission set,
/// timeouts, chunking and partial-result contracts are unchanged —
/// this is a transplant, not a rewrite. No Dart change was needed.
///
/// Seam decisions (see the package report for the full reasoning):
/// - Permission launcher: the launcher stays ACTIVITY-OWNED. It is
///   registered in MainActivity.onCreate via activityResultRegistry
///   (team lesson: registration in configureFlutterEngine can throw
///   or silently never fire, and a plugin has no onCreate). The
///   Activity publishes the registered launcher to
///   [activityPermissionLauncher] and forwards its result callback to
///   [deliverPermissionResult]; the plugin instance that launched a
///   request claims the result route at launch time
///   ([claimPendingPermissionResult]). Grant results, the
///   timeout/supersede/cancel semantics and the NO_LAUNCHER /
///   IN_FLIGHT / LAUNCH_FAILED error vocabulary are exactly as they
///   were in MainActivity. In a background engine (no Activity, or
///   none live) the published launcher is null and requestPermissions
///   fails with NO_LAUNCHER — the pre-existing code for exactly that
///   state.
/// - Coroutine scope: reads previously ran in the Activity's
///   lifecycleScope. They now run in [engineScope], a
///   SupervisorJob + Dispatchers.Main scope created when the plugin
///   attaches to an engine and cancelled when it detaches from that
///   engine ("detached from engine" ⇒ in-flight reads are
///   cancelled). Difference vs lifecycleScope: lifecycleScope also
///   cancels when the Activity is destroyed while its engine lives
///   on; engineScope does not — it is bound to the engine, which is
///   the only lifecycle a background engine has.
/// - Activity-bound methods: requestPermissions (see above),
///   openHealthConnectSettings and exportCsvFile's share sheet need
///   a foreground Activity. With none attached they fail fast with
///   the method's existing error code (NO_LAUNCHER / NO_SETTINGS /
///   CSV_EXPORT_FAILED) instead of crashing or hanging. The current
///   Dart background runner never calls them.
/// - Context: HealthConnectClient and all file/content operations
///   use the application context from the plugin binding — the same
///   client and providers the Activity context resolved to.
class HealthConnectBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    companion object {
        const val HC_CHANNEL = "com.notel.notel.playground.flutter/health_connect"
        const val HC_PROVIDER_PACKAGE = "com.google.android.apps.healthdata"
        const val SETTINGS_ACTION = "android.health.connect.action.HEALTH_HOME_SETTINGS"
        private const val REQUEST_TIMEOUT_MS = 5 * 60 * 1000L

        // ── Activity-owned permission-launcher bridge ─────────────
        // MainActivity registers the HC permission launcher in its
        // onCreate (unchanged) and publishes it here; it clears the
        // reference in onDestroy. Null whenever no Activity with a
        // registered launcher is alive — always the case in the
        // WorkManager background engine.
        @Volatile
        var activityPermissionLauncher: ActivityResultLauncher<Set<String>>? = null

        // The plugin instance with a permission request in flight.
        // Claimed at launch time (never at attach time), so when two
        // engines coexist in one process the result is routed to the
        // instance that actually launched — in practice only the
        // foreground instance can launch at all.
        @Volatile
        private var pendingPermissionPlugin: HealthConnectBridgePlugin? = null

        /// MainActivity's launcher callback forwards the granted set
        /// here. A delivery with no claimed instance is stale (timed
        /// out / cancelled / superseded) and is dropped — the exact
        /// semantics of the old `pendingResult == null` early return.
        fun deliverPermissionResult(granted: Set<String>) {
            pendingPermissionPlugin?.onPermissionResult(granted)
        }

        // ── Refresh keep-alive tap bridge (Oct 20, 2026) ─────────
        // Namespaced intent-extra key carrying the refresh date on
        // the keep-alive notification's tap intent (built by
        // RefreshKeepAliveService) and on any MainActivity intent
        // that delivers that tap.
        const val SCORE_TAP_DATE_EXTRA =
            "com.notel.notel.playground.flutter.health_connect_bridge.SCORE_TAP_DATE"

        // The date from a keep-alive notification tap, held until
        // Dart takes it via takePendingScoreTap (consume-once).
        // Static like the permission-launcher bridge: the tap can
        // land on an Activity whose engine's plugin instance is a
        // different object than the one that started the service,
        // and a cold start may publish before any Dart calls in.
        @Volatile
        private var pendingScoreTapDate: String? = null

        /// MainActivity forwards its intent from BOTH onCreate and
        /// onNewIntent (singleTop reuse delivers taps to a live
        /// Activity through onNewIntent only). A missing / blank
        /// extra publishes nothing and never clears a held date.
        fun publishScoreTapFromIntent(intent: Intent?) {
            val date = intent?.getStringExtra(SCORE_TAP_DATE_EXTRA)
            if (!date.isNullOrBlank()) {
                pendingScoreTapDate = date
            }
        }

        /// Consume-once read for the plugin instance Dart calls.
        fun takePendingScoreTapDate(): String? {
            val date = pendingScoreTapDate
            pendingScoreTapDate = null
            return date
        }
    }

    private lateinit var applicationContext: Context
    private lateinit var engineScope: CoroutineScope
    private var channel: MethodChannel? = null
    private var activity: Activity? = null

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

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSince: Long = 0L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        engineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        channel = MethodChannel(binding.binaryMessenger, HC_CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        // Named cancellation semantics: detached-from-engine ⇒ the
        // engine scope is cancelled and every in-flight read with it.
        engineScope.cancel()
        releasePendingPermissionResult()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private fun claimPendingPermissionResult() {
        pendingPermissionPlugin = this
    }

    private fun releasePendingPermissionResult() {
        if (pendingPermissionPlugin === this) {
            pendingPermissionPlugin = null
        }
    }

    /// The Activity-owned launcher's callback, routed here by
    /// [deliverPermissionResult]. Body is the old MainActivity
    /// callback verbatim, against this instance's pending state.
    fun onPermissionResult(granted: Set<String>) {
        val r = pendingResult
        pendingResult = null
        releasePendingPermissionResult()
        if (r == null) return // stale (timed out / cancelled / superseded)
        try {
            r.success(granted.toList())
        } catch (_: Exception) {
            // Result already consumed — nothing to do.
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Refresh keep-alive (Oct 20, 2026): foreground-service
            // keep-alive for a manual Daily Score refresh + its
            // notification-tap seam. See RefreshKeepAliveService.
            "startRefreshKeepAlive" -> startRefreshKeepAlive(
                call.argument<String>("date"), result
            )
            "stopRefreshKeepAlive" -> stopRefreshKeepAlive(result)
            "takePendingScoreTap" -> result.success(takePendingScoreTapDate())
            "isAvailable" -> checkAvailability(result)
            "requestPermissions" -> requestHcPermissions(result)
            "cancelRequest" -> cancelPendingRequest(result)
            "getGrantedPermissions" -> getGrantedPermissions(result)
            "probeReadAccess" -> probeReadAccess(result)
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
            "readHrvSamples" -> readHrvSamples(call.argument<Int>("days"), result)
            "readSleepHistory" -> readSleepHistory(call.argument<Int>("days"), result)
            "readSpikeCounts" -> readSpikeCounts(call.argument<Int>("days"), result)
            "exportCsvFile" -> exportCsvFile(
                call.argument<String>("fileName"),
                call.argument<String>("content"),
                result
            )
            // Report Downloads copy (report-pdf fix): the byte
            // sibling of exportCsvFile's Downloads hand-off — same
            // channel, MediaStore Downloads write, but no share
            // sheet and no cache file: the PDF bytes arrive from
            // Dart exactly as generated/shared.
            "savePdfToDownloads" -> savePdfToDownloads(
                call.argument<String>("fileName"),
                call.argument<ByteArray>("bytes"),
                result
            )
            else -> result.notImplemented()
        }
    }

    // ── Refresh keep-alive ───────────────────────────────────────
    // No silent failures (team lesson): every failure returns a
    // structured channel error Dart can catch. Start failures map
    // on the Dart side to the single code FGS_START_FAILED (Juno
    // Ruling 3); the native exception CLASS ONLY goes to logcat
    // and to the error details slot — never a message, never any
    // health value (this path carries none anyway: the only
    // argument is the refresh date).

    private fun startRefreshKeepAlive(date: String?, result: MethodChannel.Result) {
        if (date.isNullOrBlank()) {
            result.error(
                "FGS_START_FAILED",
                "Refresh keep-alive start needs a date.",
                "IllegalArgumentException"
            )
            return
        }
        try {
            val intent = Intent(
                applicationContext,
                RefreshKeepAliveService::class.java
            ).apply {
                action = RefreshKeepAliveService.ACTION_START
                putExtra(SCORE_TAP_DATE_EXTRA, date)
            }
            // A second start while running re-delivers to the same
            // service (idempotent: it rebuilds its one notification
            // with the newest date extra).
            ContextCompat.startForegroundService(applicationContext, intent)
            result.success(true)
        } catch (e: Exception) {
            // Includes SecurityException (e.g. foreground-service
            // start restrictions): Juno Ruling 3 — Dart proceeds
            // in-process and surfaces the failure on the outcome.
            Log.e("RefreshKeepAlive", "start failed: ${e.javaClass.simpleName}")
            result.error("FGS_START_FAILED", "Refresh keep-alive could not start.", e.javaClass.simpleName)
        }
    }

    private fun stopRefreshKeepAlive(result: MethodChannel.Result) {
        try {
            // stopService is a no-op when the service is not
            // running, which makes stop idempotent by construction.
            applicationContext.stopService(
                Intent(applicationContext, RefreshKeepAliveService::class.java)
            )
            result.success(true)
        } catch (e: Exception) {
            Log.e("RefreshKeepAlive", "stop failed: ${e.javaClass.simpleName}")
            result.error("FGS_STOP_FAILED", "Refresh keep-alive could not stop.", e.javaClass.simpleName)
        }
    }

    private fun checkAvailability(result: MethodChannel.Result) {
        try {
            val status = HealthConnectClient.getSdkStatus(applicationContext, HC_PROVIDER_PACKAGE)
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
        // The launcher itself stays Activity-owned (registered in
        // MainActivity.onCreate — see the class doc); this bridge
        // reference is null until that registration publishes it, and
        // always in a background engine with no live Activity.
        val launcher = activityPermissionLauncher
        if (launcher == null) {
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
            val status = HealthConnectClient.getSdkStatus(applicationContext, HC_PROVIDER_PACKAGE)
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
        claimPendingPermissionResult()
        try {
            launcher.launch(hcPermissions)
        } catch (e: Exception) {
            pendingResult = null
            releasePendingPermissionResult()
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    private fun cancelPendingRequest(result: MethodChannel.Result) {
        val pending = pendingResult
        pendingResult = null
        releasePendingPermissionResult()
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
            HealthConnectClient.getOrCreate(applicationContext)
        } catch (e: Exception) {
            result.error("CLIENT_UNAVAILABLE", e.message, hcErrorDetails(e))
            return
        }
        engineScope.launch {
            try {
                val granted = client.permissionController.getGrantedPermissions()
                result.success(granted.toList())
            } catch (e: Exception) {
                result.error("GRANTED_CHECK_FAILED", e.message, hcErrorDetails(e))
            }
        }
    }

    private fun openSettings(result: MethodChannel.Result) {
        // Activity-bound: with no Activity attached (background
        // engine) there is nothing to open — fail with this method's
        // existing error code instead of crashing or hanging.
        val act = activity
        if (act == null) {
            result.error("NO_SETTINGS", "No foreground activity is available.", null)
            return
        }
        try {
            act.startActivity(Intent(SETTINGS_ACTION))
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
    // - Every suspend call runs in engineScope.launch (the plugin's
    // engine-scoped coroutine scope — see the plugin class doc).
    // - Every failure returns result.error with a distinct visible code.
    // - "No data" is a successful null/empty result — never a fabricated
    //   number. Health VALUES are never logged.
    // - Mock/self records (package priority ≤ -100) are dropped everywhere,
    //   verbatim from the native app.

    private fun hcClientOrError(result: MethodChannel.Result): HealthConnectClient? {
        return try {
            HealthConnectClient.getOrCreate(applicationContext)
        } catch (e: Exception) {
            result.error("CLIENT_UNAVAILABLE", e.message, hcErrorDetails(e))
            null
        }
    }

    /// HC read hardening — instrument, don't swallow: the exception
    /// CLASS ONLY travels to Dart in the channel error DETAILS slot,
    /// so the surfaced UI error identifies the real failure type
    /// (e.g. "SecurityException", "IllegalStateException") without
    /// exposing raw exception text. Codes stay stable for UI
    /// pattern-matching. Class name only — never the message, never
    /// health values (Juno J1).
    private fun hcErrorDetails(e: Exception): String {
        return e.javaClass.simpleName.takeIf { it.isNotBlank() } ?: "Exception"
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

    /// Genuinely-asleep pieces of one session: the session interval
    /// minus its awake-stage intervals. Awake intervals are merged
    /// (via [mergeIntervals]) and clamped to the session interval
    /// first, so awake time outside the session never subtracts and
    /// overlapping awake stages never double-subtract. Returns the
    /// remaining asleep pieces in ascending order; empty when the
    /// session interval is empty or fully awake.
    private fun subtractAwake(
        sessionStart: Instant,
        sessionEnd: Instant,
        awakeIntervals: List<Pair<Instant, Instant>>
    ): List<Pair<Instant, Instant>> {
        if (!sessionEnd.isAfter(sessionStart)) return emptyList()
        val clampedAwake = mergeIntervals(awakeIntervals)
            .map { (awakeStart, awakeEnd) ->
                maxOf(awakeStart, sessionStart) to minOf(awakeEnd, sessionEnd)
            }
            .filter { it.first.isBefore(it.second) }
        if (clampedAwake.isEmpty()) return listOf(sessionStart to sessionEnd)
        val asleep = mutableListOf<Pair<Instant, Instant>>()
        var cursor = sessionStart
        for ((awakeStart, awakeEnd) in clampedAwake) {
            if (awakeStart.isAfter(cursor)) {
                asleep.add(cursor to awakeStart)
            }
            if (awakeEnd.isAfter(cursor)) {
                cursor = awakeEnd
            }
        }
        if (cursor.isBefore(sessionEnd)) {
            asleep.add(cursor to sessionEnd)
        }
        return asleep
    }

    /// Intraday HR read, chunked: the day is read in 4 × 6-hour
    /// windows, each paginated independently and each in its own
    /// try/catch, so one failing window or record set cannot zero
    /// the whole day (hardening: chunk + isolate). Samples flattened,
    /// mock records dropped, distinct by time, sorted ascending —
    /// semantics unchanged. Dart shapes:
    /// - all chunks OK: [{t: epochMs, bpm}] (legacy bare list)
    /// - some chunks failed: {samples: [...], partialError: details}
    /// - every chunk failed: HR_SAMPLES_READ_FAILED with the first
    ///   chunk's exception details, PLUS the outcome of an aggregate
    ///   probe (BPM_AVG over the day, a different HC service path):
    ///   if aggregates answer while record reads throw, the failure
    ///   is isolated to the record-level read path; if the probe
    ///   also throws, its exception is named too. Diagnostic only —
    ///   aggregate values never substitute for samples.
    private fun readHeartRateSamples(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
            val (dayStart, dayEnd) = dayRange(dateStr)
            val records = mutableListOf<HeartRateRecord>()
            val chunkErrors = mutableListOf<String>()
            var chunkStart = dayStart
            repeat(4) {
                val chunkEnd = minOf(chunkStart.plus(6, ChronoUnit.HOURS), dayEnd)
                try {
                    var pageToken: String? = null
                    do {
                        val response = client.readRecords(
                            ReadRecordsRequest(
                                recordType = HeartRateRecord::class,
                                timeRangeFilter = TimeRangeFilter.between(chunkStart, chunkEnd),
                                pageToken = pageToken
                            )
                        )
                        records.addAll(response.records)
                        pageToken = response.pageToken
                    } while (pageToken != null)
                } catch (e: Exception) {
                    chunkErrors.add(hcErrorDetails(e))
                }
                chunkStart = chunkEnd
            }
            if (chunkErrors.size == 4) {
                // Total failure: discriminate the failing layer with
                // one aggregate call before reporting.
                val probe = try {
                    client.aggregate(
                        AggregateRequest(
                            metrics = setOf(HeartRateRecord.BPM_AVG),
                            timeRangeFilter = TimeRangeFilter.between(dayStart, dayEnd)
                        )
                    )
                    "aggregate probe: OK"
                } catch (e2: Exception) {
                    "aggregate probe: failed (${hcErrorDetails(e2)})"
                }
                result.error(
                    "HR_SAMPLES_READ_FAILED",
                    "Could not read heart rate samples.",
                    "${chunkErrors.first()} | $probe"
                )
                return@launch
            }
            val samples = nonMock(records)
                .flatMap { record ->
                    record.samples.map { sample ->
                        sample.time.toEpochMilli() to sample.beatsPerMinute.toInt()
                    }
                }
                .distinctBy { it.first }
                .sortedBy { it.first }
                .map { mapOf("t" to it.first, "bpm" to it.second) }
            if (chunkErrors.isEmpty()) {
                result.success(samples)
            } else {
                result.success(
                    mapOf(
                        "samples" to samples,
                        "partialError" to chunkErrors.first()
                    )
                )
            }
        }
    }

    /// Grant-state probe (Dart `probeReadAccess`): one tiny real
    /// RECORD-PATH read — StepsRecord over today, first page only,
    /// results discarded (Vera F6: the defect lives in the record
    /// path; aggregates answer even when readRecords throws, so an
    /// aggregate probe could pass over a dead record layer). A
    /// SecurityException here while the grant list reports complete
    /// is the stale-grant signature. Success means THIS record read
    /// worked — it is not proof every read works. No health values
    /// cross the channel in either direction (success is a boolean;
    /// failure carries the exception class only).
    private fun probeReadAccess(result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
            try {
                val (start, end) = dayRange("today")
                client.readRecords(
                    ReadRecordsRequest(
                        recordType = StepsRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(start, end),
                        pageSize = 1
                    )
                )
                result.success(true)
            } catch (e: Exception) {
                result.error("PROBE_READ_FAILED", "Probe read failed.", hcErrorDetails(e))
            }
        }
    }

    /// `active ?: total` kcal (native rule); null when both are null.
    private fun readActiveCalories(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("CALORIES_READ_FAILED", "Could not read active calories.", hcErrorDetails(e))
            }
        }
    }

    /// Single-day sleep minutes for Home's today vitals, under the
    /// founder's summed-bouts rule (Oct 28, 2026) — the same rule
    /// readSleepHistory's Dart summarizer applies: a night's sleep
    /// is ALL its bouts added up. Candidate sessions are the
    /// nonMock sessions attributed to the requested date by the
    /// WAKE-DATE rule: the local date of a session's endTime must
    /// equal the requested date (read over [startOfDay-1day,
    /// endOfDay]) — the identical attribution readSleepHistory
    /// uses (its dateOf() helper), so a session is counted for
    /// exactly one date and the following night is never folded
    /// into a past date's read. For each candidate, its
    /// genuinely-asleep intervals are the
    /// session interval minus its merged awake-stage intervals
    /// (AWAKE, AWAKE_IN_BED, OUT_OF_BED — see [subtractAwake]);
    /// those asleep intervals are unioned across ALL candidate
    /// sessions (via [mergeIntervals], so overlapping bouts never
    /// double-count) and the result is the union's total whole
    /// minutes. Null when there are no candidate sessions; a union
    /// totalling 0 returns 0 (Dart applies the zero rule).
    private fun readSleepMinutes(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
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
                // Wake-date attribution (same rule as
                // readSleepHistory's dateOf()): a session counts
                // for the requested date only when the LOCAL DATE
                // of its endTime equals that date.
                val requestedDate = localDateOf(dateStr)
                val zone = ZoneId.systemDefault()
                val candidates = nonMock(response.records).filter { session ->
                    ZonedDateTime.ofInstant(session.endTime, zone)
                        .toLocalDate() == requestedDate
                }
                if (candidates.isEmpty()) {
                    result.success(null)
                    return@launch
                }
                val asleepIntervals = mutableListOf<Pair<Instant, Instant>>()
                for (session in candidates) {
                    val awakeIntervals = session.stages
                        .filter {
                            it.stage == SleepSessionRecord.STAGE_TYPE_AWAKE ||
                                it.stage == SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED ||
                                it.stage == SleepSessionRecord.STAGE_TYPE_OUT_OF_BED
                        }
                        .map { it.startTime to it.endTime }
                    asleepIntervals.addAll(
                        subtractAwake(session.startTime, session.endTime, awakeIntervals)
                    )
                }
                // Total the union in milliseconds and convert ONCE
                // (Vera C-1): per-piece toMinutes() would discard
                // each piece's sub-minute remainder and could
                // disagree with the Dart summarizer's whole-night
                // total by up to (pieces - 1) minutes.
                val minutesAsleep = mergeIntervals(asleepIntervals)
                    .sumOf { Duration.between(it.first, it.second).toMillis() }
                    .div(60000).toInt()
                result.success(minutesAsleep)
            } catch (e: Exception) {
                result.error("SLEEP_READ_FAILED", "Could not read sleep session.", hcErrorDetails(e))
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
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("SLEEP_STAGES_READ_FAILED", "Could not read sleep stages.", hcErrorDetails(e))
            }
        }
    }

    /// Non-mock records of the day, highest package priority, latest by
    /// time. Null when none.
    private fun readRestingHeartRate(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("RHR_READ_FAILED", "Could not read resting heart rate.", hcErrorDetails(e))
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
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("RHR_HISTORY_READ_FAILED", "Could not read resting heart rate history.", hcErrorDetails(e))
            }
        }
    }

    /// Per-day calories over [now-days, tomorrow start): `active ?: total`
    /// per day (native rule, 0 when both null — Dart treats 0 as missing).
    /// Dart shape: [{date: "YYYY-MM-DD", kcal}].
    private fun readCaloriesHistory(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 7).coerceIn(1, 180)
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("CALORIES_HISTORY_READ_FAILED", "Could not read calorie history.", hcErrorDetails(e))
            }
        }
    }

    /// BP records over [now-days, now), mock-filtered, sorted desc.
    /// Dart shape: [{t: epochMs, sys, dia}].
    private fun readBloodPressure(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 7).coerceIn(1, 180)
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("BP_READ_FAILED", "Could not read blood pressure records.", hcErrorDetails(e))
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
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("WEIGHT_READ_FAILED", "Could not read weight records.", hcErrorDetails(e))
            }
        }
    }

    /// Round 30 — latest height, native `readLatestHeight`
    /// (HealthConnectManager.kt:812-824): HeightRecords in the last
    /// 365 days, best record wins. Returns centimetres. Null when none.
    private fun readLatestHeightCm(result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("HEIGHT_READ_FAILED", "Could not read height records.", hcErrorDetails(e))
            }
        }
    }

    /// Step count for the day. Null when unavailable.
    private fun readSteps(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
            try {
                val (start, end) = dayRange(dateStr)
                val response = client.aggregate(
                    AggregateRequest(
                        metrics = setOf(StepsRecord.COUNT_TOTAL),
                        timeRangeFilter = TimeRangeFilter.between(start, end)
                    )
                )
                result.success(response[StepsRecord.COUNT_TOTAL]?.toInt())
            } catch (e: Exception) {
                result.error("STEPS_READ_FAILED", "Could not read steps.", hcErrorDetails(e))
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
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("RESPIRATORY_READ_FAILED", "Could not read respiratory rate.", hcErrorDetails(e))
            }
        }
    }

    /// Oxygen saturation: same 30-day lookback + best record as native.
    /// A raw value ≤ 1.0 is a fraction and is scaled to percent (native
    /// rule). Null when none.
    private fun readOxygenSaturation(dateStr: String?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("OXYGEN_READ_FAILED", "Could not read oxygen saturation.", hcErrorDetails(e))
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
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("HRV_READ_FAILED", "Could not read heart rate variability.", hcErrorDetails(e))
            }
        }
    }

    /// Raw HRV (RMSSD) samples over [tomorrowStart − days,
    /// tomorrowStart), read in ≤31-day chunks newest→oldest with
    /// paginated reads — the native `readHeartRateVariability`
    /// range mechanism. Mock records are dropped; NO day attribution
    /// or tier averaging happens here (Dart owns that, where it is
    /// testable): each sample crosses as {t: epochMs, ms, tier},
    /// where tier is the record origin's package-priority VALUE (no
    /// package names cross the bridge). Dart shape:
    /// [{t, ms, tier}] sorted ascending by t.
    ///
    /// Chunk isolation + partial contract mirror readSleepHistory
    /// exactly (Defect 0 / the F11 class): each chunk reads in its
    /// own try/catch, so one failing window (one bad chunk in a
    /// 90-day first-capture backfill) can no longer zero the whole
    /// read. Partial failure returns the surviving chunks' samples
    /// in the sleep map shape {items, partialError}; if EVERY chunk
    /// fails, the read still errors with the real exception class.
    private fun readHrvSamples(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 30).coerceIn(1, 3650)
        engineScope.launch {
            val zone = ZoneId.systemDefault()
            val end = ZonedDateTime.now(zone).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(n.toLong(), ChronoUnit.DAYS)
            val records = mutableListOf<HeartRateVariabilityRmssdRecord>()
            val chunkErrors = mutableListOf<String>()
            var chunkCount = 0
            var chunkEnd = end
            while (chunkEnd.isAfter(start)) {
                val chunkStart = maxOf(start, chunkEnd.minus(31, ChronoUnit.DAYS))
                chunkCount++
                try {
                    var pageToken: String? = null
                    do {
                        val response = client.readRecords(
                            ReadRecordsRequest(
                                recordType = HeartRateVariabilityRmssdRecord::class,
                                timeRangeFilter = TimeRangeFilter.between(chunkStart, chunkEnd),
                                pageToken = pageToken
                            )
                        )
                        records.addAll(response.records)
                        pageToken = response.pageToken
                    } while (pageToken != null)
                } catch (e: Exception) {
                    chunkErrors.add(hcErrorDetails(e))
                }
                chunkEnd = chunkStart
            }
            if (chunkErrors.size == chunkCount) {
                result.error(
                    "HRV_SAMPLES_READ_FAILED",
                    "Could not read heart rate variability samples.",
                    chunkErrors.first()
                )
                return@launch
            }
            try {
                val samples = nonMock(records)
                    .sortedBy { it.time }
                    .map { record ->
                        mapOf(
                            "t" to record.time.toEpochMilli(),
                            "ms" to record.heartRateVariabilityMillis,
                            "tier" to packagePriority(record.metadata.dataOrigin.packageName)
                        )
                    }
                if (chunkErrors.isEmpty()) {
                    result.success(samples)
                } else {
                    result.success(
                        mapOf(
                            "items" to samples,
                            "partialError" to chunkErrors.first()
                        )
                    )
                }
            } catch (e: Exception) {
                result.error("HRV_SAMPLES_READ_FAILED", "Could not read heart rate variability samples.", hcErrorDetails(e))
            }
        }
    }

    /// Raw sleep sessions over [tomorrowStart − days, tomorrowStart),
    /// shipped faithfully for Dart to total (founder decision
    /// Oct 28, 2026: a night's sleep = ALL its bouts added up).
    /// Kotlin no longer groups by date or picks a best session per
    /// date: EVERY nonMock session crosses the bridge as
    /// {date: "YYYY-MM-DD" (local date of the session's endTime —
    /// its wake-up date), startMs: epochMs, endMs: epochMs,
    /// awake: [[startMs, endMs], ...] for stages of type AWAKE,
    /// AWAKE_IN_BED and OUT_OF_BED, deep: [[startMs, endMs], ...]
    /// for stages of type DEEP}. Stage intervals ship RAW
    /// (unmerged, unclamped) — day attribution, interval merging /
    /// subtraction / union and the per-day totals live in Dart's
    /// summarizeSleepSessions in health_connect_service.dart, where
    /// they are testable (the codebase's attributeDailyHrv
    /// precedent: Dart owns that). Mirrors the readHrvSamples
    /// shipper pattern. NO package names cross the bridge.
    /// Sessions are sorted by date, then startMs. Partial contract
    /// is unchanged: a bare list when all chunks read OK,
    /// {items, partialError} when some chunks fail, and
    /// SLEEP_HISTORY_READ_FAILED only when every chunk fails.
    private fun readSleepHistory(days: Int?, result: MethodChannel.Result) {
        val client = hcClientOrError(result) ?: return
        val n = (days ?: 30).coerceIn(1, 3650)
        engineScope.launch {
            // Chunked + isolated like the HRV range read (and the HR
            // day read): ≤31-day windows newest→oldest, each paginated
            // in its own try/catch. One failing window cannot zero
            // the whole history; partial failure returns the sessions
            // that read plus the error (Dart map shape). If EVERY
            // window fails, the read fails with the real exception.
            val zone = ZoneId.systemDefault()
            val end = ZonedDateTime.now(zone).plusDays(1).truncatedTo(ChronoUnit.DAYS).toInstant()
            val start = end.minus(n.toLong(), ChronoUnit.DAYS)
            val records = mutableListOf<SleepSessionRecord>()
            val chunkErrors = mutableListOf<String>()
            var chunkCount = 0
            var chunkEnd = end
            while (chunkEnd.isAfter(start)) {
                val chunkStart = maxOf(start, chunkEnd.minus(31, ChronoUnit.DAYS))
                chunkCount++
                try {
                    var pageToken: String? = null
                    do {
                        val response = client.readRecords(
                            ReadRecordsRequest(
                                recordType = SleepSessionRecord::class,
                                timeRangeFilter = TimeRangeFilter.between(chunkStart, chunkEnd),
                                pageToken = pageToken
                            )
                        )
                        records.addAll(response.records)
                        pageToken = response.pageToken
                    } while (pageToken != null)
                } catch (e: Exception) {
                    chunkErrors.add(hcErrorDetails(e))
                }
                chunkEnd = chunkStart
            }
            if (chunkErrors.size == chunkCount) {
                result.error(
                    "SLEEP_HISTORY_READ_FAILED",
                    "Could not read sleep history.",
                    chunkErrors.first()
                )
                return@launch
            }
            try {
                fun dateOf(instant: Instant): String =
                    ZonedDateTime.ofInstant(instant, zone).toLocalDate().toString()

                fun stageIntervalsMs(
                    session: SleepSessionRecord,
                    vararg types: Int
                ): List<List<Long>> =
                    session.stages
                        .filter { it.stage in types }
                        .map {
                            listOf(
                                it.startTime.toEpochMilli(),
                                it.endTime.toEpochMilli()
                            )
                        }

                val out = nonMock(records)
                    .sortedWith(
                        compareBy<SleepSessionRecord> { dateOf(it.endTime) }
                            .thenBy { it.startTime.toEpochMilli() }
                    )
                    .map { session ->
                        mapOf(
                            "date" to dateOf(session.endTime),
                            "startMs" to session.startTime.toEpochMilli(),
                            "endMs" to session.endTime.toEpochMilli(),
                            "awake" to stageIntervalsMs(
                                session,
                                SleepSessionRecord.STAGE_TYPE_AWAKE,
                                SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
                                SleepSessionRecord.STAGE_TYPE_OUT_OF_BED
                            ),
                            "deep" to stageIntervalsMs(
                                session,
                                SleepSessionRecord.STAGE_TYPE_DEEP
                            )
                        )
                    }
                if (chunkErrors.isEmpty()) {
                    result.success(out)
                } else {
                    result.success(
                        mapOf(
                            "items" to out,
                            "partialError" to chunkErrors.first()
                        )
                    )
                }
            } catch (e: Exception) {
                result.error("SLEEP_HISTORY_READ_FAILED", "Could not read sleep history.", hcErrorDetails(e))
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
        engineScope.launch {
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
            } catch (e: Exception) {
                result.error("SPIKE_COUNTS_READ_FAILED", "Could not read heart rate spikes.", hcErrorDetails(e))
            }
        }
    }

    /// Native `exportMetricsCsvAsync` file hand-off: writes the CSV to
    /// the cache dir, copies it into Downloads via MediaStore, then
    /// opens the share sheet (ACTION_SEND chooser, FileProvider URI,
    /// "Share Biometrics CSV"). Success = the chooser was launched.
    private fun exportCsvFile(fileName: String?, content: String?, result: MethodChannel.Result) {
        // Activity-bound (the share sheet): with no Activity
        // attached (background engine) fail with this method's
        // existing error code, before writing anything.
        val act = activity
        if (act == null) {
            result.error("CSV_EXPORT_FAILED", "Could not export the CSV file.", null)
            return
        }
        try {
            val name = fileName?.takeIf { it.isNotBlank() } ?: "jot_metrics.csv"
            val bytes = (content ?: "").toByteArray(Charsets.UTF_8)
            val cacheFile = java.io.File(applicationContext.cacheDir, name)
            cacheFile.writeBytes(bytes)

            val resolver = applicationContext.contentResolver
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
                applicationContext, "${applicationContext.packageName}.provider", cacheFile
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, shareUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            act.startActivity(Intent.createChooser(intent, "Share Biometrics CSV"))
            result.success(true)
        } catch (e: Exception) {
            result.error("CSV_EXPORT_FAILED", "Could not export the CSV file.", hcErrorDetails(e))
        }
    }

    /// Report PDF Downloads copy (report-pdf fix, Juno Ruling 2's
    /// native half): writes [bytes] — the exact bytes Dart generated
    /// and will share, never a regeneration — into the public
    /// Downloads collection via MediaStore, scoped-storage
    /// compliant, with NO storage permission requested. Not
    /// Activity-bound (no share sheet), so it also works whenever
    /// the plugin is attached. Success only when the bytes are
    /// fully written and the row is published (IS_PENDING cleared);
    /// a partial write deletes its row so Downloads never keeps a
    /// truncated copy. Pre-Android-10 devices have no permission-
    /// free Downloads path (MediaStore relative paths start at Q),
    /// so they fail honestly with DOWNLOADS_SAVE_FAILED instead of
    /// the app requesting a broad storage permission.
    private fun savePdfToDownloads(fileName: String?, bytes: ByteArray?, result: MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
            result.error("DOWNLOADS_SAVE_FAILED", "Could not save the PDF to Downloads.", null)
            return
        }
        val name = fileName?.takeIf { it.isNotBlank() }
        if (name == null || bytes == null || bytes.isEmpty()) {
            result.error("DOWNLOADS_SAVE_FAILED", "Could not save the PDF to Downloads.", null)
            return
        }
        val resolver = applicationContext.contentResolver
        var uri: android.net.Uri? = null
        try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            if (uri == null) {
                result.error("DOWNLOADS_SAVE_FAILED", "Could not save the PDF to Downloads.", null)
                return
            }
            val stream = resolver.openOutputStream(uri)
            if (stream == null) {
                resolver.delete(uri, null, null)
                result.error("DOWNLOADS_SAVE_FAILED", "Could not save the PDF to Downloads.", null)
                return
            }
            stream.use { it.write(bytes) }
            val publish = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, publish, null, null)
            result.success(true)
        } catch (e: Exception) {
            // Never leave a partial/pending row behind on failure.
            if (uri != null) {
                try {
                    resolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
            }
            result.error("DOWNLOADS_SAVE_FAILED", "Could not save the PDF to Downloads.", hcErrorDetails(e))
        }
    }
}
