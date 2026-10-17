import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/calendar_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

/// Round 54 — real Google Calendar access for the Health Coach:
/// the connected prompt branch, the approve-time permission gate,
/// and native's insert/delete outcomes against a fake calendar
/// bridge (mock method channel, same pattern as the Health
/// Connect tests).

const _channelName = CalendarService.channelName;

/// A stateful fake bridge: permission starts as configured,
/// requestPermissions flips it to [grantOnRequest], inserts and
/// deletes record their arguments and return canned outcomes.
class FakeCalendarBridge {
  bool readGranted;
  bool writeGranted;
  final bool grantOnRequest;
  String insertOutcome = 'inserted';
  int deleteRows = 1;
  List<dynamic> upcoming = const [];
  bool throwOnUpcoming = false;
  bool throwOnInsert = false;
  bool throwInvalidArgsOnInsert = false;

  final List<MethodCall> calls = [];

  FakeCalendarBridge({
    this.readGranted = true,
    this.writeGranted = true,
    this.grantOnRequest = true,
    this.deleteRows = 1,
  });

  Future<dynamic> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getPermissionStatus':
        return {'read': readGranted, 'write': writeGranted};
      case 'requestPermissions':
        if (grantOnRequest) {
          readGranted = true;
          writeGranted = true;
        }
        return {'read': readGranted, 'write': writeGranted};
      case 'insertEvent':
        if (throwInvalidArgsOnInsert) {
          throw PlatformException(
              code: 'INVALID_ARGS',
              message: 'Calendar event title must not be null or blank.');
        }
        if (throwOnInsert) {
          throw PlatformException(code: 'CALENDAR_INSERT_FAILED');
        }
        return insertOutcome;
      case 'deleteEvents':
        return deleteRows;
      case 'getUpcomingEvents':
        if (throwOnUpcoming) {
          // Mirrors the Kotlin bridge after the P4 fix: a
          // SecurityException surfaces as an error, not an
          // empty-list success.
          throw PlatformException(
              code: 'PERMISSION_DENIED',
              message: 'Calendar permission is not granted.');
        }
        return upcoming;
      case 'listWritableCalendars':
        return [
          {
            'id': 3,
            'accountName': 'me@example.com',
            'accountType': 'com.google',
            'accessLevel': 700,
          },
        ];
    }
    throw PlatformException(code: 'UNKNOWN_METHOD');
  }

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();
}

CalendarService serviceFor(FakeCalendarBridge bridge) {
  const channel = MethodChannel(_channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, bridge.handle);
  return CalendarService(channel: channel);
}

TabsBackend backendWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

MockClient chatBackend(List<http.BaseRequest> log) {
  return MockClient((request) async {
    log.add(request);
    switch (request.url.path) {
      case '/api/ai/coach':
        return http.Response(jsonEncode({'result': 'ok'}), 200);
      case '/api/sync/coach_sessions':
      case '/api/sync/coach_messages':
        return http.Response(jsonEncode({'synced': 1}), 200);
    }
    return http.Response('{}', 404);
  });
}

Future<void> pumpChat(
  WidgetTester tester, {
  required FakeCalendarBridge bridge,
  required List<CoachChatMessage> messages,
  bool connected = true,
  List<http.BaseRequest>? log,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: CoachChatScreen(
      backend: backendWith(chatBackend(log ?? [])),
      calendarService: serviceFor(bridge),
      calendarConnected: connected,
      calendarEmail: 'me@example.com',
      sessionId: 's1',
      sessionTitle: 'Chat',
      initialMessages: messages,
    ),
  ));
  await tester.pumpAndSettle();
}

const _addMsg = CoachChatMessage(
  id: 'm1',
  sessionId: 's1',
  role: 'coach',
  content:
      'Here you go. [PROPOSE_CALENDAR_EVENT:Dentist|2026-10-20|02:30 PM|Checkup]',
  timestamp: 1,
);

