import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// became Delete. The ARCHIVED section is now DELETED COUNTERS in
/// the Past Counters style — clean muted text rows in a card,
/// 'Name (Deleted: Mon DD, YYYY)' for rows carrying a deletedAt
/// stamp, name-only for legacy stamp-less rows — with exactly one
/// action per row, the 'Bring back' restore. Active rows keep the
/// 48dp rail; its first button is now Delete (delete_outline,
/// 'Delete counter', key `counter_delete_<id>`).
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
}) async {
  tester.view.physicalSize = Size(width, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: fakeStore(<String, String>{}),
        notificationService: FakeReminderNotificationService(),
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

    testWidgets('sections render in order: active card, DELETED '
        'COUNTERS card, PAST COUNTERS card, footer', (tester) async {
      await _pumpCounters(tester, backendWithFixture());

      expect(find.text('EVENT COUNTERS'), findsOneWidget);
      expect(find.text('Doctor appointment'), findsOneWidget);
      expect(find.text('1 day until'), findsOneWidget);
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
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
      // Footer wording verbatim (Juno ruling: unchanged).
      expect(
          find.text(
              'Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.'),
          findsOneWidget);
      // The buggy plural never renders.
      expect(find.textContaining('1 days'), findsNothing);

      // Vertical order down the page.
      double dy(Finder f) => tester.getTopLeft(f).dy;
      expect(dy(find.text('Doctor appointment')),
          lessThan(dy(find.text('DELETED COUNTERS'))));
      expect(dy(find.text('DELETED COUNTERS')),
          lessThan(dy(find.text('Eye exam'))));
      expect(dy(find.text('Eye exam')),
          lessThan(dy(find.text('PAST COUNTERS'))));
      expect(
          dy(find.text('PAST COUNTERS')),
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
      // One card per section: active, deleted, past.
      expect(find.byWidgetPredicate(isCardSurface), findsNWidgets(3));
      for (final rowKey in [
        const ValueKey('counter_row_a1'),
        const ValueKey('counter_row_b1'),
        const ValueKey('counter_row_b5'),
      ]) {
        expect(
            find.ancestor(
                of: find.byKey(rowKey),
                matching: find.byWidgetPredicate(isCardSurface)),
            findsOneWidget);
      }
    });

    testWidgets('hierarchy: active full strength, deleted muted '
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
        'order; deleted rows carry only Bring back', (tester) async {
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
      // Deleted rows: NO icon rail at all — delete, edit and end are
      // gone; the only action is 'Bring back' on a ≥48dp target.
      for (final id in ['b1', 'b2', 'b3', 'b4', 'b5']) {
        for (final action in ['delete', 'edit', 'end', 'archive']) {
          expect(find.byKey(ValueKey('counter_${action}_$id')),
              findsNothing,
              reason: '$action/$id must not exist on a deleted row');
        }
        final restore =
            tester.getSize(find.byKey(ValueKey('counter_restore_$id')));
        expect(restore.height, greaterThanOrEqualTo(48),
            reason: 'restore/$id tap target');
      }
      expect(find.text('Bring back'), findsNWidgets(5));
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
      // The row moved to the Deleted card as a muted text row
      // carrying today's (Deleted: …) date.
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      final label = tester
          .widget<Text>(find.textContaining('Doctor appointment (Deleted:'));
      expect(label.style!.color, NotelColors.textSecondary);
      expect(find.text('Bring back'), findsNWidgets(6));
      // Single tap, straight to the section — no confirmation.
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('restore: Bring back on a stamped row returns it '
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
      expect(find.text('Bring back'), findsNWidgets(4));
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
      // Gone as a row; present only as a Past Counters line.
      expect(find.text('Doctor appointment'), findsNothing);
      expect(find.textContaining('Doctor appointment (Ended:'),
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
}
