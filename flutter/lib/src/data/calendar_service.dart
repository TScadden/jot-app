import 'dart:async';

import 'package:flutter/services.dart';

/// Round 54 — Google Calendar bridge service for the Health Coach.
///
/// Typed Dart wrapper over the Kotlin CalendarContract bridge in
/// MainActivity.kt (channel [channelName]). The Kotlin side mirrors
/// native `CoachViewModel` exactly:
///
/// - Insert (`approveProposedCalendarEvent`, CoachViewModel.kt:778):
///   writable-calendar selection (access >= 500, connected-email
///   preference, else first writable) happens in Kotlin at write
///   time; the raw date/time strings are parsed in Kotlin with
///   native's `yyyy-MM-dd hh:mm a` → `HH:mm` fallback → now rule;
///   the event is inserted with native's field mapping and the
///   sync-adapter URI parameters; end = start + 1 hour.
/// - Delete (`approveProposedCalendarDeleteEvent`, :941): exact
///   TITLE match across ALL calendars, plus the parsed date's day
///   window when a date is present; returns the rows deleted.
/// - Upcoming events (`getUpcomingCalendarEvents`, :1461): events
///   from the earlier of local/UTC midnight today through local
///   midnight + 15 days, formatted by [formatUpcomingCalendarEvents]
///   into native's exact context string.
///
/// Every call is try/caught and surfaces failures as a
/// [CalendarException] carrying a visible code (team lesson: silent
/// channel failures are forbidden). No call ever fabricates success.
class CalendarService {
  static const String channelName =
      'com.notel.notel.playground.flutter/calendar';

  static const String readPermission = 'android.permission.READ_CALENDAR';
  static const String writePermission =
      'android.permission.WRITE_CALENDAR';

  /// Native permission outcome copy (CoachScreen.kt:106).
  static const String permissionDeniedMessage =
      'Calendar permissions are required to manage events.';

  /// Dart gives up just before the Kotlin side's 5-minute pending
  /// window so it can cancel the native request and stay retryable
  /// (same discipline as the Health Connect bridge).
  static const Duration requestTimeout =
      Duration(minutes: 4, seconds: 30);

  final MethodChannel _channel;

  CalendarService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Whether READ_CALENDAR and WRITE_CALENDAR are both granted —
  /// native's approve-time check (CoachScreen.kt:193-230).
  Future<CalendarPermissionStatus> getPermissionStatus() async {
    try {
      final raw =
          await _channel.invokeMethod<Map>('getPermissionStatus');
      return CalendarPermissionStatus(
        read: raw?['read'] == true,
        write: raw?['write'] == true,
      );
    } on PlatformException catch (e) {
      throw CalendarException(
          e.code, e.message ?? 'Could not check calendar permissions.');
    } on MissingPluginException {
      throw const CalendarException(
          'NO_CHANNEL', 'Calendar bridge is not available.');
    }
  }

  /// Launches the system READ+WRITE calendar permission request and
  /// returns the resulting status. Mirrors native's launcher result:
  /// the caller proceeds only when BOTH are granted.
  Future<CalendarPermissionStatus> requestPermissions() async {
    try {
      final raw = await _channel
          .invokeMethod<Map>('requestPermissions')
          .timeout(requestTimeout);
      return CalendarPermissionStatus(
        read: raw?['read'] == true,
        write: raw?['write'] == true,
      );
    } on TimeoutException {
      try {
        await _channel.invokeMethod('cancelRequest');
      } catch (_) {}
      throw const CalendarException('REQUEST_TIMEOUT',
          'The permission request timed out. Please try again.');
    } on PlatformException catch (e) {
      throw CalendarException(
          e.code, e.message ?? 'Calendar permission request failed.');
    } on MissingPluginException {
      throw const CalendarException(
          'NO_CHANNEL', 'Calendar bridge is not available.');
    }
  }

  /// The writable calendars visible to the bridge (access >= 500),
  /// in provider order — the same candidate set native's insert
  /// selection considers.
  Future<List<CalendarInfo>> listWritableCalendars() async {
    try {
      final raw =
          await _channel.invokeMethod<List>('listWritableCalendars');
      final out = <CalendarInfo>[];
      for (final item in raw ?? const []) {
        if (item is Map) {
          final id = item['id'];
          out.add(CalendarInfo(
            id: id is num ? id.toInt() : -1,
            accountName: '${item['accountName'] ?? ''}',
            accountType: '${item['accountType'] ?? ''}',
            accessLevel: item['accessLevel'] is num
                ? (item['accessLevel'] as num).toInt()
                : 0,
          ));
        }
      }
      return out;
    } on PlatformException catch (e) {
      throw CalendarException(
          e.code, e.message ?? 'Could not list calendars.');
    } on MissingPluginException {
      throw const CalendarException(
          'NO_CHANNEL', 'Calendar bridge is not available.');
    }
  }