const _deleteMsg = CoachChatMessage(
  id: 'm2',
  sessionId: 's1',
  role: 'coach',
  content: 'Sure. [PROPOSE_DELETE_CALENDAR_EVENT:Dentist|2026-10-20]',
  timestamp: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(_channelName), null);
  });

  group('CalendarService (fake bridge)', () {
    test('permission status maps read/write; granted needs both',
        () async {
      final bridge = FakeCalendarBridge(readGranted: true, writeGranted: false);
      final service = serviceFor(bridge);
      final status = await service.getPermissionStatus();
      expect(status.read, isTrue);
      expect(status.write, isFalse);
      expect(status.granted, isFalse);
    });

    // ── Takeover disclosures (audit P4): permission-aware context ──
    test('P4: read permission denied → unavailable context, and '
        'the events read is never attempted', () async {
      final bridge =
          FakeCalendarBridge(readGranted: false, writeGranted: false);
      final service = serviceFor(bridge);
      final ctx = await service.upcomingEventsContext();
      expect(ctx, calendarEventsUnavailableContext);
      expect(ctx, isNot(contains('No events found.')));
      expect(bridge.callsTo('getUpcomingEvents'), isEmpty);
    });

    test('P4: permission granted + zero events → genuinely-empty '
        'context ("No events found.")', () async {
      final bridge = FakeCalendarBridge()..upcoming = const [];
      final service = serviceFor(bridge);
      final ctx = await service.upcomingEventsContext();
      expect(ctx,
          'CALENDAR EVENTS (today + next 14 days): No events found.');
      expect(bridge.callsTo('getUpcomingEvents'), hasLength(1));
    });

    test('P4: permission granted + bridge read fails (the Kotlin '
        'SecurityException path) → unavailable, not empty', () async {
      final bridge = FakeCalendarBridge()..throwOnUpcoming = true;
      final service = serviceFor(bridge);
      final ctx = await service.upcomingEventsContext();
      expect(ctx, calendarEventsUnavailableContext);
      expect(ctx, isNot(contains('No events found.')));
    });

    test('P4: permission granted + events → formatted events '
        'context', () async {
      final bridge = FakeCalendarBridge()
        ..upcoming = [
          {
            'title': 'Dentist',
            'dtstart': DateTime(2026, 10, 20, 14, 30)
                .millisecondsSinceEpoch,
            'allDay': false,
          },
        ];
      final service = serviceFor(bridge);
      final ctx = await service.upcomingEventsContext();
      expect(ctx, contains('- Dentist on 2026-10-20 02:30 PM'));
    });

    test('insert passes native-mapped fields through', () async {
      final bridge = FakeCalendarBridge();
      final service = serviceFor(bridge);
      final outcome = await service.insertEvent(
        title: 'Dentist',
        date: '2026-10-20',
        time: '02:30 PM',
        description: 'Checkup',
        connectedEmail: 'me@example.com',
      );
      expect(outcome, CalendarInsertOutcome.inserted);
      final call = bridge.callsTo('insertEvent').single;
      expect(call.arguments, {
        'title': 'Dentist',
        'date': '2026-10-20',
        'time': '02:30 PM',
        'description': 'Checkup',
        'connectedEmail': 'me@example.com',
      });
    });

    test('insert INVALID_ARGS (blank title rejected natively) '
        'surfaces as CalendarException with that code', () async {
      final bridge = FakeCalendarBridge()..throwInvalidArgsOnInsert = true;
      final service = serviceFor(bridge);
      await expectLater(
        service.insertEvent(
          title: '',
          date: '2026-10-20',
          time: '02:30 PM',
          description: 'Checkup',
          connectedEmail: 'me@example.com',
        ),
        throwsA(isA<CalendarException>()
            .having((e) => e.code, 'code', 'INVALID_ARGS')),
      );
    });

    test('upcoming-events formatting mirrors native', () {
      final timed = DateTime(2026, 10, 20, 14, 30)
          .millisecondsSinceEpoch;
      final allDay = DateTime.utc(2026, 10, 21).millisecondsSinceEpoch;
      final text = formatUpcomingCalendarEvents([
        CalendarEventItem(title: 'Dentist', startMillis: timed, allDay: false),
        CalendarEventItem(title: null, startMillis: allDay, allDay: true),
      ]);
      expect(
          text,
          'CALENDAR EVENTS (today + next 14 days):\n'
          '- Dentist on 2026-10-20 02:30 PM\n'
          '- Untitled Event on 2026-10-21 (all day)');
      expect(formatUpcomingCalendarEvents(const []),
          'CALENDAR EVENTS (today + next 14 days): No events found.');
    });

    test('permission disclosure is Juno A1 verbatim', () {
      // Takeover disclosures (P3): the canonical text lives in
      // calendar_service.dart; the coach name is an alias of it, so
      // the Settings connect-moment dialog and the approve-time
      // gate can never drift apart.
      expect(calendarCoachDisclosure, coachCalendarPermissionDisclosure);
      expect(
          coachCalendarPermissionDisclosure,
          'Tabs Coach needs read and write access to your calendar. '
          'When Google Calendar is connected, the Coach reads the '
          'titles and times of your events for today and the next 14 '
          'days and sends them to the Tabs AI service so it can '
          'answer with your schedule in context. The Coach can also '
          'add events to, and delete events from, your calendar, only '
          'for proposals you tap Approve on. Nothing is added or '
          'deleted without your approval. Tap Continue to allow '
          'calendar access.');
    });

    test('native outcome copy is verbatim, with the P5 '
        '"your calendar" wording', () {
      // Takeover disclosures (audit P5): the confirmations name
      // "your calendar", not "your Google Calendar" — inserts land
      // in the best writable DEVICE calendar, not necessarily a
      // Google one. Everything else stays native-verbatim.
      expect(
          coachCalendarAddedConfirmation('Dentist', '2026-10-20', '02:30 PM'),
          'Done! "Dentist" has been added to your calendar '
          'on 2026-10-20 at 02:30 PM. It should appear in your '
          'calendar app shortly.');
      expect(coachCalendarAddedConfirmation('Dentist', null, null),
          'Done! "Dentist" has been added to your calendar. '
          'It should appear in your calendar app shortly.');
      expect(coachCalendarDeletedConfirmation('Dentist', '2026-10-20'),
          'Successfully deleted "Dentist" scheduled for 2026-10-20 '
          'from your calendar!');
      // Juno A2: the plural (rows > 1) confirmation, verbatim.
      expect(coachCalendarDeletedPluralConfirmation(2, 'Dentist', '2026-10-20'),
          'Successfully deleted 2 events titled "Dentist" scheduled '
          'for 2026-10-20 from your calendar!');
      expect(coachCalendarDeleteNotFoundMessage('Dentist'),
          'Could not find "Dentist" on your calendar to delete.');
      expect(coachCalendarNoWritableMessage,
          contains('Could not find a writable calendar.'));
      expect(coachCalendarNullUriMessage,
          contains('The calendar insert returned no URI.'));
      expect(CalendarService.permissionDeniedMessage,
          'Calendar permissions are required to manage events.');
    });
  });

  group('enriched context branches', () {
    final now = DateTime(2026, 10, 13, 15, 4);

    test('flag off carries the not-connected instruction verbatim '
        'and no connected-branch text', () {
      final ctx = coachEnrichedUserContext('BASE', now: now);
      expect(
          ctx,
          contains('CALENDAR EVENTS: Since Google Calendar is NOT '
              'connected yet, if the user asks you to schedule a '
              'calendar event or appointment, politely guide them to '
              'connect their Google Calendar first in Settings -> '
              'Connected Apps. Do NOT output a '
              '[PROPOSE_CALENDAR_EVENT:...] tag.'));
      expect(ctx, isNot(contains('IMPORTANT DATE RESOLUTION RULES')));
      expect(ctx, isNot(contains('Since Google Calendar is connected')));
      expect(ctx, isNot(contains('CRITICAL RULES FOR READING')));
    });

    test('flag on carries the connected branch incl. events context',
        () {
      final events = formatUpcomingCalendarEvents([
        CalendarEventItem(
          title: 'Physical therapy',
          startMillis:
              DateTime(2026, 10, 13, 10, 0).millisecondsSinceEpoch,
          allDay: false,
        ),
      ]);
      final ctx = coachEnrichedUserContext('BASE',
          now: now, calendarConnected: true, calendarEventsContext: events);
      expect(
          ctx,
          contains("CURRENT TIME: The user's current local date and "
              'time is Tuesday, October 13, 2026 15:04. '
              "Today's date is 2026-10-13."));
      expect(ctx, contains('IMPORTANT DATE RESOLUTION RULES:'));
      expect(ctx, contains('- "today" = 2026-10-13'));
      expect(ctx, contains('- Physical therapy on 2026-10-13 10:00 AM'));
      expect(
          ctx,
          contains('CALENDAR EVENTS: Since Google Calendar is '
              'connected, you can propose scheduling events, setting '
              'appointments, calendar updates, or deletions.'));
      expect(
          ctx,
          contains('Format for Proposing Event: '
              '[PROPOSE_CALENDAR_EVENT:Event Title|YYYY-MM-DD|hh:mm AM/PM|Description]'));
      expect(
          ctx,
          contains('Format for Deleting Event: '
              '[PROPOSE_DELETE_CALENDAR_EVENT:Event Title|YYYY-MM-DD]'));
      expect(
          ctx, contains('CRITICAL RULES FOR READING & SCHEDULING EVENTS:'));
      expect(ctx, contains('include ALL events on 2026-10-13'));
      expect(ctx, isNot(contains('NOT connected yet')));
    });
  });

  group('calendar approval flows', () {
    testWidgets('approve add, granted → insert once, confirmation, '
        'tag APPROVED', (tester) async {
      final bridge = FakeCalendarBridge();
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      // Connected card: native's label, no limitation text.
      expect(find.text('Approve & Add'), findsOneWidget);
      expect(find.text('Native App Required'), findsNothing);
      expect(find.text(coachCalendarCardLimitation), findsNothing);

      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();

      final inserts = bridge.callsTo('insertEvent');
      expect(inserts, hasLength(1));
      final args = inserts.single.arguments as Map;
      expect(args['title'], 'Dentist');
      expect(args['date'], '2026-10-20');
      expect(args['time'], '02:30 PM');
      expect(args['description'], 'Checkup');
      expect(args['connectedEmail'], 'me@example.com');
      expect(
          find.text('Done! "Dentist" has been added to your calendar '
              'on 2026-10-20 at 02:30 PM. It should appear '
              'in your calendar app shortly.'),
          findsOneWidget);
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsOneWidget);
    });

    testWidgets('approve delete → rows=2 plural confirmation (Juno A2)',
        (tester) async {
      final bridge = FakeCalendarBridge(deleteRows: 2);
      await pumpChat(tester, bridge: bridge, messages: const [_deleteMsg]);
      expect(find.text('Approve & Delete'), findsOneWidget);
      // Juno A2: the connected pending card states the delete scope.
      expect(
          find.text('This deletes every event with this exact title '
              'on this date, across all your calendars.'),
          findsOneWidget);
      await tester.tap(find.text('Approve & Delete'));
      await tester.pumpAndSettle();
      final deletes = bridge.callsTo('deleteEvents');
      expect(deletes, hasLength(1));
      final args = deletes.single.arguments as Map;
      expect(args['title'], 'Dentist');
      expect(args['date'], '2026-10-20');
      expect(
          find.text('Successfully deleted 2 events titled "Dentist" '
              'scheduled for 2026-10-20 from your calendar!'),
          findsOneWidget);
      expect(
          find.text('Successfully deleted "Dentist" scheduled for '
              '2026-10-20 from your calendar!'),
          findsNothing);
      expect(find.text('✓ Event Deleted from Calendar'), findsOneWidget);
    });

    testWidgets('approve delete → rows=1 keeps native singular '
        'confirmation verbatim', (tester) async {
      final bridge = FakeCalendarBridge(deleteRows: 1);
      await pumpChat(tester, bridge: bridge, messages: const [_deleteMsg]);
      await tester.tap(find.text('Approve & Delete'));
      await tester.pumpAndSettle();
      expect(bridge.callsTo('deleteEvents'), hasLength(1));
      expect(
          find.text('Successfully deleted "Dentist" scheduled for '
              '2026-10-20 from your calendar!'),
          findsOneWidget);
      expect(find.text('✓ Event Deleted from Calendar'), findsOneWidget);
    });

    testWidgets('flag-off deletion card → R48 limitation, NO scope '
        'notice (Juno A2)', (tester) async {
      final bridge = FakeCalendarBridge();
      await pumpChat(tester,
          bridge: bridge, messages: const [_deleteMsg], connected: false);
      expect(find.text('Native App Required'), findsOneWidget);
      expect(find.text(coachCalendarCardLimitation), findsOneWidget);
      expect(
          find.text('This deletes every event with this exact title '
              'on this date, across all your calendars.'),
          findsNothing);
      expect(find.text(coachCalendarDeleteScopeNotice), findsNothing);
      expect(bridge.calls, isEmpty);
    });

    testWidgets('approve delete → rows=0 not-found message, still '
        'pending', (tester) async {
      final bridge = FakeCalendarBridge(deleteRows: 0);
      await pumpChat(tester, bridge: bridge, messages: const [_deleteMsg]);
      await tester.tap(find.text('Approve & Delete'));
      await tester.pumpAndSettle();
      expect(
          find.text('Could not find "Dentist" on your calendar '
              'to delete.'),
          findsOneWidget);
      // Still pending: the card is offered again.
      expect(find.text('Approve & Delete'), findsOneWidget);
      expect(find.text('✓ Event Deleted from Calendar'), findsNothing);
    });

    testWidgets('permission missing → disclosure → grant replays '
        'the approve', (tester) async {
      final bridge = FakeCalendarBridge(
          readGranted: false, writeGranted: false, grantOnRequest: true);
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      // Disclosure FIRST: no system request yet, no insert.
      expect(find.text('Calendar access needed'), findsOneWidget);
      expect(find.text(coachCalendarPermissionDisclosure), findsOneWidget);
      // Juno A1: the dialog renders the disclosure string verbatim.
      expect(
          find.text('Tabs Coach needs read and write access to your '
              'calendar. When Google Calendar is connected, the Coach '
              'reads the titles and times of your events for today and '
              'the next 14 days and sends them to the Tabs AI service '
              'so it can answer with your schedule in context. The '
              'Coach can also add events to, and delete events from, '
              'your calendar, only for proposals you tap Approve on. '
              'Nothing is added or deleted without your approval. Tap '
              'Continue to allow calendar access.'),
          findsOneWidget);
      expect(bridge.callsTo('requestPermissions'), isEmpty);
      expect(bridge.callsTo('insertEvent'), isEmpty);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(bridge.callsTo('requestPermissions'), hasLength(1));
      // The grant replayed the pending approve.
      expect(bridge.callsTo('insertEvent'), hasLength(1));
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsOneWidget);
    });

    testWidgets('permission missing → disclosure → system denial → '
        'zero writes, pending, native denial message', (tester) async {
      final bridge = FakeCalendarBridge(
          readGranted: false, writeGranted: false, grantOnRequest: false);
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(bridge.callsTo('requestPermissions'), hasLength(1));
      expect(bridge.callsTo('insertEvent'), isEmpty);
      expect(bridge.callsTo('deleteEvents'), isEmpty);
      expect(find.text('Approve & Add'), findsOneWidget); // pending
      expect(
          find.text('Calendar permissions are required to manage events.'),
          findsOneWidget); // snackbar
    });

    testWidgets('permission missing → disclosure → "Not now" → '
        'zero bridge writes, proposal still pending, no success',
        (tester) async {
      final bridge = FakeCalendarBridge(
          readGranted: false, writeGranted: false, grantOnRequest: true);
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      expect(find.text('Calendar access needed'), findsOneWidget);
      expect(find.text(coachCalendarPermissionDisclosure), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(bridge.callsTo('requestPermissions'), isEmpty);
      expect(bridge.callsTo('insertEvent'), isEmpty);
      expect(bridge.callsTo('deleteEvents'), isEmpty);
      expect(find.text('Approve & Add'), findsOneWidget); // pending
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsNothing);
      expect(find.textContaining('has been added to your calendar'),
          findsNothing);
    });

    testWidgets('permission missing → disclosure → barrier dismiss → '
        'zero bridge writes, proposal still pending, no success',
        (tester) async {
      final bridge = FakeCalendarBridge(
          readGranted: false, writeGranted: false, grantOnRequest: true);
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      expect(find.text('Calendar access needed'), findsOneWidget);

      // Tap outside the dialog to dismiss it via the barrier.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Calendar access needed'), findsNothing);
      expect(bridge.callsTo('requestPermissions'), isEmpty);
      expect(bridge.callsTo('insertEvent'), isEmpty);
      expect(bridge.callsTo('deleteEvents'), isEmpty);
      expect(find.text('Approve & Add'), findsOneWidget); // pending
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsNothing);
      expect(find.textContaining('has been added to your calendar'),
          findsNothing);
    });

    testWidgets('insert INVALID_ARGS → proposal stays pending with '
        'honest error, no added confirmation', (tester) async {
      final bridge = FakeCalendarBridge()
        ..throwInvalidArgsOnInsert = true;
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      expect(bridge.callsTo('insertEvent'), hasLength(1));
      expect(
          find.text('I could not add that to your calendar. Want me '
              'to try again? [INVALID_ARGS]'),
          findsOneWidget);
      expect(find.text('Approve & Add'), findsOneWidget); // pending
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsNothing);
      expect(find.textContaining('has been added to your calendar'),
          findsNothing);
    });

    testWidgets('no writable calendar → honest failure posted, '
        'proposal pending, no false added', (tester) async {
      final bridge = FakeCalendarBridge()
        ..insertOutcome = 'noWritableCalendar';
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      expect(find.text(coachCalendarNoWritableMessage), findsOneWidget);
      expect(find.text('Approve & Add'), findsOneWidget);
      expect(find.text('✓ Event Scheduled & Added to Calendar'),
          findsNothing);
      expect(find.textContaining('has been added to your calendar'),
          findsNothing);
    });

    testWidgets('null URI → native error posted, proposal pending',
        (tester) async {
      final bridge = FakeCalendarBridge()..insertOutcome = 'nullUri';
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      expect(find.text(coachCalendarNullUriMessage), findsOneWidget);
      expect(find.text('Approve & Add'), findsOneWidget);
    });

    testWidgets('bridge insert failure → FriendlyErrors message '
        'with visible code, proposal pending', (tester) async {
      final bridge = FakeCalendarBridge()..throwOnInsert = true;
      await pumpChat(tester, bridge: bridge, messages: const [_addMsg]);
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      expect(
          find.text('I could not add that to your calendar. Want me '
              'to try again? [CALENDAR_INSERT_FAILED]'),
          findsOneWidget);
      expect(find.text('Approve & Add'), findsOneWidget);
    });

    testWidgets('flag off → R48 limitation treatment, approve '
        'disabled', (tester) async {
      final bridge = FakeCalendarBridge();
      await pumpChat(tester,
          bridge: bridge, messages: const [_addMsg], connected: false);
      expect(find.text('Native App Required'), findsOneWidget);
      expect(find.text(coachCalendarCardLimitation), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Native App Required'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(button.onPressed, isNull);
      expect(bridge.calls, isEmpty);
    });

    testWidgets('connected send carries live upcoming events into '
        'the coach request context', (tester) async {
      final log = <http.BaseRequest>[];
      final bridge = FakeCalendarBridge()
        ..upcoming = [
          {
            'title': 'Physical therapy',
            'dtstart': DateTime(2026, 10, 14, 9, 0).millisecondsSinceEpoch,
            'allDay': false,
          },
        ];
      await pumpChat(tester,
          bridge: bridge, messages: const [], log: log);
      await tester.enterText(find.byType(TextField), 'what do I have?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      final coachReq = log
          .where((r) => r.url.path == '/api/ai/coach')
          .toList();
      expect(coachReq, hasLength(1));
      final body = jsonDecode((coachReq.single as http.Request).body)
          as Map<String, dynamic>;
      final ctx = body['userContext'] as String;
      expect(ctx, contains('Since Google Calendar is connected'));
      expect(ctx,
          contains('- Physical therapy on 2026-10-14 09:00 AM'));
    });

    // ── Takeover disclosures (audit P4): the coach request must
    // distinguish "permission missing" from "genuinely empty" ──
    testWidgets('P4: connected send with calendar permission DENIED '
        'sends the unavailable context, never "No events found."',
        (tester) async {
      final log = <http.BaseRequest>[];
      final bridge =
          FakeCalendarBridge(readGranted: false, writeGranted: false);
      await pumpChat(tester,
          bridge: bridge, messages: const [], log: log);
      await tester.enterText(find.byType(TextField), 'what do I have?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      final coachReq =
          log.where((r) => r.url.path == '/api/ai/coach').toList();
      expect(coachReq, hasLength(1));
      final body = jsonDecode((coachReq.single as http.Request).body)
          as Map<String, dynamic>;
      final ctx = body['userContext'] as String;
      expect(ctx, contains('Calendar events are unavailable right now.'));
      expect(ctx, isNot(contains('No events found.')));
      // The events read is not even attempted without permission.
      expect(bridge.callsTo('getUpcomingEvents'), isEmpty);
    });

    testWidgets('P4: connected send with permission granted and a '
        'genuinely empty calendar sends "No events found."',
        (tester) async {
      final log = <http.BaseRequest>[];
      final bridge = FakeCalendarBridge()..upcoming = const [];
      await pumpChat(tester,
          bridge: bridge, messages: const [], log: log);
      await tester.enterText(find.byType(TextField), 'what do I have?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      final coachReq =
          log.where((r) => r.url.path == '/api/ai/coach').toList();
      expect(coachReq, hasLength(1));
      final body = jsonDecode((coachReq.single as http.Request).body)
          as Map<String, dynamic>;
      final ctx = body['userContext'] as String;
      expect(ctx, contains('No events found.'));
      expect(ctx,
          isNot(contains('Calendar events are unavailable right now.')));
    });
  });
}
