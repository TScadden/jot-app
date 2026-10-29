import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Round 37 — Event Counters visual polish (presentation only).
///
/// The screen moved from one loose card (active rows, an in-card
/// ARCHIVED header, footer text and Past Counters all stacked in a
/// single surface) to one standard card per section — active /
/// ARCHIVED / PAST COUNTERS — with divider-separated rows, a muted
/// archived treatment, a 48dp right action rail with tooltips, the
/// explainer as a page footer, and singular/plural day labels from
/// the shared [EventCounterItem.daysLabel] helper.
///
/// Delete/Restore round (Oct 27, 2026, founder direction): Archive
/// became Delete. The ARCHIVED section became DELETED COUNTERS in
/// the Past Counters style — clean muted text rows in a card,
/// 'Name (Deleted: Mon DD, YYYY)' for rows carrying a deletedAt
/// stamp, name-only for legacy stamp-less rows — with exactly one
/// action per row, the 'Bring back' restore. Active rows keep the
/// 48dp rail; its first button is now Delete (delete_outline,
/// 'Delete counter', key `counter_delete_<id>`).
///
/// Unified Past box round (Oct 28, 2026, founder direction): the
/// DELETED COUNTERS section is GONE — ONE 'PAST COUNTERS' box
/// holds every non-active counter (archived OR delete-stamped —
/// the unified predicate) AND the ended-counter history entries,
/// and every row's only action is renamed 'Restore'. Restoring a
/// history entry recreates its counter.
///
/// These tests pin the structure AND re-prove the behavior end to
/// end: delete / restore / edit / end-and-save / create fire the
/// same guarded saves through _saveCounters.
class FakeCountersBackend extends TabsBackend {
  Map<String, dynamic>? pullBody;
  final List<Map<String, dynamic>> profilePushes = [];

  FakeCountersBackend({super.sessionStore});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pullBody;

  @override
  void invalidateSyncPull() {}

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePushes.add(fields);
    return true;
  }
}

SettingsStore fakeStore(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

/// Local midnight [days] from today's calendar day.
DateTime _midnightPlus(int days) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + days);
}

Map<String, dynamic> _counterMap({
  required String id,
  required String name,
  required int targetInDays,
  bool isUp = false,
  bool autoUp = false,
  bool isArchived = false,
  int? deletedAt,
}) {
  final map = <String, dynamic>{
    'id': id,
    'name': name,
    'targetDate': _midnightPlus(targetInDays).millisecondsSinceEpoch,
    'isUp': isUp,
    'autoUp': autoUp,
    'isFavorite': false,
    'isArchived': isArchived,
  };
  if (deletedAt != null) map['deletedAt'] = deletedAt;
  return map;
}

/// The screenshot-shaped fixture: one active counter ("Doctor
/// appointment — 1 day until") over a long deleted list, including
/// the long duplicate-suffixed name from the founder's real list.
/// b1 carries a deletedAt stamp (deleted through the new Delete
/// action); the other deleted rows are stamp-less legacy rows
/// (archived before the stamp existed) and must render name-only.
List<Map<String, dynamic>> _screenshotCounters() => [
      _counterMap(id: 'a1', name: 'Doctor appointment', targetInDays: 1),
      _counterMap(
          id: 'b1',
          name: 'Specialist appointment (Brad) (2)',
          targetInDays: 5,
          isArchived: true,
          deletedAt: DateTime(2026, 10, 27).millisecondsSinceEpoch),
      _counterMap(
          id: 'b2',
          name: 'Dentist appointment',
          targetInDays: -3,
          isUp: true,
          isArchived: true),
      _counterMap(
          id: 'b3',
          name: 'Physical therapy evaluation intake appointment',
          targetInDays: 12,
          isArchived: true),
      _counterMap(
          id: 'b4',
          name: 'Lab work',
          targetInDays: -1,
          isUp: true,
          isArchived: true),
      _counterMap(
          id: 'b5', name: 'Eye exam', targetInDays: 2, isArchived: true),
    ];

Map<String, dynamic> _pull(
        List<Map<String, dynamic>> counters,
        {List<Map<String, dynamic>> history = const []}) =>
    {
      'isUnlimited': false,
      'isAdmin': false,
      'nickname': 'Tyson',
      'tag': '1234',
      'profile': {
        'eventCounters': jsonEncode(counters),
        'counterHistory': jsonEncode(history),
      },
      'insights': const [],
    };

