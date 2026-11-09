import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';

import 'test_helpers.dart';

/// C-07 (Pass 2 audit, verdict v-highrest §1 — PARTIALLY HOLDS):
/// TodaySummary medication Take/Skip swallowed log-entry failure —
/// `postLogEntries`' bool result was ignored (production returns
/// false on HTTP failure instead of throwing), throws were swallowed
/// by a bare catch, and a null resolved category skipped the post
/// entirely — with NO LogEntryOutbox staging, so the entry vanished
/// in-session with no signal and no History entry to delete (the
/// founder's Round 41 undo).
///
/// The fix stages the constructed entry via
/// [LogEntryOutbox.stageForBackend] on every failure path, mirroring
/// quick-log/history, so it survives restart and flushes when
/// connectivity returns. These tests FAIL pre-fix (the outbox stays
/// empty) and pass post-fix.

class MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

TodayPlanStore planStoreWith(MemoryStore s) {
  final store = TodayPlanStore.testInstance();
  store.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return store;
}

/// Fake backend at the TabsBackend seam (the RecordingToolsBackend
/// pattern): serves canned pulled entries/categories and a
/// configurable post outcome — false (the production HTTP-failure
/// shape), throw, or success.
class MedActionFakeBackend extends TabsBackend {
  MedActionFakeBackend({required FakeSessionStore session})
      : super(sessionStore: session);

  List<QuickLogEntry> pulledEntries = [];
  List<QuickLogCategory> pulledCategories = const [
    QuickLogCategory(
      id: 8,
      name: 'Medication',
      icon: 'Medication',
      colorHex: '#4ECDC4',
      isDefault: true,
      sortOrder: 3,
    ),
  ];
  bool postResult = true;
  bool postThrows = false;
  final List<QuickLogEntry> postAttempts = [];

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async =>
      List.of(pulledEntries);

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async =>
      List.of(pulledCategories);

  @override
  Future<bool> postLogEntries(List<QuickLogEntry> entries) async {
    postAttempts.addAll(entries);
    if (postThrows) throw StateError('transport exploded');
    return postResult;
  }

  @override
  void invalidateSyncPull() {}
}

