import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/migraine_pressure.dart';
import 'package:tabs_lab/src/data/migraine_time_format.dart';
import 'package:tabs_lab/src/data/migraine_trends.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/migraine_block.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';

import 'test_helpers.dart';

/// Migraine attack timer — production port (Juno ruling 2026-10-26).
/// Copy assertions use Juno's FINAL strings verbatim, including her
/// three §E worked examples as fixtures.

class MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

MigraineAttackStore storeWith(MemoryStore s) =>
    MigraineAttackStore.withStorage(
      read: s.read,
      write: s.write,
      delete: s.delete,
    );

class FakeMigraineNotifier implements MigraineNotifier {
  bool enabled;
  bool launch = false;
  final List<int> showCalls = [];
  int cancelCount = 0;
  FakeMigraineNotifier({this.enabled = true});

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> showAttack(int elapsedMin) async {
    if (!enabled) return false;
    showCalls.add(elapsedMin);
    return true;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  Future<bool> areNotificationsEnabled() async => enabled;

  @override
  Future<bool> launchMigrainePayload() async => launch;
}

class FakeTrendsGateway implements MigraineTrendsGateway {
  final List<QuickLogEntry> posted = [];
  bool postResult = true;
  int categoryId = 7;
  int nextId = 100;

  @override
  Future<bool> postEntry(QuickLogEntry entry) async {
    posted.add(entry);
    return postResult;
  }

  @override
  Future<int> resolveSymptomsCategoryId() async => categoryId;

