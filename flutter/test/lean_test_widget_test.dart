import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart' show HrSample;
import 'package:tabs_lab/src/data/lean_test_session.dart';
import 'package:tabs_lab/src/data/lean_test_strings.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/features/tools/lean_test_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

// Widget half of the item-6 suite: safety-screen order/gating
// (§8.13–14), stop presence (§8.15), full-flow, stop outcomes,
// interrupted paths, assist confirmation, past tests, tile hiding.

LeanTestSessionStore _memoryStore(Map<String, String> backing) =>
    LeanTestSessionStore.withStorage(
      read: (key) async => backing[key],
      write: (key, value) async => backing[key] = value,
      delete: (key) async => backing.remove(key),
    );

class FakeLeanGateway implements LeanTestGateway {
  int? categoryId = 7;
  int nextId = 100;
  final List<QuickLogEntry> staged = [];
  List<QuickLogEntry> entries = const [];
  List<HrSample> samples = const [];

  @override
  Future<int?> resolveCategoryId() async => categoryId;

  @override
  Future<int> allocateEntryId() async => nextId++;

  @override
  Future<bool> stageEntry(QuickLogEntry entry) async {
    staged.add(entry);
    return true;
  }

  @override
  Future<List<QuickLogEntry>> loadEntries() async => entries;

  @override
  Future<List<HrSample>> readHrSamples(String dateStr) async => samples;
}

