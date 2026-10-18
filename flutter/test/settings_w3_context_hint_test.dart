import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/settings_store.dart';

import 'settings_r29_test.dart' as r29;

/// Workstream 3 (Oct 16, 2026) — Personal Context surfacing,
/// Flutter half.
///
/// 1. Caption: the editor no longer wears the goals framing
///    ("training for a marathon"). It discloses that the text is
///    quoted word for word as background in clinical reports,
///    is sent to the Health Coach with every message, and that
///    the medication list is authoritative for reports.
/// 2. Known-names hint: when the context text mentions a
///    medication that exists as an entry (active ∪ archived),
///    a visible, dismissible hint says the medication list wins
///    for reports. Known names only — no lexicon, no fuzzy
///    matching — and the hint is UI-only: the editor's debounced
///    save behavior is unchanged.

const _caption =
    'This text is quoted word for word as background in your '
    'clinical reports and is sent to the Health Coach with '
    'every message. Your medication list is authoritative '
    'for reports, so keep any medications mentioned here in '
    'sync with that list.';

const _oldCaption =
    "Tell Tabs about your goals (e.g. 'training for a marathon').";

Map<String, dynamic> _row({
  required String id,
  required String name,
  bool isPresent = true,
  String endDate = 'Present',
  bool isDeleted = false,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'name': name,
  'startDate': 'Sep 2026',
  'endDate': endDate,
  'isPresent': isPresent,
  'dose': '7.5mg',
  'frequency': 'Twice daily',
  'updatedAt': 1000,
  'isDeleted': isDeleted,
  ...extra,
};

/// Ivabradine active, Escitalopram archived, Ghost Med a deleted
/// tombstone, Stamp Med archived only via the defensive stamp.
List<Map<String, dynamic>> _medRows() => [
  _row(id: 'm1', name: 'Ivabradine'),
  _row(
    id: 'm2',
    name: 'Escitalopram',
    isPresent: false,
    endDate: 'Oct 16, 2026',
  ),
  _row(id: 'm3', name: 'Ghost Med', isDeleted: true),
  _row(id: 'm4', name: 'Stamp Med', extra: {'isArchived': true}),
];

List<MedicationEntry> _entries() => parseMedicationBlob(_medRows());

/// Pumps Settings on the MAIN page with the context NOT
/// privacy-hidden (unless [hidden] is set), the given context
/// text, and the fixture medication list on the profile.
Future<r29.FakeSettingsBackend> _pumpMain(
  WidgetTester tester, {
  required String userContext,
  bool hidden = false,
}) async {
  final backend = r29.FakeSettingsBackend()
    ..pullBody = r29.pull(
      profile: {
        'userContext': userContext,
        'medications': jsonEncode(_medRows()),
      },
    );
  await r29.pumpSettings(
    tester,
    r29.host(
      r29.screen(
        backend: backend,
        store: r29.fakeStore(<String, String>{
          if (!hidden) SettingsStore.userContextHiddenKey: 'false',
        }),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  group('medicationNamesMentionedInContext (known-names scan)', () {
    test('active entry name present → hint set contains it', () {
      expect(
        medicationNamesMentionedInContext(
          'I take Ivabradine for my heart rate.',
          _entries(),
        ),
        ['Ivabradine'],
      );
    });

    test('archived entry name present → hint set contains it', () {
      expect(
        medicationNamesMentionedInContext(
          'I stopped Escitalopram in October.',
          _entries(),
        ),
        ['Escitalopram'],
      );
    });

    test('stamp-only archived entry name present → flagged', () {
      expect(
        medicationNamesMentionedInContext('Stamp Med was a trial.', _entries()),
        ['Stamp Med'],
      );
    });

    test('unrelated text → no hint', () {
      expect(
        medicationNamesMentionedInContext(
          'I am training for a marathon and drink a gallon of '
          'water a day.',
          _entries(),
        ),
        isEmpty,
      );
    });

    test('a drug with NO entry is never flagged (no lexicon)', () {
      expect(
        medicationNamesMentionedInContext(
          'Pyridostigmine came up at my appointment.',
          _entries(),
        ),
        isEmpty,
      );
    });

    test('deleted tombstone name present → NOT flagged', () {
      expect(
        medicationNamesMentionedInContext(
          'Ghost Med is long gone.',
          _entries(),
        ),
        isEmpty,
      );
    });

    test('matching is case-insensitive', () {
      expect(
        medicationNamesMentionedInContext(
          'ivabradine twice a day, every day',
          _entries(),
        ),
        ['Ivabradine'],
      );
    });

    test('punctuation boundaries count as mentions', () {
      expect(
        medicationNamesMentionedInContext(
          'Current: Ivabradine, (Escitalopram ended).',
          _entries(),
        ),
        ['Ivabradine', 'Escitalopram'],
      );
    });

    test('a name inside a longer word does NOT match', () {
      final entries = parseMedicationBlob([
        _row(id: 'x1', name: 'Iron'),
        _row(id: 'x2', name: 'D3'),
      ]);
      expect(
        medicationNamesMentionedInContext(
          'Ironing clothes; plan D30 starts Monday.',
          entries,
        ),
        isEmpty,
      );
    });

    test('multiple mentions return in entry order, deduplicated', () {
      expect(
        medicationNamesMentionedInContext(
          'Escitalopram ended; Ivabradine stays; ivabradine '
          'again.',
          _entries(),
        ),
        ['Ivabradine', 'Escitalopram'],
      );
    });

    test('empty text or empty entry list → no hint', () {
      expect(medicationNamesMentionedInContext('', _entries()), isEmpty);
      expect(
        medicationNamesMentionedInContext('Ivabradine', const []),
        isEmpty,
      );
    });
  });

  group('Personal Context caption (Workstream 3)', () {
    testWidgets('main page shows the disclosure caption, not the '
        'goals framing', (tester) async {
      await _pumpMain(tester, userContext: 'background notes');
      expect(find.text('Personal Context'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('personal_context_caption')),
        findsOneWidget,
      );
      expect(find.text(_caption), findsOneWidget);
      expect(find.text(_oldCaption), findsNothing);
    });
  });

  group('Personal Context medication-name hint (Workstream 3)', () {
    testWidgets('active med mentioned → visible hint naming it', (
      tester,
    ) async {
      await _pumpMain(
        tester,
        userContext: 'I take Ivabradine twice daily for POTS.',
      );
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Medication names in this text: '
          'Ivabradine.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'your medication list wins over '
          'this text',
        ),
        findsOneWidget,
      );
    });

    testWidgets('archived med mentioned → hint names it too', (tester) async {
      await _pumpMain(tester, userContext: 'Escitalopram did not work for me.');
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsOneWidget,
      );
      expect(find.textContaining('Escitalopram'), findsWidgets);
    });

    testWidgets('unrelated context → no hint', (tester) async {
      await _pumpMain(
        tester,
        userContext: 'Training for a marathon this spring.',
      );
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsNothing,
      );
    });

    testWidgets('dismiss hides the hint', (tester) async {
      await _pumpMain(tester, userContext: 'I take Ivabradine twice daily.');
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('personal_context_med_hint_dismiss')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsNothing,
      );
    });

    testWidgets('dismissal is per mention set: mentioning a second med '
        'brings the hint back', (tester) async {
      await _pumpMain(tester, userContext: 'I take Ivabradine twice daily.');
      await tester.tap(
        find.byKey(const ValueKey('personal_context_med_hint_dismiss')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('personal_context_field')),
        'I take Ivabradine. Escitalopram ended in October.',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsOneWidget,
      );
      expect(find.textContaining('Escitalopram'), findsWidgets);
    });

    testWidgets('typing a med name into a clean context raises the hint '
        'live, and the debounced save is unchanged', (tester) async {
      final backend = await _pumpMain(tester, userContext: 'No meds here yet.');
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('personal_context_field')),
        'Now on Ivabradine twice daily.',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsOneWidget,
      );
      // Save behavior untouched: nothing pushed inside the
      // debounce window, exactly one userContext push after it.
      expect(backend.profilePushes, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(backend.profilePushes, [
        equals({'userContext': 'Now on Ivabradine twice daily.'}),
      ]);
    });

    testWidgets('privacy-hidden context: no field, no hint, and the med '
        'name leaks nowhere on the page', (tester) async {
      await _pumpMain(
        tester,
        userContext: 'I take Ivabradine twice daily.',
        hidden: true,
      );
      expect(find.text('Hidden for your privacy'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('personal_context_field')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('personal_context_med_hint')),
        findsNothing,
      );
      expect(find.textContaining('Ivabradine'), findsNothing);
    });
  });
}
