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

  /// Flow3 (Nov 19, 2026) — resume marker: the index (into the
  /// flow3 step order consent=0, profileSetup=1, conditions=2,
  /// connections=3, gems=4, membership=5, setupLoading=6) of the
  /// step a mid-flow user left at, written as each step completes.
  /// Absent = no flow3 resume pending.
  static const stepMarkerKey = 'onboarding_step_v1';

  /// Flow3 — set true only when the NEW flow's setup-loading step
  /// completes. Gates the one-time post-onboarding notification
  /// card on Home: users who completed onboarding under older
  /// flows never carry this key, so they are never nagged.
  static const flow3CompletedKey = 'onboarding_flow3_completed';

  /// Flow3 — set once the post-onboarding notification card has
  /// been shown (whichever button the user picked).
  static const flow3NotifPromptShownKey =
      'onboarding_flow3_notif_prompt_shown';

  /// Onboarding reorder (Nov 27, 2026) — pre-account phase keys.
  /// Device-scoped (never owner-stamped until registration carries
  /// the answers forward): the user walks consent → profile →
  /// conditions → connections → gems BEFORE an account exists.
  /// [preAccountInProgressKey] marks a live pre-account run — it
  /// is what distinguishes carry-forward state from FOREIGN
  /// unstamped state (which registration must still wipe).
  static const preAccountInProgressKey =
      'onboarding_pre_account_in_progress';
  static const preAccountLastActivityKey =
      'onboarding_pre_account_last_activity';

  /// Pre-account abandonment window (Juno ruling 3): answers +
  /// marker expire 30 days after the last pre-account activity.
  static const preAccountTtl = Duration(days: 30);

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
  /// Flow3 resume marker (see [stepMarkerKey]). Null when absent
  /// or malformed.
  Future<int?> getStepMarker() async {
    try {
      final v = await _read(stepMarkerKey);
      return v == null ? null : int.tryParse(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> setStepMarker(int stepIndex) =>
      _write(stepMarkerKey, '$stepIndex');

  Future<void> clearStepMarker() async {
    try {
      await _delete(stepMarkerKey);
    } catch (_) {}
  }

  Future<bool> getFlow3Completed() => _readBool(flow3CompletedKey, false);
  Future<void> setFlow3Completed(bool v) => _writeBool(flow3CompletedKey, v);

  // ── Pre-account phase (onboarding reorder, Nov 27, 2026) ─────

  Future<bool> getPreAccountInProgress() =>
      _readBool(preAccountInProgressKey, false);
  Future<void> setPreAccountInProgress(bool v) =>
      _writeBool(preAccountInProgressKey, v);

  Future<DateTime?> getPreAccountLastActivity() async {
    try {
      final v = await _read(preAccountLastActivityKey);
      return v == null ? null : DateTime.tryParse(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> touchPreAccountActivity({DateTime? now}) =>
      _write(preAccountLastActivityKey,
          (now ?? DateTime.now()).toIso8601String());

  /// True when a live pre-account run has passed its 30-day
  /// abandonment window. No recorded activity → not expired (a
  /// run stamps activity on entry; absence means no live run).
  Future<bool> isPreAccountExpired({DateTime? now}) async {
    if (!await getPreAccountInProgress()) return false;
    final last = await getPreAccountLastActivity();
    if (last == null) return false;
    return (now ?? DateTime.now()).difference(last) > preAccountTtl;
  }

  Future<bool> hasPreAccountAnswers() async {
    if (await getPreAccountInProgress()) return true;
    return false;
  }

  /// Wipes ONLY the pre-account payload: answers, resume marker,
  /// consent flags and the pre-account keys themselves. Used by
  /// the 30-day expiry sweep and by login-to-existing-account
  /// (Juno ruling 3: wiped at login success, no merge, no post).
  /// The owner stamp is NOT touched — the login/register funnel
  /// owns it. Never throws.
  Future<void> clearPreAccountState() async {
    for (final k in const [
      userContextKey,
      userConditionsKey,
      stepMarkerKey,
      hasConsentedKey,
      introConsultationSeenKey,
      preAccountInProgressKey,
      preAccountLastActivityKey,
    ]) {
      try {
        await _delete(k);
      } catch (_) {}
    }
  }

  /// Registration carry-forward (Juno ruling 3/7): the pre-account
  /// answers become the NEW account's — stamp ONLY the owner,
  /// point the resume marker at Membership (the step registration
  /// resumes at), and end the pre-account phase. Every other
  /// onboarding key (consent, context, conditions) is preserved
  /// byte-for-byte. Never throws.
  Future<void> preservePreAccountForRegistration(String? email) async {
    final expected = _normalizeEmail(email);
    try {
      if (expected != null) await _write(ownerEmailKey, expected);
      await _write(stepMarkerKey, '5'); // OnboardingStep.membership
      await _delete(preAccountInProgressKey);
      await _delete(preAccountLastActivityKey);
    } catch (_) {}
  }

  Future<bool> getFlow3NotifPromptShown() =>
      _readBool(flow3NotifPromptShownKey, false);
  Future<void> setFlow3NotifPromptShown(bool v) =>
      _writeBool(flow3NotifPromptShownKey, v);

  Future<bool> hasAnyState() async {
    for (final k in const [
      onboardingCompleteKey,
      hasConsentedKey,
      introConsultationSeenKey,
      userContextKey,
      userConditionsKey,
      ownerEmailKey,
      stepMarkerKey,
      flow3CompletedKey,
      flow3NotifPromptShownKey,
      preAccountInProgressKey,
      preAccountLastActivityKey,
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
      stepMarkerKey,
      flow3CompletedKey,
      flow3NotifPromptShownKey,
      preAccountInProgressKey,
      preAccountLastActivityKey,
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
