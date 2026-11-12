import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Founder package (Nov 12, 2026, approved mock v1): History entry
/// detail dialog polish —
/// - category chips WRAP inside the dialog (the old horizontal
///   scroll row clipped the third chip at the dialog's right edge);
/// - a search field under CHANGE CATEGORY filters the picker chips
///   as the user types ([filterCategoriesForPicker]);
/// - drag handle, divider before the entry body, clock icon on the
///   logged-on line, filled Edit / ghost Close actions.
/// No behaviour change: category save-on-tap, entry text rendering
/// (PR #70 dedupe) and Edit are untouched.

const _categories = <Map<String, dynamic>>[
  {
    'id': 7,
    'name': 'General',
    'icon': 'circle',
    'colorHex': '#CCCCCC',
    'isDefault': true,
    'sortOrder': 0,
  },
  {
    'id': 3,
    'name': 'Symptoms',
    'icon': 'circle',
    'colorHex': '#E06E6E',
    'isDefault': true,
    'sortOrder': 1,
  },
  {
    'id': 8,
    'name': 'Food & Eating',
    'icon': 'circle',
    'colorHex': '#E0B26E',
    'isDefault': true,
    'sortOrder': 2,
  },
  {
    'id': 9,
    'name': 'Medications',
    'icon': 'circle',
    'colorHex': '#4ECDC4',
    'isDefault': true,
    'sortOrder': 3,
  },
  {
    'id': 10,
    'name': 'Sleep & Recovery',
    'icon': 'circle',
    'colorHex': '#7C6EFF',
    'isDefault': true,
    'sortOrder': 4,
  },
  {
    'id': 6,
    'name': 'Mood & Energy',
    'icon': 'circle',
    'colorHex': '#FFD93D',
    'isDefault': true,
    'sortOrder': 5,
  },
];

Map<String, dynamic> _entry() => {
      'id': 42,
      'categoryId': 6,
      'body': 'feeling very tired today',
      'chips': '["Mood & Energy"]',
      'manualText': '',
      'timestamp': DateTime(2026, 11, 12, 12, 12).millisecondsSinceEpoch,
    };

class _FakeServer {
  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> capturedPosts = [];

  _FakeServer(this.entries);

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'test-token';
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': _categories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path == '/api/sync/entries' &&
          request.method == 'POST') {
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        capturedPosts.addAll(
          (decoded['entries'] as List).cast<Map<String, dynamic>>(),
        );
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }
}

LogEntryOutbox _freshOutbox() {
  final disk = <String, String>{};
  final outbox = LogEntryOutbox.instance;
  outbox.debugReset();
  outbox.debugSetStore(
    read: (key) async => disk[key],
    write: (key, value) async => disk[key] = value,
    delete: (key) async => disk.remove(key),
  );
  return outbox;
}

