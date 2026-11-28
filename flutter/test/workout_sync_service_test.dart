import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/workout_sync.dart';
import 'package:tabs_lab/src/data/workout_sync_store.dart';

import 'test_helpers.dart';

/// WorkoutSyncService pins (workout sync package, DESIGN §7):
/// the §4 dedup/merge rule over the founder's real 28-session
/// fixture, the permission tri-state, fail-closed reads, field
/// construction (DECISIONS decision 6 / JUNO-STRINGS §1.3), and
/// the rich-read channel parse.

const _owner = 'a@example.com';

WorkoutSession _s(
  int startMs,
  int endMs,
  int type, {
  int? kcalTotal,
  int? kcalActive,
  int? hrAvg,
  int? hrMax,
  String? title,
  String hcId = '',
  String? clientRecordId,
  String dataOrigin = 'com.google.android.apps.fitness',
}) =>
    WorkoutSession(
      startMs: startMs,
      endMs: endMs,
      exerciseType: type,
      title: title,
      hcId: hcId,
      clientRecordId: clientRecordId,
      dataOrigin: dataOrigin,
      kcalActive: kcalActive,
      kcalTotal: kcalTotal,
      hrAvg: hrAvg,
      hrMax: hrMax,
    );

/// The founder's real acceptance set, shaped from
/// founder-workouts-raw.json (DECISIONS decision 13: 28 sessions,
/// 12 walking + 16 other, HR on all 28, calories on 22 — the
/// 0.13-kcal session's figure rounds to 0 and is missing under
/// the zero rule). The dump's per-session energy is the TOTAL
/// figure, so it lands in kcalTotal.
List<WorkoutSession> founderFixture() => [
      _s(1790119667000, 1790121729000, 79,
          hrAvg: 85, hrMax: 119, hcId: '4d2f8f09-b265-37f3-8ac3-581fd8d98ee6'),
      _s(1790469537000, 1790470722000, 79,
          hrAvg: 109, hrMax: 152, hcId: '80ffd5db-66dd-3a02-a148-f991a6ba13b2'),
      _s(1790623591000, 1790625374000, 79,
          hrAvg: 141, hrMax: 183, hcId: 'ee65c703-bd73-33a3-8a17-62fb3ee2aeca'),
      _s(1790634712000, 1790637143000, 79,
          hrAvg: 94, hrMax: 116, hcId: '4ded8d23-be25-35cb-b2fa-fbd1f566ed1f'),
      _s(1790711377000, 1790713120000, 79,
          kcalTotal: 62,
          hrAvg: 104,
          hrMax: 132,
          hcId: 'f56acac8-1b58-3ccc-8673-934f76c1db3b'),
      _s(1791837543000, 1791838541000, 79,
          kcalTotal: 34,
          hrAvg: 118,
          hrMax: 137,
          hcId: '1b762835-6bd1-3440-9a99-a9c3b50d8e35'),
      _s(1791937895000, 1791938410000, 0,
          kcalTotal: 0,
          hrAvg: 120,
          hrMax: 144,
          hcId: '763691f2-5fcd-3b26-b79b-7fe20340b0c3'),
      _s(1792028895000, 1792031216000, 79,
          kcalTotal: 113,
          hrAvg: 115,
          hrMax: 161,
          hcId: '7d34f04a-1f3b-32b5-8321-59a0843717b5'),
      _s(1792031484000, 1792033182000, 79,
          kcalTotal: 78,
          hrAvg: 144,
          hrMax: 172,
          hcId: '62bbbce0-cd6f-3eaa-972f-912c92576344'),
      _s(1792034144000, 1792035052000, 79,
          kcalTotal: 33,
          hrAvg: 122,
          hrMax: 144,
          hcId: 'e1d936ad-7c87-3cbf-81d7-950564a83352'),
      _s(1792683765000, 1792684490000, 0,
          hrAvg: 159, hrMax: 184, hcId: '532205dc-ffd8-3ff4-bb99-850441d557b3'),
      _s(1792723356000, 1792726015000, 79,
          kcalTotal: 80,
          hrAvg: 96,
          hrMax: 127,
          hcId: '75f99b31-e5e1-3694-854d-219b5d7febbe'),
      _s(1793225280000, 1793229512000, 79,
          kcalTotal: 42,
          hrAvg: 99,
          hrMax: 135,
          hcId: '6e42c71c-bcb0-35a4-a5f6-d1e8dfe502c5'),
      _s(1793668758000, 1793669448000, 0,
          kcalTotal: 13,
          hrAvg: 103,
          hrMax: 141,
          hcId: 'fa79d3cd-9704-32c6-827f-fc18336a71d9'),
      _s(1793755146000, 1793756656000, 0,
          kcalTotal: 14,
          hrAvg: 112,
          hrMax: 171,
          hcId: 'e643edae-b917-3565-9d18-b28fa67e2b63'),
      _s(1793758094000, 1793759482000, 0,
          kcalTotal: 3,
          hrAvg: 102,
          hrMax: 145,
          hcId: '8a6b73ba-76ae-34b3-9869-6f1806f053f7'),
      _s(1793838128000, 1793840093000, 0,
          kcalTotal: 19,
          hrAvg: 117,
          hrMax: 146,
          hcId: '037d104e-c95e-368b-874b-3902818f1971'),
      _s(1793927606000, 1793928728000, 0,
          kcalTotal: 6,
          hrAvg: 137,
          hrMax: 199,
          hcId: '84608917-aaeb-38ec-b0d1-e81734ff2de6'),
      _s(1794077662000, 1794078665000, 0,
          kcalTotal: 23,
          hrAvg: 100,
          hrMax: 124,
          hcId: 'fe6eaedf-3c77-344b-868a-f613167bd86f'),
      _s(1794079476000, 1794080641000, 0,
          kcalTotal: 42,
          hrAvg: 99,
          hrMax: 116,
          hcId: 'b1f89849-88fc-3a1c-a34c-a643087a036d'),
      _s(1794084313000, 1794085388000, 0,
          kcalTotal: 50,
          hrAvg: 110,
          hrMax: 125,
          hcId: '9c91fc2f-988f-351f-9c15-852402550ef3'),
      _s(1794088347000, 1794091196000, 79,
          kcalTotal: 40,
          hrAvg: 92,
          hrMax: 112,
          hcId: '259c94ea-6285-31f4-a549-07235a35e560'),
      _s(1794096748000, 1794098918000, 0,
          kcalTotal: 68,
          hrAvg: 105,
          hrMax: 139,
          hcId: '161ee0fd-195c-309e-80ef-4d1df5bfde21'),
      _s(1794160615000, 1794161403000, 0,
          kcalTotal: 10,
          hrAvg: 112,
          hrMax: 149,
          hcId: '8fceec27-ffb2-35a7-8340-c991dc8a07da'),
      _s(1794276447000, 1794277510000, 0,
          kcalTotal: 8,
          hrAvg: 105,
          hrMax: 137,
          hcId: 'f2dad8c8-eb2b-31e5-a05a-a7db3ac80b44'),
      _s(1794441448000, 1794444825000, 0,
          kcalTotal: 9,
          hrAvg: 121,
          hrMax: 163,
          hcId: '3e9b68af-78d2-353b-9dd9-d3a10329ed83'),
      _s(1795553884000, 1795555628000, 0,
          kcalTotal: 14,
          hrAvg: 107,
          hrMax: 126,
          hcId: 'd529b155-aaa8-3ef8-b26b-5e2dc306fdae'),
      _s(1795749682000, 1795751328000, 0,
          kcalTotal: 6,
          hrAvg: 104,
          hrMax: 133,
          hcId: 'c96973f6-b8e5-3cc7-8ba6-4b6ae130f819'),
    ];

