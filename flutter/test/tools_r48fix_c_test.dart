import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/reminder_alarm_sync.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

/// Round 48 fix round (seat β — Health Coach) — tests for:
/// - Juno F1: the enriched prompt carries native's NOT-connected
///   calendar instruction (no calendar-proposal elicitation, no
///   events-data schedule rule); pending calendar cards state the
///   limitation ON the card with a disabled approve control, and
///   the snackbar copy names the native Tabs app.
/// - Juno F2: Coach reminder approval runs the Reminders create
///   permission gate BEFORE writing; denial leaves the proposal
///   pending with nothing written and no confirmation; a grant
///   writes the row AND runs the alarm reconcile.
/// - Vera F2 (coach half): note approval with a failed re-pull
///   posts ZERO entries (never the id-1 overwrite) and errors.
/// - Vera F6: list / reminder / medication appends splice RAW
///   blob rows — non-Map rows and unknown-key rows survive.
/// - Juno F3: file approval with no attached source message gets
///   its own accurate message, distinct from the generic one.

TabsBackend backendWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

MockClient serverClient(
  List<http.BaseRequest> log, {
  Map<String, dynamic> profile = const {},
  List<dynamic> pullEntries = const [],
  bool pullFails = false,
  bool documentsFail = false,
}) {
  return MockClient((request) async {
    log.add(request);
    switch (request.url.path) {
      case '/api/sync/pull':
        if (pullFails) return http.Response('boom', 500);
        return http.Response(
            jsonEncode({
              'isUnlimited': true,
              'profile': profile,
              'entries': pullEntries,
              'categories': [],
            }),
            200);
      case '/api/sync/profile':
      case '/api/sync/coach_sessions':
      case '/api/sync/coach_messages':
        return http.Response(jsonEncode({'saved': true, 'synced': 1}), 200);
      case '/api/ai/classify-coach-note':
        return http.Response(
            jsonEncode({
              'result': {'categoryId': 3},
            }),
            200);
      case '/api/sync/entries':
        return http.Response(jsonEncode({'synced': 1}), 200);
      case '/api/sync/documents':
        if (documentsFail) return http.Response('boom', 500);
        return http.Response(jsonEncode({'synced': 1}), 200);
    }
    return http.Response('{}', 404);
  });
}

List<http.Request> requestsTo(List<http.BaseRequest> log, String path) => [
      for (final r in log)
        if (r.url.path == path && r is http.Request) r,
    ];

dynamic lastProfileField(List<http.BaseRequest> log, String field) {
  final pushes = requestsTo(log, '/api/sync/profile');
  expect(pushes, isNotEmpty, reason: 'expected a profile push');
  final body = jsonDecode(pushes.last.body) as Map<String, dynamic>;
  return jsonDecode(body[field] as String);
}