Future<void> _pumpCounters(
  WidgetTester tester,
  FakeCountersBackend backend, {
  double width = 1080,
  FakeReminderNotificationService? notifs,
}) async {
  tester.view.physicalSize = Size(width, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: fakeStore(<String, String>{}),
        notificationService: notifs ?? FakeReminderNotificationService(),
        openEventCounters: true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

List<dynamic> _pushedCounters(FakeCountersBackend backend) {
  final push = backend.profilePushes
      .lastWhere((p) => p.containsKey('eventCounters'));
  return jsonDecode(push['eventCounters'] as String) as List<dynamic>;
}

List<dynamic> _pushedHistory(FakeCountersBackend backend) {
  final push = backend.profilePushes
      .lastWhere((p) => p.containsKey('counterHistory'));
  return jsonDecode(push['counterHistory'] as String) as List<dynamic>;
}

void main() {
  group('daysLabel singular/plural (shared helper)', () {
    final now = DateTime(2026, 10, 13, 12, 0);
    EventCounterItem item(DateTime target,
            {bool isUp = false, bool autoUp = false}) =>
        EventCounterItem(
          id: 'x',
          name: 'X',
          targetDate: target.millisecondsSinceEpoch,
          isUp: isUp,
          autoUp: autoUp,
        );

    test('1 is singular, everything else plural, both directions', () {
      expect(item(DateTime(2026, 10, 14)).daysLabel(now: now),
          '1 day until');
      expect(item(DateTime(2026, 10, 15)).daysLabel(now: now),
          '2 days until');
      expect(item(DateTime(2026, 10, 13)).daysLabel(now: now),
          '0 days until');
      expect(
          item(DateTime(2026, 10, 12), isUp: true).daysLabel(now: now),
          '1 day since');
      expect(
          item(DateTime(2026, 10, 11), isUp: true).daysLabel(now: now),
          '2 days since');
      expect(
          item(DateTime(2026, 10, 12), autoUp: true).daysLabel(now: now),
          '1 day since');
    });
  });

  group('EventCounterItem deletedAt serialization', () {
    test('toMap emits deletedAt ONLY when set; fromMap parses num '
        'and numeric string tolerantly; copyWith can set AND clear',
        () {
      final plain = EventCounterItem(id: 'x', name: 'X', targetDate: 1);
      expect(plain.deletedAt, isNull);
      expect(plain.toMap().containsKey('deletedAt'), isFalse,
          reason: 'an unset stamp must omit the key — the blob is '
              'stored verbatim, so omission is the clear');

      final stamped = plain.copyWith(deletedAt: 1700000000000);
      expect(stamped.toMap()['deletedAt'], 1700000000000);
      expect(EventCounterItem.fromMap(stamped.toMap()).deletedAt,
          1700000000000);
      expect(
          EventCounterItem.fromMap(
              {...plain.toMap(), 'deletedAt': '1700000000000'}).deletedAt,
          1700000000000);
      expect(
          EventCounterItem.fromMap({...plain.toMap(), 'deletedAt': 'junk'})
              .deletedAt,
          isNull);
      expect(
          EventCounterItem.fromMap({...plain.toMap(), 'deletedAt': 1.5})
              .deletedAt,
          1);

      // copyWith: an omitted argument keeps the stamp…
      expect(stamped.copyWith(name: 'Y').deletedAt, 1700000000000);
      // …and an explicit null clears it (the restore).
      final restored = stamped.copyWith(isArchived: false, deletedAt: null);
      expect(restored.deletedAt, isNull);
      expect(restored.toMap().containsKey('deletedAt'), isFalse);
      expect(restored, plain);
    });
  });

  group('Event Counters polish (screenshot fixture)', () {
    FakeCountersBackend backendWithFixture() => FakeCountersBackend()
      ..pullBody = _pull(_screenshotCounters(), history: [
        {
          'name': 'Old physical',
          'targetDate': _midnightPlus(-40).millisecondsSinceEpoch,
          'endedAt': DateTime(2026, 9, 1).millisecondsSinceEpoch,
        },
      ]);

    testWidgets('sections render in order: active card, ONE unified '
        'PAST COUNTERS card (deleted counters + history), footer',
        (tester) async {
      await _pumpCounters(tester, backendWithFixture());

      expect(find.text('EVENT COUNTERS'), findsOneWidget);
      expect(find.text('Doctor appointment'), findsOneWidget);
      expect(find.text('1 day until'), findsOneWidget);
      // The separate Deleted section is gone for good.
      expect(find.text('DELETED COUNTERS'), findsNothing);
      // The stamped deleted row carries its (Deleted: …) date; the
      // legacy stamp-less rows render name-only — no invented date.
      expect(
          find.text(
              'Specialist appointment (Brad) (2) (Deleted: Oct 27, 2026)'),
          findsOneWidget);
      expect(find.text('Eye exam'), findsOneWidget);
      expect(find.text('PAST COUNTERS'), findsOneWidget);
      expect(find.text('Old physical (Ended: Sep 01, 2026)'),
          findsOneWidget);
      // Every Past-box row — deleted counters AND the history
      // entry — offers 'Restore'; the old name is gone.
      expect(find.text('Restore'), findsNWidgets(6));
      expect(find.text('Bring back'), findsNothing);
      // Footer wording verbatim (Juno ruling: unchanged).
      expect(
          find.text(
              'Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.'),
          findsOneWidget);
      // The buggy plural never renders.
      expect(find.textContaining('1 days'), findsNothing);

      // Vertical order down the page: active, then the Past label,
      // then the deleted counters, then the history entry, then
      // the footer — all inside the one box.
      double dy(Finder f) => tester.getTopLeft(f).dy;
      expect(dy(find.text('Doctor appointment')),
          lessThan(dy(find.text('PAST COUNTERS'))));
      expect(dy(find.text('PAST COUNTERS')),
          lessThan(dy(find.text('Eye exam'))));
      expect(dy(find.text('Eye exam')),
          lessThan(dy(find.text('Old physical (Ended: Sep 01, 2026)'))));
      expect(
          dy(find.text('Old physical (Ended: Sep 01, 2026)')),
          lessThan(dy(find.text(
              'Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.'))));
    });

    testWidgets('rows live in standard surface cards', (tester) async {
      await _pumpCounters(tester, backendWithFixture());
      bool isCardSurface(Widget w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == NotelColors.surface &&
          (w.decoration as BoxDecoration).borderRadius ==
              BorderRadius.circular(16);
      // One card per section: active, and the ONE unified past box.
      expect(find.byWidgetPredicate(isCardSurface), findsNWidgets(2));
      for (final rowKey in [
        const ValueKey('counter_row_a1'),
        const ValueKey('counter_row_b1'),
        const ValueKey('counter_row_b5'),
        const ValueKey('counter_history_row_0'),
      ]) {
        expect(
            find.ancestor(
                of: find.byKey(rowKey),
                matching: find.byWidgetPredicate(isCardSurface)),
            findsOneWidget);
      }
    });

    testWidgets('hierarchy: active full strength, past-box muted '
        'text rows', (tester) async {
      await _pumpCounters(tester, backendWithFixture());
      final activeName = tester.widget<Text>(find.text('Doctor appointment'));
      expect(activeName.style!.color, NotelColors.textPrimary);
      final activeLabel = tester.widget<Text>(find.text('1 day until'));
      expect(activeLabel.style!.color, NotelColors.primary);

      // Deleted rows: ONE muted 11px text per row — the stamped row
      // carries its (Deleted: …) date, the legacy row is name-only.
      final stamped = tester.widget<Text>(find.text(
          'Specialist appointment (Brad) (2) (Deleted: Oct 27, 2026)'));
      expect(stamped.style!.color, NotelColors.textSecondary);
      expect(stamped.style!.fontSize, 11);
      final legacy = tester.widget<Text>(find.text('Eye exam'));
      expect(legacy.style!.color, NotelColors.textSecondary);
      expect(legacy.style!.fontSize, 11);
      // No day-count label renders for a deleted row any more.
      expect(find.text('2 days until'), findsNothing);
      expect(find.text('1 day since'), findsNothing);
    });

    testWidgets('action rail: active row keeps three 48dp targets in '
        'order; past-box rows carry only Restore', (tester) async {
      await _pumpCounters(tester, backendWithFixture());
      for (final action in ['delete', 'edit', 'end']) {
        final size =
            tester.getSize(find.byKey(ValueKey('counter_${action}_a1')));
        expect(size.width, greaterThanOrEqualTo(48), reason: '$action/a1');
        expect(size.height, greaterThanOrEqualTo(48), reason: '$action/a1');
      }
      // Same order left→right and a shared center line on the row.
      final delete =
          tester.getCenter(find.byKey(const ValueKey('counter_delete_a1')));
      final edit =
          tester.getCenter(find.byKey(const ValueKey('counter_edit_a1')));
      final end =
          tester.getCenter(find.byKey(const ValueKey('counter_end_a1')));
      expect(delete.dx, lessThan(edit.dx));
      expect(edit.dx, lessThan(end.dx));
      expect(delete.dy, edit.dy);
      expect(edit.dy, end.dy);
      expect(find.byTooltip('Delete counter'), findsOneWidget);
      expect(find.byTooltip('Edit counter'), findsOneWidget);
      expect(find.byTooltip('End counter'), findsOneWidget);
      // Past-box rows: NO icon rail at all — delete, edit and end
      // are gone; the only action is 'Restore' on a ≥48dp target.
      for (final id in ['b1', 'b2', 'b3', 'b4', 'b5']) {
        for (final action in ['delete', 'edit', 'end', 'archive']) {
          expect(find.byKey(ValueKey('counter_${action}_$id')),
              findsNothing,
              reason: '$action/$id must not exist on a past-box row');
        }
        final restore =
            tester.getSize(find.byKey(ValueKey('counter_restore_$id')));
        expect(restore.height, greaterThanOrEqualTo(48),
            reason: 'restore/$id tap target');
      }
      // The history row's Restore is a ≥48dp target too.
      final historyRestore = tester.getSize(
          find.byKey(const ValueKey('counter_restore_history_0')));
      expect(historyRestore.height, greaterThanOrEqualTo(48));
      expect(find.text('Restore'), findsNWidgets(6));
      expect(find.text('Bring back'), findsNothing);
    });

    testWidgets('long names wrap without breaking the row', (tester) async {
      await _pumpCounters(tester, backendWithFixture(), width: 400);
      expect(tester.takeException(), isNull);
      // Same deleted style, short vs long name: the long name's own
      // text block is taller (it wrapped), the short one is one line.
      final shortNameH = tester.getSize(find.text('Eye exam')).height;
      final longNameH = tester
          .getSize(find.text(
              'Specialist appointment (Brad) (2) (Deleted: Oct 27, 2026)'))
          .height;
      expect(longNameH, greaterThan(shortNameH));
      final intakeNameH = tester
          .getSize(
              find.text('Physical therapy evaluation intake appointment'))
          .height;
      expect(intakeNameH, greaterThan(shortNameH));
      // Rows grow with the wrapped text — never shrink or clip.
      final shortRowH =
          tester.getSize(find.byKey(const ValueKey('counter_row_b5'))).height;
      final longRowH =
          tester.getSize(find.byKey(const ValueKey('counter_row_b1'))).height;
      expect(longRowH, greaterThanOrEqualTo(shortRowH));
      // The name never runs under the restore button.
      final nameRight = tester
          .getTopRight(find.text(
              'Specialist appointment (Brad) (2) (Deleted: Oct 27, 2026)'))
          .dx;
      final restoreLeft = tester
          .getTopLeft(find.byKey(const ValueKey('counter_restore_b1')))
          .dx;
      expect(nameRight, lessThanOrEqualTo(restoreLeft));
      expect(tester.takeException(), isNull);
    });
  });

  group('Event Counters behavior (Delete/Restore)', () {
    testWidgets('delete: tapping the rail deletes through the same '
        'save — isArchived set AND a deletedAt stamp on the blob',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      final before = DateTime.now().millisecondsSinceEpoch;
      await tester.tap(find.byKey(const ValueKey('counter_delete_a1')));
      await tester.pumpAndSettle();
      final after = DateTime.now().millisecondsSinceEpoch;
      final saved = _pushedCounters(backend);
      final a1 = saved.firstWhere((c) => c['id'] == 'a1');
      expect(a1['isArchived'], isTrue);
      expect(a1['deletedAt'], isA<int>());
      expect(a1['deletedAt'] as int, greaterThanOrEqualTo(before));
      expect(a1['deletedAt'] as int, lessThanOrEqualTo(after));
      expect(saved.length, 6);
      // The row moved to the unified Past box as a muted text row
      // carrying today's (Deleted: …) date.
      expect(find.text('PAST COUNTERS'), findsOneWidget);
      expect(find.text('DELETED COUNTERS'), findsNothing);
      final label = tester
          .widget<Text>(find.textContaining('Doctor appointment (Deleted:'));
      expect(label.style!.color, NotelColors.textSecondary);
      expect(find.text('Restore'), findsNWidgets(6));
      // Single tap, straight to the section — no confirmation.
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('restore: Restore on a stamped row returns it '
        'active, data intact, with NO deletedAt key pushed',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_restore_b1')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      final b1 = saved.firstWhere((c) => c['id'] == 'b1');
      expect(b1['isArchived'], isFalse);
      expect(b1.containsKey('deletedAt'), isFalse,
          reason: 'omitting the key is what clears the stamp '
              'server-side (whole-blob verbatim store)');
      expect(b1['name'], 'Specialist appointment (Brad) (2)');
      expect(b1['targetDate'], _midnightPlus(5).millisecondsSinceEpoch);
      // Active again: full-strength name in the active card.
      final name = tester
          .widget<Text>(find.text('Specialist appointment (Brad) (2)'));
      expect(name.style!.color, NotelColors.textPrimary);
      expect(find.text('Restore'), findsNWidgets(4));
      expect(find.text('Bring back'), findsNothing);
    });

    testWidgets('restore: a legacy stamp-less row restores the same '
        'way', (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_restore_b5')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      final b5 = saved.firstWhere((c) => c['id'] == 'b5');
      expect(b5['isArchived'], isFalse);
      expect(b5.containsKey('deletedAt'), isFalse);
      final name = tester.widget<Text>(find.text('Eye exam'));
      expect(name.style!.color, NotelColors.textPrimary);
    });

    testWidgets('edit: rail opens the same dialog and saves the rename',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_edit_a1')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Counter'), findsOneWidget);
      final field =
          tester.widget<TextField>(find.byKey(const ValueKey('counter_name_field')));
      expect(field.controller!.text, 'Doctor appointment');
      await tester.enterText(
          find.byKey(const ValueKey('counter_name_field')),
          'Doctor appointment updated');
      await tester.tap(find.byKey(const ValueKey('counter_save')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      final a1 = saved.firstWhere((c) => c['id'] == 'a1');
      expect(a1['name'], 'Doctor appointment updated');
      expect(find.text('Doctor appointment updated'), findsOneWidget);
    });

    testWidgets('end: rail removes the counter and appends to history '
        '(active rows only — deleted rows have no End)', (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_end_a1')));
      await tester.pumpAndSettle();
      final push = backend.profilePushes
          .lastWhere((p) => p.containsKey('counterHistory'));
      final saved = jsonDecode(push['eventCounters'] as String) as List;
      expect(saved.any((c) => c['id'] == 'a1'), isFalse);
      expect(saved.length, 5);
      final history =
          jsonDecode(push['counterHistory'] as String) as List<dynamic>;
      expect(history.first['name'], 'Doctor appointment');
      expect(history.first['targetDate'],
          _midnightPlus(1).millisecondsSinceEpoch);
      // Gone as a row; present only as a Past Counters line, with
      // a Restore action of its own in the unified box.
      expect(find.text('Doctor appointment'), findsNothing);
      expect(find.textContaining('Doctor appointment (Ended:'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('counter_restore_history_0')),
          findsOneWidget);
    });

    testWidgets('create: Add New Counter still saves a new counter',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('add_counter')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('counter_name_field')), 'New thing');
      await tester.tap(find.byKey(const ValueKey('counter_save')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      expect(saved.length, 7);
      expect(saved.any((c) => c['name'] == 'New thing'), isTrue);
      expect(find.text('New thing'), findsOneWidget);
    });
  });

  group('Unified Past box (Oct 28, 2026)', () {
    // The four data shapes of the unified predicate:
    // (i) archived, no stamp; (ii) stamp only; (iii) both;
    // (iv) neither.
    List<Map<String, dynamic>> fourShapes() => [
          _counterMap(
              id: 's4', name: 'Shape Active', targetInDays: 3),
          _counterMap(
              id: 's1',
              name: 'Shape Archived Only',
              targetInDays: 3,
              isArchived: true),
          _counterMap(
              id: 's2',
              name: 'Shape Stamp Only',
              targetInDays: 3,
              deletedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch),
          _counterMap(
              id: 's3',
              name: 'Shape Both Marks',
              targetInDays: 3,
              isArchived: true,
              deletedAt: DateTime(2026, 10, 21).millisecondsSinceEpoch),
        ];

    test('predicate matrix (unit): isActive / isNonActive / '
        'counterMapIsActive / activeEventCounters agree', () {
      final items = fourShapes().map(EventCounterItem.fromMap).toList();
      final byId = {for (final c in items) c.id: c};
      expect(byId['s1']!.isActive, isFalse);
      expect(byId['s2']!.isActive, isFalse,
          reason: 'a stamp-only row is NOT active');
      expect(byId['s3']!.isActive, isFalse);
      expect(byId['s4']!.isActive, isTrue);
      expect(items.where((c) => c.isNonActive).map((c) => c.id),
          ['s1', 's2', 's3']);
      for (final m in fourShapes()) {
        expect(EventCounterItem.counterMapIsActive(m),
            EventCounterItem.fromMap(m).isActive,
            reason: 'raw-map predicate must match for ${m['id']}');
      }
      expect(activeEventCounters(items).map((c) => c.id), ['s4']);
    });

    testWidgets('four shapes render in the right lists: stamp-only '
        'is in the Past box (NOT active), archived-only is '
        'name-only, both-marks shows its Deleted date', (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(fourShapes());
      await _pumpCounters(tester, backend);

      expect(find.text('DELETED COUNTERS'), findsNothing);
      expect(find.text('PAST COUNTERS'), findsOneWidget);
      // (iv) neither mark: the only active row, full rail.
      expect(find.byKey(const ValueKey('counter_delete_s4')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('counter_restore_s4')),
          findsNothing);
      // (i) archived, no stamp: name-only in the box, no invented
      // date, no active rail.
      expect(find.text('Shape Archived Only'), findsOneWidget);
      expect(find.byKey(const ValueKey('counter_delete_s1')),
          findsNothing);
      // (ii) stamp only: in the box WITH its (Deleted: …) date —
      // and crucially NOT in the active list.
      expect(find.text('Shape Stamp Only (Deleted: Oct 20, 2026)'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('counter_delete_s2')),
          findsNothing);
      expect(find.byKey(const ValueKey('counter_edit_s2')),
          findsNothing);
      expect(find.byKey(const ValueKey('counter_end_s2')),
          findsNothing);
      // (iii) both marks: same box, same (Deleted: …) label.
      expect(find.text('Shape Both Marks (Deleted: Oct 21, 2026)'),
          findsOneWidget);
      // Exactly the three non-active rows offer Restore.
      expect(find.text('Restore'), findsNWidgets(3));
      expect(find.text('Bring back'), findsNothing);
      // Only the active row shows a day label ('3 days until' once).
      expect(find.text('3 days until'), findsOneWidget);
    });

    testWidgets('restore of a stamp-only row clears BOTH marks in '
        'the pushed blob', (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(fourShapes());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_restore_s2')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      final s2 = saved.firstWhere((c) => c['id'] == 's2');
      expect(s2['isArchived'], isFalse);
      expect(s2.containsKey('deletedAt'), isFalse,
          reason: 'no deletedAt key in the pushed blob — omission '
              'is what clears the stamp server-side');
      // Active again on screen with its rail back.
      expect(find.byKey(const ValueKey('counter_delete_s2')),
          findsOneWidget);
    });

    testWidgets('history restore: recreates an active counter with '
        'the stored name/targetDate, removes the history entry, in '
        'ONE save carrying both fields', (tester) async {
      final endedTarget = _midnightPlus(9).millisecondsSinceEpoch;
      final backend = FakeCountersBackend()
        ..pullBody = _pull(
          [_counterMap(id: 'a1', name: 'Doctor appointment', targetInDays: 1)],
          history: [
            {
              'name': 'Ended thing',
              'targetDate': endedTarget,
              'endedAt': DateTime(2026, 9, 1).millisecondsSinceEpoch,
            },
            {
              'name': 'Other ended',
              'targetDate': _midnightPlus(-5).millisecondsSinceEpoch,
              'endedAt': DateTime(2026, 8, 1).millisecondsSinceEpoch,
            },
          ],
        );
      await _pumpCounters(tester, backend);
      expect(find.text('Ended thing (Ended: Sep 01, 2026)'),
          findsOneWidget);
      final pushesBefore = backend.profilePushes.length;
      await tester.tap(
          find.byKey(const ValueKey('counter_restore_history_0')));
      await tester.pumpAndSettle();

      // ONE save, carrying BOTH fields (the pair moved atomically).
      final newPushes = backend.profilePushes.sublist(pushesBefore);
      expect(newPushes, hasLength(1));
      expect(newPushes.single.containsKey('eventCounters'), isTrue);
      expect(newPushes.single.containsKey('counterHistory'), isTrue);

      final saved = _pushedCounters(backend);
      expect(saved, hasLength(2));
      final recreated =
          saved.firstWhere((c) => c['name'] == 'Ended thing');
      expect(recreated['targetDate'], endedTarget);
      expect(recreated['isArchived'], isFalse);
      expect(recreated.containsKey('deletedAt'), isFalse);
      expect(recreated['isUp'], isFalse);
      expect(recreated['autoUp'], isFalse);
      expect(recreated['isFavorite'], isFalse);
      // A fresh unique id (the Add dialog's epoch-ms generation):
      // not any pre-existing id, and numeric-ms shaped.
      expect(recreated['id'], isNot('a1'));
      expect(int.tryParse('${recreated['id']}'), isNotNull);

      // The restored entry is gone from history; the other entry
      // is untouched.
      final history = _pushedHistory(backend);
      expect(history, hasLength(1));
      expect(history.single['name'], 'Other ended');

      // On screen: an active full-strength row, and the history
      // line is gone.
      final name = tester.widget<Text>(find.text('Ended thing'));
      expect(name.style!.color, NotelColors.textPrimary);
      expect(find.text('Ended thing (Ended: Sep 01, 2026)'),
          findsNothing);
      expect(find.text('Other ended (Ended: Aug 01, 2026)'),
          findsOneWidget);
    });

    testWidgets('reminders: delete cancels a future counter\'s '
        'alarm, Restore re-arms it; restoring a past-dated counter '
        'arms nothing', (tester) async {
      final notifs = FakeReminderNotificationService();
      final backend = FakeCountersBackend()
        ..pullBody = _pull([
          _counterMap(id: 'f1', name: 'Future thing', targetInDays: 10),
          _counterMap(
              id: 'p1',
              name: 'Past thing',
              targetInDays: -3,
              isArchived: true,
              deletedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch),
        ]);
      await _pumpCounters(tester, backend, notifs: notifs);
      final futureId = eventNotificationId('f1');
      final pastId = eventNotificationId('p1');
      final target = _midnightPlus(10);
      // NOTE: the load-time reminder sync is not asserted here —
      // in the widget-test environment it sits behind the real
      // Health Connect status read inside _load. The SAVE-driven
      // syncs below are the seams this test pins (the same
      // _syncReminders pass runs after every _saveCounters).

      // Delete cancels through the post-save reminder re-sync.
      await tester.tap(find.byKey(const ValueKey('counter_delete_f1')));
      await tester.pumpAndSettle();
      expect(notifs.once.containsKey(futureId), isFalse);
      expect(notifs.cancelled, contains(futureId));

      // Restore re-arms the future-dated counter through the same
      // re-sync (the restored row reads active to the projection).
      await tester.tap(find.byKey(const ValueKey('counter_restore_f1')));
      await tester.pumpAndSettle();
      expect(notifs.once[futureId],
          DateTime(target.year, target.month, target.day, 9));

      // Restoring the past-dated counter arms nothing (the
      // projection skips past dates, as before).
      await tester.tap(find.byKey(const ValueKey('counter_restore_p1')));
      await tester.pumpAndSettle();
      expect(notifs.once.containsKey(pastId), isFalse);
      // And it is active on screen now.
      expect(find.byKey(const ValueKey('counter_delete_p1')),
          findsOneWidget);
    });
  });
}
