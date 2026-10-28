import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Round 32 — on-device onboarding state, mirroring the native
/// DataStore keys in `NotelPreferences.kt` one for one:
///
/// - `onboarding_complete` (bool, default false) — :47 key, :457-458
///   flow. THE completion flag: native's `SplashViewModel.checkAuthState`
///   reads it at startup (`SplashScreen.kt:39-53`) and native's
///   `SetupLoadingViewModel.finalizeSetup` sets it true
///   (`SetupLoadingScreen.kt:87`) before pushing the profile.
/// - `has_consented` (bool, default false) — :49 key, :281 flow.
///   Set by the consent step (`MainActivity.kt` consent route).
/// - `intro_consultation_seen` (bool, default false) — :50 key, :286
///   flow. Set by the consultation-intro step.
/// - `user_context` (string, default "") — :51 key, :469-470 flow.
///   The profile-setup free text; pushed to the server as the profile
///   field `userContext` (`SyncManager.pushProfileData`).
/// - `user_conditions` (string JSON array, default "[]") — :52 key,
///   :474 flow. Written by native's `ConditionRepository` as a JSON
///   string of condition names; pushed as the profile field
///   `conditions` (the same JSON string).
/// - `onboarding_owner_email` (string, default absent) — Flutter-only
///   account binding (Oct 28, 2026, founder seed findings): the store
///   holds one account's profile context and conditions, and the
///   onboarding screens prefill from it local-first, so the state is
///   owner-stamped and wiped on an account mismatch at login /
///   register ([clearIfOwnerMismatch], the CoachMemoryStore /
///   MigraineAttackStore pattern). Before this key existed the store
///   was global: any state left on the device — by a previous
///   account or an older app generation — prefilled the NEXT
///   account's onboarding and was pushed into its server profile.
///
/// Storage follows the app's existing pattern ([SettingsStore],
/// [SessionStore]): flutter_secure_storage (Android Keystore-backed
/// EncryptedSharedPreferences), injectable read/write/delete for tests.
///
/// The server copy of the completion state is the profile field
/// `onboardingComplete` in `POST /api/sync/profile`
/// (`SyncProfileRequest.onboardingComplete`, JotApi.kt); the sync pull
/// restores it (`SyncManager.pullAllData`, profile handling) — the
/// AppFlow startup resolver applies the same reconciliation.
class OnboardingStore {
  static const onboardingCompleteKey = 'onboarding_complete';
  static const hasConsentedKey = 'has_consented';
  static const introConsultationSeenKey = 'intro_consultation_seen';
  static const userContextKey = 'user_context';
  static const userConditionsKey = 'user_conditions';
  static const ownerEmailKey = 'onboarding_owner_email';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  OnboardingStore();

  OnboardingStore._(this._read, this._write, this._delete);

  @visibleForTesting
  factory OnboardingStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  }) =>
      OnboardingStore._(read, write, delete);

  Future<bool> _readBool(String key, bool fallback) async {
    try {
      final v = await _read(key);
      if (v == 'true') return true;
      if (v == 'false') return false;
    } catch (_) {}
    return fallback;
  }

  Future<void> _writeBool(String key, bool value) =>
      _write(key, value ? 'true' : 'false');

  /// Native default false (NotelPreferences.kt:458).
  Future<bool> getOnboardingComplete() =>
      _readBool(onboardingCompleteKey, false);
  Future<void> setOnboardingComplete(bool v) =>
      _writeBool(onboardingCompleteKey, v);

  /// Native default false (NotelPreferences.kt:281).
  Future<bool> getHasConsented() => _readBool(hasConsentedKey, false);
  Future<void> setHasConsented(bool v) => _writeBool(hasConsentedKey, v);

  /// Native default false (NotelPreferences.kt:286).
  Future<bool> getIntroConsultationSeen() =>
      _readBool(introConsultationSeenKey, false);
  Future<void> setIntroConsultationSeen(bool v) =>
      _writeBool(introConsultationSeenKey, v);

  /// True when ANY onboarding key has ever been written on this
  /// device. Distinguishes an account that entered the Round 32 flow
  /// (its steps write flags as they complete, and registration stamps
  /// `onboarding_complete=false` up front) from a pre-Round-32 stored
  /// session, which has no onboarding keys at all — native marks such
  /// existing accounts complete (login and pull both set the flag),
  /// and the startup resolver does the same instead of dropping an
  /// existing user into onboarding.
  Future<bool> hasAnyState() async {
    for (final k in const [
      onboardingCompleteKey,
      hasConsentedKey,
      introConsultationSeenKey,
      userContextKey,
      userConditionsKey,
      ownerEmailKey,
    ]) {
      try {
        if (await _read(k) != null) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Native default "" (NotelPreferences.kt:470).
  Future<String> getUserContext() async {
    try {
      return await _read(userContextKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> setUserContext(String v) => _write(userContextKey, v);

  /// The raw stored JSON (native default "[]").
  Future<String> getUserConditionsRaw() async {
    try {
      return await _read(userConditionsKey) ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  /// Selected condition names, decoded from the stored JSON array.
  /// Malformed storage reads as an empty selection (never throws).
  Future<List<String>> getConditions() async {
    final raw = await getUserConditionsRaw();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => '$e').where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Persists the selection in native's shape: a JSON array string of
  /// condition names (ConditionRepository.persistAndScheduleSync).
  Future<void> setConditions(List<String> conditions) =>
      _write(userConditionsKey, jsonEncode(conditions));

  /// Wipes every onboarding key. Called from AppFlow's logout path
  /// (which also serves Round 29's "Reset Account Status" — native
  /// `SettingsViewModel.restartOnboarding` calls
  /// `preferences.clearCredentials()`, a FULL DataStore clear, before
  /// logging out, so the next account on this device starts
  /// onboarding from a clean slate).
  Future<void> clear() async {
    for (final k in const [
      onboardingCompleteKey,
      hasConsentedKey,
      introConsultationSeenKey,
      userContextKey,
      userConditionsKey,
      ownerEmailKey,
    ]) {
      try {
        await _delete(k);
      } catch (_) {}
    }
  }

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// Login/register ownership enforcement, mirroring
  /// [CoachMemoryStore.clearIfOwnerMismatch]: onboarding state is
  /// account-bound. When the stored owner differs from [email] —
  /// including legacy state with NO owner stamp, which predates the
  /// binding and cannot be attributed to the signing-in account —
  /// every onboarding key is wiped and the store is re-stamped to
  /// [email], so a previous account's (or an older app generation's)
  /// context text and conditions can never prefill this account's
  /// onboarding or be pushed into its server profile. State stamped
  /// to [email] itself is preserved (same-account resume). Returns
  /// true when a wipe happened. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    try {
      final owner = _normalizeEmail(await _read(ownerEmailKey));
      if (owner == expected) return false;
      final hadState = owner != null || await hasAnyState();
      if (hadState) await clear();
      await _write(ownerEmailKey, expected);
      return hadState;
    } catch (_) {
      return false;
    }
  }
}
