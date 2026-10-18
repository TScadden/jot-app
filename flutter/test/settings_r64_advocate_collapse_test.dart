import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Round 64 — the "Past Professional Updates" list on the AI &
/// Clinical Advocate page is collapsible and COLLAPSED by default on
/// every open (founder directive), mirroring Today Summary's
/// collapsed-by-default header pattern. The Add Professional Update
/// button stays visible without expanding anything, and the
/// edit/delete actions stay intact once expanded.
SettingsStore store() => SettingsStore.withStorage(
      read: (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );

const _u1 = 'From the Doctor (Sep 01, 2026): first note';
const _u2 = 'From the Doctor (Sep 15, 2026): second note';
const _u3 = 'From the Doctor (Oct 01, 2026): third note';

Finder _headerIcon(IconData icon) => find.descendant(
    of: find.byKey(const ValueKey('past_updates_header')),
    matching: find.byIcon(icon));

Future<void> pumpAi(WidgetTester tester,
    r29.FakeSettingsBackend backend) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: store(),
        notificationService: FakeReminderNotificationService(),
        urlLauncher: (uri) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('AI & Clinical Advocate'));
  await tester.pumpAndSettle();
}

r29.FakeSettingsBackend backendWithUpdates() =>
    r29.FakeSettingsBackend()
      ..pullBody = r29.pull(profile: {
        'userContext': 'my doctor said to track standing tolerance',
        'professionalUpdates': '$_u1\n\n$_u2\n\n$_u3',
      });

void main() {
  group('Past Professional Updates collapse (R64)', () {
    testWidgets(
        '(a) collapsed on open: header + count + Add visible, '
        'update items NOT rendered', (tester) async {
      await pumpAi(tester, backendWithUpdates());
      // Header row + title are visible.
      expect(find.byKey(const ValueKey('past_updates_header')),
          findsOneWidget);
      expect(find.text('Past Doctor Updates'), findsOneWidget);
      // (d) the header shows the correct update count.
      expect(find.byKey(const ValueKey('past_updates_count')),
          findsOneWidget);
      expect(find.text('(3)'), findsOneWidget);
      // Add button stays prominent without expanding anything.
      expect(find.byKey(const ValueKey('add_protocol_button')),
          findsOneWidget);
      expect(find.text('Add Doctor Update'), findsOneWidget);
      // The update list items and their actions are NOT rendered.
      expect(find.text(_u1), findsNothing);
      expect(find.text(_u2), findsNothing);
      expect(find.text(_u3), findsNothing);
      expect(find.byKey(const ValueKey('edit_protocol_0')), findsNothing);
      expect(
          find.byKey(const ValueKey('delete_protocol_0')), findsNothing);
      // Chevron points down while collapsed.
      expect(_headerIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(_headerIcon(Icons.keyboard_arrow_up), findsNothing);
    });

    testWidgets(
        '(b) tapping the header expands the list with edit/delete '
        'actions reachable', (tester) async {
      final backend = backendWithUpdates();
      await pumpAi(tester, backend);
      await tester.tap(find.byKey(const ValueKey('past_updates_header')));
      await tester.pumpAndSettle();
      expect(find.text(_u1), findsOneWidget);
      expect(find.text(_u2), findsOneWidget);
      expect(find.text(_u3), findsOneWidget);
      expect(_headerIcon(Icons.keyboard_arrow_up), findsOneWidget);
      // Edit action is reachable and opens the edit dialog.
      await tester.tap(find.byKey(const ValueKey('edit_protocol_1')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Doctor Update'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // Delete action is reachable and pushes the shortened list.
      await tester.tap(find.byKey(const ValueKey('delete_protocol_0')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes.last['professionalUpdates'],
          '$_u2\n\n$_u3');
      // Count follows the data after the delete.
      expect(find.text('(2)'), findsOneWidget);
    });

    testWidgets('(c) tapping the header again collapses the list',
        (tester) async {
      await pumpAi(tester, backendWithUpdates());
      await tester.tap(find.byKey(const ValueKey('past_updates_header')));
      await tester.pumpAndSettle();
      expect(find.text(_u1), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('past_updates_header')));
      await tester.pumpAndSettle();
      expect(find.text(_u1), findsNothing);
      expect(find.text(_u2), findsNothing);
      expect(
          find.byKey(const ValueKey('delete_protocol_0')), findsNothing);
      // Header, count, and Add button remain.
      expect(find.text('Past Doctor Updates'), findsOneWidget);
      expect(find.text('(3)'), findsOneWidget);
      expect(find.byKey(const ValueKey('add_protocol_button')),
          findsOneWidget);
      expect(_headerIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('chevron button also toggles the section',
        (tester) async {
      await pumpAi(tester, backendWithUpdates());
      await tester.tap(find.byKey(const ValueKey('past_updates_toggle')));
      await tester.pumpAndSettle();
      expect(find.text(_u1), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('past_updates_toggle')));
      await tester.pumpAndSettle();
      expect(find.text(_u1), findsNothing);
    });

    testWidgets(
        'a fresh open of the page starts minimized again '
        '(expanded state never survives re-entry)', (tester) async {
      await pumpAi(tester, backendWithUpdates());
      await tester.tap(find.byKey(const ValueKey('past_updates_header')));
      await tester.pumpAndSettle();
      expect(find.text(_u1), findsOneWidget);
      // Leave the AI page and re-enter it.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI & Clinical Advocate'));
      await tester.pumpAndSettle();
      expect(find.text('Past Doctor Updates'), findsOneWidget);
      expect(find.text('(3)'), findsOneWidget);
      expect(find.text(_u1), findsNothing);
      expect(
          find.byKey(const ValueKey('delete_protocol_0')), findsNothing);
    });

    testWidgets('(d) header count matches a single update',
        (tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(profile: {
          'userContext': 'my doctor said to track standing tolerance',
          'professionalUpdates': _u1,
        });
      await pumpAi(tester, backend);
      expect(find.text('(1)'), findsOneWidget);
      expect(find.text(_u1), findsNothing);
    });
  });
}
