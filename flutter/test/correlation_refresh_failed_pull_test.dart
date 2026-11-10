import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_insight_store.dart';
import 'package:tabs_lab/src/data/correlation_refresh.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// H1-01 regression tests — a FAILED sync pull must never be
/// treated as an empty account by [CorrelationRefresher].
///
/// Before the fix, `fetchLogEntryDtos` / `fetchLogCategories`
/// returned `const []` on pull failure, the med-event and
/// med-list providers mapped null to `const []`, and
/// `refreshIfStale` recomputed the sync-dependent families from
/// zero data and overwrote the persisted Patterns records. One
/// offline background wake silently destroyed unlocked insights.
///
/// The contract now: a failed input is distinguishable (null)
/// all the way to the refresher, and any family that depends on
/// a failed input is skipped entirely — record AND fingerprint
/// untouched — while genuinely-empty successful pulls still
/// recompute exactly as before, and purely local families (F1,
/// biometrics only) still refresh.
///
/// D-T01 extends the same contract to the device-local intake
/// target history (tests (e)/(f)): before it, the production
/// target provider mapped ANY store read failure to an empty
/// history and the refresher did not gate on it, so one failed
/// settings read recomputed F2 — its only consumer — from an
/// erroneous empty history and overwrote its persisted numbers
/// records with an n=0 progress state on an otherwise
/// successful refresh.

class _FakeDisk {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

String _day(int offset) => addDaysToDayKey('2026-09-01', offset);

int _tsFor(String dayKey, {int hour = 12}) {
  final p = parseDayKey(dayKey)!;
  return DateTime(p.year, p.month, p.day, hour).millisecondsSinceEpoch;
}

const _categories = [
  QuickLogCategory(
      id: 1,
      name: 'Symptoms',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 0),
  QuickLogCategory(
      id: 6,
      name: 'Mood & Energy',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 1),
];

Map<String, DailyBiometrics> _bioMap(int lastOffset) => {
      for (var i = 0; i <= lastOffset; i++)
        _day(i): DailyBiometrics(
          date: _day(i),
          sleepMinutes: i.isEven ? 300 : 500,
          dailyScore: 70,
          scoreSleep: 70,
          scoreHrv: 70,
          scoreRestingHr: 70,
        ),
    };

List<QuickLogEntry> _richEntries() {
  final out = <QuickLogEntry>[];
  var id = 100;
  // Feeling check-ins (F4) on offsets 0..19.
  for (var i = 0; i < 20; i++) {
    out.add(QuickLogEntry(
      id: id++,
      categoryId: 6,
      body: 'Feeling: ${i.isEven ? 5 : 1}/5 Today',
      chips: '["Daily Ranking"]',
      manualText: '',
      timestamp: _tsFor(_day(i)),
    ));
  }
  // Flare days (F2 incidence / F3) on offsets 2, 5, 8.
  for (final i in [2, 5, 8]) {
    out.add(QuickLogEntry(
      id: id++,
      categoryId: 1,
      body: 'Flare',
      chips: '["Flare Day"]',
      manualText: '',
      timestamp: _tsFor(_day(i)),
    ));
  }
  // Intake (F2) on offsets 0..13: even days hit a 2,000 mL
  // target, odd days miss — both groups populated so the seeded
  // F2 score splits land in the numbers state.
  for (var i = 0; i < 14; i++) {
    out.add(QuickLogEntry(
      id: id++,
      categoryId: 7,
      body: 'Water',
      chips: '["Intake", "Water"]',
      manualText: jsonEncode(
          {'v': 1, 'kind': 'Water', 'fluidMl': i.isEven ? 2400 : 400}),
      timestamp: _tsFor(_day(i)),
    ));
  }
  return out;
}

MedicationChangeEvent _contractEvent() {
  MedicationFieldSnapshot snap({required bool present}) =>
      MedicationFieldSnapshot(
        dose: '5 mg',
        frequency: 'Daily',
        startDate: '',
        endDate: '',
        isPresent: present,
      );
  return MedicationChangeEvent(
    id: 'e-start',
    medId: 'm1',
    medName: 'MedA',
    type: 'start',
    oldSnapshot: snap(present: false),
    newSnapshot: snap(present: true),
    effectiveDate: 'Sep 15, 2026',
    recordedAt: _tsFor('2026-09-15', hour: 9),
    source: 'tools',
  );
}

MedChangeEventInput _medEvent() =>
    medChangeEventInputFromEvent(_contractEvent());

final _seedMedication = MedicationEntry(
  id: 'm1',
  name: 'MedA',
  startDate: 'Sep 1, 2026',
  dose: '5 mg',
  frequency: 'Daily',
);

class _FixedTargetProvider implements IntakeTargetHistoryProvider {
  @override
  Future<List<IntakeTargetHistoryEntry>> loadTargetHistory() async => const [
        IntakeTargetHistoryEntry(
          fluidTargetMl: 2000,
          effectiveFromDay: '2026-09-01',
        ),
      ];
}

/// D-T01: the target-history load FAILED (null) — the signal
/// production's SettingsIntakeTargetHistoryProvider now returns
/// when the device-local target store cannot be read.
class _FailingTargetProvider implements IntakeTargetHistoryProvider {
  @override
  Future<List<IntakeTargetHistoryEntry>?> loadTargetHistory() async => null;
}

/// D-T01: the target-history load SUCCEEDED and there genuinely
/// are no targets — a non-null empty history.
class _EmptyTargetProvider implements IntakeTargetHistoryProvider {
  @override
  Future<List<IntakeTargetHistoryEntry>?> loadTargetHistory() async =>
      const [];
}

CorrelationInputs _richInputs({
  required Map<String, DailyBiometrics> biometrics,
  List<MedicationEntry> medications = const [],
}) =>
    CorrelationInputs(
      biometrics: biometrics,
      entries: _richEntries(),
      categories: _categories,
      targetHistory: const [
        IntakeTargetHistoryEntry(
          fluidTargetMl: 2000,
          effectiveFromDay: '2026-09-01',
        ),
      ],
      medEvents: [_medEvent()],
      medications: medications,
      nowDayKey: '2026-09-30',
    );

HealthHistoryStore _historyStore(_FakeDisk disk,
    Map<String, DailyBiometrics> bio) {
  disk.values[HealthHistoryStore.storageKey] = jsonEncode({
    'days': {for (final e in bio.entries) e.key: e.value.toJson()},
  });
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: disk.read, write: disk.write, delete: disk.delete);
  return store;
}

