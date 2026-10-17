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

  /// Takeover disclosures (audit P4): builds the coach's
  /// upcoming-events context PERMISSION-AWARELY. When calendar
  /// read permission is not granted — or the bridge read fails,
  /// including the Kotlin side's SecurityException, which it now
  /// surfaces as a PERMISSION_DENIED error instead of an empty
  /// list — the context is native's "Calendar events are
  /// unavailable right now." It must NEVER be "No events found.":
  /// that string is reserved for a successful read that genuinely
  /// returned zero events, so the model (and the Data Safety
  /// story) never receives a false "no events" signal.
  Future<String> upcomingEventsContext() async {
    try {
      final status = await getPermissionStatus();
      if (!status.read) return calendarEventsUnavailableContext;
      final events = await getUpcomingEvents();
      return formatUpcomingCalendarEvents(events);
    } on CalendarException {
      return calendarEventsUnavailableContext;
    } catch (_) {
      return calendarEventsUnavailableContext;
    }
  }

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

// ── Calendar disclosure (Round 54 A1, canonical copy) ──────────────────────

/// The A1 calendar disclosure: what the Health Coach does with
/// calendar access, in the build's own words. Shown BEFORE the
/// system permission request at a coach calendar approval, and —
/// takeover disclosures (audit P3) — duplicated at the Connected
/// Apps "Connect Google Calendar" moment in Settings, so the
/// disclosure no longer fires only at approve time (a manual
/// grant via Android system settings used to bypass it entirely).
/// The Health Coach screen keeps its historical name for this
/// string as an alias (`coachCalendarPermissionDisclosure`).
const String calendarCoachDisclosure =
    'Tabs Coach needs read and write access to your calendar. When Google Calendar is connected, the Coach reads the titles and times of your events for today and the next 14 days and sends them to the Tabs AI service so it can answer with your schedule in context. The Coach can also add events to, and delete events from, your calendar, only for proposals you tap Approve on. Nothing is added or deleted without your approval. Tap Continue to allow calendar access.';

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

/// Native's insert confirmation (CoachViewModel.kt:884-891),
/// with ONE deliberate wording change — takeover disclosures
/// (audit P5): native says "your Google Calendar", but the bridge
/// inserts into the best writable DEVICE calendar (connected-email
/// preferred), which is not necessarily a Google calendar, so the
/// confirmation says "your calendar". Same P5 change applies to
/// the delete confirmations and the delete not-found message
/// below. (The P1 privacy-policy paragraph keeps its audit-exact
/// "Google Calendar" wording — P5 governs in-app copy only.)
String coachCalendarAddedConfirmation(
    String title, String? date, String? time) {
  final dateLabel = (date != null && date.isNotEmpty) ? ' on $date' : '';
  final timeLabel = (time != null && time.isNotEmpty) ? ' at $time' : '';
  return 'Done! "$title" has been added to your calendar'
      '$dateLabel$timeLabel. It should appear in your calendar '
      'app shortly.';
}

/// Native's delete confirmation (CoachViewModel.kt:978-985),
/// with the P5 "your calendar" wording (see above).
String coachCalendarDeletedConfirmation(String title, String? date) {
  final dateLabel =
      (date != null && date.isNotEmpty) ? ' scheduled for $date' : '';
  return 'Successfully deleted "$title"$dateLabel from your '
      'calendar!';
}

/// Round 54 fix round (Juno A2) — count-aware delete confirmation
/// for when the bridge deleted MORE THAN ONE exact-title match:
/// the singular native string would understate what happened.
/// Display only — what gets deleted is unchanged. (P5 wording.)
String coachCalendarDeletedPluralConfirmation(
    int rows, String title, String? date) {
  return 'Successfully deleted $rows events titled "$title" '
      'scheduled for $date from your calendar!';
}

/// Native's delete not-found message (CoachViewModel.kt:987-993),
/// with the P5 "your calendar" wording (see above).
String coachCalendarDeleteNotFoundMessage(String title) =>
    'Could not find "$title" on your calendar to delete.';

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