const _exerciseCat = QuickLogCategory(
  id: 5,
  name: 'Exercise',
  icon: 'circle',
  colorHex: '#4ECDC4',
  isDefault: false,
  sortOrder: 2,
);
const _generalCat = QuickLogCategory(
  id: 7,
  name: 'General',
  icon: 'circle',
  colorHex: '#CCCCCC',
  isDefault: true,
  sortOrder: 0,
);

/// One harness per case: real WorkoutSyncStore (test instance)
/// and the real LogEntryOutbox singleton, both over in-memory
/// fake disks; every other touch is a closure over mutable
/// fields the case arranges.
class _Harness {
  final storeDisk = <String, String>{};
  final outboxDisk = <String, String>{};
  late final WorkoutSyncStore store;
  late final LogEntryOutbox outbox;

  List<QuickLogEntry> pulled = [];
  List<QuickLogCategory>? categories = const [_exerciseCat, _generalCat];
  HcReadOutcome<List<WorkoutSession>> outcome =
      const HcReadOutcome(value: []);
  Set<String> granted = const {kReadExercisePermission};
  bool grantedThrows = false;
  HcAvailability probeResult = fakeHcSnapshot();
  int nowMsValue = 999000;

  int readCalls = 0;
  int allocateCalls = 0;
  int stageCalls = 0;
  int flushCalls = 0;