CorrelationInsightStore _insightStore(_FakeDisk disk) {
  final store = CorrelationInsightStore.testInstance();
  store.debugSetStore(read: disk.read, write: disk.write, delete: disk.delete);
  return store;
}

Future<CorrelationInsightStore> _seededInsightStore(
  _FakeDisk disk,
  CorrelationInputs inputs,
) async {
  final store = _insightStore(disk);
  final records = computeCorrelationInsights(inputs, computedAtMs: 111);
  await store.writeAll({for (final r in records) r.storeKey: r});
  return store;
}

TabsBackend _backend(MockClient client) => TabsBackend(
      client: client,
      sessionStore: FakeSessionStore()..token = 'tok',
    );

CorrelationRefresher _refresher({
  required TabsBackend backend,
  required HealthHistoryStore history,
  required CorrelationInsightStore insights,
  IntakeTargetHistoryProvider? targetProvider,
}) =>
    CorrelationRefresher(
      backend: backend,
      historyStore: history,
      insightStore: insights,
      targetProvider: targetProvider ?? _FixedTargetProvider(),
      medEventProvider: BackendMedChangeEventProvider(backend: backend),
      medListProvider: BackendMedicationListProvider(backend: backend),
      readEmail: () async => null,
      now: () => DateTime(2026, 9, 30, 12),
    );