const _medItem = TodayPlanItem(
  kind: PlanItemKind.medication,
  id: 'med_med-uuid-1_Daily',
  title: 'Ivabradine',
  timeDisplay: 'Daily',
  isCompleted: false,
  status: DoseStatus.pending,
  dose: '7.5 mg',
  medKey: 'med-uuid-1',
  slot: 'Daily',
);

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  late Map<String, String> outboxDisk;
  setUp(() {
    outboxDisk = <String, String>{};
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => outboxDisk[key],
      write: (key, value) async => outboxDisk[key] = value,
      delete: (key) async => outboxDisk.remove(key),
    );
  });
  tearDown(() => LogEntryOutbox.instance.debugReset());

  ({TodaySummaryLoader loader, MedActionFakeBackend backend, MemoryStore planMem})
      harness() {
    final session = FakeSessionStore()
      ..token = 'tok'
      ..email = 'a@x.com';
    final backend = MedActionFakeBackend(session: session);
    final planMem = MemoryStore();
    final loader = TodaySummaryLoader(
      backend: backend,
      planStore: planStoreWith(planMem),
      sessionStore: session,
    );
    return (loader: loader, backend: backend, planMem: planMem);
  }

  final now = DateTime.now();

  group('C-07 — med Take/Skip entry failure stages into the outbox', () {
    test('Take + post returns false → entry staged, not dropped',
        () async {
      final h = harness();
      h.backend.postResult = false;
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.taken, now: now);
      // The direct post was attempted exactly once…
      expect(h.backend.postAttempts, hasLength(1));
      expect(h.backend.postAttempts.single.body, 'Took Ivabradine 7.5 mg');
      // …and its failure staged the entry instead of dropping it.
      final records = LogEntryOutbox.instance.records;
      expect(records, hasLength(1));
      expect(records.single.entry.body, 'Took Ivabradine 7.5 mg');
      expect(records.single.entry.categoryId, 8);
      expect(records.single.serverKnown, isFalse);
      // The local med record still landed (unchanged semantics).
      final state = await planStoreWith(h.planMem)
          .load(email: 'a@x.com', todayStr: dateStrOf(now));
      expect(state.medActions['med-uuid-1|Daily'], DoseStatus.taken);
    });

    test('Take + post throws → entry staged, action does not throw',
        () async {
      final h = harness();
      h.backend.postThrows = true;
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.taken, now: now);
      final records = LogEntryOutbox.instance.records;
      expect(records, hasLength(1));
      expect(records.single.entry.body, 'Took Ivabradine 7.5 mg');
      expect(records.single.entry.categoryId, 8);
      expect(records.single.serverKnown, isFalse);
    });

    test('Skip from pending + post returns false → corrected entry '
        'staged', () async {
      final h = harness();
      h.backend.postResult = false;
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.skipped, now: now);
      final records = LogEntryOutbox.instance.records;
      expect(records, hasLength(1));
      expect(records.single.entry.body,
          '[Corrected to Skipped] Took Ivabradine 7.5 mg');
      expect(records.single.entry.categoryId, 8);
      expect(records.single.serverKnown, isFalse);
    });

    test('Skip after a Take + post returns false → the rewrite is '
        'staged against the SAME entry id, server-known', () async {
      final h = harness();
      h.backend.pulledEntries = [
        QuickLogEntry(
          id: 55,
          categoryId: 8,
          body: 'Took Ivabradine 7.5 mg',
          chips: '[]',
          manualText: '',
          timestamp: now.millisecondsSinceEpoch,
        ),
      ];
      h.backend.postResult = false;
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.skipped, now: now);
      final records = LogEntryOutbox.instance.records;
      expect(records, hasLength(1));
      expect(records.single.entry.id, 55);
      expect(records.single.entry.body,
          '[Corrected to Skipped] Took Ivabradine 7.5 mg');
      expect(records.single.serverKnown, isTrue);
    });

    test('Pull failure (categories resolve to null) + Take → entry '
        'still staged under the seeded Medication category', () async {
      final h = harness();
      // The pull-failure shape: fetchLogEntryDtos/fetchLogCategories
      // both degrade to [] in production, so resolveSummaryCategoryId
      // returns null and the pre-fix code never attempted the post.
      h.backend.pulledEntries = [];
      h.backend.pulledCategories = [];
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.taken, now: now);
      expect(h.backend.postAttempts, isEmpty);
      final records = LogEntryOutbox.instance.records;
      expect(records, hasLength(1));
      expect(records.single.entry.body, 'Took Ivabradine 7.5 mg');
      expect(records.single.entry.categoryId, 8);
      expect(records.single.serverKnown, isFalse);
    });

    test('Staged entry flushes once the backend recovers', () async {
      final h = harness();
      h.backend.postResult = false;
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.taken, now: now);
      expect(LogEntryOutbox.instance.records, hasLength(1));
      h.backend.postResult = true;
      final flushed = await LogEntryOutbox.instance.flush(h.backend);
      expect(flushed, isTrue);
      expect(LogEntryOutbox.instance.records, isEmpty);
      // One failed direct attempt + one successful flush delivery.
      expect(h.backend.postAttempts, hasLength(2));
      expect(h.backend.postAttempts.last.body, 'Took Ivabradine 7.5 mg');
    });

    test('Happy path: post succeeds → nothing staged', () async {
      final h = harness();
      h.backend.postResult = true;
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.taken, now: now);
      expect(h.backend.postAttempts, hasLength(1));
      expect(LogEntryOutbox.instance.records, isEmpty);
    });

    test('Guard: outbox disk load failure never crashes the med '
        'action and the local record still lands', () async {
      final h = harness();
      h.backend.postResult = false;
      // The outbox blob read now throws: allocateEntryId raises
      // StateError in that window (PR #51) and stage returns false —
      // the med action must absorb both honestly.
      LogEntryOutbox.instance.debugSetStore(
        read: (key) async => throw StateError('storage gone'),
        write: (key, value) async {},
        delete: (key) async {},
      );
      await h.loader
          .setMedicationAction(_medItem, DoseStatus.taken, now: now);
      final state = await planStoreWith(h.planMem)
          .load(email: 'a@x.com', todayStr: dateStrOf(now));
      expect(state.medActions['med-uuid-1|Daily'], DoseStatus.taken);
    });
  });
}
