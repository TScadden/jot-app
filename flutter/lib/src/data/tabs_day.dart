import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The ONE shared Tabs-day definition (boundary migration,
/// founder decision Nov 19, 2026: the Tabs day becomes the
/// calendar day).
///
/// Historically a Tabs day started at 04:00 local (the "legacy"
/// rule). From a persisted cutover instant on, a Tabs day is the
/// calendar day (midnight local). The derivation is INSTANT-BASED:
///
/// - an instant BEFORE the cutover uses the legacy rule
///   (anchor = instant − 4h; the day starts at 04:00 local on the
///   anchor's calendar date; the key is the anchor's calendar
///   date), so historical instants keep their legacy labels
///   forever — history is never rewritten, in stored keys or in
///   re-derived analytics labels;
/// - an instant AT OR AFTER the cutover uses the calendar rule
///   (anchor = the instant itself; the day starts at local
///   midnight; the key is its calendar date).
///
/// The cutover is the first midnight STRICTLY after the first
/// load under the new build (see [TabsDayBoundary.load]), so the
/// truncated day is always the install date's day: it spans
/// [install-date 04:00, next midnight) = 20 hours, and the key
/// sequence across the seam stays consecutive `yyyy-MM-dd`
/// calendar dates (audit §4.2/§4.3).
///
/// An UNINITIALIZED boundary (no cutover loaded — every unit test
/// that never calls [TabsDayBoundary.load]) derives LEGACY
/// everywhere: the existing suite was written against the 04:00
/// rule and stays green untouched. Production always loads at
/// bootstrap (main.dart, pre-runApp).
///
/// Persistence follows the app's SettingsStore pattern
/// (flutter_secure_storage — Android Keystore-backed
/// EncryptedSharedPreferences; the app has no SharedPreferences):
/// the cutover instant is stored as epoch milliseconds under
/// [TabsDayBoundary.cutoverStorageKey]. Storage is injectable
/// for tests, like every other store in this codebase.

/// Plain local `yyyy-MM-dd` formatting of [d]'s calendar date.
String tabsDayFormat(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Whether [now] derives under the calendar rule for [cutover]:
/// a cutover exists and [now] is at or after it.
bool _isCalendar(DateTime now, DateTime? cutover) =>
    cutover != null && !now.isBefore(cutover);

/// The Tabs-day anchor for [now] under an explicit [cutover]:
/// legacy rule → [now] shifted back 4 hours (the calendar date of
/// the anchor is the Tabs day); calendar rule → [now] itself.
DateTime anchorFor(DateTime now, DateTime? cutover) =>
    _isCalendar(now, cutover) ? now : now.subtract(const Duration(hours: 4));

/// The start instant of the Tabs day containing [now] under an
/// explicit [cutover]: legacy rule → 04:00 local on the anchor's
/// calendar date; calendar rule → local midnight.
DateTime dayStartFor(DateTime now, DateTime? cutover) {
  if (_isCalendar(now, cutover)) {
    return DateTime(now.year, now.month, now.day);
  }
  final anchor = anchorFor(now, cutover);
  return DateTime(anchor.year, anchor.month, anchor.day, 4);
}

/// The Tabs-day key (`yyyy-MM-dd`) containing [now] under an
/// explicit [cutover].
String keyFor(DateTime now, DateTime? cutover) =>
    tabsDayFormat(anchorFor(now, cutover));

/// The Tabs-day key for an epoch-milliseconds timestamp under an
/// explicit [cutover].
String keyForMs(int timestampMs, DateTime? cutover) =>
    keyFor(DateTime.fromMillisecondsSinceEpoch(timestampMs), cutover);

/// The next Tabs-day boundary strictly after [now] under an
/// explicit [cutover]: the first instant at which the Tabs-day
/// key changes. Before the cutover that is the cutover itself
/// when it precedes the next legacy 04:00 boundary (the truncated
/// day ends at midnight, not at 04:00); otherwise the next 04:00
/// (legacy) or the next midnight (calendar rule).
DateTime nextBoundaryFor(DateTime now, DateTime? cutover) {
  if (_isCalendar(now, cutover)) {
    return DateTime(now.year, now.month, now.day + 1);
  }
  final start = dayStartFor(now, cutover);
  final legacyNext = DateTime(start.year, start.month, start.day + 1, 4);
  if (cutover != null && !cutover.isAfter(legacyNext)) return cutover;
  return legacyNext;
}

/// The first local midnight STRICTLY after [now] (a [now] exactly
/// at midnight stamps the NEXT midnight).
DateTime firstMidnightStrictlyAfter(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1);

/// The persisted Tabs-day cutover holder (see the file header).
///
/// [instance] is the app-wide singleton the delegates read;
/// production loads it once at bootstrap. Tests either pin the
/// singleton via [debugCutoverAt] or construct an independent
/// instance with injected storage/clock to exercise [load].
class TabsDayBoundary {
  /// Storage key for the persisted cutover instant (epoch ms).
  static const String cutoverStorageKey = 'tabs_day_cutover_ms_v1';

  /// The app-wide instance.
  static final TabsDayBoundary instance = TabsDayBoundary();

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final DateTime Function() _clock;

  TabsDayBoundary({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
    DateTime Function()? clock,
  })  : _read = read ??
            ((key) => const FlutterSecureStorage().read(key: key)),
        _write = write ??
            ((key, value) =>
                const FlutterSecureStorage().write(key: key, value: value)),
        _clock = clock ?? DateTime.now;

  DateTime? _cutoverAt;

  /// The persisted cutover instant, or null when [load] has not
  /// run (or found nothing and has not stamped yet). A null
  /// cutover derives the legacy rule everywhere.
  DateTime? get cutoverAt => _cutoverAt;

  /// Loads the cutover from storage; when no value is stored,
  /// stamps the first midnight strictly after the load instant
  /// and persists it. Never throws: an unreadable store reads as
  /// absent (the house pattern), and a failed persist still
  /// leaves the in-memory stamp for this session.
  Future<void> load() async {
    String? raw;
    try {
      raw = await _read(cutoverStorageKey);
    } catch (_) {
      raw = null;
    }
    final storedMs = raw == null ? null : int.tryParse(raw);
    if (storedMs != null) {
      _cutoverAt = DateTime.fromMillisecondsSinceEpoch(storedMs);
      return;
    }
    final cutover = firstMidnightStrictlyAfter(_clock());
    _cutoverAt = cutover;
    try {
      await _write(
        cutoverStorageKey,
        '${cutover.millisecondsSinceEpoch}',
      );
    } catch (_) {
      // Best-effort: the in-memory stamp governs this session; a
      // later cold start re-stamps (still strictly after ITS load
      // instant, so the seam can only move later, never earlier).
    }
  }

  /// Pins the cutover for tests (engine-level seam tests drive
  /// the real delegates, which read the singleton). Pass null to
  /// restore the uninitialized legacy default.
  @visibleForTesting
  set debugCutoverAt(DateTime? value) => _cutoverAt = value;

  /// The anchor for [now] under the loaded cutover.
  DateTime anchor(DateTime now) => anchorFor(now, _cutoverAt);

  /// The start instant of the Tabs day containing [now] under
  /// the loaded cutover.
  DateTime dayStart(DateTime now) => dayStartFor(now, _cutoverAt);

  /// The Tabs-day key containing [now] under the loaded cutover.
  String key(DateTime now) => keyFor(now, _cutoverAt);

  /// The Tabs-day key for [timestampMs] under the loaded cutover.
  String keyForMs(int timestampMs) => keyFor(
      DateTime.fromMillisecondsSinceEpoch(timestampMs), _cutoverAt);

  /// The next Tabs-day boundary strictly after [now] under the
  /// loaded cutover.
  DateTime nextBoundary(DateTime now) => nextBoundaryFor(now, _cutoverAt);
}