Map<String, dynamic> _richPullBody() => {
      'entries': [for (final e in _richEntries()) e.toSyncJson()],
      'categories': [for (final c in _categories) c.toSyncJson()],
      'profile': <String, dynamic>{},
    };

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('provider failure contract', () {
    test('med-event provider: fetch failure is null, not empty', () async {
      final failing = _backend(
          MockClient((_) async => http.Response('nope', 500)));
      expect(
        await BackendMedChangeEventProvider(backend: failing)
            .loadMedChangeEvents(),
        isNull,
      );
    });

    test('med-event provider: successful empty is empty, not null',
        () async {
      final ok = _backend(MockClient((_) async => http.Response(
            jsonEncode({'success': true, 'events': []}),
            200,
          )));
      final events =
          await BackendMedChangeEventProvider(backend: ok)
              .loadMedChangeEvents();
      expect(events, isNotNull);
      expect(events, isEmpty);
    });

    test('med-list provider: pull failure is null, not empty', () async {
      final failing = _backend(
          MockClient((_) async => http.Response('nope', 500)));
      expect(
        await BackendMedicationListProvider(backend: failing)
            .loadMedications(),
        isNull,
      );
    });

    test('med-list provider: successful pull with no meds is empty',
        () async {
      final ok = _backend(MockClient((_) async => http.Response(
            jsonEncode({'entries': [], 'categories': [], 'profile': {}}),
            200,
          )));
      final meds =
          await BackendMedicationListProvider(backend: ok).loadMedications();
      expect(meds, isNotNull);
      expect(meds, isEmpty);
    });
  });

  group('refreshIfStale', () {
    test('(a) populated store + total pull failure → every persisted '
        'record unchanged', () async {
      final bio = _bioMap(29);
      final history = _historyStore(_FakeDisk(), bio);
      final insightDisk = _FakeDisk();
      final insights = await _seededInsightStore(
        insightDisk,
        _richInputs(biometrics: bio, medications: [_seedMedication]),
      );
      final before = await insights.readAll();
      expect(before.length, greaterThan(5)); // populated, incl. F5 event
      expect(before.keys.any((k) => k.startsWith('F5/')), isTrue);
      final blobBefore =
          insightDisk.values[CorrelationInsightStore.storageKey];

      // Offline wake: EVERY backend endpoint fails.
      final backend = _backend(
          MockClient((_) async => http.Response('down', 500)));
      final outcome = await _refresher(
        backend: backend,
        history: history,
        insights: insights,
      ).refreshIfStale();

      expect(outcome.recomputedCount, 0);
      final after = await insights.readAll();
      expect(after, equals(before));
      expect(
        insightDisk.values[CorrelationInsightStore.storageKey],
        blobBefore,
      );
    });

    test('(b) populated store + successful-but-empty pull → recompute '
        'still happens', () async {
      final bio = _bioMap(29);
      final history = _historyStore(_FakeDisk(), bio);
      final insights = await _seededInsightStore(
        _FakeDisk(),
        _richInputs(biometrics: bio),
      );
      final before = await insights.readAll();
      final f2Before = before['F2/fluid-score']!;
      expect(f2Before.state, InsightState.numbers);

      final backend = _backend(MockClient((request) async {
        if (request.url.path == '/api/sync/medication-events') {
          return http.Response(
            jsonEncode({'success': true, 'events': []}),
            200,
          );
        }
        return http.Response(
          jsonEncode({'entries': [], 'categories': [], 'profile': {}}),
          200,
        );
      }));
      final outcome = await _refresher(
        backend: backend,
        history: history,
        insights: insights,
      ).refreshIfStale();

      expect(outcome.ran, isTrue);
      expect(outcome.recomputedCount, greaterThan(0));
      final after = await insights.readAll();
      // The genuinely-empty account state recomputes honestly:
      // F2's intake feature is absent → unavailable, replacing the
      // seeded numbers record.
      expect(after['F2/fluid-score']!.state, InsightState.unavailable);
      expect(after['F2/fluid-score'], isNot(f2Before));
    });

    test('(c) med-events fetch fails → F5 skipped, local F1 still '
        'refreshes when stale', () async {
      // Seed from data through Sep 29; the refresher's history
      // carries one more day (Sep 30), so fingerprints move.
      final seededBio = _bioMap(28);
      final insights = await _seededInsightStore(
        _FakeDisk(),
        _richInputs(biometrics: seededBio),
      );
      final before = await insights.readAll();
      final f5Before = {
        for (final e in before.entries)
          if (e.key.startsWith('F5/')) e.key: e.value,
      };
      expect(f5Before, isNotEmpty);
      final f1aBefore = before['F1/F1a']!;

      final history = _historyStore(_FakeDisk(), _bioMap(29));
      final backend = _backend(MockClient((request) async {
        if (request.url.path == '/api/sync/medication-events') {
          return http.Response('down', 500);
        }
        return http.Response(jsonEncode(_richPullBody()), 200);
      }));
      final outcome = await _refresher(
        backend: backend,
        history: history,
        insights: insights,
      ).refreshIfStale();

      final after = await insights.readAll();
      // F5: no recompute, no overwrite, no new unavailable record —
      // seeded records and fingerprints exactly as they were.
      expect(after.containsKey('F5/F5'), isFalse);
      for (final e in f5Before.entries) {
        expect(after[e.key], e.value, reason: '${e.key} must be untouched');
      }
      // F1 is purely local (biometrics): it still refreshes.
      expect(after['F1/F1a']!.inputFingerprint,
          isNot(f1aBefore.inputFingerprint));
      expect(outcome.recomputedCount, greaterThan(0));
    });

    test('(e) target-history load fails (null) + successful rich '
        'pull → F2 records and fingerprints untouched', () async {
      final bio = _bioMap(29);
      final history = _historyStore(_FakeDisk(), bio);
      final insightDisk = _FakeDisk();
      final insights = await _seededInsightStore(
        insightDisk,
        _richInputs(biometrics: bio),
      );
      final before = await insights.readAll();
      final f2Before = before['F2/fluid-score']!;
      // The seeded fingerprint was computed WITH one target in
      // force ('targets': 1) and the seeded split is a real
      // numbers record — exactly what a failed settings read
      // destroyed before D-T01.
      expect(f2Before.state, InsightState.numbers);
      final blobBefore =
          insightDisk.values[CorrelationInsightStore.storageKey];

      // The pull SUCCEEDS with the same rich data the store was
      // seeded from; only the device-local target-history load
      // fails (null).
      final backend = _backend(MockClient((request) async {
        if (request.url.path == '/api/sync/medication-events') {
          return http.Response(
            jsonEncode({
              'success': true,
              'events': [_contractEvent().toJson()],
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_richPullBody()), 200);
      }));
      final outcome = await _refresher(
        backend: backend,
        history: history,
        insights: insights,
        targetProvider: _FailingTargetProvider(),
      ).refreshIfStale();

      expect(outcome.ran, isTrue);
      expect(outcome.recomputedCount, 0);
      final after = await insights.readAll();
      expect(after, equals(before));
      for (final e in before.entries) {
        if (e.key.startsWith('F2/')) {
          expect(after[e.key], e.value,
              reason: '${e.key} must be untouched');
          expect(after[e.key]!.inputFingerprint, e.value.inputFingerprint,
              reason: '${e.key} fingerprint must be untouched');
        }
      }
      expect(
        insightDisk.values[CorrelationInsightStore.storageKey],
        blobBefore,
      );
    });

    test('(f) genuinely empty target history (successful load, no '
        'failure) → F2 still refreshes normally', () async {
      final bio = _bioMap(29);
      final history = _historyStore(_FakeDisk(), bio);
      final insights = await _seededInsightStore(
        _FakeDisk(),
        _richInputs(biometrics: bio),
      );
      final before = await insights.readAll();
      final f2Before = before['F2/fluid-score']!;
      expect(f2Before.state, InsightState.numbers);

      final backend = _backend(MockClient((request) async {
        if (request.url.path == '/api/sync/medication-events') {
          return http.Response(
            jsonEncode({
              'success': true,
              'events': [_contractEvent().toJson()],
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_richPullBody()), 200);
      }));
      final outcome = await _refresher(
        backend: backend,
        history: history,
        insights: insights,
        targetProvider: _EmptyTargetProvider(),
      ).refreshIfStale();

      expect(outcome.ran, isTrue);
      expect(outcome.recomputedCount, greaterThan(0));
      final after = await insights.readAll();
      // A successful empty history is NOT gated: with no target
      // in force every intake day is unclassifiable, so F2's
      // fluid-score split honestly recomputes to the n=0
      // progress state — the exact recompute (e) forbids when
      // the empty history is really a failed read.
      final f2After = after['F2/fluid-score']!;
      expect(f2After, isNot(f2Before));
      expect(f2After.inputFingerprint,
          isNot(f2Before.inputFingerprint));
      expect(f2After.state, InsightState.progress);
      expect(f2After.groups[0].n, 0);
      expect(f2After.groups[1].n, 0);
    });

    test('(d) med-list pull fails while med-events succeed → F5 '
        'still skipped', () async {
      final bio = _bioMap(29);
      final history = _historyStore(_FakeDisk(), bio);
      final insights = await _seededInsightStore(
        _FakeDisk(),
        _richInputs(biometrics: bio, medications: [_seedMedication]),
      );
      final before = await insights.readAll();
      final f5Before = before['F5/e-start']!;
      expect(f5Before, isNotNull);

      // The sync pull (entries/categories/profile medications)
      // fails, but the medication-events endpoint answers with
      // the real event. F5 depends on BOTH, so it must skip: its
      // seeded-bounds fingerprint was computed WITH the med list.
      final backend = _backend(MockClient((request) async {
        if (request.url.path == '/api/sync/medication-events') {
          return http.Response(
            jsonEncode({
              'success': true,
              'events': [_contractEvent().toJson()],
            }),
            200,
          );
        }
        return http.Response('down', 500);
      }));
      await _refresher(
        backend: backend,
        history: history,
        insights: insights,
      ).refreshIfStale();

      final after = await insights.readAll();
      expect(after['F5/e-start'], f5Before);
      expect(after.containsKey('F5/F5'), isFalse);
    });
  });
}