  /// Inserts one event, native semantics (see class doc). The raw
  /// [date]/[time] tag strings go to Kotlin, which parses them
  /// exactly like native. Returns the outcome; a thrown
  /// [CalendarException] is native's outer-catch path — the caller
  /// shows [coachCalendarAddFailureMessage] for it, exactly like
  /// native posts `FriendlyErrors.coachCalendarAddFailure`.
  Future<CalendarInsertOutcome> insertEvent({
    required String title,
    String? date,
    String? time,
    String? description,
    required String connectedEmail,
  }) async {
    try {
      final raw = await _channel.invokeMethod<String>('insertEvent', {
        'title': title,
        'date': date,
        'time': time,
        'description': description,
        'connectedEmail': connectedEmail,
      });
      switch (raw) {
        case 'inserted':
          return CalendarInsertOutcome.inserted;
        case 'noWritableCalendar':
          return CalendarInsertOutcome.noWritableCalendar;
        case 'nullUri':
          return CalendarInsertOutcome.nullUri;
        default:
          throw CalendarException(
              'UNKNOWN_OUTCOME', 'Unexpected insert outcome: $raw');
      }
    } on PlatformException catch (e) {
      throw CalendarException(
          e.code, e.message ?? 'Calendar insert failed.');
    } on MissingPluginException {
      throw const CalendarException(
          'NO_CHANNEL', 'Calendar bridge is not available.');
    }
  }

  /// Deletes events by exact title (+ the date's day window when
  /// [date] is given), native semantics. Returns rows deleted.
  Future<int> deleteEvents({
    required String title,
    String? date,
  }) async {
    try {
      return await _channel.invokeMethod<int>('deleteEvents', {
            'title': title,
            'date': date,
          }) ??
          0;
    } on PlatformException catch (e) {
      throw CalendarException(
          e.code, e.message ?? 'Calendar delete failed.');
    } on MissingPluginException {
      throw const CalendarException(
          'NO_CHANNEL', 'Calendar bridge is not available.');
    }
  }

  /// Upcoming events for the coach context (native query bounds and
  /// ordering live in Kotlin). Throws [CalendarException] on failure —
  /// the caller mirrors native's outer catch by using
  /// [calendarEventsUnavailableContext].
  Future<List<CalendarEventItem>> getUpcomingEvents() async {
    try {
      final raw = await _channel.invokeMethod<List>('getUpcomingEvents');
      final out = <CalendarEventItem>[];
      for (final item in raw ?? const []) {
        if (item is Map) {
          final start = item['dtstart'];
          out.add(CalendarEventItem(
            title: item['title']?.toString(),
            startMillis: start is num ? start.toInt() : 0,
            allDay: item['allDay'] == true || item['allDay'] == 1,
          ));
        }
      }
      return out;
    } on PlatformException catch (e) {
      throw CalendarException(
          e.code, e.message ?? 'Could not read calendar events.');
    } on MissingPluginException {
      throw const CalendarException(
          'NO_CHANNEL', 'Calendar bridge is not available.');
    }
  }
}

/// READ + WRITE calendar permission state (native requires both).
class CalendarPermissionStatus {
  final bool read;
  final bool write;

  const CalendarPermissionStatus({required this.read, required this.write});

  bool get granted => read && write;
}

/// One writable calendar (native's Calendars projection).
class CalendarInfo {
  final int id;
  final String accountName;
  final String accountType;
  final int accessLevel;

  const CalendarInfo({
    required this.id,
    required this.accountName,
    required this.accountType,
    required this.accessLevel,
  });
}

/// Native insert outcomes: inserted (URI non-null), aborted before
/// insert because no writable calendar exists, or a null URI back
/// from the provider (native: WRITE_CALENDAR likely denied).
enum CalendarInsertOutcome { inserted, noWritableCalendar, nullUri }

/// One upcoming event row from the bridge.
class CalendarEventItem {
  final String? title;
  final int startMillis;
  final bool allDay;

  const CalendarEventItem({
    required this.title,
    required this.startMillis,
    required this.allDay,
  });
}

class CalendarException implements Exception {
  final String code;
  final String message;

  const CalendarException(this.code, this.message);

  @override
  String toString() => 'CalendarException[$code]: $message';
}

// ── Native outcome copy (CoachViewModel.kt, verbatim) ───────────────────────