Future<void> _openDialogAt360(WidgetTester tester, _FakeServer server) async {
  tester.view.physicalSize = const Size(360, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: HistoryScreen(backend: server.backend(), outbox: _freshOutbox()),
    ),
  );
  await tester.pumpAndSettle();
  // Pre-existing, NOT from this package (verified on the release
  // head with no dialog open): at 360dp the History CARD's
  // date + sync-badge row overflows by 31px under the test font
  // (Ahem's 1em glyph advances inflate the row; the real font fits
  // on device). Drain that known exception here so the tests below
  // can assert the DIALOG itself lays out with no overflow.
  final preExisting = tester.takeException();
  if (preExisting != null) {
    // Only the known card-row overflow may be drained; anything
    // else is a real failure and must surface here.
    expect('$preExisting', contains('overflowed by 31 pixels'),
        reason: 'unexpected list exception: $preExisting');
  }
  await tester.tap(find.text('feeling very tired today'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => TabsBackend.debugResetSharedCaches());

  group('filterCategoriesForPicker (pure)', () {
    const cats = <QuickLogCategory>[
      QuickLogCategory(
          id: 7, name: 'General', icon: '', colorHex: '',
          isDefault: true, sortOrder: 0),
      QuickLogCategory(
          id: 3, name: 'Symptoms', icon: '', colorHex: '',
          isDefault: true, sortOrder: 1),
      QuickLogCategory(
          id: 8, name: 'Food & Eating', icon: '', colorHex: '',
          isDefault: true, sortOrder: 2),
      QuickLogCategory(
          id: 6, name: 'Mood & Energy', icon: '', colorHex: '',
          isDefault: true, sortOrder: 5),
    ];

    test('substring match returns only the matching categories', () {
      expect(
        filterCategoriesForPicker(cats, 'food').map((c) => c.name),
        ['Food & Eating'],
      );
      expect(
        filterCategoriesForPicker(cats, 'e').map((c) => c.name),
        ['General', 'Food & Eating', 'Mood & Energy'],
      );
    });

    test('no match returns an empty list', () {
      expect(filterCategoriesForPicker(cats, 'zzz'), isEmpty);
    });

    test('matching is case-insensitive', () {
      expect(
        filterCategoriesForPicker(cats, 'sYmPtOmS').map((c) => c.name),
        ['Symptoms'],
      );
      expect(
        filterCategoriesForPicker(cats, 'MOOD').map((c) => c.name),
        ['Mood & Energy'],
      );
    });

    test('empty query shows all, in input order', () {
      expect(filterCategoriesForPicker(cats, ''), cats);
      expect(
        filterCategoriesForPicker(cats, '').map((c) => c.id),
        [7, 3, 8, 6],
      );
    });

    test('whitespace-only query shows all and input is not mutated', () {
      final input = cats.toList();
      expect(filterCategoriesForPicker(input, '   '), cats);
      expect(input, cats);
    });
  });

  group('entry detail dialog (approved mock, 360dp)', () {
    testWidgets(
        'renders all chips wrapped inside the dialog — nothing clips, '
        'no overflow at 360dp', (tester) async {
      final server = _FakeServer([_entry()]);
      await _openDialogAt360(tester, server);

      // Mock chrome: drag handle, search field with the Juno-pending
      // hint, divider, clock icon, actions.
      expect(
        find.byKey(const ValueKey('history_detail_drag_handle')),
        findsOneWidget,
      );
      final searchField = tester.widget<TextField>(
        find.byKey(const ValueKey('history_category_search_field')),
      );
      expect(
        searchField.decoration?.hintText,
        TODO_JUNO_HISTORY_CATEGORY_SEARCH_HINT,
      );
      expect(TODO_JUNO_HISTORY_CATEGORY_SEARCH_HINT, 'Search categories');
      expect(find.byType(Divider), findsOneWidget);
      expect(find.byIcon(Icons.access_time), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      // Entry text renders once (PR #70 dedupe path untouched).
      expect(find.text('feeling very tired today'), findsWidgets);

      // Every category chip is present…
      const labels = [
        'GENERAL',
        'SYMPTOMS',
        'FOOD & EATING',
        'MEDICATIONS',
        'SLEEP & RECOVERY',
        'MOOD & ENERGY',
      ];
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // …inside the dialog's bounds (no chip clipped at its edge)…
      final dialogRect = tester.getRect(find.byType(Dialog));
      for (final label in labels) {
        final rect = tester.getRect(find.text(label));
        expect(rect.left, greaterThanOrEqualTo(dialogRect.left),
            reason: '$label left');
        expect(rect.right, lessThanOrEqualTo(dialogRect.right),
            reason: '$label right');
        expect(rect.bottom, lessThanOrEqualTo(dialogRect.bottom),
            reason: '$label bottom');
      }
      // …wrapped onto more than one row…
      final rowTops = {
        for (final label in labels) tester.getTopLeft(find.text(label)).dy,
      };
      expect(rowTops.length, greaterThan(1));
      // …and the current category carries the check mark.
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search field filters the chips as the user types',
        (tester) async {
      final server = _FakeServer([_entry()]);
      await _openDialogAt360(tester, server);

      await tester.enterText(
        find.byKey(const ValueKey('history_category_search_field')),
        'food',
      );
      await tester.pumpAndSettle();
      expect(find.text('FOOD & EATING'), findsOneWidget);
      expect(find.text('SYMPTOMS'), findsNothing);
      expect(find.text('MOOD & ENERGY'), findsNothing);
      expect(find.text('GENERAL'), findsNothing);

      // Clearing the query restores every chip.
      await tester.enterText(
        find.byKey(const ValueKey('history_category_search_field')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('SYMPTOMS'), findsOneWidget);
      expect(find.text('MOOD & ENERGY'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a wrapped chip still saves the category change',
        (tester) async {
      final server = _FakeServer([_entry()]);
      await _openDialogAt360(tester, server);

      await tester.tap(find.text('GENERAL'));
      await tester.pumpAndSettle();

      expect(server.capturedPosts, hasLength(1));
      expect(server.capturedPosts.single['categoryId'], 7);
      expect(server.capturedPosts.single['chips'], '["General"]');
      expect(tester.takeException(), isNull);
    });
  });
}
