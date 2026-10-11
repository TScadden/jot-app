package com.notel.notel.playground.flutter

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.result.ActivityResultLauncher
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
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch

/// Round 12: Health Connect bridge for the connections screen (and future
/// onboarding connections step).
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
class MainActivity : FlutterActivity() {

    companion object {
        const val HC_CHANNEL = "com.notel.notel.playground.flutter/health_connect"
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Registered here in onCreate — never in configureFlutterEngine()
        // (the fragment-transaction timing there can throw or silently never
        // fire). Equivalent to activityResultRegistry.register(...).
        permissionLauncher = registerForActivityResult(
            PermissionController.createRequestPermissionResultContract()
        ) { granted: Set<String> ->
            val r = pendingResult
            pendingResult = null
            if (r == null) return@registerForActivityResult // stale (timed out / cancelled / superseded)
            try {
                r.success(granted.toList())
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
                    else -> result.notImplemented()
                }
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
}
