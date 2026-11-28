import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/workout_sync_store.dart';
import 'package:tabs_lab/src/features/settings/workout_sync_diagnostics.dart';

/// Workout sync diagnostics card pins (ROUND 3): the Developer
/// Terminal card renders the last run record — stage, verdict,
/// counts, abort code — and honestly reports when no run has
/// been recorded. Counts/stages/codes only; there are no health
/// values anywhere in the record to render.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  WorkoutSyncStore storeOver(Map<String, String> disk) {
    final store = WorkoutSyncStore.testInstance();
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    return store;
  }

  Future<void> pumpCard(WidgetTester tester, WorkoutSyncStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkoutSyncDiagnosticsCard(store: store)),
      ),
    );
    // Let the mount warm settle.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders the seeded run record lines', (tester) async {
    final disk = <String, String>{};
    final store = storeOver(disk);
    await store.warmFromDisk(currentEmail: 'a@example.com');
    await store.recordRun(const WorkoutSyncRunRecord(
      startedAtMs: 1000,
      finishedAtMs: 2000,
      stage: 'done',
      grantVerdict: 'granted',
      sessionsRead: 28,
      entriesCreated: 27,
      entriesAdopted: 1,
      sessionsSkipped: 1,
      readPartial: true,
      abortCode: 'StateError',
    ));
    await store.markSynced(3000);

    await pumpCard(tester, store);

    expect(find.text('Workout sync diagnostics'), findsOneWidget);
    expect(find.textContaining('Stage reached: done'), findsOneWidget);
    expect(find.textContaining('Grant verdict: granted'), findsOneWidget);
    expect(find.textContaining('Sessions read: 28'), findsOneWidget);
    expect(find.textContaining('Entries created: 27'), findsOneWidget);
    expect(find.textContaining('Entries adopted: 1'), findsOneWidget);
    expect(find.textContaining('Sessions skipped: 1'), findsOneWidget);
    expect(find.textContaining('Partial read: yes'), findsOneWidget);
    expect(find.textContaining('Abort code: StateError'), findsOneWidget);
    expect(find.textContaining('Last synced:'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('empty store renders the no-run line', (tester) async {
    final disk = <String, String>{};
    final store = storeOver(disk);
    await pumpCard(tester, store);

    expect(find.text('Workout sync diagnostics'), findsOneWidget);
    expect(
        find.textContaining('no run recorded yet'), findsOneWidget);
    expect(find.textContaining('Last synced: never'), findsOneWidget);
  });
}