void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required LeanTestSessionStore store,
  required FakeLeanGateway gateway,
  required DateTime Function() clock,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: LeanTestScreen(store: store, gateway: gateway, clock: clock),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _startTest(WidgetTester tester) async {
  await tester.tap(find.byType(Checkbox));
  await tester.pump();
  await tester.tap(find.text(leanS5));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _enterHrAndSave(WidgetTester tester, String hr) async {
  await tester.enterText(find.byType(TextField).first, hr);
  await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('§8.14 safety screen: order, gating, verbatim strings', () {
    testWidgets('E1, E2, D1, S2, S3 render in the ruled order; S5 '
        'disabled until the R4 confirmation', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final now = DateTime(2026, 10, 28, 9);
      await _pumpScreen(
        tester,
        store: _memoryStore(backing),
        gateway: FakeLeanGateway(),
        clock: () => now,
      );
      for (final s in [leanE1, leanE2, leanD1, leanS2, leanS3, leanS4a]) {
        expect(find.text(s), findsOneWidget, reason: 'missing: $s');
      }
      double top(String s) => tester.getTopLeft(find.text(s)).dy;
      expect(top(leanE1) < top(leanE2), isTrue);
      expect(top(leanE2) < top(leanD1), isTrue);
      expect(top(leanD1) < top(leanS2), isTrue);
      expect(top(leanS2) < top(leanS3), isTrue);
      expect(top(leanS3) < top(leanS4a), isTrue);
      // D1 verbatim, in its own block.
      expect(
          find.byKey(const ValueKey('lean_d1_block')), findsOneWidget);
      // S5 disabled until the confirmation is selected.
      final startButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, leanS5));
      expect(startButton.onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      final enabledButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, leanS5));
      expect(enabledButton.onPressed, isNotNull);
    });

    testWidgets('plain exit from the safety screen writes no record',
        (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final gateway = FakeLeanGateway();
      final now = DateTime(2026, 10, 28, 9);
      await _pumpScreen(
        tester,
        store: _memoryStore(backing),
        gateway: gateway,
        clock: () => now,
      );
      expect(find.text(leanS5), findsOneWidget);
      expect(backing, isEmpty);
      expect(gateway.staged, isEmpty);
    });

    testWidgets('rendered safety text passes the copy lint',
        (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final now = DateTime(2026, 10, 28, 9);
      await _pumpScreen(
        tester,
        store: _memoryStore(backing),
        gateway: FakeLeanGateway(),
        clock: () => now,
      );
      const banned = [
        'keep going',
        'push through',
        'almost there',
        'great job',
        'well done',
        "we'll watch",
        'monitoring',
        "we'll alert",
        'skip your',
        'withhold',
        "don't take",
        'stop taking',
        'drink more',
        'extra salt',
        'take your medications as usual',
        '30 bpm',
        '40 bpm',
        'meets criteria',
        'positive test',
        'negative test',
      ];
      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        final text = (widget.data ?? '').toLowerCase();
        for (final b in banned) {
          expect(text.contains(b), isFalse,
              reason: 'banned "$b" rendered: ${widget.data}');
        }
      }
    });
  });

  group('full flow', () {
    testWidgets('safety → rest captures → transition → standing '
        '0–10 → completed result with S2 again', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final gateway = FakeLeanGateway();
      var now = DateTime(2026, 10, 28, 9);
      await _pumpScreen(
        tester,
        store: _memoryStore(backing),
        gateway: gateway,
        clock: () => now,
      );
      await _startTest(tester);
      expect(find.text(leanS6), findsOneWidget);

      // Rest minute 9: first baseline capture.
      now = now.add(const Duration(minutes: 9));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(leanN1), findsOneWidget);
      await _enterHrAndSave(tester, '70');

      // Rest minute 10: second baseline capture.
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(leanN1), findsOneWidget);
      await _enterHrAndSave(tester, '72');

      // Transition: standing starts ONLY from the S7 tap.
      expect(find.text(leanS8), findsOneWidget);
      expect(find.text(leanS7), findsOneWidget);
      await tester.tap(find.text(leanS7));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Standing minutes 0–10.
      for (var m = 0; m <= 10; m++) {
        expect(find.text(leanS9(m)), findsOneWidget,
            reason: 'missing prompt for minute $m');
        expect(find.text(leanS11Action), findsOneWidget);
        if (m == 2) {
          // Symptom note on a standing checkpoint only.
          await tester.enterText(
              find.byType(TextField).at(3), 'Feeling steady');
        }
        await _enterHrAndSave(tester, '${90 + m}');
        if (m < 10) {
          now = now.add(const Duration(minutes: 1));
          await tester.pump(const Duration(seconds: 1));
        }
      }

      // Result: S12 heading + completion line, baseline label, S2.
      expect(find.text(leanS12Heading), findsOneWidget);
      expect(
          find.textContaining('Completed all 10 minutes'), findsOneWidget);
      expect(
          find.text(
              'Baseline (average of your two resting readings): 71 bpm'),
          findsOneWidget);
      expect(find.text(leanS2), findsOneWidget);
      expect(find.textContaining('Feeling steady'), findsOneWidget);
      expect(gateway.staged.length, 1);
      final payload = jsonDecode(gateway.staged.single.manualText);
      expect(payload['outcome'], 'completed');
      expect(payload['disclaimerVersion'], 2);
      expect((payload['checkpoints'] as List).length, 11);
      expect(await _memoryStore(backing).load(), isNull);
    });
  });

  group('§8.15 stop presence and stop outcomes', () {
    testWidgets('stop action present and tappable at every standing '
        'minute state', (tester) async {
      _tallView(tester);
      for (var m = 0; m <= 10; m++) {
        final backing = <String, String>{};
        final store = _memoryStore(backing);
        final base = DateTime(2026, 10, 28, 9);
        final standingStart = base.add(const Duration(minutes: 11));
        await store.save(LeanTestSession(
          startedAtMs: base.millisecondsSinceEpoch,
          restStartedAtMs: base.millisecondsSinceEpoch,
          standingStartedAtMs: standingStart.millisecondsSinceEpoch,
          checkpoints: [
            for (var k = 0; k < m; k++)
              LeanCapture(
                minute: k,
                tMs: standingStart.millisecondsSinceEpoch + k * 60000,
                hr: 90 + k,
              ),
          ],
        ));
        final now = standingStart.add(Duration(minutes: m));
        await _pumpScreen(
          tester,
          store: store,
          gateway: FakeLeanGateway(),
          clock: () => now,
        );
        final stop = find.text(leanS11Action);
        expect(stop, findsOneWidget, reason: 'minute $m');
        // Without scrolling: the stop action is inside the viewport.
        final rect = tester.getRect(stop);
        expect(rect.bottom, lessThanOrEqualTo(2600),
            reason: 'minute $m stop off-screen');
        await tester.tap(stop);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text(leanS11Response), findsOneWidget,
            reason: 'minute $m stop response');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('standing stop renders S11 response, the standing '
        'outcome form, and S2 — never N5', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final base = DateTime(2026, 10, 28, 9);
      final standingStart = base.add(const Duration(minutes: 11));
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
        standingStartedAtMs: standingStart.millisecondsSinceEpoch,
        checkpoints: [
          LeanCapture(
              minute: 0,
              tMs: standingStart.millisecondsSinceEpoch,
              hr: 90,
              symptomNote: 'Note at zero'),
          LeanCapture(
              minute: 1,
              tMs: standingStart.millisecondsSinceEpoch + 60000,
              hr: 95),
        ],
      ));
      final now = standingStart.add(const Duration(minutes: 2));
      await _pumpScreen(tester,
          store: store, gateway: gateway, clock: () => now);
      await tester.tap(find.text(leanS11Action));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(leanS11Response), findsOneWidget);
      expect(find.text(leanN5), findsNothing);
      expect(find.textContaining('Stopped early at minute 2'),
          findsOneWidget);
      expect(find.text(leanS2), findsOneWidget);
      expect(gateway.staged.length, 1);
      final payload = jsonDecode(gateway.staged.single.manualText);
      expect(payload['stoppedAtMinute'], 2);
      expect((payload['checkpoints'] as List).length, 2);
    });

    testWidgets('rest stop with a value renders N5, the §9 rest '
        'outcome form, and S2 — never the S11 response',
        (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final base = DateTime(2026, 10, 28, 9);
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
        baselineCaptures: [
          LeanCapture(
              minute: 9,
              tMs: base.millisecondsSinceEpoch + 9 * 60000,
              hr: 70),
        ],
      ));
      final now = base.add(const Duration(minutes: 9));
      await _pumpScreen(tester,
          store: store, gateway: gateway, clock: () => now);
      await tester.tap(find.text(leanS11Action));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(leanN5), findsOneWidget);
      expect(find.text(leanS11Response), findsNothing);
      expect(
          find.textContaining('Stopped early during rest at minute 9'),
          findsOneWidget);
      expect(find.text(leanS2), findsOneWidget);
      expect(gateway.staged.length, 1);
    });

    testWidgets('rest stop with NO values: N5 only, no entry, no '
        'completion line, session discarded', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final base = DateTime(2026, 10, 28, 9);
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
      ));
      final now = base.add(const Duration(minutes: 3));
      await _pumpScreen(tester,
          store: store, gateway: gateway, clock: () => now);
      await tester.tap(find.text(leanS11Action));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(leanN5), findsOneWidget);
      expect(find.textContaining('Guided lean test recorded'),
          findsNothing);
      expect(find.text(leanS12Heading), findsNothing);
      expect(gateway.staged, isEmpty);
      expect(await store.load(), isNull);
    });
  });

  group('interrupted paths', () {
    testWidgets('expired standing with values shows N3; close as '
        'interrupted stages the entry', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final base = DateTime(2026, 10, 28, 9);
      final standingStart = base.add(const Duration(minutes: 11));
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
        standingStartedAtMs: standingStart.millisecondsSinceEpoch,
        checkpoints: [
          LeanCapture(
              minute: 0,
              tMs: standingStart.millisecondsSinceEpoch,
              hr: 90),
        ],
      ));
      final now = standingStart.add(const Duration(minutes: 40));
      await _pumpScreen(tester,
          store: store, gateway: gateway, clock: () => now);
      expect(find.text(leanN3Line), findsOneWidget);
      await tester.tap(find.text(leanN3Close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Interrupted'), findsWidgets);
      expect(find.text(leanS2), findsOneWidget);
      expect(gateway.staged.length, 1);
      final payload = jsonDecode(gateway.staged.single.manualText);
      expect(payload['outcome'], 'interrupted');
    });

    testWidgets('discard and start over returns to Phase 0 with the '
        'confirmation unselected and writes nothing', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final base = DateTime(2026, 10, 28, 9);
      final standingStart = base.add(const Duration(minutes: 11));
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
        standingStartedAtMs: standingStart.millisecondsSinceEpoch,
        checkpoints: [
          LeanCapture(
              minute: 0,
              tMs: standingStart.millisecondsSinceEpoch,
              hr: 90),
        ],
      ));
      final now = standingStart.add(const Duration(minutes: 40));
      await _pumpScreen(tester,
          store: store, gateway: gateway, clock: () => now);
      await tester.tap(find.text(leanN3Discard));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(leanE1), findsOneWidget);
      final startButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, leanS5));
      expect(startButton.onPressed, isNull);
      expect(gateway.staged, isEmpty);
      expect(await store.load(), isNull);
    });

    testWidgets('expired standing with ZERO values is silently '
        'discarded at relaunch — no interrupted screen',
        (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final base = DateTime(2026, 10, 28, 9);
      final standingStart = base.add(const Duration(minutes: 11));
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
        standingStartedAtMs: standingStart.millisecondsSinceEpoch,
      ));
      final now = standingStart.add(const Duration(minutes: 40));
      await _pumpScreen(
        tester,
        store: store,
        gateway: FakeLeanGateway(),
        clock: () => now,
      );
      expect(find.text(leanN3Line), findsNothing);
      expect(find.text(leanE1), findsOneWidget);
      expect(await store.load(), isNull);
    });

    testWidgets('rest expired while dead relaunches into the stand '
        'transition, not an interrupted screen', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final base = DateTime(2026, 10, 28, 9);
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
        baselineCaptures: [
          LeanCapture(
              minute: 9,
              tMs: base.millisecondsSinceEpoch + 9 * 60000,
              hr: 70),
          LeanCapture(
              minute: 10,
              tMs: base.millisecondsSinceEpoch + 10 * 60000,
              hr: 72),
        ],
      ));
      final now = base.add(const Duration(minutes: 45));
      await _pumpScreen(
        tester,
        store: store,
        gateway: FakeLeanGateway(),
        clock: () => now,
      );
      expect(find.text(leanN3Line), findsNothing);
      expect(find.text(leanS7), findsOneWidget);
    });

    testWidgets('an active session routes every entry into the live '
        'session — no safety screen, no second start', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final base = DateTime(2026, 10, 28, 9);
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
      ));
      final now = base.add(const Duration(minutes: 2));
      await _pumpScreen(
        tester,
        store: store,
        gateway: FakeLeanGateway(),
        clock: () => now,
      );
      expect(find.text(leanS5), findsNothing);
      expect(find.text(leanS6), findsOneWidget);
    });
  });

  group('Health Connect assist (§8.9 widget path)', () {
    testWidgets('an unconfirmed offer writes nothing; confirming '
        'and saving stores health_connect with the sample time',
        (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final base = DateTime(2026, 10, 28, 9);
      await store.save(LeanTestSession(
        startedAtMs: base.millisecondsSinceEpoch,
        restStartedAtMs: base.millisecondsSinceEpoch,
      ));
      final now = base.add(const Duration(minutes: 9));
      final sampleMs = now.millisecondsSinceEpoch - 2 * 60000;
      gateway.samples = [HrSample(timeMs: sampleMs, bpm: 66)];
      await _pumpScreen(tester,
          store: store, gateway: gateway, clock: () => now);
      expect(find.text(leanN1), findsOneWidget);
      await tester.tap(find.text(leanN2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('2 minutes before this checkpoint'),
          findsOneWidget);
      // Unconfirmed: the persisted session still has no capture.
      var persisted = await store.load();
      expect(persisted!.baselineCaptures, isEmpty);
      // Confirm, then save the capture.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      persisted = await store.load();
      expect(persisted!.baselineCaptures.length, 1);
      final capture = persisted.baselineCaptures.single;
      expect(capture.hr, 66);
      expect(capture.source, 'health_connect');
      expect(capture.sampleTMs, sampleMs);
    });
  });

  group('past tests (N4)', () {
    testWidgets('past results render from payload: date, outcome '
        'label, recorded values', (tester) async {
      _tallView(tester);
      final backing = <String, String>{};
      final gateway = FakeLeanGateway();
      final result = LeanTestResult(
        startedAtMs: DateTime(2026, 10, 27, 9).millisecondsSinceEpoch,
        outcome: 'completed',
        baselineReadings: [
          LeanCapture(
              minute: 9,
              tMs: DateTime(2026, 10, 27, 9, 9).millisecondsSinceEpoch,
              hr: 70),
        ],
        checkpoints: [
          LeanCapture(
              minute: 0,
              tMs: DateTime(2026, 10, 27, 9, 11).millisecondsSinceEpoch,
              hr: 92),
        ],
      );
      gateway.entries = [
        buildLeanTestEntry(id: 3, categoryId: 7, result: result)
      ];
      final now = DateTime(2026, 10, 28, 9);
      await _pumpScreen(
        tester,
        store: _memoryStore(backing),
        gateway: gateway,
        clock: () => now,
      );
      expect(find.text(leanN4), findsOneWidget);
      expect(find.textContaining('Completed all 10 minutes'),
          findsOneWidget);
      expect(find.textContaining('92 bpm'), findsWidgets);
    });
  });

  group('Tools tile (§8.10 widget path)', () {
    ToolOrderStore orderStore() {
      final store = ToolOrderStore();
      final map = <String, String>{};
      store.debugSetIO(
        read: (key) async => map[key],
        write: (key, value) async => map[key] = value,
      );
      return store;
    }

    testWidgets('tile hides when Symptoms cannot be name-resolved',
        (tester) async {
      final gateway = FakeLeanGateway()..categoryId = null;
      await tester.pumpWidget(MaterialApp(
        home: ToolsScreen(orderStore: orderStore(), leanGateway: gateway),
      ));
      await tester.pumpAndSettle();
      expect(find.text(leanS1Label), findsNothing);
    });

    testWidgets('tile shows with S1 label and subtitle when resolved',
        (tester) async {
      final gateway = FakeLeanGateway()..categoryId = 7;
      await tester.pumpWidget(MaterialApp(
        home: ToolsScreen(orderStore: orderStore(), leanGateway: gateway),
      ));
      await tester.pumpAndSettle();
      // The grid is lazy; scroll the lean tile into view.
      await tester.scrollUntilVisible(find.text(leanS1Label), 200);
      expect(find.text(leanS1Label), findsOneWidget);
      expect(find.text(leanS1Subtitle), findsOneWidget);
    });
  });
}
