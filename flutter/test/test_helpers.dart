import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/session_store.dart';

/// In-memory stand-in for [SessionStore] so widget tests never touch
/// platform channels (flutter_secure_storage) or real credentials.
class FakeSessionStore extends SessionStore {
  String? token;
  String? refreshToken;
  String? email;

  @override
  Future<void> saveSession({
    required String token,
    required String refreshToken,
    required String email,
  }) async {
    this.token = token;
    this.refreshToken = refreshToken;
    this.email = email;
  }

  @override
  Future<void> saveRotatedTokens({
    required String token,
    required String refreshToken,
  }) async {
    this.token = token;
    this.refreshToken = refreshToken;
    // Email deliberately untouched — partial save (H1-02).
  }

  @override
  Future<String?> readToken() async => token;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<String?> readEmail() async => email;

  @override
  Future<void> clear() async {
    token = null;
    refreshToken = null;
    email = null;
  }
}

/// Round 30 — in-memory [ReminderNotificationService] so Settings
/// widget tests never touch the notifications plugin. Records every
/// scheduled id so tests can assert the schedule state.
class FakeReminderNotificationService implements ReminderNotificationService {
  bool enabled;
  bool grantOnRequest;
  bool exact = true;
  int requestCount = 0;

  /// Fix round (Juno F1) — ordered record of the permission-gate
  /// calls (`canScheduleExact`, `requestNotificationsPermission`,
  /// `requestExactAlarmsPermission`, `areNotificationsEnabled`) so
  /// tests can assert the gate's call order.
  final List<String> calls = [];
  final Map<int, String> daily = {};

  /// Per-id title/body/channelId recorded by [scheduleDaily], so
  /// tests can assert the exact notification copy and channel
  /// without changing the existing [daily] ('$hour:$minute')
  /// behaviour other tests depend on.
  final Map<int, ({String title, String body, String channelId})>
      dailyDetails = {};
  final Map<int, DateTime> once = {};
  final Map<int, String> weekly = {};
  final List<int> cancelled = [];

  FakeReminderNotificationService(
      {this.enabled = true, this.grantOnRequest = true});

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> areNotificationsEnabled() async {
    calls.add('areNotificationsEnabled');
    return enabled;
  }

  @override
  Future<bool> requestNotificationsPermission() async {
    calls.add('requestNotificationsPermission');
    requestCount++;
    enabled = grantOnRequest;
    return enabled;
  }

  @override
  Future<bool> canScheduleExact() async {
    calls.add('canScheduleExact');
    return exact;
  }

  @override
  Future<void> requestExactAlarmsPermission() async {
    calls.add('requestExactAlarmsPermission');
    exact = true;
  }

  @override
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required int hour,
    required int minute,
    required bool highImportance,
  }) async {
    daily[id] = '$hour:$minute';
    dailyDetails[id] = (title: title, body: body, channelId: channelId);
  }

  @override
  Future<void> scheduleOnce({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required DateTime when,
    required bool highImportance,
  }) async {
    once[id] = when;
  }

  @override
  Future<void> scheduleWeekly({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required int weekday,
    required int hour,
    required int minute,
    required bool highImportance,
  }) async {
    weekly[id] = '$weekday $hour:$minute';
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    daily.remove(id);
    dailyDetails.remove(id);
    once.remove(id);
    weekly.remove(id);
  }
}
