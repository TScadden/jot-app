import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_insight_store.dart';

/// Phase 1, item 5 — insight store tests (spec §8, test 9's
/// round-trip half; premium gating is the UI worker's surface).

class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

CorrelationInsightStore _store(_FakeStore fake) {
  final s = CorrelationInsightStore.testInstance();
  s.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return s;
}

const _numbersRecord = InsightRecord(
  familyId: 'F1',
  splitId: 'F1a',
  windowKey: 'last90d',
  state: InsightState.numbers,
  groups: [
    InsightGroup(
        label: 'nights under 6 hours of sleep', n: 5, mean: 70, median: 70),
    InsightGroup(
        label: 'nights with 6 or more hours of sleep',
        n: 9,
        mean: 80,
        median: 80),
  ],
  componentOutcomes: [
    InsightComponentOutcome(
      outcomeId: 'scoreSleep',
      state: InsightState.numbers,
      groups: [
        InsightGroup(label: 'a', n: 5, mean: 71, median: 71),
        InsightGroup(label: 'b', n: 9, mean: 81, median: 81),
      ],
    ),
    InsightComponentOutcome(
      outcomeId: 'scoreHrv',
      state: InsightState.progress,
      groups: [
        InsightGroup(label: 'a', n: 2),
        InsightGroup(label: 'b', n: 3),
      ],
    ),
  ],
  computedAtMs: 123456789,
  throughDate: '2026-09-28',
  inputFingerprint: 'v1|F1|through:2026-09-28|bio:90|sleep:80',
);

const _incidenceRecord = InsightRecord(
  familyId: 'F2',
  splitId: 'fluid-flare',
  windowKey: 'last90d',
  state: InsightState.numbers,
  groups: [
    InsightGroup(label: 'days your logged intake reached your target', n: 7),
    InsightGroup(
        label: 'days your logged intake was below your target', n: 7),
  ],
  incidence: IncidenceResult(x: 7, n: 7, y: 0, m: 7),
  computedAtMs: 123456789,
  throughDate: '2026-09-28',
  inputFingerprint: 'v1|F2|through:2026-09-28|bio:90|flare:7|intake:14',
);

const _f3Record = InsightRecord(
  familyId: 'F3',
  splitId: 'F3',
  windowKey: 'last90d',
  state: InsightState.numbers,
  groups: [
    InsightGroup(label: 'days you logged a flare', n: 7, mean: 40, median: 40),
    InsightGroup(
        label: 'days with no flare logged', n: 7, mean: 80, median: 80),
  ],
  coOccurrence: CoOccurrence(
    confounderLabel: 'sleep',
    groupADays: 'flare',
    groupBDays: 'non-flare',
    valueA: 300,
    valueB: 500,
  ),
  computedAtMs: 123456789,
  throughDate: '2026-09-28',
  inputFingerprint: 'v1|F3|through:2026-09-28|bio:90|flare:7|sleep:14',
);

const _f5Record = InsightRecord(
  familyId: 'F5',
  splitId: 'ev1',
  windowKey: 'event:ev1',
  state: InsightState.progress,
  groups: [
    InsightGroup(label: 'scored days before the change', n: 14),
    InsightGroup(label: 'scored days after the change', n: 2),
  ],
  headerLabel: 'Started MedA · 5 mg',
  subjectName: 'MedA',
  computedAtMs: 123456789,
  throughDate: '2026-09-28',
  inputFingerprint: 'v1|F5|through:2026-09-28|bio:28|events:1',
);

const _f5DeleteRecord = InsightRecord(
  familyId: 'F5',
  splitId: 'ev2',
  windowKey: 'event:ev2',
  state: InsightState.unavailable,
  groups: [
    InsightGroup(label: 'scored days before the change', n: 0),
    InsightGroup(label: 'scored days after the change', n: 0),
  ],
  subjectName: 'MedB', // headerLabel null for deletes, by design
  computedAtMs: 123456789,
  throughDate: '2026-09-28',
  inputFingerprint: 'v1|F5|through:2026-09-28|bio:28|events:2',
);

void main() {
  test('records round-trip through the insight store identically',
      () async {
    final fake = _FakeStore();
    final store = _store(fake);
    store.bindToAccount('user@example.com');
    await store.writeAll({
      for (final r in [
        _numbersRecord,
        _incidenceRecord,
        _f3Record,
        _f5Record,
        _f5DeleteRecord,
      ])
        r.storeKey: r,
    });

    // A fresh instance over the same disk blob (a restart).
    final reopened = _store(fake);
    final read = await reopened.readAll();
    expect(read.length, 5);
    expect(read['F1/F1a'], _numbersRecord);
    expect(read['F2/fluid-flare'], _incidenceRecord);
    expect(read['F3/F3'], _f3Record);
    expect(read['F5/ev1'], _f5Record);
    expect(read['F5/ev2'], _f5DeleteRecord);
    expect(read['F5/ev2']!.headerLabel, isNull);
    expect(read['F5/ev2']!.subjectName, 'MedB');
  });

  test('record JSON round-trip is lossless on its own', () {
    for (final r in [
      _numbersRecord,
      _incidenceRecord,
      _f3Record,
      _f5Record,
      _f5DeleteRecord,
    ]) {
      expect(InsightRecord.fromJson(r.toJson()), r, reason: r.splitId);
    }
  });

  test('writeRecords merges per key without dropping other splits',
      () async {
    final fake = _FakeStore();
    final store = _store(fake);
    await store.writeRecords([_numbersRecord]);
    await store.writeRecords([_f3Record]);
    final read = await store.readAll();
    expect(read.length, 2);
    expect(read['F1/F1a'], _numbersRecord);
    expect(read['F3/F3'], _f3Record);
  });

  test('a blob owned by a different account is dropped, never served',
      () async {
    final fake = _FakeStore();
    final store = _store(fake);
    store.bindToAccount('first@example.com');
    await store.writeAll({_numbersRecord.storeKey: _numbersRecord});

    final other = _store(fake);
    final read = await other.readAll();
    // Unbound warm adopts the blob (house pattern); an explicit
    // differing account wipes it.
    expect(read.length, 1);
    final wiped = await other.clearIfOwnerMismatch('second@example.com');
    expect(wiped, isTrue);
    expect(await other.readAll(), isEmpty);
  });
}