  @override
  Future<int> generateEntryId() async => nextId++;
}

class Harness {
  final MemoryStore mem = MemoryStore();
  late final MigraineAttackStore store = storeWith(mem);
  final FakeMigraineNotifier notifier = FakeMigraineNotifier();
  final FakeTrendsGateway gateway = FakeTrendsGateway();
  DateTime now = DateTime(2026, 10, 26, 9, 12);
  late final MigraineController controller = MigraineController(
    store: store,
    notifier: notifier,
    gateway: gateway,
    clock: () => now,
  );
}

MigraineAttack attackFixture({
  required DateTime start,
  required DateTime end,
  String aura = 'NONE',
  int pain = 0,
  String meds = '',
  int relief = 0,
}) =>
    MigraineAttack(
      id: start.millisecondsSinceEpoch,
      startTimestamp: start.millisecondsSinceEpoch,
      endTimestamp: end.millisecondsSinceEpoch,
      auraPhase: aura,
      painPeak: pain,
      medsTaken: meds,
      reliefRating: relief,
      updatedAt: end.millisecondsSinceEpoch,
    );

void main() {
  group('formatElapsedDuration (Lab port)', () {
    test('under 60 minutes', () {
      expect(formatElapsedDuration(0), '0 min');
      expect(formatElapsedDuration(45), '45 min');
      expect(formatElapsedDuration(59), '59 min');
    });
    test('at/over 60 minutes', () {
      expect(formatElapsedDuration(60), '1h 0m');
      expect(formatElapsedDuration(135), '2h 15m');
    });
  });

  group('formatAttackTimestamp (Lab port)', () {
    test('Juno example shape', () {
      final ms = DateTime(2026, 10, 26, 11, 27).millisecondsSinceEpoch;
      expect(formatAttackTimestamp(ms), 'Oct 26, 11:27 AM');
    });
    test('midnight and noon', () {
      expect(
        formatAttackTimestamp(
            DateTime(2026, 1, 5, 0, 5).millisecondsSinceEpoch),
        'Jan 5, 12:05 AM',
      );
      expect(
        formatAttackTimestamp(
            DateTime(2026, 12, 25, 12, 0).millisecondsSinceEpoch),
        'Dec 25, 12:00 PM',
      );
    });
  });

  group('Juno §E worked examples (verbatim fixtures)', () {
    test('example 1 — full', () {
      final attack = attackFixture(
        start: DateTime(2026, 10, 26, 9, 12),
        end: DateTime(2026, 10, 26, 11, 27),
        aura: 'VISUAL',
        pain: 8,
        meds: 'sumatriptan',
        relief: 4,
      );
      final entry =
          buildMigraineTrendsEntry(attack, entryId: 42, categoryId: 1);
      expect(
        entry.body,
        'Migraine attack — 2h 15m. Aura: visual. Peak pain 8/10. '
        'Meds: sumatriptan. Relief 4/5. Started Oct 26, 9:12 AM.',
      );
      expect(entry.manualText, 'Ended Oct 26, 11:27 AM');
      expect(entry.timestamp, attack.startTimestamp);
      expect(entry.chips, '["Migraine attack"]');
      expect(entry.id, 42);
      expect(entry.categoryId, 1);
    });

    test('example 2 — dismissed form (relief unset)', () {
      final attack = attackFixture(
        start: DateTime(2026, 10, 26, 9, 12),
        end: DateTime(2026, 10, 26, 9, 57),
        pain: 6,
      );
      expect(
        buildMigraineTrendsBody(attack),
        'Migraine attack — 45 min. Peak pain 6/10. Meds: no meds logged. '
        'Relief not rated. Started Oct 26, 9:12 AM.',
      );
    });

    test('example 3 — pain never touched', () {
      final attack = attackFixture(
        start: DateTime(2026, 10, 26, 9, 12),
        end: DateTime(2026, 10, 26, 9, 24),
      );
      expect(
        buildMigraineTrendsBody(attack),
        'Migraine attack — 12 min. Peak pain not logged. '
        'Meds: no meds logged. Relief not rated. Started Oct 26, 9:12 AM.',
      );
    });
  });

  group('pressure lookup (Lab FL-005 port)', () {
    String bodyWith(int n, double first) => jsonEncode({
          'hourly': {
            'surface_pressure': [first, ...List.filled(n - 1, 1000.0)],
          },
        });

    test('≥12 values → first value', () async {
      final v = await fetchPressureHpa(
        lat: 40.0,
        lon: -111.0,
        httpGet: (_) async => bodyWith(24, 1013.25),
      );
      expect(v, 1013.25);
    });

    test('<12 values → not captured', () async {
      final v = await fetchPressureHpa(
        lat: 40.0,
        lon: -111.0,
        httpGet: (_) async => bodyWith(5, 1013.25),
      );
      expect(v, 0.0);
    });

    test('any failure → 0.0', () async {
      final v = await fetchPressureHpa(
        lat: 40.0,
        lon: -111.0,
        httpGet: (_) async => throw Exception('offline'),
      );
      expect(v, 0.0);
    });

    test('zero first value → not captured (zero-value rule)', () async {
      final v = await fetchPressureHpa(
        lat: 40.0,
        lon: -111.0,
        httpGet: (_) async => bodyWith(24, 0.0),
      );
      expect(v, 0.0);
    });
  });

  group('notification content guard (Juno condition 1)', () {
    test('title/body/channel are exactly Juno §B, no health details', () {
      expect(LocalMigraineNotifier.notificationId, 7303);
      expect(LocalMigraineNotifier.channelName, 'Migraine attack');
      expect(
        LocalMigraineNotifier.channelDescription,
        'Shows while a migraine attack is being timed. '
        'Tap the notification to end the attack.',
      );
      expect(LocalMigraineNotifier.title, 'Migraine attack in progress');
      expect(LocalMigraineNotifier.bodyForElapsed(45),
          '45 min so far. Tap to end the attack.');
      expect(LocalMigraineNotifier.bodyForElapsed(135),
          '2h 15m so far. Tap to end the attack.');
      final surfaces = [
        LocalMigraineNotifier.title,
        LocalMigraineNotifier.bodyForElapsed(45),
        LocalMigraineNotifier.channelName,
        LocalMigraineNotifier.channelDescription,
      ].join(' ').toLowerCase();
      for (final banned in [
        'pain',
        'sumatriptan',
        'aura',
        'hpa',
        'relief',
        'pressure',
        'meds',
      ]) {
        expect(surfaces, isNot(contains(banned)),
            reason: 'notification surface must not contain "$banned"');
      }
      expect(LocalMigraineNotifier.isMigrainePayload('migraine_attack'),
          isTrue);
      expect(LocalMigraineNotifier.isMigrainePayload('2026-10-26'), isFalse);
      expect(LocalMigraineNotifier.isMigrainePayload(null), isFalse);
    });
  });

  group('controller — tap-end + form save (one entry per attack)', () {
    test('tap ends at tap time; form save updates the SAME entry',
        () async {
      final h = Harness();
      await h.controller.initialize();
      expect(await h.controller.startAttack(), isTrue);
      await h.controller
          .updateActive(auraPhase: 'VISUAL', painPeak: 8, medsTaken: '');
      h.now = DateTime(2026, 10, 26, 11, 27);
      final tapMs = h.now.millisecondsSinceEpoch;
      final ended = await h.controller.endFromNotificationTap(tapMs: tapMs);
      expect(ended, isNotNull);
      expect(ended!.endTimestamp, tapMs);
      expect(h.controller.isActive, isFalse);
      expect(h.notifier.cancelCount, greaterThan(0));
      expect(h.gateway.posted, hasLength(1));
      final first = h.gateway.posted.single;
      expect(first.id, 100);
      expect(first.categoryId, 7);
      expect(first.body, contains('Relief not rated.'));
      expect(h.controller.hasPendingDetails, isTrue);

      // Form save: relief selected now; same entry id, updated body.
      final consumed = h.controller.consumePendingDetails();
      expect(consumed, isNotNull);
      expect(h.controller.consumePendingDetails(), isNull,
          reason: 'one-shot signal is consumed exactly once');
      final ok = await h.controller.saveDetails(
        attackId: ended.id,
        reliefRating: 4,
        medsTaken: 'sumatriptan',
        auraPhase: 'VISUAL',
      );
      expect(ok, isTrue);
      expect(h.gateway.posted, hasLength(2));
      final updated = h.gateway.posted.last;
      expect(updated.id, first.id, reason: 'never a second entry');
      expect(
        updated.body,
        'Migraine attack — 2h 15m. Aura: visual. Peak pain 8/10. '
        'Meds: sumatriptan. Relief 4/5. Started Oct 26, 9:12 AM.',
      );
      final stored = await h.store.loadById(ended.id);
      expect(stored!.trendsEntryId, 100);
      expect(stored.trendsEntryPending, isFalse);
      expect(stored.reliefRating, 4);
    });

    test('tap-end idempotence: second/stale tap is a no-op', () async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 26, 9, 57);
      final tapMs = h.now.millisecondsSinceEpoch;
      final ended = await h.controller.endFromNotificationTap(tapMs: tapMs);
      expect(ended!.endTimestamp, tapMs);
      // Second tap: no second end, no second entry, no new signal.
      h.controller.consumePendingDetails();
      final again = await h.controller.endFromNotificationTap(
          tapMs: tapMs + 60000);
      expect(again, isNull);
      expect(h.gateway.posted, hasLength(1));
      expect(h.controller.hasPendingDetails, isFalse);
      final stored = await h.store.loadById(ended.id);
      expect(stored!.endTimestamp, tapMs);
    });

    test('tap with no active attack is a plain app open', () async {
      final h = Harness();
      await h.controller.initialize();
      final result = await h.controller.endFromNotificationTap();
      expect(result, isNull);
      expect(h.gateway.posted, isEmpty);
      expect(h.controller.hasPendingDetails, isFalse);
      expect(h.controller.startError, isNull);
    });
  });

  group('controller — restart survival', () {
    test('persisted active attack reloads; elapsed from stored start',
        () async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      final startMs = h.now.millisecondsSinceEpoch;

      // New controller over the same store (app restart).
      final h2 = Harness();
      final c2 = MigraineController(
        store: h.store,
        notifier: h2.notifier,
        gateway: h2.gateway,
        clock: () => h2.now,
      );
      h2.now = DateTime(2026, 10, 26, 9, 57);
      await c2.initialize();
      expect(c2.isActive, isTrue);
      expect(c2.activeAttack!.startTimestamp, startMs);
      expect(c2.elapsedMinutes(), 45);
      // Notification re-posted on reconcile (permission allows).
      expect(h2.notifier.showCalls, [45]);
    });

    test('no active attack on start → stale 7303 cancelled', () async {
      final h = Harness();
      await h.controller.initialize();
      expect(h.notifier.cancelCount, greaterThan(0));
    });
  });

  group('controller — notification denied', () {
    test('attack runs, note-line condition met, end still works',
        () async {
      final h = Harness();
      h.notifier.enabled = false;
      await h.controller.initialize();
      expect(await h.controller.startAttack(), isTrue);
      expect(h.controller.isActive, isTrue);
      expect(h.controller.notificationPosted, isFalse,
          reason: 'drives the Juno §F note line in the block');
      expect(h.controller.startError, isNull);
      // The MigraineNotifier surface has no permission-request
      // method at all — start can never prompt (Juno §F).
      final ok = await h.controller
          .endWithReliefDialog(reliefRating: 2, finalPainPeak: 6);
      expect(ok, isTrue);
      expect(h.controller.isActive, isFalse);
      expect(h.gateway.posted, hasLength(1));
      expect(h.gateway.posted.single.body, contains('Relief 2/5.'));
    });
  });

  group('controller — start failure + pending Trends retry', () {
    test('store write failure shows Juno §F start line', () async {
      final failing = MigraineAttackStore.withStorage(
        read: (_) async => null,
        write: (_, _) async => throw StateError('disk full'),
        delete: (_) async {},
      );
      final h = Harness();
      final c = MigraineController(
        store: failing,
        notifier: h.notifier,
        gateway: h.gateway,
        clock: () => h.now,
      );
      expect(await c.startAttack(), isFalse);
      expect(c.startError,
          'Could not start the attack log. Please try again.');
      expect(c.isActive, isFalse);
    });

    test('offline end sets pending; retry lands the same entry once',
        () async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      h.gateway.postResult = false;
      h.now = DateTime(2026, 10, 26, 9, 57);
      await h.controller.endWithReliefDialog(reliefRating: 3);
      var stored = (await h.store.loadAll()).single;
      expect(stored.trendsEntryPending, isTrue);
      expect(stored.trendsEntryId, 100);
      expect(h.gateway.posted, hasLength(1));

      h.gateway.postResult = true;
      await h.controller.retryPendingTrends();
      stored = (await h.store.loadAll()).single;
      expect(stored.trendsEntryPending, isFalse);
      expect(h.gateway.posted, hasLength(2));
      expect(h.gateway.posted.last.id, 100,
          reason: 'retry upserts the same entry id');
    });

    test(
        'form save failure returns false (form stays open, §F); '
        'retry re-saves details only', () async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 26, 9, 57);
      final ended =
          await h.controller.endFromNotificationTap(tapMs: h.now.millisecondsSinceEpoch);
      h.gateway.postResult = false;
      final ok = await h.controller
          .saveDetails(attackId: ended!.id, reliefRating: 5);
      expect(ok, isFalse,
          reason: 'form stays open with the §F line; retry re-saves');
      // Retry succeeds and updates the same entry.
      h.gateway.postResult = true;
      final retry = await h.controller
          .saveDetails(attackId: ended.id, reliefRating: 5);
      expect(retry, isTrue);
      expect(h.gateway.posted.last.id, h.gateway.posted.first.id);
      expect(h.gateway.posted.last.body, contains('Relief 5/5.'));
    });

    test('dialog path raises no form signal', () async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      await h.controller.endWithReliefDialog(reliefRating: 4);
      expect(h.controller.hasPendingDetails, isFalse);
      expect(h.gateway.posted.single.body, contains('Relief 4/5.'));
    });

    test('notification elapsed refresh on tick', () async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      expect(h.notifier.showCalls, [0]);
      h.now = DateTime(2026, 10, 26, 9, 42);
      await h.controller.refreshNotification();
      expect(h.notifier.showCalls.last, 30);
    });
  });

  group('BackendMigraineTrendsGateway', () {
    TabsBackend backendFor(MockClient client) {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      return TabsBackend(client: client, sessionStore: session);
    }

    test('Symptoms category resolves by name, fallback 1', () async {
      final byName = BackendMigraineTrendsGateway(backendFor(MockClient(
        (_) async => http.Response(
          jsonEncode({
            'entries': <dynamic>[],
            'categories': [
              {'id': 9, 'name': 'Symptoms'},
              {'id': 1, 'name': 'Other'},
            ],
            'profile': <String, dynamic>{},
          }),
          200,
        ),
      )));
      expect(await byName.resolveSymptomsCategoryId(), 9);

      final byFallback = BackendMigraineTrendsGateway(backendFor(
          MockClient(
        (_) async => http.Response(
          jsonEncode({
            'entries': <dynamic>[],
            'categories': [
              {'id': 1, 'name': 'Other'},
            ],
            'profile': <String, dynamic>{},
          }),
          200,
        ),
      )));
      expect(await byFallback.resolveSymptomsCategoryId(), 1);
    });

    test('entry id follows the Quick Log max+1 convention', () async {
      final gateway = BackendMigraineTrendsGateway(backendFor(MockClient(
        (_) async => http.Response(
          jsonEncode({
            'entries': [
              {'id': 3, 'categoryId': 1, 'body': '', 'chips': '[]', 'manualText': '', 'timestamp': 1},
              {'id': 41, 'categoryId': 1, 'body': '', 'chips': '[]', 'manualText': '', 'timestamp': 2},
            ],
            'categories': <dynamic>[],
            'profile': <String, dynamic>{},
          }),
          200,
        ),
      )));
      expect(await gateway.generateEntryId(), 42);
    });
  });

  group('relief dialog (widget)', () {
    Future<Harness> activeHarness(WidgetTester tester) async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      return h;
    }

    testWidgets('Back leaves the attack running; Save ends with relief',
        (tester) async {
      final h = await activeHarness(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: MigraineBlock(controller: h.controller))),
      ));
      await tester.pumpAndSettle();
      expect(find.text('End attack'), findsOneWidget);
      expect(find.text('Notifications are off. End the attack here '
          'when it passes.'), findsNothing);

      await tester.tap(find.text('End attack'));
      await tester.pumpAndSettle();
      expect(find.text('Relief rating'), findsOneWidget);
      expect(find.text('How much relief do you feel now?'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(h.controller.isActive, isTrue,
          reason: 'Back never ends an attack (Juno §A)');
      expect(h.gateway.posted, isEmpty);

      await tester.tap(find.text('End attack'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(h.controller.isActive, isFalse);
      expect(h.gateway.posted, hasLength(1));
      expect(h.gateway.posted.single.body, contains('Relief 3/5.'),
          reason: 'dialog default relief is 3 (Lab behavior)');
      expect(h.controller.hasPendingDetails, isFalse,
          reason: 'no details form on the dialog path');
    });

    testWidgets('note line shows only when no notification is posted',
        (tester) async {
      final h = Harness();
      h.notifier.enabled = false;
      await h.controller.initialize();
      await h.controller.startAttack();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: MigraineBlock(controller: h.controller))),
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Notifications are off. End the attack here when '
            'it passes.'),
        findsOneWidget,
      );
    });
  });

  group('details form (widget, Juno §C)', () {
    Future<({Harness h, MigraineAttack ended})> endedHarness() async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      await h.controller.updateActive(painPeak: 6, medsTaken: '');
      h.now = DateTime(2026, 10, 26, 9, 57);
      final ended = await h.controller
          .endFromNotificationTap(tapMs: h.now.millisecondsSinceEpoch);
      h.controller.consumePendingDetails();
      return (h: h, ended: ended!);
    }

    Future<void> pumpForm(
        WidgetTester tester, Harness h, MigraineAttack ended) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMigraineDetailsForm(context,
                  controller: h.controller, attack: ended),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Migraine attack ended'), findsOneWidget);
    }

    testWidgets(
        'relief unselected initially; save without relief → not rated; '
        'prefilled pain commits untouched', (tester) async {
      final s = await endedHarness();
      await pumpForm(tester, s.h, s.ended);
      expect(
        find.text('You ended this attack at Oct 26, 9:57 AM when you '
            'tapped the notification. Add the details below to finish '
            'the record.'),
        findsOneWidget,
      );
      expect(
        find.text('If you leave without saving, the attack stays '
            'ended and relief stays unset.'),
        findsOneWidget,
      );
      final options = tester
          .widgetList<ReliefOption>(
              find.descendant(
                  of: find.byType(MigraineDetailsForm),
                  matching: find.byType(ReliefOption)))
          .toList();
      expect(options, hasLength(5));
      expect(options.every((o) => !o.selected), isTrue,
          reason: 'Condition 2: NOTHING pre-selected in the form');
      expect(find.text('Peak pain: 6 / 10'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Migraine attack ended'), findsNothing);
      expect(s.h.gateway.posted, hasLength(2));
      final updated = s.h.gateway.posted.last;
      expect(updated.id, s.h.gateway.posted.first.id);
      expect(updated.body, contains('Relief not rated.'));
      expect(updated.body, contains('Peak pain 6/10.'),
          reason: 'prefilled pain commits without a slider touch');
    });

    testWidgets('unprefilled pain untouched → not logged', (tester) async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 26, 9, 24);
      final ended = await h.controller
          .endFromNotificationTap(tapMs: h.now.millisecondsSinceEpoch);
      await pumpForm(tester, h, ended!);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(h.gateway.posted.last.body,
          contains('Peak pain not logged.'));
    });

    testWidgets('dismiss discards edits; entry stays as written at end',
        (tester) async {
      final s = await endedHarness();
      await pumpForm(tester, s.h, s.ended);
      await tester.enterText(
          find.descendant(
              of: find.byType(MigraineDetailsForm),
              matching: find.byType(TextField)),
          'rizatriptan');
      await tester.ensureVisible(find.text('Not now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Migraine attack ended'), findsNothing);
      expect(s.h.gateway.posted, hasLength(1),
          reason: 'dismiss posts nothing');
      final stored = await s.h.store.loadById(s.ended.id);
      expect(stored!.medsTaken, '');
      expect(stored.reliefRating, 0);
    });

    testWidgets('selecting relief commits it on save', (tester) async {
      final s = await endedHarness();
      await pumpForm(tester, s.h, s.ended);
      await tester.ensureVisible(find.descendant(
          of: find.byType(MigraineDetailsForm), matching: find.text('4')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(MigraineDetailsForm), matching: find.text('4')));
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(s.h.gateway.posted.last.body, contains('Relief 4/5.'));
    });
  });

  group('collapsed header (widget, Juno §D)', () {
    setUp(() {
      final mem = <String, String>{};
      HealthHistoryStore.instance.debugSetStore(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      HealthHistoryStore.instance.debugReset();
    });

    testWidgets(
        'subtitle replaced while active, plan subtitle restored after end',
        (tester) async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 26, 9, 57);

      final planMem = MemoryStore();
      final cacheMem = MemoryStore();
      final planStore = TodayPlanStore.testInstance();
      planStore.debugSetStore(
          read: planMem.read, write: planMem.write, delete: planMem.delete);
      final cache = TodaySummaryCache.testInstance();
      cache.debugSetStore(
          read: cacheMem.read, write: cacheMem.write, delete: cacheMem.delete);
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': <dynamic>[],
              'profile': <String, dynamic>{},
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response(jsonEncode({'habits': <dynamic>[]}), 200);
        }
        return http.Response('{}', 404);
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TodaySummaryCard(
              backend: TabsBackend(client: client, sessionStore: session),
              healthConnectService: _FakeHc(),
              planStore: planStore,
              summaryCache: cache,
              sessionStore: session,
              migraineController: h.controller,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Migraine attack · 45 min'), findsOneWidget,
          reason: 'header subtitle REPLACED while the attack runs');

      await h.controller.endWithReliefDialog(reliefRating: 3);
      await tester.pumpAndSettle();
      expect(find.text('Migraine attack · 45 min'), findsNothing);
      expect(find.text('No plans recorded today'), findsWidgets,
          reason: 'plan subtitle returns unchanged after the end');
    });
  });
}

class _FakeHc extends HealthConnectService {
  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
}
