import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart' show HrSample;
import 'package:tabs_lab/src/data/lean_test_session.dart';
import 'package:tabs_lab/src/data/lean_test_strings.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';

// Phase 1 item 6 — Guided Lean Test suite (spec §8 items 1–16 plus
// the founder-override §9 additions). Test 17 (PDF Z7 fixture) is
// deferred: item 3 is not in this base; the hand-off is the payload
// contract pinned by the payload tests below.

const int _t0 = 1761660000000; // a fixed session start
int _min(int m) => m * 60000;

LeanTestSessionStore _memoryStore(Map<String, String> backing) =>
    LeanTestSessionStore.withStorage(
      read: (key) async => backing[key],
      write: (key, value) async => backing[key] = value,
      delete: (key) async => backing.remove(key),
    );

class FakeLeanGateway implements LeanTestGateway {
  int? categoryId = 7;
  int nextId = 100;
  bool stageSucceeds = true;
  final List<QuickLogEntry> staged = [];
  List<QuickLogEntry> entries = const [];
  List<HrSample> samples = const [];

  @override
  Future<int?> resolveCategoryId() async => categoryId;

  @override
  Future<int> allocateEntryId() async => nextId++;

  @override
  Future<bool> stageEntry(QuickLogEntry entry) async {
    if (!stageSucceeds) return false;
    staged.add(entry);
    return true;
  }

  @override
  Future<List<QuickLogEntry>> loadEntries() async => entries;

  @override
  Future<List<HrSample>> readHrSamples(String dateStr) async => samples;
}

LeanCapture _cap(int minute, int tMs, {int? hr, int? sys, int? dia}) =>
    LeanCapture(minute: minute, tMs: tMs, hr: hr, sys: sys, dia: dia);

