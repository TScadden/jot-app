import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

import 'test_helpers.dart';

TabsBackend _backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

/// Tyson's EXACT production row (Nov 21, 2026): minimal native row —
/// no fixedMinute, no daysOfWeekConfig, no interval keys. The server
/// (user_profiles.reminders TEXT) holds exactly this JSON array.
Map<String, dynamic> _tysonRow({required bool enabled}) => {
      'id': 9,
      'title': 'Take meds',
      'type': 'FIXED',
      'fixedHour': 10,
      'isEnabled': enabled,
    };

/// The literal DB string for the enabled row.
const String _tysonDbStringEnabled =
    '[{"id":9,"title":"Take meds","type":"FIXED","fixedHour":10,"isEnabled":true}]';

/// In-memory stand-in for the sync server, modelled on
/// tools_r47_test.dart's _ReminderServer: pull serves
/// profile.reminders as a raw TEXT string (production shape);
/// profile pushes replace the stored rows.
class _ReminderServer {
  List<Map<String, dynamic>> rows;
  bool failPush = false;
  final List<Map<String, dynamic>> pushes = [];

  _ReminderServer(this.rows);

  MockClient client() => MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'profile': {'reminders': jsonEncode(rows)},
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/profile') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          pushes.add(body);
          if (failPush) return http.Response('{"error":"x"}', 500);
          rows = TabsBackend.decodeProfileList(body['reminders']);
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      });

  List<Map<String, dynamic>> get lastPushedRows =>
      TabsBackend.decodeProfileList(pushes.last['reminders']);
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

/// A notification service whose cancel() stalls until the test
/// releases it — models a stalled plugin/platform call on device
/// (the founder defect: one stalled cancel must not wedge the
/// screen's write controls).
class _StallingNotificationService extends FakeReminderNotificationService {
  Completer<void>? cancelGate;
  int cancelCalls = 0;

  @override
  Future<void> cancel(int id) async {
    cancelCalls++;
    final g = cancelGate;
    if (g != null) await g.future;
    await super.cancel(id);
  }
}

/// A notification service where every cancel/schedule costs async
/// time — models the 1500 serial platform round trips of a full
/// alarm reconcile on a healthy but slow device.
class _SlowNotificationService extends FakeReminderNotificationService {
  final Duration delay;
  int cancelCalls = 0;
  _SlowNotificationService(this.delay);

  @override
  Future<void> cancel(int id) async {
    cancelCalls++;
    await Future<void>.delayed(delay);
    await super.cancel(id);
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
    await Future<void>.delayed(delay);
    await super.scheduleDaily(
      id: id,
      title: title,
      body: body,
      channelId: channelId,
      channelName: channelName,
      hour: hour,
      minute: minute,
      highImportance: highImportance,
    );
  }
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('repro: decode of Tyson minimal row', () {
    test('literal DB string decodes to one row, enabled', () {
      final rows = TabsBackend.decodeProfileList(_tysonDbStringEnabled);
      expect(rows, hasLength(1));
      expect(rows.single['id'], 9);
      expect(rows.single['isEnabled'], isTrue);
      final models = parseReminderModels(rows);
      expect(models, hasLength(1));
      expect(models.single.isEnabled, isTrue);
      expect(models.single.fixedHour, 10);
      expect(models.single.fixedMinute, 0);
      expect(reminderScheduleSummary(models.single), '10:00 AM');
    });

    test('double-encoded DB string decodes to one row, enabled', () {
      final rows =
          TabsBackend.decodeProfileList(jsonEncode(_tysonDbStringEnabled));
      expect(rows, hasLength(1));
      expect(parseReminderModels(rows).single.isEnabled, isTrue);
    });
  });

