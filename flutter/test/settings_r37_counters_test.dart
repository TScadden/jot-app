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
/// These tests pin the new structure AND re-prove the pre-round
/// behavior end to end: archive / unarchive / edit / end-and-save /
/// create fire the exact same saves with the exact same payloads.
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
}) =>
    {
      'id': id,
      'name': name,
      'targetDate': _midnightPlus(targetInDays).millisecondsSinceEpoch,
      'isUp': isUp,
      'autoUp': autoUp,
      'isFavorite': false,
      'isArchived': isArchived,
    };

/// The screenshot-shaped fixture: one active counter ("Doctor
/// appointment — 1 day until") over a long archived list, including
/// the long duplicate-suffixed name from the founder's real list.
List<Map<String, dynamic>> _screenshotCounters() => [
      _counterMap(id: 'a1', name: 'Doctor appointment', targetInDays: 1),
      _counterMap(
          id: 'b1',
          name: 'Specialist appointment (Brad) (2)',
          targetInDays: 5,
          isArchived: true),
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

  group('Event Counters polish (screenshot fixture)', () {
    FakeCountersBackend backendWithFixture() => FakeCountersBackend()
      ..pullBody = _pull(_screenshotCounters(), history: [
        {
          'name': 'Old physical',
          'targetDate': _midnightPlus(-40).millisecondsSinceEpoch,
          'endedAt': DateTime(2026, 9, 1).millisecondsSinceEpoch,
        },
      ]);

    testWidgets('sections render in order: active card, ARCHIVED card, '
        'PAST COUNTERS card, footer', (tester) async {
      await _pumpCounters(tester, backendWithFixture());

      expect(find.text('EVENT COUNTERS'), findsOneWidget);
      expect(find.text('Doctor appointment'), findsOneWidget);
      expect(find.text('1 day until'), findsOneWidget);
      expect(find.text('ARCHIVED'), findsOneWidget);
      expect(find.text('Specialist appointment (Brad) (2)'),
          findsOneWidget);
      expect(find.text('PAST COUNTERS'), findsOneWidget);
      expect(find.text('Old physical (Ended: Sep 01, 2026)'),
          findsOneWidget);
      // Footer wording verbatim.
      expect(
          find.text(
              'Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.'),
          findsOneWidget);
      // The buggy plural never renders.
      expect(find.textContaining('1 days'), findsNothing);

      // Vertical order down the page.
      double dy(Finder f) => tester.getTopLeft(f).dy;
      expect(dy(find.text('Doctor appointment')),
          lessThan(dy(find.text('ARCHIVED'))));
      expect(dy(find.text('ARCHIVED')),
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
      // One card per section: active, archived, past.
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

    testWidgets('hierarchy: active full strength, archived muted',
        (tester) async {
      await _pumpCounters(tester, backendWithFixture());
      final activeName = tester.widget<Text>(find.text('Doctor appointment'));
      expect(activeName.style!.color, NotelColors.textPrimary);
      final activeLabel = tester.widget<Text>(find.text('1 day until'));
      expect(activeLabel.style!.color, NotelColors.primary);

      final archivedName =
          tester.widget<Text>(find.text('Eye exam'));
      expect(archivedName.style!.color, NotelColors.textSecondary);
      final archivedLabel = tester.widget<Text>(find.text('2 days until'));
      expect(archivedLabel.style!.color, NotelColors.textSecondary);
      final sinceLabel = tester.widget<Text>(find.text('1 day since'));
      expect(sinceLabel.style!.color, NotelColors.textSecondary);
    });

    testWidgets('action rail: three 48dp targets, same order, tooltips',
        (tester) async {
      await _pumpCounters(tester, backendWithFixture());
      for (final id in ['a1', 'b1', 'b5']) {
        for (final action in ['archive', 'edit', 'end']) {
          final size =
              tester.getSize(find.byKey(ValueKey('counter_${action}_$id')));
          expect(size.width, greaterThanOrEqualTo(48), reason: '$action/$id');
          expect(size.height, greaterThanOrEqualTo(48),
              reason: '$action/$id');
        }
        // Same order left→right and a shared center line per row.
        final archive =
            tester.getCenter(find.byKey(ValueKey('counter_archive_$id')));
        final edit =
            tester.getCenter(find.byKey(ValueKey('counter_edit_$id')));
        final end =
            tester.getCenter(find.byKey(ValueKey('counter_end_$id')));
        expect(archive.dx, lessThan(edit.dx));
        expect(edit.dx, lessThan(end.dx));
        expect(archive.dy, edit.dy);
        expect(edit.dy, end.dy);
      }
      expect(find.byTooltip('Archive counter'), findsOneWidget);
      expect(find.byTooltip('Unarchive counter'), findsNWidgets(5));
      expect(find.byTooltip('Edit counter'), findsNWidgets(6));
      expect(find.byTooltip('End counter'), findsNWidgets(6));
      // Uniform row height for single-line rows across sections.
      final activeH =
          tester.getSize(find.byKey(const ValueKey('counter_row_a1'))).height;
      final archivedH =
          tester.getSize(find.byKey(const ValueKey('counter_row_b5'))).height;
      expect(activeH, archivedH);
    });

    testWidgets('long names wrap without breaking the row or the rail',
        (tester) async {
      await _pumpCounters(tester, backendWithFixture(), width: 400);
      expect(tester.takeException(), isNull);
      // Same archived style, short vs long name: the long name's own
      // text block is taller (it wrapped), the short one is one line.
      final shortNameH = tester.getSize(find.text('Eye exam')).height;
      final longNameH = tester
          .getSize(find.text('Specialist appointment (Brad) (2)'))
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
      // The name never runs under the action rail.
      final nameRight =
          tester.getTopRight(find.text('Specialist appointment (Brad) (2)')).dx;
      final railLeft = tester
          .getTopLeft(find.byKey(const ValueKey('counter_archive_b1')))
          .dx;
      expect(nameRight, lessThanOrEqualTo(railLeft));
      expect(tester.takeException(), isNull);
    });
  });

  group('Event Counters behavior unchanged', () {
    testWidgets('archive: tapping the rail archives with the same save',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_archive_a1')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      final a1 = saved.firstWhere((c) => c['id'] == 'a1');
      expect(a1['isArchived'], isTrue);
      expect(saved.length, 6);
      // The row moved to the archived card: now rendered muted.
      final name = tester.widget<Text>(find.text('Doctor appointment'));
      expect(name.style!.color, NotelColors.textSecondary);
      expect(find.byTooltip('Unarchive counter'), findsNWidgets(6));
    });

    testWidgets('unarchive: tapping an archived rail restores it active',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_archive_b5')));
      await tester.pumpAndSettle();
      final saved = _pushedCounters(backend);
      final b5 = saved.firstWhere((c) => c['id'] == 'b5');
      expect(b5['isArchived'], isFalse);
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

    testWidgets('end: rail removes the counter and appends to history',
        (tester) async {
      final backend = FakeCountersBackend()
        ..pullBody = _pull(_screenshotCounters());
      await _pumpCounters(tester, backend);
      await tester.tap(find.byKey(const ValueKey('counter_end_b2')));
      await tester.pumpAndSettle();
      final push = backend.profilePushes
          .lastWhere((p) => p.containsKey('counterHistory'));
      final saved = jsonDecode(push['eventCounters'] as String) as List;
      expect(saved.any((c) => c['id'] == 'b2'), isFalse);
      expect(saved.length, 5);
      final history =
          jsonDecode(push['counterHistory'] as String) as List<dynamic>;
      expect(history.first['name'], 'Dentist appointment');
      expect(history.first['targetDate'],
          _midnightPlus(-3).millisecondsSinceEpoch);
      // Gone as a row; present only as a Past Counters line.
      expect(find.text('Dentist appointment'), findsNothing);
      expect(find.textContaining('Dentist appointment (Ended:'),
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