void main() {
  group('§8.1 phase derivation from timestamps', () {
    test('rest elapsed derives from restStartedAtMs', () {
      final s = LeanTestSession(startedAtMs: _t0, restStartedAtMs: _t0);
      expect(s.restElapsedMinutes(_t0 + _min(6)), 6);
      expect(s.phaseAt(_t0 + _min(6)), LeanPhase.rest);
    });

    test('relaunch mid-standing renders the true elapsed minute', () {
      final s = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
      );
      final now = _t0 + _min(11) + _min(4);
      expect(s.standingElapsedMinutes(now), 4);
      expect(s.currentStandingMinute(now), 4);
      expect(s.relaunchAt(now), LeanRelaunch.resume);
    });
  });

  group('§8.2 / §9 expiry while dead', () {
    test('standing expired with values closes interrupted, never resumes',
        () {
      final s = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
        checkpoints: [_cap(0, _t0 + _min(11), hr: 90)],
      );
      final now = _t0 + _min(11) + _min(31); // ended 20 minutes ago
      expect(s.standingExpired(now), isTrue);
      expect(s.relaunchAt(now), LeanRelaunch.interrupted);
    });

    test('standing expired with ZERO values routes to the N3 '
        'interrupted path — no silent discard (F3)', () {
      // §5.3 permits exactly two interrupted paths and §9 Q2
      // covers only a user-initiated rest stop: an expired
      // standing session at relaunch presents N3 whether or not
      // it holds recorded values.
      final s = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
      );
      final now = _t0 + _min(11) + _min(31);
      expect(s.relaunchAt(now), LeanRelaunch.interrupted);
    });

    test('rest expired while dead presents the stand transition', () {
      final s = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        baselineCaptures: [
          _cap(9, _t0 + _min(9), hr: 70),
          _cap(10, _t0 + _min(10), hr: 72),
        ],
      );
      expect(s.relaunchAt(_t0 + _min(45)), LeanRelaunch.transition);
      expect(s.standingStartedAtMs, isNull);
    });
  });

  group('§8.3 one active session', () {
    test('the store holds exactly one session; a save replaces it',
        () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      await store.save(
          LeanTestSession(startedAtMs: _t0, restStartedAtMs: _t0));
      await store.save(LeanTestSession(
          startedAtMs: _t0 + _min(60), restStartedAtMs: _t0 + _min(60)));
      final loaded = await store.load();
      expect(loaded!.startedAtMs, _t0 + _min(60));
      final blob = jsonDecode(backing[LeanTestSessionStore.storageKey]!);
      expect(blob['session'], isA<Map>());
    });
  });

  group('§8.4 stand transition is user-tapped only', () {
    test('rest expiry alone creates no standing timestamp', () {
      final s = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        baselineCaptures: [
          _cap(9, _t0 + _min(9), hr: 70),
          _cap(10, _t0 + _min(10), hr: 72),
        ],
      );
      final now = _t0 + _min(30);
      expect(s.phaseAt(now), LeanPhase.transition);
      expect(s.standingElapsedMinutes(now), isNull);
    });
  });

  group('§8.5 zero rule', () {
    test('0 and empty normalize to not recorded', () {
      expect(leanEnteredValue('0'), isNull);
      expect(leanEnteredValue(''), isNull);
      expect(leanEnteredValue('  '), isNull);
      expect(leanEnteredValue('72'), 72);
    });

    test('a valueless capture omits values and renders Not recorded', () {
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        checkpoints: [_cap(0, _t0 + _min(11))],
      );
      final payload = jsonEncode(result.toPayload());
      expect(payload.contains('"hr"'), isFalse);
      expect(payload.contains('"hr":0'), isFalse);
      expect(result.valueLines().first, 'Minute 0: $leanU2');
      expect(result.bodyText().contains(': 0'), isFalse);
    });
  });

  group('§8.6 baseline forms', () {
    test('two readings: mean_of_two with both raw readings kept', () {
      final readings = [
        _cap(9, _t0 + _min(9), hr: 70, sys: 118, dia: 76),
        _cap(10, _t0 + _min(10), hr: 72, sys: 120, dia: 78),
      ];
      final baseline = leanBaselineOf(readings)!;
      expect(baseline.form, 'mean_of_two');
      expect(baseline.hrMean, 71);
      expect(leanBaselineLabel(baseline),
          'Baseline (average of your two resting readings): 71 bpm');
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        baselineReadings: readings,
      );
      final payload = result.toPayload();
      expect((payload['baseline'] as Map)['form'], 'mean_of_two');
      expect(((payload['baseline'] as Map)['readings'] as List).length, 2);
      expect(result.valueLines().join('\n'), contains('Resting reading 1'));
      expect(result.valueLines().join('\n'), contains('Resting reading 2'));
    });

    test('one reading: single form with the single-reading label', () {
      final baseline = leanBaselineOf([_cap(9, _t0 + _min(9), hr: 70)])!;
      expect(baseline.form, 'single');
      expect(leanBaselineLabel(baseline),
          'Baseline (your one resting reading): 70 bpm');
    });

    test('zero readings: no baseline anywhere', () {
      expect(leanBaselineOf(const []), isNull);
      final result = LeanTestResult(startedAtMs: _t0, outcome: 'completed');
      expect(result.toPayload().containsKey('baseline'), isFalse);
      expect(
          result.valueLines().any((l) => l.contains('Baseline')), isFalse);
      expect(
          result.valueLines().any((l) => l.contains('Resting')), isFalse);
    });
  });

  group('§8.7 exactly-once offline staging', () {
    test('failed stage keeps id + pending entry; retry lands it once',
        () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway()..stageSucceeds = false;
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        baselineCaptures: [_cap(9, _t0 + _min(9), hr: 70)],
      );
      await store.save(session);
      final close = await closer.closeRestStop(session, _t0 + _min(9));
      expect(close.staged, isFalse);
      expect(gateway.staged, isEmpty);
      final persisted = await store.load();
      expect(persisted, isNotNull);
      expect(persisted!.allocatedEntryId, 100);
      expect(persisted.pendingEntryJson, isNotNull);
      expect(persisted.pendingEntryJson!['id'], 100);

      gateway.stageSucceeds = true;
      final landed = await retryPendingLeanTestEntry(
        store: store,
        stage: (entry) => gateway.stageEntry(entry),
      );
      expect(landed, isTrue);
      expect(gateway.staged.length, 1);
      expect(gateway.staged.single.id, 100);
      expect(await store.load(), isNull);
    });

    test('successful close discards the local session only after staging',
        () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
        checkpoints: [_cap(0, _t0 + _min(11), hr: 90)],
      );
      await store.save(session);
      final close =
          await closer.closeStandingStop(session, _t0 + _min(11) + _min(2));
      expect(close.staged, isTrue);
      expect(await store.load(), isNull);
    });
  });

  group('§8.8 payload-only derivation', () {
    test('editing the entry body changes no derivation', () {
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'stopped_early',
        stoppedPhase: 'standing',
        stoppedAtMinute: 3,
        baselineReadings: [_cap(9, _t0 + _min(9), hr: 70)],
        checkpoints: [_cap(0, _t0 + _min(11), hr: 95)],
      );
      final entry = buildLeanTestEntry(id: 5, categoryId: 7, result: result);
      final edited = entry.copyWith(body: 'completely different prose');
      final fromEdited = leanPastResults([edited]);
      expect(fromEdited.length, 1);
      expect(fromEdited.single.completionLine, result.completionLine);
      expect(fromEdited.single.valueLines(), result.valueLines());
      // Non-lean entries are ignored by the past-tests derivation.
      final other = QuickLogEntry(
        id: 6,
        categoryId: 7,
        body: 'x',
        chips: jsonEncode(['Headache']),
        manualText: entry.manualText,
        timestamp: _t0,
      );
      expect(leanPastResults([other]), isEmpty);
    });
  });

  group('§8.9 source honesty', () {
    test('assist offers the freshest sample at or before now, with age',
        () {
      final checkpoint = _t0 + _min(20);
      final samples = [
        HrSample(timeMs: _t0 + _min(10), bpm: 64),
        HrSample(timeMs: _t0 + _min(17), bpm: 66),
        HrSample(timeMs: _t0 + _min(25), bpm: 99), // after now: ignored
      ];
      final offer = leanAssistOffer(samples,
          nowMs: _t0 + _min(20), checkpointTMs: checkpoint);
      expect(offer!.sample.bpm, 66);
      expect(offer.displayLine, contains('3 minutes before this checkpoint'));
    });

    test('a sample at the checkpoint minute uses the plain U1 form', () {
      final t = _t0 + _min(20);
      final offer = leanAssistOffer([HrSample(timeMs: t, bpm: 66)],
          nowMs: t, checkpointTMs: t);
      expect(offer!.displayLine, startsWith('Recorded at '));
      expect(offer.displayLine, isNot(contains('before this checkpoint')));
    });

    test('no stored sample offers nothing', () {
      expect(
          leanAssistOffer(const [], nowMs: _t0, checkpointTMs: _t0), isNull);
    });
  });

  group('§8.10 category resolution', () {
    QuickLogCategory cat(int id, String name) => QuickLogCategory(
        id: id,
        name: name,
        icon: 'circle',
        colorHex: '#CCCCCC',
        isDefault: false,
        sortOrder: 0);

    test('name match wins', () {
      expect(resolveLeanCategoryId([cat(9, 'Symptoms')]), 9);
    });

    test('fallback id 1 only when a pulled category carries it', () {
      expect(resolveLeanCategoryId([cat(1, 'Other')]), 1);
    });

    test('double miss resolves null', () {
      expect(resolveLeanCategoryId([cat(4, 'Other')]), isNull);
      expect(resolveLeanCategoryId(const []), isNull);
    });
  });

  group('§8.11 stop at standing minute 3', () {
    test('outcome, minute, and absent later minutes', () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
        baselineCaptures: [
          _cap(9, _t0 + _min(9), hr: 70),
          _cap(10, _t0 + _min(10), hr: 72),
        ],
        checkpoints: [
          _cap(0, _t0 + _min(11), hr: 90),
          _cap(1, _t0 + _min(12), hr: 95),
          _cap(2, _t0 + _min(13), hr: 97),
          _cap(3, _t0 + _min(14), hr: 99),
        ],
      );
      final close =
          await closer.closeStandingStop(session, _t0 + _min(14) + 30000);
      final payload = close.result!.toPayload();
      expect(payload['outcome'], 'stopped_early');
      expect(payload['stoppedPhase'], 'standing');
      expect(payload['stoppedAtMinute'], 3);
      final minutes =
          (payload['checkpoints'] as List).map((c) => c['minute']).toList();
      expect(minutes, [0, 1, 2, 3]);
      expect(close.result!.outcomeLabel, 'Stopped early at minute 3');
    });
  });

  group('§8.12 outcome labels identical across surfaces', () {
    // Scope (corrected, F9): this checks the History body and the
    // past-tests surface, which both derive from the payload; the
    // result screen renders the same `completionLine` getter, and
    // the Z7/PDF surface is deferred to item 3 — the name no
    // longer claims surfaces it does not exercise.
    test('History body and past tests agree on the S12 line', () {
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'stopped_early',
        stoppedPhase: 'rest',
        stoppedAtMinute: 9,
        baselineReadings: [_cap(9, _t0 + _min(9), hr: 70)],
      );
      final entry = buildLeanTestEntry(id: 5, categoryId: 7, result: result);
      // The body IS the History rendering; past tests derive from
      // the payload only. Both must carry the same S12 line.
      expect(entry.body.split('\n').first, result.completionLine);
      final past = leanPastResults([entry]);
      expect(past.single.completionLine, result.completionLine);
      expect(result.completionLine,
          contains('Stopped early during rest at minute 9'));
    });
  });

  group('§9 rest-phase stops', () {
    test('rest stop with a value stages an entry with the rest form',
        () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        baselineCaptures: [_cap(9, _t0 + _min(9), hr: 70)],
      );
      await store.save(session);
      final close = await closer.closeRestStop(session, _t0 + _min(9));
      expect(close.hasEntry, isTrue);
      expect(gateway.staged.length, 1);
      expect(close.result!.outcomeLabel,
          'Stopped early during rest at minute 9');
      expect(close.result!.toPayload()['stoppedPhase'], 'rest');
      expect(await store.load(), isNull);
    });

    test('rest stop with NO values stages nothing and discards', () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session =
          LeanTestSession(startedAtMs: _t0, restStartedAtMs: _t0);
      await store.save(session);
      final close = await closer.closeRestStop(session, _t0 + _min(3));
      expect(close.hasEntry, isFalse);
      expect(close.result, isNull);
      expect(gateway.staged, isEmpty);
      expect(await store.load(), isNull);
    });

    test('a 0-only capture is not a recorded value for §9 Q2', () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway();
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        baselineCaptures: [_cap(9, _t0 + _min(9))], // submitted, empty
      );
      await store.save(session);
      final close = await closer.closeRestStop(session, _t0 + _min(10));
      expect(close.hasEntry, isFalse);
      expect(gateway.staged, isEmpty);
    });
  });

  group('payload contract', () {
    test('disclaimerVersion is 2 and kind is lean_test', () {
      final result = LeanTestResult(startedAtMs: _t0, outcome: 'completed');
      final payload = result.toPayload();
      expect(payload['v'], 1);
      expect(payload['kind'], 'lean_test');
      expect(payload['disclaimerVersion'], 2);
      final entry = buildLeanTestEntry(id: 1, categoryId: 7, result: result);
      expect(entry.chips, jsonEncode(['Lean Test']));
      final parsed = LeanTestResult.fromPayloadText(entry.manualText);
      expect(parsed, isNotNull);
      expect(parsed!.disclaimerVersion, 2);
    });

    test('no derived difference figure exists in any rendering', () {
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        baselineReadings: [
          _cap(9, _t0 + _min(9), hr: 70),
          _cap(10, _t0 + _min(10), hr: 72),
        ],
        checkpoints: [_cap(0, _t0 + _min(11), hr: 130)],
      );
      final text = result.bodyText();
      // 130 - 71 = 59 must never appear as a computed figure.
      expect(text.contains('59'), isFalse);
      expect(jsonEncode(result.toPayload()).contains('"delta"'), isFalse);
    });

    test('a lone systolic or diastolic renders as itself, never '
        'as Not recorded', () {
      // Bram fix: leanCaptureValuesText dropped a lone BP number
      // and rendered U2 for a value that WAS recorded (§5 rule 6).
      final sysOnly = _cap(0, _t0, hr: 72, sys: 120);
      expect(leanCaptureValuesText(sysOnly), contains('Systolic: 120 mmHg'));
      expect(leanCaptureValuesText(sysOnly), isNot(contains(leanU2)));
      final diaOnly = _cap(0, _t0, dia: 80);
      expect(leanCaptureValuesText(diaOnly), contains('Diastolic: 80 mmHg'));
      // A BP-only baseline with a lone systolic still gets its
      // ruled baseline label with the recorded value in it.
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        baselineReadings: [_cap(9, _t0 + _min(9), sys: 118)],
      );
      expect(leanBaselineLabel(result.baseline),
          'Baseline (your one resting reading): Systolic: 118 mmHg');
      expect(result.bodyText(), contains('Systolic: 118 mmHg'));
    });
  });

  // Scope (corrected, F9): this lint scans the shipped string
  // TABLE (`allLeanTestStrings`) plus, in the source-scan test
  // below, the three feature source files for S4d and the bpm
  // thresholds. It does not scan the data-display labels rendered
  // from `lean_test_session.dart` (`Resting reading…`, `Minute…`,
  // value lines) — those are data display, not sentence copy, and
  // claiming this lint covers them would overclaim its scope.
  group('§8.13 copy lint over the shipped string table', () {
    const banned = [
      'meets criteria',
      'positive test',
      'negative test',
      'indicates',
      'suggests you',
      '30 bpm',
      '40 bpm',
      'keep going',
      'push through',
      'almost there',
      "don't give up",
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
    ];

    test('no banned phrasing in any shipped string', () {
      for (final s in allLeanTestStrings) {
        final lower = s.toLowerCase();
        for (final b in banned) {
          expect(lower.contains(b), isFalse,
              reason: 'banned "$b" found in shipped string: $s');
        }
      }
    });

    test('"you have" verdict phrasing appears nowhere; D1 keeps '
        'only its ruled precondition form', () {
      // The spec §8.13 ban targets verdict phrasing ("you have
      // <condition>"). D1 — Juno's verbatim precondition string —
      // contains "If you have not talked with your clinician", which
      // is not a verdict; it is the one permitted occurrence, pinned
      // here so any other "you have" anywhere fails.
      for (final s in allLeanTestStrings) {
        if (s == leanD1) continue;
        expect(s.toLowerCase().contains('you have'), isFalse,
            reason: '"you have" outside D1: $s');
      }
      expect('you have'.allMatches(leanD1.toLowerCase()).length, 1);
      expect(leanD1, contains('you have not talked'));
    });

    test('diagnosis wording appears only as the S2 negation', () {
      for (final s in allLeanTestStrings) {
        if (s == leanS2) continue;
        expect(s.toLowerCase().contains('diagnos'), isFalse,
            reason: 'diagnosis wording outside S2: $s');
      }
      expect(leanS2, contains('does not diagnose'));
    });

    test('the rejected S4d string is absent from the feature sources', () {
      for (final path in [
        'lib/src/data/lean_test_strings.dart',
        'lib/src/data/lean_test_session.dart',
        'lib/src/features/tools/lean_test_screen.dart',
      ]) {
        final source = File(path).readAsStringSync().toLowerCase();
        expect(source.contains('take your medications as usual'), isFalse,
            reason: 'S4d found in $path');
        expect(source.contains('30 bpm'), isFalse);
        expect(source.contains('40 bpm'), isFalse);
      }
    });
  });

  group('F1/F2 pending retention and owner gating', () {
    Future<LeanTestSessionStore> storeWithPending(
        Map<String, String> backing, FakeLeanGateway gateway) async {
      final store = _memoryStore(backing);
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        baselineCaptures: [_cap(9, _t0 + _min(9), hr: 70)],
      );
      await store.save(session);
      final close = await closer.closeRestStop(session, _t0 + _min(9));
      expect(close.staged, isFalse);
      expect(close.isPending, isTrue);
      return store;
    }

    test('a pending entry survives retain (expiry/logout); the SAME '
        'account rebinds and its retry lands it exactly once',
        () async {
      final backing = <String, String>{};
      final gateway = FakeLeanGateway()..stageSucceeds = false;
      final store = await storeWithPending(backing, gateway);
      // Session expiry / retain-mode logout.
      expect(await store.retainUnconfirmed(), isTrue);
      expect(backing.containsKey(LeanTestSessionStore.storageKey),
          isTrue);
      expect(store.hasBoundOwner, isFalse);
      // While unbound, nothing is served.
      expect(await store.load(), isNull);
      // Same account signs back in: no mismatch, blob kept.
      expect(
          await store.clearIfOwnerMismatch(
              LeanTestSessionStore.debugDefaultOwner),
          isFalse);
      final loaded = await store.load();
      expect(loaded!.pendingEntryJson, isNotNull);
      gateway.stageSucceeds = true;
      final landed = await retryPendingLeanTestEntry(
        store: store,
        stage: (entry) => gateway.stageEntry(entry),
      );
      expect(landed, isTrue);
      expect(gateway.staged.length, 1);
      expect(gateway.staged.single.id, 100);
      expect(await store.load(), isNull);
    });

    test('a DIFFERENT account signing in drops a retained pending '
        'blob via owner mismatch before any retry can stage it',
        () async {
      final backing = <String, String>{};
      final gateway = FakeLeanGateway()..stageSucceeds = false;
      final store = await storeWithPending(backing, gateway);
      expect(await store.retainUnconfirmed(), isTrue);
      expect(await store.clearIfOwnerMismatch('other@example.com'),
          isTrue);
      expect(backing.containsKey(LeanTestSessionStore.storageKey),
          isFalse);
      gateway.stageSucceeds = true;
      final stagedCalls = <QuickLogEntry>[];
      final landed = await retryPendingLeanTestEntry(
        store: store,
        stage: (entry) async {
          stagedCalls.add(entry);
          return true;
        },
      );
      expect(landed, isFalse);
      expect(stagedCalls, isEmpty);
    });

    test('retain with NO pending entry falls through to the wipe',
        () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      await store.save(
          LeanTestSession(startedAtMs: _t0, restStartedAtMs: _t0));
      expect(await store.retainUnconfirmed(), isFalse);
      expect(backing.containsKey(LeanTestSessionStore.storageKey),
          isFalse);
    });

    test('an unbound-owner load serves nothing and deletes nothing',
        () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      await store.save(
          LeanTestSession(startedAtMs: _t0, restStartedAtMs: _t0));
      store.debugSetBoundOwner(null);
      expect(store.hasBoundOwner, isFalse);
      expect(await store.load(), isNull);
      // The blob survives unserved for the login enforcement.
      expect(backing.containsKey(LeanTestSessionStore.storageKey),
          isTrue);
      // Saving against an unbound owner is refused too.
      await store.save(LeanTestSession(
          startedAtMs: _t0 + _min(60), restStartedAtMs: _t0 + _min(60)));
      store.debugSetBoundOwner(LeanTestSessionStore.debugDefaultOwner);
      expect((await store.load())!.startedAtMs, _t0);
    });

    test('a mismatched-owner retry stages nothing', () async {
      final backing = <String, String>{};
      final gateway = FakeLeanGateway()..stageSucceeds = false;
      final store = await storeWithPending(backing, gateway);
      // Bound to a different owner WITHOUT the login enforcement
      // (the void this gate closes): the retry must still refuse.
      store.debugSetBoundOwner('other@example.com');
      final stagedCalls = <QuickLogEntry>[];
      final landed = await retryPendingLeanTestEntry(
        store: store,
        stage: (entry) async {
          stagedCalls.add(entry);
          return true;
        },
      );
      expect(landed, isFalse);
      expect(stagedCalls, isEmpty);
      expect(gateway.staged, isEmpty);
    });
  });

  group('F5 close outcomes: staged, pending, or nothing', () {
    test('category double-miss at close: result with NO entry, not '
        'staged, not pending; the session stays live', () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway()..categoryId = null;
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
        checkpoints: [_cap(0, _t0 + _min(11), hr: 90)],
      );
      await store.save(session);
      final close =
          await closer.closeStandingStop(session, _t0 + _min(12));
      expect(close.result, isNotNull);
      expect(close.entry, isNull);
      expect(close.staged, isFalse);
      expect(close.isPending, isFalse);
      expect(gateway.staged, isEmpty);
      // The session was not discarded: it remains the live session.
      expect(await store.load(), isNotNull);
    });

    test('a failed stage is genuinely pending: entry present, '
        'staged false, pending true', () async {
      final backing = <String, String>{};
      final store = _memoryStore(backing);
      final gateway = FakeLeanGateway()..stageSucceeds = false;
      final closer = LeanTestCloser(store: store, gateway: gateway);
      final session = LeanTestSession(
        startedAtMs: _t0,
        restStartedAtMs: _t0,
        standingStartedAtMs: _t0 + _min(11),
        checkpoints: [_cap(0, _t0 + _min(11), hr: 90)],
      );
      await store.save(session);
      final close =
          await closer.closeStandingStop(session, _t0 + _min(12));
      expect(close.entry, isNotNull);
      expect(close.staged, isFalse);
      expect(close.isPending, isTrue);
    });
  });

  group('F6 per-value source stamping', () {
    test('a Health Connect HR assist tags only HR; hand-typed BP '
        'in the same capture stays manual, end-to-end', () {
      final capture = LeanCapture(
        minute: 0,
        tMs: _t0 + _min(11),
        hr: 92,
        sys: 121,
        dia: 79,
        hrSource: 'health_connect',
        hrSampleTMs: _t0 + _min(10),
        bpSource: 'manual',
      );
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        checkpoints: [capture],
      );
      final payload = result.toPayload();
      final row = (payload['checkpoints'] as List).single as Map;
      expect(row['hrSource'], 'health_connect');
      expect(row['hrSampleTMs'], _t0 + _min(10));
      expect(row['bpSource'], 'manual');
      expect(row.containsKey('source'), isFalse);
      final parsed = LeanTestResult.fromPayload(payload)!;
      final back = parsed.checkpoints.single;
      expect(back.hrSource, 'health_connect');
      expect(back.hrSampleTMs, _t0 + _min(10));
      expect(back.bpSource, 'manual');
      expect(back.sys, 121);
    });
  });

  group('F7 baseline per-field form and slot minutes', () {
    test('one HR reading among two readings renders under the '
        'single-reading label for HR', () {
      final readings = [
        _cap(9, _t0 + _min(9), hr: 70),
        _cap(10, _t0 + _min(10), sys: 120, dia: 80),
      ];
      final baseline = leanBaselineOf(readings)!;
      expect(baseline.hrCount, 1);
      expect(baseline.hrForm, 'single');
      expect(baseline.sysForm, 'single');
      expect(leanBaselineLabel(baseline),
          'Baseline (your one resting reading): 70 bpm');
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        baselineReadings: readings,
      );
      final fieldForms =
          (result.toPayload()['baseline'] as Map)['fieldForms'] as Map;
      expect(fieldForms['hr'], 'single');
    });

    test('a lone minute-10 baseline reading keeps minute 10 '
        'through the payload round-trip', () {
      final result = LeanTestResult(
        startedAtMs: _t0,
        outcome: 'completed',
        baselineReadings: [_cap(10, _t0 + _min(10), hr: 72)],
      );
      final payload = result.toPayload();
      final rows = (payload['baseline'] as Map)['readings'] as List;
      expect(rows.single['minute'], 10);
      final parsed = LeanTestResult.fromPayload(payload)!;
      expect(parsed.baselineReadings.single.minute, 10);
    });
  });

  group('§8.16 no-auto-start structure', () {
    test('the only session construction is the safety-screen start, '
        'and the only LeanTestScreen route is the Tools tile', () {
      final screenSource =
          File('lib/src/features/tools/lean_test_screen.dart')
              .readAsStringSync();
      final sessionSource =
          File('lib/src/data/lean_test_session.dart').readAsStringSync();
      final toolsSource =
          File('lib/src/features/tools/tools_screen.dart').readAsStringSync();
      // Sessions are constructed in exactly one place: _start,
      // behind the R4 confirmation in the screen.
      expect('LeanTestSession(startedAtMs'.allMatches(screenSource).length, 1);
      expect(sessionSource.contains('LeanTestSession(startedAtMs'), isFalse);
      // The tile route is the only place the screen is pushed.
      expect('LeanTestScreen('.allMatches(toolsSource).length, 1);
      expect(screenSource.contains('standingStartedAtMs: _nowMs'), isTrue);
    });
  });
}