/// Native's no-writable-calendar abort (CoachViewModel.kt:819-823).
const String coachCalendarNoWritableMessage =
    'Could not find a writable calendar. Please ensure Calendar '
    'permissions are granted in Settings > Apps > Tabs > Permissions.';

/// Native's null-URI error (CoachViewModel.kt:893-900).
const String coachCalendarNullUriMessage =
    'The calendar insert returned no URI. This usually means '
    'WRITE_CALENDAR permission was denied. Please go to Settings > '
    'Apps > Tabs > Permissions and enable Calendar access, then '
    'try again.';

/// Native `FriendlyErrors.coachCalendarAddFailure` — posted on the
/// insert path's outer catch.
const String coachCalendarAddFailureMessage =
    'I could not add that to your calendar. Want me to try again?';

/// Native `FriendlyErrors.coachCalendarDeleteFailure` — posted on
/// the delete path's outer catch.
const String coachCalendarDeleteFailureMessage =
    'I could not remove that from your calendar. Want me to try again?';

/// Native's not-connected return from `getUpcomingCalendarEvents`.
const String coachCalendarNotConnectedContext =
    'No Google Calendar connected.';

/// Native's outer-catch return from `getUpcomingCalendarEvents`.
const String calendarEventsUnavailableContext =
    'Calendar events are unavailable right now.';

/// Native's insert confirmation (CoachViewModel.kt:884-891):
/// `Done! "$title" has been added to your Google Calendar` plus
/// ` on $date` / ` at $time` when present, then the closing
/// sentence.
String coachCalendarAddedConfirmation(
    String title, String? date, String? time) {
  final dateLabel = (date != null && date.isNotEmpty) ? ' on $date' : '';
  final timeLabel = (time != null && time.isNotEmpty) ? ' at $time' : '';
  return 'Done! "$title" has been added to your Google Calendar'
      '$dateLabel$timeLabel. It should appear in your Google '
      'Calendar app shortly.';
}

/// Native's delete confirmation (CoachViewModel.kt:978-985).
String coachCalendarDeletedConfirmation(String title, String? date) {
  final dateLabel =
      (date != null && date.isNotEmpty) ? ' scheduled for $date' : '';
  return 'Successfully deleted "$title"$dateLabel from your '
      'Google Calendar!';
}

/// Round 54 fix round (Juno A2) — count-aware delete confirmation
/// for when the bridge deleted MORE THAN ONE exact-title match:
/// the singular native string would understate what happened.
/// Display only — what gets deleted is unchanged.
String coachCalendarDeletedPluralConfirmation(
    int rows, String title, String? date) {
  return 'Successfully deleted $rows events titled "$title" '
      'scheduled for $date from your Google Calendar!';
}

/// Native's delete not-found message (CoachViewModel.kt:987-993).
String coachCalendarDeleteNotFoundMessage(String title) =>
    'Could not find "$title" on your Google Calendar to delete.';

// ── Upcoming-events context formatting (native, verbatim rules) ────────────

String _pad2(int v) => v.toString().padLeft(2, '0');

/// "yyyy-MM-dd hh:mm a" in local time (native's timed formatter).
String formatCalendarTimedEvent(DateTime dt) {
  final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final amPm = dt.hour < 12 ? 'AM' : 'PM';
  return '${dt.year}-${_pad2(dt.month)}-${_pad2(dt.day)} '
      '${_pad2(h12)}:${_pad2(dt.minute)} $amPm';
}

/// Formats bridge events into native `getUpcomingCalendarEvents`'
/// output: `- $title on $formattedDate` lines under the
/// `CALENDAR EVENTS (today + next 14 days):` header, all-day events
/// formatted as a UTC date + " (all day)", untitled events as
/// "Untitled Event".
String formatUpcomingCalendarEvents(List<CalendarEventItem> events) {
  if (events.isEmpty) {
    return 'CALENDAR EVENTS (today + next 14 days): No events found.';
  }
  final lines = <String>[];
  for (final e in events) {
    final title = e.title ?? 'Untitled Event';
    final String formatted;
    if (e.allDay) {
      final utc = DateTime.fromMillisecondsSinceEpoch(e.startMillis,
          isUtc: true);
      formatted =
          '${utc.year}-${_pad2(utc.month)}-${_pad2(utc.day)} (all day)';
    } else {
      formatted = formatCalendarTimedEvent(
          DateTime.fromMillisecondsSinceEpoch(e.startMillis));
    }
    lines.add('- $title on $formatted');
  }
  return 'CALENDAR EVENTS (today + next 14 days):\n${lines.join('\n')}';
}
