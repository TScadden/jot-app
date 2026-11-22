import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/settings/grant_diagnostics.dart';

/// Diagnostics-surface pins for the grants fix (Nov 20, 2026):
/// grant-path failures must be RECORDED in the services'
/// diagnostics state (the Developer Terminal card's source) —
/// never swallowed silently — and the card must render that
/// state. Before the fix there was no diagnostics state at all:
/// the production gem ledger sat at 0 rows while nothing in the
/// app could say why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 20, 12);

  StreakState settledState() => StreakState(
        seeded: true,
        countedDays: {'2026-11-20'},
        summaryCompletedDays: {'2026-11-20'},
      );

  GemService gemsWith({
    required Future<GemRequestResult> Function(String) grant,
    Future<String?> Function(String)? read,
  }) {
    final s = GemService(
      grant: grant,
      spend: (id) async => (statusCode: 200, body: null),
      pullBalance: () async => 0,
    );
    s.debugSetStore(
      read: read ?? (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );
    return s;
  }

  BadgeService badgesWith({
    required Future<GemRequestResult> Function(String) grant,
  }) {
    final s = BadgeService(grant: grant);
    s.debugSetStore(
      read: (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );
    return s;
  }

  test('a thrown grant request is recorded in diagnostics state '
      'and the key stays visibly pending', () async {
    final gems = gemsWith(
      grant: (key) async => throw StateError('socket closed'),
    );
    final result = await gems.processCompletion(
      summaryTabsDay: '2026-11-20',
      previousStreak: 0,
      newStreak: 1,
      settledState: settledState(),
      now: now,
    );
    // The completion flow is not broken by the failure…
    expect(result.lines, isEmpty);
    // …but the failure is on the record, and the queue shows it.
    expect(gems.diagLoaded, isTrue);
    expect(gems.diagPendingCount, 1);
    expect(gems.diagGrantedCount, 0);
    expect(gems.diagLastError, startsWith('grant:'));
    expect(gems.diagLastError, contains('socket closed'));
  });

  test('a wedged storage entry recovers and the recovery is '
      'visible in diagnostics state', () async {
    final gems = gemsWith(
      grant: (key) async =>
          (statusCode: 200, body: {'gemBalance': 5, 'alreadyGranted': false}),
      read: (k) async => throw StateError('keystore wedged'),
    );
    await gems.onAppOpen(state: settledState(), now: now);
    await gems.processCompletion(
      summaryTabsDay: '2026-11-20',
      previousStreak: 0,
      newStreak: 1,
      settledState: settledState(),
      now: now,
    );
    expect(gems.diagLoaded, isTrue);
    expect(gems.diagRecoveredLoad, isTrue);
    expect(gems.diagLastError, startsWith('load:'));
    expect(gems.diagGrantedCount, 1);
  });

  test('an escaped app-open sync error lands in diagnostics '
      'state via recordSyncError', () {
    final badges = badgesWith(
      grant: (key) async =>
          (statusCode: 200, body: {'gemBalance': 0, 'alreadyGranted': false}),
    );
    badges.recordSyncError(StateError('inputs loader exploded'));
    expect(badges.diagLastError, startsWith('sync:'));
    expect(badges.diagLastError, contains('inputs loader exploded'));
  });

  testWidgets('the dev card renders both services\' state, '
      'including the last error', (tester) async {
    final gems = gemsWith(
      grant: (key) async => throw StateError('socket closed'),
    );
    await gems.processCompletion(
      summaryTabsDay: '2026-11-20',
      previousStreak: 0,
      newStreak: 1,
      settledState: settledState(),
      now: now,
    );
    final badges = badgesWith(
      grant: (key) async =>
          (statusCode: 200, body: {'gemBalance': 0, 'alreadyGranted': false}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GrantDiagnosticsCard(gemService: gems, badgeService: badges),
        ),
      ),
    );
    expect(find.text('Grants diagnostics'), findsOneWidget);
    expect(find.textContaining('Gems: loaded'), findsOneWidget);
    expect(find.textContaining('pending 1'), findsOneWidget);
    expect(find.textContaining('socket closed'), findsOneWidget);
    expect(find.textContaining('Badges: loaded'), findsNothing);
    // Badges service has not loaded yet (no entry point ran), so
    // its line honestly reads NOT loaded.
    expect(find.textContaining('Badges: NOT loaded'), findsOneWidget);
    expect(find.text('Retry pending grants'), findsOneWidget);
  });
}
