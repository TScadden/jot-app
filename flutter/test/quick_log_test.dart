import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';

/// Round 19 — unit tests for the Quick Log pure logic (ports of native
/// `QuickLogViewModel` / `TemplateAndDefaultsRepository` behavior).

QuickLogEntry _entry({
  int id = 1,
  int categoryId = 3,
  String body = 'body',
  int? timestamp,
}) =>
    QuickLogEntry(
      id: id,
      categoryId: categoryId,
      body: body,
      chips: '',
      manualText: '',
      timestamp: timestamp ?? 0,
    );

void main() {
  group('todayEntryCount', () {
    test('counts entries since local midnight', () {
      final now = DateTime(2026, 10, 11, 15, 30);
      final midnight = DateTime(2026, 10, 11).millisecondsSinceEpoch;
      final entries = [
        _entry(id: 1, timestamp: midnight + 1000), // today
        _entry(id: 2, timestamp: midnight - 1000), // yesterday
        _entry(id: 3, timestamp: midnight), // exactly midnight → today
      ];
      expect(todayEntryCount(entries, now: now), 2);
    });

    test('empty list → 0 (honest "no entries yet")', () {
      expect(todayEntryCount(const [], now: DateTime(2026, 10, 11)), 0);
    });
  });

  group('recentSuggestions', () {
    test('dedupes on categoryId + lowercase body, newest first, cap 10', () {
      final entries = [
        _entry(id: 1, body: 'Took Escitalopram 50mg'),
        _entry(id: 2, body: 'took escitalopram 50MG'), // dupe
        _entry(id: 3, body: 'Took Ivabradine 7.5mg'),
        _entry(id: 4, categoryId: 9, body: 'Took Escitalopram 50mg'), // other cat → kept
      ];
      final out = recentSuggestions(entries,
          activeMedicationNames: const {}, medicationCategoryId: null);
      expect(out.map((e) => e.id).toList(), [1, 3, 4]);
    });

    test('medication entries need an active med name in the body', () {
      final entries = [
        _entry(id: 1, categoryId: 8, body: 'Took Escitalopram 50mg'),
        _entry(id: 2, categoryId: 8, body: 'Took OldMed 10mg'),
        _entry(id: 3, categoryId: 3, body: 'Headache'),
      ];
      final out = recentSuggestions(entries,
          activeMedicationNames: {'escitalopram'},
          medicationCategoryId: 8);
      expect(out.map((e) => e.id).toList(), [1, 3]);
    });

    test('limit honored', () {
      final entries =
          List.generate(30, (i) => _entry(id: i, body: 'note $i'));
      final out = recentSuggestions(entries,
          activeMedicationNames: const {},
          medicationCategoryId: null,
          limit: 10);
      expect(out.length, 10);
    });
  });

  group('cleanChips', () {
    test('strips parens, ?, collapses whitespace; caps 3 words / 20 chars', () {
      final out = cleanChips(
        [
          'Brain Fog (severe)',
          'chest  pain?',
          'a very long chip name indeed',
          'this chip is way too long for display',
          '  ',
          'Brain fog', // dupe (case-insensitive)
        ],
        'Symptoms',
      );
      expect(
        out,
        ['Brain Fog', 'chest pain', 'a very long', 'this chip is'],
      );
    });

    test('medication category drops prohibited terms', () {
      final out = cleanChips(
        ['Took pill', 'Drank water', 'hydration mix'],
        'Medication',
      );
      expect(out, ['Took pill']);
    });

    test('non-medication category keeps those terms', () {
      final out = cleanChips(['Drank water'], 'General');
      expect(out, ['Drank water']);
    });
  });

  group('rankCategories', () {
    test('most-logged first, ties by recency, then sortOrder', () {
      const cats = [
        QuickLogCategory(
            id: 1, name: 'A', icon: '', colorHex: '#fff', isDefault: true, sortOrder: 0),
        QuickLogCategory(
            id: 2, name: 'B', icon: '', colorHex: '#fff', isDefault: true, sortOrder: 1),
        QuickLogCategory(
            id: 3, name: 'C', icon: '', colorHex: '#fff', isDefault: true, sortOrder: 2),
      ];
      final entries = [
        _entry(id: 1, categoryId: 2, timestamp: 100),
        _entry(id: 2, categoryId: 2, timestamp: 200),
        _entry(id: 3, categoryId: 3, timestamp: 300),
      ];
      final ranked = rankCategories(cats, entries);
      expect(ranked.map((c) => c.id).toList(), [2, 3, 1]);
    });

    test('recency breaks frequency ties', () {
      const cats = [
        QuickLogCategory(
            id: 1, name: 'A', icon: '', colorHex: '#fff', isDefault: true, sortOrder: 0),
        QuickLogCategory(
            id: 2, name: 'B', icon: '', colorHex: '#fff', isDefault: true, sortOrder: 1),
      ];
      final entries = [
        _entry(id: 1, categoryId: 1, timestamp: 100),
        _entry(id: 2, categoryId: 2, timestamp: 900),
      ];
      final ranked = rankCategories(cats, entries);
      expect(ranked.map((c) => c.id).toList(), [2, 1]);
    });
  });

  group('QuickLogEntry.fromJson', () {
    test('parses the sync-pull row shape', () {
      final e = QuickLogEntry.fromJson({
        'id': 42,
        'categoryId': 3,
        'body': 'Brain fog',
        'chips': 'Brain Fog',
        'manualText': '',
        'timestamp': 1760220000000,
        'updatedAt': 1760220001000,
      });
      expect(e.id, 42);
      expect(e.categoryId, 3);
      expect(e.body, 'Brain fog');
      expect(e.timestamp, 1760220000000);
    });

    test('toSyncJson carries the fields POST /api/sync/entries needs', () {
      final e = _entry(id: 7, categoryId: 3, body: 'x', timestamp: 99);
      final j = e.toSyncJson();
      expect(j['id'], 7);
      expect(j['categoryId'], 3);
      expect(j['body'], 'x');
      expect(j['timestamp'], 99);
      expect(j['updatedAt'], isA<int>());
    });
  });

  group('QuickLogCategory.fromJson', () {
    test('parses the sync-pull category shape', () {
      final c = QuickLogCategory.fromJson({
        'id': 8,
        'name': 'Medication',
        'icon': 'Medication',
        'colorHex': '#4ECDC4',
        'isDefault': false,
        'sortOrder': 3,
      });
      expect(c.id, 8);
      expect(c.name, 'Medication');
      expect(c.color.toARGB32(), 0xFF4ECDC4);
    });

    test('bad colorHex falls back to Tabs purple', () {
      final c = QuickLogCategory.fromJson(
          {'id': 1, 'name': 'X', 'colorHex': 'nope'});
      expect(c.color.toARGB32(), 0xFF7C6EFF);
    });
  });
}