  Future<void> init() async {
    store = WorkoutSyncStore.testInstance();
    store.debugSetStore(
      read: (k) async => storeDisk[k],
      write: (k, v) async => storeDisk[k] = v,
      delete: (k) async => storeDisk.remove(k),
    );
    await store.warmFromDisk(currentEmail: _owner);
    outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    _wireOutboxDisk();
  }

  void _wireOutboxDisk() {
    outbox.debugSetStore(
      read: (k) async => outboxDisk[k],
      write: (k, v) async => outboxDisk[k] = v,
      delete: (k) async => outboxDisk.remove(k),
    );
  }

  /// Simulates the staged records' push landing (the queue
  /// drains; the pull becomes the merged truth).
  void simulatePushLanded() {
    outbox.debugReset();
    _wireOutboxDisk();
  }

  WorkoutSyncService service() => WorkoutSyncService.withDeps(
        store: store,
        outbox: outbox,
        probe: () async => probeResult,
        grantedPermissions: () async {
          if (grantedThrows) throw StateError('grant read failed');
          return granted;
        },
        readRich: (days) async {
          readCalls++;
          expect(days, WorkoutSyncService.readWindowDays);
          return outcome;
        },
        fetchEntries: () async => pulled,
        fetchCategories: () async => categories,
        allocateId: (serverMaxId) async {
          allocateCalls++;
          return outbox.allocateEntryId(
              serverMaxId: serverMaxId, ownerEmail: _owner);
        },
        stageEntry: (entry) async {
          stageCalls++;
          return outbox.stage(entry, serverKnown: false, ownerEmail: _owner);
        },
        flushOutbox: () async {
          flushCalls++;
        },
        nowMs: () => nowMsValue,
      );

  List<QuickLogEntry> get stagedEntries => outbox.entries;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dedup over the founder fixture (28 sessions)', () {
    test('first run creates exactly 28; second run creates 0', () async {
      final h = _Harness();
      await h.init();
      h.outcome = HcReadOutcome(value: founderFixture());
      final svc = h.service();

      expect(await svc.syncAfterCapture(), isTrue);
      expect(h.stagedEntries, hasLength(28));
      expect(h.allocateCalls, 28);
      expect(h.stageCalls, 28);
      expect(h.flushCalls, 1); // one flush per run
      expect(h.store.links, hasLength(28));
      expect(h.store.lastSyncMs, h.nowMsValue);

      // Shape pins: 12 Walking + 16 Workout bodies.
      final bodies = h.stagedEntries.map((e) => e.body).toList();
      expect(bodies.where((b) => b.startsWith('Walking · ')), hasLength(12));
      expect(bodies.where((b) => b.startsWith('Workout · ')), hasLength(16));
      for (final e in h.stagedEntries) {
        expect(e.chips, 'Workout, Health Connect');
        expect(e.categoryId, 5); // Exercise chain head
      }
      // Session 1: 34.37 min wall → 34; no calories in the dump.
      final first = h.stagedEntries
          .firstWhere((e) => e.timestamp == 1790119667000);
      expect(first.body, 'Walking · 34 min');
      expect(first.manualText, 'avg HR 85 · max HR 119');
      // Session 5 (JUNO-STRINGS row b): total-only calories get
      // the total label, never a bare figure.
      final fifth = h.stagedEntries
          .firstWhere((e) => e.timestamp == 1790711377000);
      expect(fifth.body, 'Walking · 29 min');
      expect(fifth.manualText,
          'Total 62 kcal (incl. rest) · avg HR 104 · max HR 132');
      // The 0.13-kcal session: the figure rounds to 0 = missing.
      final zeroKcal = h.stagedEntries
          .firstWhere((e) => e.timestamp == 1791937895000);
      expect(zeroKcal.body, 'Workout · 9 min');
      expect(zeroKcal.manualText, 'avg HR 120 · max HR 144');

      // Second run over the same read: nothing new.
      expect(await svc.syncAfterCapture(), isTrue);
      expect(h.stagedEntries, hasLength(28));
      expect(h.allocateCalls, 28);
      expect(h.stageCalls, 28);
      expect(h.flushCalls, 1);
    });