  group('repro: Reminders screen with Tyson minimal row', () {
    Widget screen(_ReminderServer server,
        {FakeReminderNotificationService? notifs}) {
      return RemindersScreen(
        backend: _backendWith(server.client(), token: 'tok'),
        notificationService: notifs ?? FakeReminderNotificationService(),
      );
    }

    testWidgets('(a) minimal row isEnabled:true renders Switch ON',
        (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: true)]);
      await _pump(tester, screen(server));
      expect(find.text('Take meds'), findsOneWidget);
      expect(find.text('10:00 AM'), findsOneWidget);
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue, reason: 'server says enabled; must render ON');
      expect(sw.onChanged, isNotNull);
    });

    testWidgets(
        '(b) minimal row isEnabled:false -> tap -> push carries true, '
        'switch stays ON, alarm scheduled', (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: false)]);
      final notifs = FakeReminderNotificationService();
      await _pump(tester, screen(server, notifs: notifs));
      var sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isFalse);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(server.pushes, hasLength(1));
      expect(server.lastPushedRows.single['isEnabled'], isTrue);
      expect(server.rows.single['isEnabled'], isTrue);
      sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue, reason: 'switch must stay ON after settle');
      // Alarm for id 9: block base 100000 + 9*1500 = 113500, slot 0, 10:00.
      expect(notifs.daily[113500], '10:0');
    });

    testWidgets('(c) re-entry: fresh screen against same server stays ON',
        (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: false)]);
      await _pump(tester, screen(server));
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(server.rows.single['isEnabled'], isTrue);

      // Fresh screen instance = re-entry. The interstitial pump
      // forces the old State to dispose (same-type pumpWidget
      // would reuse it and skip initState/_load entirely).
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      await _pump(tester, screen(server));
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue, reason: 'pushed ON state must survive re-entry');
    });

    testWidgets('(d) toggle OFF pushes false and cancels the alarm',
        (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: true)]);
      final notifs = FakeReminderNotificationService();
      await _pump(tester, screen(server, notifs: notifs));
      // Load reconcile scheduled the daily alarm.
      expect(notifs.daily[113500], '10:0');

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(server.lastPushedRows.single['isEnabled'], isFalse);
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isFalse);
      expect(notifs.daily.containsKey(113500), isFalse,
          reason: 'toggle OFF must cancel the alarm');
    });

    testWidgets(
        '(e) OFF then ON in one session (the founder sequence): '
        'second tap turns it back on', (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: true)]);
      final notifs = FakeReminderNotificationService();
      await _pump(tester, screen(server, notifs: notifs));

      await tester.tap(find.byType(Switch).first); // OFF
      await tester.pumpAndSettle();
      expect(server.rows.single['isEnabled'], isFalse);
      expect(
          tester.widget<Switch>(find.byType(Switch).first).value, isFalse);

      await tester.tap(find.byType(Switch).first); // back ON
      await tester.pumpAndSettle();
      expect(server.pushes, hasLength(2));
      expect(server.lastPushedRows.single['isEnabled'], isTrue);
      expect(server.rows.single['isEnabled'], isTrue);
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue,
          reason: 'toggle must turn BACK on after an OFF in the same session');
      expect(sw.onChanged, isNotNull,
          reason: 'controls must not stay wedged after a toggle cycle');
      expect(notifs.daily[113500], '10:0');
    });
  });

  group('repro: alarm reconcile must never wedge the toggle', () {
    testWidgets(
        '(f) stalled cancel: controls stay live, second toggle still '
        'pushes, alarm note surfaces, recovery completes the sync',
        (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: false)]);
      final notifs = _StallingNotificationService();
      await _pump(
          tester,
          RemindersScreen(
            backend: _backendWith(server.client(), token: 'tok'),
            notificationService: notifs,
          ));
      expect(
          tester.widget<Switch>(find.byType(Switch).first).value, isFalse);

      // Stall every cancel from now on (load reconcile already ran).
      notifs.cancelGate = Completer<void>();
      await tester.tap(find.byType(Switch).first);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // The push landed (server holds true — the coordinator's
      // production evidence), and the switch shows the saved state.
      expect(server.pushes, hasLength(1));
      expect(server.rows.single['isEnabled'], isTrue);
      var sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue);
      // THE DEFECT: while the alarm reconcile is stalled, every
      // write control must stay live — the push already succeeded.
      expect(sw.onChanged, isNotNull,
          reason: 'a stalled alarm sync must not wedge the toggle');

      // A second toggle during the stall still pushes.
      await tester.tap(find.byType(Switch).first);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(server.pushes, hasLength(2),
          reason: 'second toggle must push even while alarms stall');
      expect(server.rows.single['isEnabled'], isFalse);
      sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNotNull);

      // The stalled alarm sync is bounded: once it times out, the
      // honest alarm note surfaces (existing Juno copy).
      for (var i = 0; i < 30 && find.textContaining('alarm could not be scheduled').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(
          find.text(
              'Saved. The alarm could not be scheduled — check notification permissions.'),
          findsOneWidget,
          reason: 'a scheduling stall must surface the alarm note, '
              'not silent dead controls');

      // Release the stall and re-enter: the load reconcile of a
      // fresh screen re-syncs from the saved state, so the final
      // alarm state matches the final (disabled) state even though
      // the stalled tasks' plugin work could only finish late.
      // (Explicit drain loop: pumpAndSettle returns once frames
      // stop, which can leave alarm future chains mid-flight.)
      notifs.cancelGate!.complete();
      notifs.cancelGate = null;
      // Interstitial pump: drains the released stalled chains and
      // forces the old screen's State to dispose, so the next pump
      // is a genuine re-entry (fresh initState/_load).
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(MaterialApp(
        home: RemindersScreen(
          backend: _backendWith(server.client(), token: 'tok'),
          notificationService: notifs,
        ),
      ));
      for (var i = 0;
          i < 200 && notifs.daily.containsKey(113500);
          i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(notifs.daily.containsKey(113500), isFalse,
          reason: 'toggle OFF state must win the final reconcile');
      await tester.pumpAndSettle();
      sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNotNull);
    });

    testWidgets(
        '(g) slow cancels (10ms x 1500): the toggle write path '
        'releases immediately, not after the whole crawl',
        (tester) async {
      final server = _ReminderServer([_tysonRow(enabled: false)]);
      final notifs = _SlowNotificationService(const Duration(milliseconds: 10));
      await tester.pumpWidget(MaterialApp(
        home: RemindersScreen(
          backend: _backendWith(server.client(), token: 'tok'),
          notificationService: notifs,
        ),
      ));
      for (var i = 0; i < 50 && find.byType(Switch).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Switch), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      // 2s of fake time: the push is long done, but a 1500-cancel
      // reconcile crawl (15s) cannot be.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(server.pushes, hasLength(1));
      expect(server.rows.single['isEnabled'], isTrue);
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue);
      expect(sw.onChanged, isNotNull,
          reason: 'controls must release with the push, not after '
              '1500 serial alarm cancels');

      // Drain the queued reconciles explicitly (pumpAndSettle
      // returns once frames stop; the alarm crawl runs on timers):
      // load crawl 15s + write crawl 15s of fake time, bounded.
      for (var i = 0; i < 90 && notifs.daily[113500] != '10:0'; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      // After everything drains, the alarm matches the saved state.
      expect(notifs.daily[113500], '10:0');
      expect(tester.widget<Switch>(find.byType(Switch).first).onChanged,
          isNotNull);
    });
  });
}
