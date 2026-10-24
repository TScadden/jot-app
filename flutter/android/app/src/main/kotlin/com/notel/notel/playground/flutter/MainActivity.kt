package com.notel.notel.playground.flutter

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognizerIntent
import androidx.core.content.ContextCompat
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.health.connect.client.PermissionController
import com.notel.notel.playground.flutter.health_connect_bridge.HealthConnectBridgePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Round 12: Health Connect bridge for the connections screen (and future
/// onboarding connections step). The bridge's channel handlers now live
/// in HealthConnectBridgePlugin (local plugin package
/// plugins/health_connect_bridge) so the generated plugin registrant
/// installs them on every FlutterEngine — the main engine AND the
/// WorkManager background engine. This Activity keeps exactly one HC
/// job: owning the permission launcher (below).
///
/// NOTE: extends FlutterFragmentActivity (not FlutterActivity) because the
/// permission launcher needs ComponentActivity's ActivityResultRegistry —
/// plain FlutterActivity extends android.app.Activity, which has none.
///
/// Team-lessons applied (see ~/workspace/team/memory/LESSONS.md):
/// - Permission launcher registered in onCreate() via activityResultRegistry
///   (NOT in configureFlutterEngine — the fragment transaction timing there
///   can throw or silently never fire). The plugin never registers its
///   own launcher; it launches through the one registered here.
/// - Runtime request set = the 14 record-type reads + HISTORY, exactly like
///   the native app. READ_HEALTH_DATA_IN_BACKGROUND is never in this set.
/// - No silent failures: every error path returns a visible error code.
/// - Stuck-request guard: an in-flight request older than the timeout is
///   superseded, never stacked; Dart can also explicitly cancel.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        const val VOICE_CHANNEL = "com.notel.notel.playground.flutter/voice"
        const val FILE_PICKER_CHANNEL = "com.notel.notel.playground.flutter/file_picker"
        const val CALENDAR_CHANNEL = "com.notel.notel.playground.flutter/calendar"
        // TAKEOVER integration (billing gate): deliberately NOT
        // playground-prefixed — the channel name is fixed by the
        // billing branch's probe (billing_play_store.dart
        // probePackageName(): MethodChannel('com.notel.notel/app_info'),
        // invokeMethod<String>('getPackageName')). The handler returns
        // this context's package name, so the SAME MainActivity answers
        // com.notel.notel.playground.flutter in the Lab build (billing
        // gate stays closed there — that is the point) and
        // com.notel.notel in the prod build.
        const val APP_INFO_CHANNEL = "com.notel.notel/app_info"
        // Round 48: BP CSV import cap, same as native MAX_CSV_FILE_BYTES.
        private const val MAX_CSV_FILE_BYTES = 5 * 1024 * 1024
        // Round 65: knowledge-document pick cap (see doc picker).
        private const val MAX_DOC_FILE_BYTES = 15 * 1024 * 1024
        // TAKEOVER Phase 4: migration-bundle pick cap. A bundle can
        // carry the extracted-knowledge store, so it gets more room
        // than a CSV; past this the export almost certainly is not
        // a migration file.
        private const val MAX_MIGRATION_FILE_BYTES = 25 * 1024 * 1024
        // TAKEOVER Phase 4 fix (Vera LOW): the migration export is
        // plaintext health data sitting in cacheDir — it must not
        // linger. Canonical export name (MigrationBundleService
        // .fileName on the Dart side); swept on every launch, and a
        // share also schedules its own deletion (see
        // scheduleMigrationExportCleanup). The delay after the
        // chooser returns gives the receiving app time to actually
        // read the file through its FileProvider URI before it
        // disappears; the launch sweep is the backstop for a
        // process that dies before the delay elapses.
        private const val MIGRATION_EXPORT_FILE_NAME = "tabs-lab-migration.json"
        private const val MIGRATION_EXPORT_CLEANUP_DELAY_MS = 60 * 1000L
        private const val REQUEST_TIMEOUT_MS = 5 * 60 * 1000L
    }

    private lateinit var permissionLauncher: ActivityResultLauncher<Set<String>>

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

    // Round 65: document picker for Digital Knowledge Extraction.
    // A second GetContent launcher (native SettingsScreen launches
    // GetContent "*/*" for the same flow); its callback returns the
    // picked file's display name, MIME type, and base64 bytes —
    // the triple native ingestFile derives from the Uri. The CSV
    // launcher above returns decoded text only, which would
    // destroy PDFs/images before extraction.
    private lateinit var docPickerLauncher: ActivityResultLauncher<String>
    private var pendingDocResult: MethodChannel.Result? = null

    // TAKEOVER Phase 4: migration-bundle picker for "Import from
    // Tabs Lab". A third GetContent launcher on the file_picker
    // channel; returns the picked file's TEXT (the bundle is one
    // JSON document). Registered in onCreate like every launcher.
    private lateinit var migrationPickerLauncher: ActivityResultLauncher<String>
    private var pendingMigrationResult: MethodChannel.Result? = null

    // TAKEOVER Phase 4 fix (Vera LOW): the migration SHARE chooser
    // runs through a result launcher (registered in onCreate like
    // every launcher) so its return can trigger deletion of the
    // plaintext export file it served.
    private lateinit var migrationShareLauncher: ActivityResultLauncher<Intent>
    private var pendingMigrationShareFile: java.io.File? = null

    // Round 54: calendar permission launcher for the Health Coach
    // (native CoachScreen.kt:89-113 requests READ+WRITE together at
    // first approve). Registered in onCreate like the HC launcher.
    private lateinit var calendarPermissionLauncher: ActivityResultLauncher<Array<String>>
    private var pendingCalendarResult: MethodChannel.Result? = null
    private var pendingCalendarSince: Long = 0L

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Refresh keep-alive tap (Oct 20, 2026): this Activity is
        // singleTop, so a tap on the keep-alive notification while
        // the app is alive arrives HERE, not in onCreate. Forward
        // the date extra to the plugin (the same Activity→plugin
        // publish seam as the HC permission launcher below); Dart
        // consumes it via the plugin's takePendingScoreTap.
        setIntent(intent)
        HealthConnectBridgePlugin.publishScoreTapFromIntent(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Refresh keep-alive tap, cold-start half: a tap that
        // launched the app carries the refresh date extra on this
        // intent (see onNewIntent for the live-delivery half).
        HealthConnectBridgePlugin.publishScoreTapFromIntent(intent)
        // Vera LOW backstop: a migration export left in cacheDir by
        // a previous session (chooser never returned, process died,
        // or a build predating the cleanup) is deleted on launch —
        // plaintext health data never survives into a new session.
        try {
            java.io.File(cacheDir, MIGRATION_EXPORT_FILE_NAME).delete()
        } catch (_: Exception) {
            // Best-effort hygiene only; a failed sweep must never
            // block startup.
        }
        // Registered here in onCreate — never in configureFlutterEngine()
        // (the fragment-transaction timing there can throw or silently never
        // fire). Same semantics as Compose's rememberLauncherForActivityResult.
        permissionLauncher = activityResultRegistry.register(
            "hc_permission_launcher",
            PermissionController.createRequestPermissionResultContract()
        ) { granted: Set<String> ->
            // The pending state lives in HealthConnectBridgePlugin
            // now; the plugin instance that launched the request has
            // claimed the result route, and a delivery with no claim
            // is stale and dropped (the old pendingResult == null
            // early return).
            HealthConnectBridgePlugin.deliverPermissionResult(granted)
        }
        // Publish the registered launcher to the plugin (cleared in
        // onDestroy). Registration stays HERE, in onCreate — never in
        // configureFlutterEngine and never in the plugin (team
        // lesson: the fragment-transaction timing there can throw or
        // silently never fire).
        HealthConnectBridgePlugin.activityPermissionLauncher = permissionLauncher
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
        docPickerLauncher = activityResultRegistry.register(
            "doc_picker_launcher",
            ActivityResultContracts.GetContent()
        ) { uri ->
            val r = pendingDocResult
            pendingDocResult = null
            if (r == null) return@register // stale (superseded)
            if (uri == null) {
                // User cancelled — a null success, not an error.
                try { r.success(null) } catch (_: Exception) { }
                return@register
            }
            // Resolve name/MIME exactly like native ingestFile:
            // display name from the content resolver, MIME from
            // getType with the same "application/pdf" fallback.
            val mimeType = contentResolver.getType(uri) ?: "application/pdf"
            var displayName = "unknown_file"
            try {
                contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && cursor.moveToFirst()) {
                        displayName = cursor.getString(idx) ?: displayName
                    }
                }
            } catch (_: Exception) { }
            // Read off the main thread with a 15 MB cap (Gemini's
            // inline-data requests are the real ceiling; a file
            // past this cap could never be extracted, so failing
            // visibly here beats a doomed upload).
            Thread {
                var failureCode: String? = null
                var failureMessage: String? = null
                var base64: String? = null
                try {
                    val stream = contentResolver.openInputStream(uri)
                    if (stream == null) {
                        failureCode = "READ_FAILED"
                        failureMessage = "Couldn't read this file. Please try a different file."
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
                                if (total > MAX_DOC_FILE_BYTES) {
                                    tooLarge = true
                                    break
                                }
                                out.write(buf, 0, n)
                            }
                            if (tooLarge) {
                                failureCode = "TOO_LARGE"
                                failureMessage = "This file is too large to add. The limit is 15 MB."
                            } else {
                                base64 = android.util.Base64.encodeToString(
                                    out.toByteArray(), android.util.Base64.NO_WRAP)
                            }
                        }
                    }
                } catch (e: Exception) {
                    failureCode = "READ_FAILED"
                    failureMessage = "Couldn't read this file. Please try a different file."
                }
                val nameSnapshot = displayName
                runOnUiThread {
                    val code = failureCode
                    val b64 = base64
                    try {
                        if (code != null) {
                            r.error(code, failureMessage, null)
                        } else if (b64 == null) {
                            r.error("READ_FAILED",
                                "Couldn't read this file. Please try a different file.", null)
                        } else {
                            r.success(mapOf(
                                "name" to nameSnapshot,
                                "mimeType" to mimeType,
                                "base64Data" to b64
                            ))
                        }
                    } catch (_: Exception) {
                        // Result already consumed — nothing to do.
                    }
                }
            }.start()
        }
        migrationPickerLauncher = activityResultRegistry.register(
            "migration_picker_launcher",
            ActivityResultContracts.GetContent()
        ) { uri ->
            val r = pendingMigrationResult
            pendingMigrationResult = null
            if (r == null) return@register // stale (superseded)
            if (uri == null) {
                // User cancelled the picker — a null success, not an
                // error (Dart treats null as "no file chosen").
                try { r.success(null) } catch (_: Exception) { }
                return@register
            }
            // Read off the main thread with the migration cap
            // (CSV-picker semantics: TooLarge / Failed / Ok with
            // the BOM stripped).
            Thread {
                var failureCode: String? = null
                var failureMessage: String? = null
                var text: String? = null
                try {
                    val stream = contentResolver.openInputStream(uri)
                    if (stream == null) {
                        failureCode = "READ_FAILED"
                        failureMessage = "Couldn't read this file. Please try a different file."
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
                                if (total > MAX_MIGRATION_FILE_BYTES) {
                                    tooLarge = true
                                    break
                                }
                                out.write(buf, 0, n)
                            }
                            if (tooLarge) {
                                failureCode = "TOO_LARGE"
                                failureMessage = "This file is too large to import. The limit is 25 MB."
                            } else {
                                text = out.toString(Charsets.UTF_8.name()).removePrefix("\uFEFF")
                            }
                        }
                    }
                } catch (e: Exception) {
                    failureCode = "READ_FAILED"
                    failureMessage = "Couldn't read this file. Please try a different file."
                }
                runOnUiThread {
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
        migrationShareLauncher = activityResultRegistry.register(
            "migration_share_launcher",
            ActivityResultContracts.StartActivityForResult()
        ) { _ ->
            // The share chooser has returned: schedule deletion of
            // the plaintext export file (Vera LOW). The result code
            // is meaningless for a chooser — cleanup happens either
            // way, sent or cancelled.
            val file = pendingMigrationShareFile
            pendingMigrationShareFile = null
            if (file != null) scheduleMigrationExportCleanup(file)
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

    override fun onDestroy() {
        // Unpublish the HC permission launcher so a background engine
        // in this process can never launch through a dead Activity's
        // launcher — it gets the plugin's NO_LAUNCHER error instead.
        if (HealthConnectBridgePlugin.activityPermissionLauncher === permissionLauncher) {
            HealthConnectBridgePlugin.activityPermissionLauncher = null
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The Health Connect channel (HC_CHANNEL) is NOT wired here:
        // it is registered by HealthConnectBridgePlugin, a local
        // FlutterPlugin, so the generated registrant installs it on
        // every engine — including the WorkManager background engine,
        // where this Activity's handlers never existed. The Activity
        // still owns the HC permission launcher (see onCreate).
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
                    // Round 65: knowledge-document pick (name/MIME/
                    // base64) for Digital Knowledge Extraction.
                    "pickDocumentFile" -> pickDocumentFile(result)
                    // TAKEOVER Phase 4: migration-bundle pick + share
                    // (Lab export → production import).
                    "pickMigrationText" -> pickMigrationText(result)
                    "shareMigrationFile" -> shareMigrationFile(
                        call.argument<String>("fileName"),
                        call.argument<String>("content"),
                        result
                    )
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
        // TAKEOVER integration (billing gate): package-name probe for
        // the billing branch's BillingEnvironment. Contract (matches
        // billing_play_store.dart probePackageName exactly):
        //   channel: com.notel.notel/app_info
        //   method:  getPackageName  (no arguments)
        //   returns: String — this context's package name
        // The billing gate is an AND: this answer must equal
        // com.notel.notel AND the build must carry
        // --dart-define=TABS_PRODUCTION_BILLING=true (prod CI only).
        // In the Lab this returns the Lab package name, so the gate
        // stays closed. Error path returns a visible code — never a
        // silent null that could be misread (team lesson).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPackageName" -> {
                        try {
                            result.success(packageName)
                        } catch (e: Exception) {
                            result.error("PACKAGE_NAME_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Round 48: launches the system file picker and returns the
    /// picked file's text to Dart (null when the user cancels).
    /// Every failure path returns a visible error code — never a
    /// silent no-op.
    /// Round 65: launches the system document picker for Digital
    /// Knowledge Extraction. Every failure path returns a visible
    /// error code — never a silent no-op.
    private fun pickDocumentFile(result: MethodChannel.Result) {
        if (pendingDocResult != null) {
            result.error("IN_FLIGHT", "A file pick is already in progress", null)
            return
        }
        if (!::docPickerLauncher.isInitialized) {
            result.error("UNAVAILABLE", "Couldn't open the file picker.", null)
            return
        }
        pendingDocResult = result
        try {
            docPickerLauncher.launch("*/*")
        } catch (e: Exception) {
            pendingDocResult = null
            result.error("LAUNCH_FAILED", "Couldn't open the file picker.", null)
        }
    }

    /// TAKEOVER Phase 4: launches the system file picker and returns
    /// the picked migration bundle's text to Dart (null when the user
    /// cancels). Every failure path returns a visible error code —
    /// never a silent no-op.
    private fun pickMigrationText(result: MethodChannel.Result) {
        if (pendingMigrationResult != null) {
            result.error("IN_FLIGHT", "A file pick is already in progress", null)
            return
        }
        if (!::migrationPickerLauncher.isInitialized) {
            result.error("UNAVAILABLE", "Couldn't open the file picker.", null)
            return
        }
        pendingMigrationResult = result
        try {
            migrationPickerLauncher.launch("*/*")
        } catch (e: Exception) {
            pendingMigrationResult = null
            result.error("LAUNCH_FAILED", "Couldn't open the file picker.", null)
        }
    }

    /// TAKEOVER Phase 4: export hand-off for the migration bundle —
    /// the Round 48 CSV pattern (cache-dir file + FileProvider URI +
    /// ACTION_SEND chooser), with two deliberate differences: the
    /// MIME type is application/json, and there is NO MediaStore
    /// copy to Downloads. The bundle carries health data; the share
    /// sheet is the delivery, not a second plaintext copy left on
    /// shared storage. Success = the chooser was launched.
    private fun shareMigrationFile(fileName: String?, content: String?, result: MethodChannel.Result) {
        try {
            val name = fileName?.takeIf { it.isNotBlank() } ?: MIGRATION_EXPORT_FILE_NAME
            val bytes = (content ?: "").toByteArray(Charsets.UTF_8)
            val cacheFile = java.io.File(cacheDir, name)
            cacheFile.writeBytes(bytes)
            val shareUri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.provider", cacheFile
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, shareUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(intent, "Share Tabs data")
            if (::migrationShareLauncher.isInitialized) {
                // Chooser via the result launcher: its return
                // schedules the export file's deletion (Vera LOW).
                pendingMigrationShareFile = cacheFile
                migrationShareLauncher.launch(chooser)
            } else {
                // Launcher missing (should not happen — it is
                // registered in onCreate): still share, and still
                // schedule the cleanup directly.
                startActivity(chooser)
                scheduleMigrationExportCleanup(cacheFile)
            }
            result.success(true)
        } catch (_: Exception) {
            pendingMigrationShareFile = null
            result.error("SHARE_FAILED", "Could not share the export file.", null)
        }
    }

    /// Schedules deletion of a shared migration export file after
    /// a grace delay (the receiving app reads it through the
    /// FileProvider URI once the chooser returns; deleting in the
    /// same instant could race that read). Only deletes when the
    /// file is still the exact write that was shared — a newer
    /// export under the same name (newer mtime) is left for its
    /// own cleanup / the next-launch sweep. Never throws.
    private fun scheduleMigrationExportCleanup(file: java.io.File) {
        try {
            val sharedModified = file.lastModified()
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    if (file.lastModified() == sharedModified) file.delete()
                } catch (_: Exception) {
                }
            }, MIGRATION_EXPORT_CLEANUP_DELAY_MS)
        } catch (_: Exception) {
            // The next-launch sweep in onCreate is the backstop.
        }
    }

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
    /// caught natively and yields an empty list; mirrored here —
    /// with ONE deliberate exception (takeover disclosures, audit
    /// P4): a SecurityException means calendar permission is not
    /// granted, and it surfaces as a PERMISSION_DENIED error so
    /// Dart substitutes native's "Calendar events are unavailable
    /// right now." context. An empty success here must mean the
    /// calendar is genuinely empty, never "permission missing".
    private fun getUpcomingCalendarEvents(result: MethodChannel.Result) {
        Thread {
            val events = mutableListOf<Map<String, Any?>>()
            var permissionDenied = false
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
                } catch (_: SecurityException) {
                    // P4 (see function doc): permission is missing —
                    // do NOT fall through to an empty-list success.
                    permissionDenied = true
                } catch (_: Exception) {
                    // B-10: a non-Security query failure must NOT fall
                    // through to an empty-list success (Dart renders that
                    // as "No events found.", a false signal). Mirror the
                    // outer catch: signal CALENDAR_READ_FAILED so Dart
                    // substitutes "Calendar events are unavailable
                    // right now."
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
            if (permissionDenied) {
                runOnUiThread {
                    try {
                        result.error(
                            "PERMISSION_DENIED",
                            "Calendar permission is not granted.",
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