    test('tombstoned session reappearing in the read creates 0',
        () async {
      final h = _Harness();
      await h.init();
      final session = founderFixture().first;
      h.outcome = HcReadOutcome(value: [session]);
      final svc = h.service();
      expect(await svc.syncAfterCapture(), isTrue);
      final entryId = h.stagedEntries.single.id;

      // The History delete hook's store effect.
      final prior = await h.store.tombstoneForEntry(entryId);
      expect(prior, isNotNull);

      expect(await svc.syncAfterCapture(), isTrue);
      expect(h.allocateCalls, 1);
      expect(h.stageCalls, 1);
      expect(h.store.linkForKey(session.dedupKey)!.state,
          WorkoutLinkState.tombstoned);
    });
  });

  group('merge rule (DESIGN §4)', () {
    final t0 = DateTime(2026, 11, 20, 9).millisecondsSinceEpoch;
    WorkoutSession walk() =>
        _s(t0, t0 + 30 * 60000, 79, hrAvg: 100, hrMax: 130, hcId: 'walk-1');
    QuickLogEntry manualAt(int ts, {String chips = 'Workout'}) =>
        QuickLogEntry(
          id: 900,
          categoryId: 7,
          body: 'Legs workout',
          chips: chips,
          manualText: '',
          timestamp: ts,
        );

    test('manual Workout entry inside the window → link, 0 new',
        () async {
      final h = _Harness();
      await h.init();
      h.pulled = [manualAt(t0 + 5 * 60000)];
      h.outcome = HcReadOutcome(value: [walk()]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 0);
      final link = h.store.linkForKey('hc:walk-1');
      expect(link!.state, WorkoutLinkState.adopted);
      expect(link.origin, WorkoutLinkOrigin.manual);
      expect(link.entryId, 900);
    });

    test('manual Workout entry exactly at start − 10 min → adopted',
        () async {
      final h = _Harness();
      await h.init();
      h.pulled = [manualAt(t0 - 10 * 60000)];
      h.outcome = HcReadOutcome(value: [walk()]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 0);
      expect(h.store.linkForKey('hc:walk-1')!.state,
          WorkoutLinkState.adopted);
    });

    test('manual Workout entry 11 min before start → no match, 1 new',
        () async {
      final h = _Harness();
      await h.init();
      h.pulled = [manualAt(t0 - 11 * 60000)];
      h.outcome = HcReadOutcome(value: [walk()]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 1);
      expect(h.store.linkForKey('hc:walk-1')!.state,
          WorkoutLinkState.linked);
    });

    test('non-workout entry inside the window does not suppress',
        () async {
      final h = _Harness();
      await h.init();
      h.pulled = [manualAt(t0 + 5 * 60000, chips: '')];
      h.outcome = HcReadOutcome(value: [walk()]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 1);
    });

    test('nearest manual candidate wins', () async {
      final h = _Harness();
      await h.init();
      h.pulled = [
        manualAt(t0 + 20 * 60000),
        const QuickLogEntry(
          id: 901,
          categoryId: 7,
          body: 'Morning walk',
          chips: 'Workout',
          manualText: '',
          timestamp: 0, // replaced below
        ),
      ];
      // Rebuild the near candidate with its real timestamp.
      h.pulled[1] = QuickLogEntry(
        id: 901,
        categoryId: 7,
        body: 'Morning walk',
        chips: 'Workout',
        manualText: '',
        timestamp: t0 + 2 * 60000,
      );
      h.outcome = HcReadOutcome(value: [walk()]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.store.linkForKey('hc:walk-1')!.entryId, 901);
    });

    test('two sessions the same day → 2 new', () async {
      final h = _Harness();
      await h.init();
      h.outcome = HcReadOutcome(value: [
        _s(t0, t0 + 20 * 60000, 79, hcId: 'day-1'),
        _s(t0 + 3 * 3600000, t0 + 3 * 3600000 + 25 * 60000, 0,
            hcId: 'day-2'),
      ]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 2);
      expect(h.store.links, hasLength(2));
    });

    test('staged-but-unlinked synced entry is adopted, 0 new',
        () async {
      final h = _Harness();
      await h.init();
      // A prior run staged this entry, then died before the link
      // write (§1.3 step 4 ordering).
      final stagedId = await h.outbox.allocateEntryId(
          serverMaxId: 0, ownerEmail: _owner);
      await h.outbox.stage(
        QuickLogEntry(
          id: stagedId,
          categoryId: 5,
          body: 'Walking · 30 min',
          chips: 'Workout, Health Connect',
          manualText: 'avg HR 100 · max HR 130',
          timestamp: t0,
        ),
        serverKnown: false,
        ownerEmail: _owner,
      );
      h.outcome = HcReadOutcome(value: [walk()]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.allocateCalls, 0);
      expect(h.stageCalls, 0);
      final link = h.store.linkForKey('hc:walk-1');
      expect(link!.state, WorkoutLinkState.adopted);
      expect(link.origin, WorkoutLinkOrigin.synced);
      expect(link.entryId, stagedId);
    });

    test('missing hcId → hashed tier-3 key, dedup on second run',
        () async {
      final h = _Harness();
      await h.init();
      final session = _s(t0, t0 + 30 * 60000, 79); // no ids at all
      final key = session.dedupKey;
      expect(key, startsWith('hc:fp:'));
      expect(key.length, 'hc:fp:'.length + 64);
      // The hashed key retains no readable session facts.
      expect(key.contains('$t0'), isFalse);
      expect(key.contains('79'), isFalse);
      h.outcome = HcReadOutcome(value: [session]);
      final svc = h.service();
      expect(await svc.syncAfterCapture(), isTrue);
      expect(await svc.syncAfterCapture(), isTrue);
      expect(h.stageCalls, 1);
      expect(h.store.linkForKey(key), isNotNull);
    });

    test('clientRecordId tier keys hc:cr:<pkg>:<id>', () async {
      final h = _Harness();
      await h.init();
      final session = _s(t0, t0 + 30 * 60000, 79,
          clientRecordId: 'abc123', dataOrigin: 'com.example.app');
      expect(session.dedupKey, 'hc:cr:com.example.app:abc123');
      h.outcome = HcReadOutcome(value: [session]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.store.linkForKey('hc:cr:com.example.app:abc123'),
          isNotNull);
    });
  });

  group('field construction (DECISIONS 6 / JUNO-STRINGS §1.3)', () {
    WorkoutSession base({
      int? kcalActive,
      int? kcalTotal,
      int? hrAvg,
      int? hrMax,
      String? title,
    }) =>
        _s(1000000, 1000000 + 34 * 60000, 79,
            kcalActive: kcalActive,
            kcalTotal: kcalTotal,
            hrAvg: hrAvg,
            hrMax: hrMax,
            title: title,
            hcId: 'x');

    test('metrics line — the ruled combinations', () {
      // (a) active + avg + max
      expect(
        workoutMetricsLine(base(kcalActive: 62, hrAvg: 104, hrMax: 132)),
        '62 kcal · avg HR 104 · max HR 132',
      );
      // (b) total only + avg + max
      expect(
        workoutMetricsLine(base(kcalTotal: 62, hrAvg: 104, hrMax: 132)),
        'Total 62 kcal (incl. rest) · avg HR 104 · max HR 132',
      );
      // (c1) HR only, both
      expect(workoutMetricsLine(base(hrAvg: 104, hrMax: 132)),
          'avg HR 104 · max HR 132');
      // (c2) HR only, average only
      expect(workoutMetricsLine(base(hrAvg: 104)), 'avg HR 104');
      // (c3) HR only, maximum only
      expect(workoutMetricsLine(base(hrMax: 132)), 'max HR 132');
      // (c4) calories only, active
      expect(workoutMetricsLine(base(kcalActive: 62)), '62 kcal');
      // (c5) calories only, total
      expect(workoutMetricsLine(base(kcalTotal: 62)),
          'Total 62 kcal (incl. rest)');
      // (c6) title + full metrics (active) — title always first
      expect(
        workoutMetricsLine(base(
            title: 'Morning walk', kcalActive: 62, hrAvg: 104, hrMax: 132)),
        'Morning walk · 62 kcal · avg HR 104 · max HR 132',
      );
      // (c7) title + full metrics (total)
      expect(
        workoutMetricsLine(base(
            title: 'Morning walk', kcalTotal: 62, hrAvg: 104, hrMax: 132)),
        'Morning walk · Total 62 kcal (incl. rest) · avg HR 104 · max HR 132',
      );
      // (c8) title + HR only
      expect(
        workoutMetricsLine(base(title: 'Morning walk', hrAvg: 104, hrMax: 132)),
        'Morning walk · avg HR 104 · max HR 132',
      );
      // (c9) title only
      expect(workoutMetricsLine(base(title: 'Morning walk')), 'Morning walk');
      // (c10) nothing present
      expect(workoutMetricsLine(base()), '');
      // Both figures present: active wins, total never shown.
      expect(
        workoutMetricsLine(base(kcalActive: 62, kcalTotal: 90)),
        '62 kcal',
      );
      // Zeroes are missing data, never rendered parts.
      expect(
        workoutMetricsLine(base(kcalActive: 0, kcalTotal: 0, hrAvg: 0, hrMax: 0)),
        '',
      );
      // A whitespace-only title is no title.
      expect(workoutMetricsLine(base(title: '   ', hrAvg: 104)), 'avg HR 104');
      // The word "burned" appears in no variant.
      expect(
        workoutMetricsLine(base(kcalTotal: 62, hrAvg: 104, hrMax: 132)),
        isNot(contains('burn')),
      );
    });

    test('entry shape: body, chips, timestamp, category', () {
      final entry = buildSyncedWorkoutEntry(
        session: base(kcalActive: 62, hrAvg: 104, hrMax: 132),
        id: 581,
        categoryId: 5,
      );
      expect(entry.id, 581);
      expect(entry.body, 'Walking · 34 min');
      expect(entry.chips, 'Workout, Health Connect');
      expect(entry.timestamp, 1000000); // session startMs
      expect(entry.categoryId, 5);
      // Type labels: 79 → Walking, 0 → Workout, unknown → Workout.
      expect(
        buildSyncedWorkoutEntry(
          session: _s(0, 27 * 60000, 0, hcId: 'y'),
          id: 1,
          categoryId: 7,
        ).body,
        'Workout · 27 min',
      );
      expect(
        buildSyncedWorkoutEntry(
          session: _s(0, 27 * 60000, 999, hcId: 'z'),
          id: 1,
          categoryId: 7,
        ).body,
        'Workout · 27 min',
      );
      expect(workoutExerciseTypeLabel(70), 'Strength Training');
      expect(workoutExerciseTypeLabel(56), 'Running');
    });
  });

  group('permission tri-state (DESIGN §3.2)', () {
    test('granted → syncs', () async {
      final h = _Harness();
      await h.init();
      h.outcome = HcReadOutcome(value: [founderFixture().first]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 1);
    });

    test('verified denial → 0 creations, no store mutation', () async {
      final h = _Harness();
      await h.init();
      h.granted = const {}; // live set answered, READ_EXERCISE absent
      h.outcome = HcReadOutcome(value: founderFixture());
      expect(await h.service().syncAfterCapture(), isFalse);
      expect(h.readCalls, 0);
      expect(h.stageCalls, 0);
      expect(h.store.links, isEmpty);
      expect(h.store.lastSyncMs, isNull);
    });

    test('grant read throws (unknown) → 0 creations, no denial claim',
        () async {
      final h = _Harness();
      await h.init();
      h.grantedThrows = true;
      h.outcome = HcReadOutcome(value: founderFixture());
      expect(await h.service().syncAfterCapture(), isFalse);
      expect(h.readCalls, 0);
      expect(h.stageCalls, 0);
      expect(h.store.links, isEmpty);
    });

    test('probe unavailable → 0 creations', () async {
      final h = _Harness();
      await h.init();
      h.probeResult = fakeHcSnapshot(serviceAvailable: false);
      h.outcome = HcReadOutcome(value: founderFixture());
      expect(await h.service().syncAfterCapture(), isFalse);
      expect(h.readCalls, 0);
      expect(h.stageCalls, 0);
    });

    test('probe grant layer unknown → 0 creations', () async {
      final h = _Harness();
      await h.init();
      h.probeResult = const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: null, // grant layer unknown
        bridgeErrorCode: 'TEST',
        stepsProbe: null,
        persistedConnected: false,
      );
      h.outcome = HcReadOutcome(value: founderFixture());
      expect(await h.service().syncAfterCapture(), isFalse);
      expect(h.readCalls, 0);
      expect(h.stageCalls, 0);
    });
  });

  group('fail-closed reads (DESIGN §3.3)', () {
    test('whole-read error → 0 creations, lastSyncMs unstamped',
        () async {
      final h = _Harness();
      await h.init();
      h.outcome = const HcReadOutcome(
        value: [],
        errorCode: 'EXERCISE_SESSIONS_RICH_READ_FAILED',
      );
      expect(await h.service().syncAfterCapture(), isFalse);
      expect(h.stageCalls, 0);
      expect(h.store.links, isEmpty);
      expect(h.store.lastSyncMs, isNull);
    });

    test('empty success → 0 creations, lastSyncMs stamped', () async {
      final h = _Harness();
      await h.init();
      h.outcome = const HcReadOutcome(value: []);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 0);
      expect(h.store.lastSyncMs, h.nowMsValue);
    });

    test('partial enrichment → proceeds; missing fields stay missing',
        () async {
      final h = _Harness();
      await h.init();
      final session = founderFixture()[4]; // has kcalTotal + HR
      h.outcome = HcReadOutcome(
        value: [
          _s(session.startMs, session.endMs, session.exerciseType,
              hrAvg: session.hrAvg, hrMax: session.hrMax, hcId: session.hcId),
        ],
        partialCode: 'EXERCISE_SESSIONS_RICH_PARTIAL',
      );
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 1);
      // Calories failed to enrich this run: no calorie part, and
      // crucially no fabricated 0 — the HR parts still land.
      expect(h.stagedEntries.single.manualText, 'avg HR 104 · max HR 132');
      expect(h.store.lastSyncMs, h.nowMsValue);
    });

    test('failed categories pull aborts before creation', () async {
      final h = _Harness();
      await h.init();
      h.categories = null; // fetchLogCategoriesOrNull failure shape
      h.outcome = HcReadOutcome(value: founderFixture());
      expect(await h.service().syncAfterCapture(), isFalse);
      expect(h.stageCalls, 0);
      expect(h.store.links, isEmpty);
      expect(h.store.lastSyncMs, isNull);
    });
  });

  group('create-only discipline', () {
    test('linked entry edited in the pull → re-run leaves it, creates 0',
        () async {
      final h = _Harness();
      await h.init();
      final session = founderFixture().first;
      h.outcome = HcReadOutcome(value: [session]);
      final svc = h.service();
      expect(await svc.syncAfterCapture(), isTrue);
      final created = h.stagedEntries.single;

      // The push lands; the user then edits the entry; the next
      // pull carries HIS version.
      h.simulatePushLanded();
      h.pulled = [created.copyWith(body: 'My morning walk, edited')];
      expect(await svc.syncAfterCapture(), isTrue);
      expect(h.allocateCalls, 1);
      expect(h.stageCalls, 1); // never re-staged over his edit
      expect(h.pulled.single.body, 'My morning walk, edited');
      expect(h.store.linkForKey(session.dedupKey)!.entryId, created.id);
    });

    test('concurrent calls join the in-flight run (single-flight)',
        () async {
      final h = _Harness();
      await h.init();
      h.outcome = HcReadOutcome(value: [founderFixture().first]);
      final svc = h.service();
      final a = svc.syncAfterCapture();
      final b = svc.syncAfterCapture();
      expect(identical(a, b), isTrue);
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(h.readCalls, 1);
      expect(h.stageCalls, 1);
    });
  });

  group('background-shape run (DESIGN §3.1)', () {
    test('service runs after an owner-bound warm of store + outbox',
        () async {
      // Mirrors DailyScoreBackgroundRunner: both stores warmed
      // owner-bound in the isolate BEFORE the service runs; no
      // foreground singleton state is involved (fresh store
      // instance, reset outbox over a fresh disk).
      final h = _Harness();
      await h.init(); // performs exactly those owner-bound warms
      h.outcome = HcReadOutcome(value: [founderFixture().first]);
      expect(await h.service().syncAfterCapture(), isTrue);
      expect(h.stageCalls, 1);
      expect(h.store.ownerEmail, _owner);
    });
  });

  group('rich read channel parse (health_connect_service)', () {
    const channel =
        MethodChannel(HealthConnectService.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    HealthConnectService svc() => HealthConnectService(channel: channel);

    Map<String, dynamic> row({
      Object? kcalActive = 62,
      Object? kcalTotal,
      Object? hrAvg = 104,
      Object? hrMax = 132,
    }) =>
        {
          'startMs': 1000000,
          'endMs': 3040000,
          'exerciseType': 79,
          'title': 'Morning walk',
          'notes': null,
          'hcId': 'uuid-1',
          'clientRecordId': null,
          'clientRecordVersion': 0,
          'dataOrigin': 'com.example.app',
          'lastModifiedMs': 2000000,
          'recordingMethod': 1,
          'startZoneOffsetSec': -21600,
          'endZoneOffsetSec': -21600,
          'kcalActive': kcalActive,
          'kcalTotal': kcalTotal,
          'hrAvg': hrAvg,
          'hrMax': hrMax,
        };

    test('bare list parses the full field set; 0 aggregates → null',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readExerciseSessionsRich');
        return [row(kcalActive: 0, hrAvg: 0)];
      });
      final outcome = await svc().readExerciseSessionsRich(400);
      expect(outcome.failed, isFalse);
      expect(outcome.partial, isFalse);
      final s = outcome.value.single;
      expect(s.startMs, 1000000);
      expect(s.endMs, 3040000);
      expect(s.exerciseType, 79);
      expect(s.typeLabel, 'Walking');
      expect(s.title, 'Morning walk');
      expect(s.hcId, 'uuid-1');
      expect(s.dataOrigin, 'com.example.app');
      expect(s.recordingMethod, 1);
      expect(s.startZoneOffsetSec, -21600);
      expect(s.kcalActive, isNull); // 0 = missing (zero rule)
      expect(s.hrAvg, isNull);
      expect(s.hrMax, 132);
      expect(s.dedupKey, 'hc:uuid-1');
      expect(s.durationMinutes, 34);
    });

    test('partial envelope parses items + partial code, not a failure',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return {
          'items': [row()],
          'partialError': 'SecurityException',
        };
      });
      final outcome = await svc().readExerciseSessionsRich(400);
      expect(outcome.failed, isFalse);
      expect(outcome.partial, isTrue);
      expect(outcome.partialCode, 'EXERCISE_SESSIONS_RICH_PARTIAL');
      expect(outcome.value, hasLength(1));
      expect(outcome.value.single.kcalActive, 62);
    });

    test('whole-read PlatformException → error outcome, NOT a list',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
            code: 'EXERCISE_SESSIONS_RICH_READ_FAILED',
            message: 'Could not read exercise sessions.');
      });
      final outcome = await svc().readExerciseSessionsRich(400);
      expect(outcome.failed, isTrue);
      expect(outcome.errorCode, 'EXERCISE_SESSIONS_RICH_READ_FAILED');
      expect(outcome.value, isEmpty);
    });

    test('empty success is an empty list, not an error', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => []);
      final outcome = await svc().readExerciseSessionsRich(400);
      expect(outcome.failed, isFalse);
      expect(outcome.value, isEmpty);
    });
  });
}