Future<void> pumpChat(
  WidgetTester tester, {
  required TabsBackend backend,
  FakeReminderNotificationService? notifs,
  required List<CoachChatMessage> messages,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: CoachChatScreen(
        backend: backend,
        notificationService:
            notifs ?? FakeReminderNotificationService(),
        sessionId: 's1',
        sessionTitle: 'Chat',
        initialMessages: messages,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

CoachChatMessage coachMsg(String content, {String id = 'm1'}) =>
    CoachChatMessage(
      id: id,
      sessionId: 's1',
      role: 'coach',
      content: content,
      timestamp: 1,
    );

/// Lets a shown SnackBar expire so no timer is left pending.
Future<void> flushSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('Juno F1 — enriched context (not-connected calendar)', () {
    test('carries the native not-connected instruction verbatim in spirit',
        () {
      final ctx = coachEnrichedUserContext('BASE',
          now: DateTime(2026, 10, 13, 15, 4));
      expect(ctx, contains('Google Calendar is NOT connected yet'));
      expect(ctx, contains('Settings -> Connected Apps'));
      expect(ctx,
          contains('Do NOT output a [PROPOSE_CALENDAR_EVENT:...] tag'));
      expect(
          ctx,
          contains(
              'Do NOT output a [PROPOSE_DELETE_CALENDAR_EVENT:...] tag'));
      expect(ctx, contains('connect their Google Calendar first'));
    });

    test('no calendar-proposal elicitation and no events-data rule', () {
      final ctx = coachEnrichedUserContext(null,
          now: DateTime(2026, 10, 13, 15, 4));
      expect(ctx, isNot(contains('You can propose scheduling events')));
      expect(ctx, isNot(contains('Format for Proposing Event')));
      expect(ctx, isNot(contains('Format for Deleting Event')));
      expect(ctx, isNot(contains('generate a new revised')));
      expect(ctx,
          isNot(contains('CRITICAL RULES FOR READING & SCHEDULING EVENTS')));
      expect(ctx, isNot(contains('include ALL events')));
      // The other action instructions are untouched.
      expect(ctx, contains('[PROPOSE_LIST:ListName|Item1|Item2|Item3|...]'));
      expect(ctx, contains('[PROPOSE_REMINDER:Reminder Title|HH:MM]'));
      expect(ctx, contains('[PROPOSE_MEDICATION:'));
    });

    test('snackbar copy names the native Tabs app', () {
      expect(
          coachCalendarUnavailableMessage,
          'Calendar changes require the native Tabs app. '
          'Open the native Tabs app to add or delete calendar events.');
      expect(coachCalendarUnavailableMessage, contains('native Tabs app'));
      expect(coachCalendarUnavailableMessage,
          isNot(contains('Open Tabs on Android')));
      expect(
          coachCalendarCardLimitation,
          'Calendar changes require the native Tabs app. '
          'This app cannot add or delete calendar events.');
    });
  });

  group('Juno F1 — calendar cards are honest on the card', () {
    testWidgets('event card: limitation on card, approve disabled, '
        'dismiss works and never claims success', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [
          coachMsg(
              'Event idea. [PROPOSE_CALENDAR_EVENT:Dentist|2026-10-20|02:30 PM|Checkup]'),
        ],
      );
      expect(find.text('Proposed Calendar Event'), findsOneWidget);
      // The limitation is ON the card, before any tap.
      expect(find.text(coachCalendarCardLimitation), findsOneWidget);
      expect(find.text('Approve & Add'), findsNothing);
      final approve = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Approve'));
      expect(approve.onPressed, isNull);
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsNothing);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('✗ Event Dismissed'), findsOneWidget);
      expect(find.text("Okay, I won't add that to your calendar."),
          findsOneWidget);
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsNothing);
    });

    testWidgets('deletion card: limitation on card, approve disabled, '
        'dismiss works', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [
          coachMsg(
              'Delete it? [PROPOSE_DELETE_CALENDAR_EVENT:Dentist|2026-10-20]'),
        ],
      );
      expect(find.text('Proposed Calendar Deletion'), findsOneWidget);
      expect(find.text(coachCalendarCardLimitation), findsOneWidget);
      expect(find.text('Approve & Delete'), findsNothing);
      final approve = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Approve'));
      expect(approve.onPressed, isNull);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('✗ Deletion Dismissed'), findsOneWidget);
      expect(find.text("Okay, I won't delete that event."), findsOneWidget);
      expect(find.text('✓ Event Deleted from Calendar'), findsNothing);
    });
  });

  group('Juno F2 — reminder approval runs the permission gate', () {
    final existingReminderRow = <String, dynamic>{
      'id': 5,
      'title': 'Existing',
      'type': 'FIXED',
      'fixedHour': 9,
      'fixedMinute': 30,
      'intervalHours': 2,
      'intervalMinutes': 0,
      'startHour': 8,
      'startMinute': 0,
      'endHour': 21,
      'endMinute': 0,
      'isEnabled': true,
      'daysOfWeekConfig': '',
      'futureReminderKey': {'nested': true},
    };

    Map<String, dynamic> reminderProfile() => {
          'reminders': jsonEncode(['plain string row', existingReminderRow]),
        };

    List<CoachChatMessage> reminderMessages() => [
          coachMsg('Reminder? [PROPOSE_REMINDER:Take medication|08:00]'),
        ];

    testWidgets('gate denied at the rationale: blob unchanged, proposal '
        'still pending, no confirmation appended', (tester) async {
      final log = <http.BaseRequest>[];
      final notifs = FakeReminderNotificationService();
      await pumpChat(
        tester,
        backend:
            backendWith(serverClient(log, profile: reminderProfile())),
        notifs: notifs,
        messages: reminderMessages(),
      );
      await tester.ensureVisible(find.text('Set It'));
      await tester.tap(find.text('Set It'));
      await tester.pumpAndSettle();
      // The shared gate ran in its required order: the exact-alarm
      // check came first, then the rationale dialog.
      expect(notifs.calls.first, 'canScheduleExact');
      expect(find.text('Enable Notifications'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      // The system request never fired from a denial.
      expect(notifs.calls, isNot(contains('requestNotificationsPermission')));
      // Nothing was written anywhere.
      expect(requestsTo(log, '/api/sync/profile'), isEmpty);
      expect(requestsTo(log, '/api/sync/pull'), isEmpty);
      // The honest reason shows; the proposal is still pending and
      // no confirmation was appended.
      expect(find.text(coachReminderPermissionDeniedMessage),
          findsOneWidget);
      expect(find.text('Set Reminder?'), findsOneWidget);
      expect(find.text('✓ Reminder Set'), findsNothing);
      expect(find.textContaining("Done! I've set a reminder"), findsNothing);
      expect(notifs.daily, isEmpty);
      await flushSnack(tester);
    });

    testWidgets('gate denied at the system request: same pending outcome',
        (tester) async {
      final log = <http.BaseRequest>[];
      final notifs = FakeReminderNotificationService()
        ..grantOnRequest = false;
      await pumpChat(
        tester,
        backend:
            backendWith(serverClient(log, profile: reminderProfile())),
        notifs: notifs,
        messages: reminderMessages(),
      );
      await tester.ensureVisible(find.text('Set It'));
      await tester.tap(find.text('Set It'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(notifs.calls, contains('requestNotificationsPermission'));
      expect(requestsTo(log, '/api/sync/profile'), isEmpty);
      expect(find.text(coachReminderPermissionDeniedMessage),
          findsOneWidget);
      expect(find.text('Set Reminder?'), findsOneWidget);
      expect(find.textContaining("Done! I've set a reminder"), findsNothing);
      expect(notifs.daily, isEmpty);
      await flushSnack(tester);
    });

    testWidgets('gate granted: reminder row written AND alarm-sync invoked',
        (tester) async {
      final log = <http.BaseRequest>[];
      final notifs = FakeReminderNotificationService();
      await pumpChat(
        tester,
        backend:
            backendWith(serverClient(log, profile: reminderProfile())),
        notifs: notifs,
        messages: reminderMessages(),
      );
      await tester.ensureVisible(find.text('Set It'));
      await tester.tap(find.text('Set It'));
      await tester.pumpAndSettle();
      expect(find.text('Enable Notifications'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      // The row was written (raw rows preserved — Vera F6 too).
      final rows = lastProfileField(log, 'reminders') as List;
      expect(rows, hasLength(3));
      expect(rows[0], 'plain string row');
      expect(rows[1], existingReminderRow);
      final added = rows[2] as Map<String, dynamic>;
      expect(added['title'], 'Take medication');
      expect(added['id'], 6);
      expect(added['isEnabled'], isTrue);
      expect(added['fixedHour'], 8);
      expect(added['fixedMinute'], 0);

      // The alarm reconcile actually scheduled the new reminder
      // (and re-synced the existing one).
      expect(notifs.daily[reminderSlotId(6, 0)], '8:0');
      expect(notifs.daily[reminderSlotId(5, 0)], '9:30');

      expect(find.text('✓ Reminder Set'), findsOneWidget);
      expect(
          find.text(
              'Done! I\'ve set a reminder for "Take medication" at 8:00 AM.'),
          findsOneWidget);
    });
  });

  group('Vera F2 — note approval aborts on a failed pull', () {
    testWidgets('failed pull: zero posts, visible error, still pending',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log,
            pullFails: true,
            pullEntries: [
              {'id': 1, 'body': 'the real entry 1'},
            ])),
        messages: [coachMsg('Note? [PROPOSE_NOTE: drank water]')],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      // ZERO entry posts — above all, no id-1 upsert.
      expect(requestsTo(log, '/api/sync/entries'), isEmpty);
      expect(find.text(coachNotePullFailedMessage), findsOneWidget);
      expect(find.text('Suggested Note Log'), findsOneWidget);
      expect(find.text("Great! I've saved that note to your history."),
          findsNothing);
      await flushSnack(tester);
    });

    testWidgets('successful pull still saves with max-id + 1',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, pullEntries: [
          {'id': 7, 'body': 'older'},
          {'id': 3, 'body': 'oldest'},
        ])),
        messages: [coachMsg('Note? [PROPOSE_NOTE: drank water]')],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      final posts = requestsTo(log, '/api/sync/entries');
      expect(posts, hasLength(1));
      final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
      expect((body['entries'] as List).single['id'], 8);
      expect(find.text("Great! I've saved that note to your history."),
          findsOneWidget);
    });
  });

  group('Vera F6 — raw-row splicing', () {
    test('decodeCoachProfileBlobRaw preserves every row verbatim', () {
      final rows = decodeCoachProfileBlobRaw(jsonEncode([
        'plain string row',
        42,
        {'name': 'Keep', 'unknownKey': 'x'},
      ]));
      expect(rows, [
        'plain string row',
        42,
        {'name': 'Keep', 'unknownKey': 'x'},
      ]);
      expect(decodeCoachProfileBlobRaw('not json'), isEmpty);
      expect(decodeCoachProfileBlobRaw(null), isEmpty);
    });

    testWidgets('list append preserves a non-Map row and an '
        'unknown-key row in the pushed blob', (tester) async {
      final log = <http.BaseRequest>[];
      final keepRow = <String, dynamic>{
        'name': 'Keep',
        'items': ['x'],
        'futureListKey': 42,
      };
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'userLists': jsonEncode(['plain string row', keepRow]),
        })),
        messages: [
          coachMsg('List? [PROPOSE_LIST:Groceries|Milk|Eggs]'),
        ],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      final rows = lastProfileField(log, 'userLists') as List;
      expect(rows, hasLength(3));
      expect(rows[0], 'plain string row');
      expect(rows[1], keepRow);
      expect(jsonEncode(rows[1]), jsonEncode(keepRow));
      expect(rows[2], {
        'name': 'Groceries',
        'items': ['Milk', 'Eggs'],
      });
      expect(find.text('✓ List Created'), findsOneWidget);
    });

    testWidgets('medication append preserves a non-Map row and an '
        'unknown-key row in the pushed blob', (tester) async {
      final log = <http.BaseRequest>[];
      final existingMed = <String, dynamic>{
        'id': 'm1',
        'name': 'Existing',
        'startDate': 'Jan 2025',
        'endDate': 'Present',
        'isPresent': true,
        'dose': '5 mg',
        'frequency': 'Daily',
        'updatedAt': 1,
        'isDeleted': false,
        'unknownMedKey': 'keep-me',
      };
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'medications': jsonEncode(['plain string row', existingMed]),
        })),
        messages: [
          coachMsg(
              'Med? [PROPOSE_MEDICATION:NewMed|Jun 2026||true]'),
        ],
      );
      await tester.ensureVisible(find.text('Approve & Add'));
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();

      final rows = lastProfileField(log, 'medications') as List;
      expect(rows, hasLength(3));
      expect(rows[0], 'plain string row');
      expect(rows[1], existingMed);
      expect(jsonEncode(rows[1]), jsonEncode(existingMed));
      final added = rows[2] as Map<String, dynamic>;
      expect(added['name'], 'NewMed');
      expect(added['endDate'], 'Present');
      expect(added['isPresent'], isTrue);
      expect(find.text('✓ Medication Added to Profile'), findsOneWidget);
    });
  });

  group('Juno F3 — file approval failure messages', () {
    testWidgets('no source document: the distinct not-attached message',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [coachMsg('Save it? [PROPOSE_FILE:report.pdf]')],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      expect(requestsTo(log, '/api/sync/documents'), isEmpty);
      expect(find.text(coachFileNotAttachedMessage), findsOneWidget);
      expect(
          coachFileNotAttachedMessage,
          'That file was not attached in this app, so there is nothing '
          'to save from here.');
      expect(
          find.text(
              'Could not save that. Check your connection and try again.'),
          findsNothing);
      expect(find.text('Save Document to Tabs DB?'), findsOneWidget);
      await flushSnack(tester);
    });

    testWidgets('source exists but the save fails: generic message kept',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, documentsFail: true)),
        messages: const [
          CoachChatMessage(
            id: 'u1',
            sessionId: 's1',
            role: 'user',
            content: '📄 Uploaded file: report.pdf\n\nExtracted text',
            timestamp: 1,
          ),
          CoachChatMessage(
            id: 'm1',
            sessionId: 's1',
            role: 'coach',
            content: 'Save it? [PROPOSE_FILE:report.pdf]',
            timestamp: 2,
          ),
        ],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      expect(requestsTo(log, '/api/sync/documents'), hasLength(1));
      expect(
          find.text(
              'Could not save that. Check your connection and try again.'),
          findsOneWidget);
      expect(find.text(coachFileNotAttachedMessage), findsNothing);
      await flushSnack(tester);
    });
  });
}
