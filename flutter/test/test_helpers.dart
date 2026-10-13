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
  final Map<int, String> daily = {};
  final Map<int, DateTime> once = {};
  final Map<int, String> weekly = {};
  final List<int> cancelled = [];

  FakeReminderNotificationService(
      {this.enabled = true, this.grantOnRequest = true});

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> areNotificationsEnabled() async => enabled;

  @override
  Future<bool> requestNotificationsPermission() async {
    requestCount++;
    enabled = grantOnRequest;
    return enabled;
  }

  @override
  Future<bool> canScheduleExact() async => exact;

  @override
  Future<void> requestExactAlarmsPermission() async {
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
    once.remove(id);
    weekly.remove(id);
  }
}
