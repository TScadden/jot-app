import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';

/// Round 63 — Quick Log archived-medication fix.
///
/// The defect: Quick Log's `_activeMedicationNames` parsed the raw
/// profile blob and skipped a med ONLY if `m['isArchived'] == true`
/// (strict bool on a key the blob never carries in either stored
/// generation), so archived meds still appeared as active
/// medication suggestions in Quick Log's recent suggestions.
///
/// The fix routes the computation through the shared model
/// (`MedicationEntry.fromBlobRow` + `isArchived`, via the top-level
/// [activeMedicationNamesFromProfile] the screen now delegates to).
/// These fixtures cover BOTH stored generations and assert that
/// Quick Log's set and the shared model's classification AGREE
/// row for row:
///
/// - Generation B (native-era): rows carry NO `isPresent` key and
///   NO `isArchived` key (native kotlinx omits DTO defaults) — the
///   model's end-date fallback is the only archived signal:
///   a dated `endDate` (`MMM d, yyyy`) ⇒ archived; the literal
///   `"Present"` sentinel ⇒ active.
/// - Flutter-era: rows carry an explicit `isPresent` flag:
///   `false` ⇒ archived; `true` ⇒ active.

/// A native-era (Generation B) ARCHIVED row: no `isPresent` key,
/// no `isArchived` key, `endDate` a stamped `MMM d, yyyy` date.
Map<String, dynamic> nativeEraArchivedRow() => <String, dynamic>{
      'id': 'gen-b-archived',
      'name': 'Native Ended Med',
      'startDate': 'Jan 5, 2026',
      'endDate': 'Oct 1, 2026',
      'dose': '10mg',
      'frequency': 'Daily',
      'updatedAt': 1000,
      'isDeleted': false,
    };

/// A native-era (Generation B) ACTIVE row: no `isPresent` key,
/// no `isArchived` key, `endDate` the literal `"Present"` sentinel.
Map<String, dynamic> nativeEraActiveRow() => <String, dynamic>{
      'id': 'gen-b-active',
      'name': 'Native Current Med',
      'startDate': 'Jan 5, 2026',
      'endDate': 'Present',
      'dose': '10mg',
      'frequency': 'Daily',
      'updatedAt': 1000,
      'isDeleted': false,
    };

/// A Flutter-era ARCHIVED row: explicit `isPresent: false`.
Map<String, dynamic> flutterEraArchivedRow() => <String, dynamic>{
      'id': 'flutter-archived',
      'name': 'Flutter Ended Med',
      'startDate': 'Feb 1, 2026',
      'endDate': 'Sep 15, 2026',
      'isPresent': false,
      'dose': '5mg',
      'frequency': 'Daily',
      'updatedAt': 2000,
      'isDeleted': false,
    };

/// A Flutter-era ACTIVE row: explicit `isPresent: true`.
Map<String, dynamic> flutterEraActiveRow() => <String, dynamic>{
      'id': 'flutter-active',
      'name': 'Flutter Current Med',
      'startDate': 'Feb 1, 2026',
      'endDate': 'Present',
      'isPresent': true,
      'dose': '5mg',
      'frequency': 'Daily',
      'updatedAt': 2000,
      'isDeleted': false,
    };

List<Map<String, dynamic>> bothGenerationRows() => [
      nativeEraArchivedRow(),
      nativeEraActiveRow(),
      flutterEraArchivedRow(),
      flutterEraActiveRow(),
    ];

/// The profile shape Quick Log actually receives: the medications
/// blob as a JSON string on the profile map.
Map<String, dynamic> profileWith(List<Map<String, dynamic>> rows) =>
    <String, dynamic>{'medications': jsonEncode(rows)};

void main() {
  group('shared model classification (both generations)', () {
    test('native-era archived row: no isPresent key, dated endDate '
        '→ isArchived', () {
      final row = nativeEraArchivedRow();
      expect(row.containsKey('isPresent'), isFalse);
      expect(row.containsKey('isArchived'), isFalse);
      final entry = MedicationEntry.fromBlobRow(row)!;
      expect(entry.isArchived, isTrue);
    });

    test('native-era active row: no isPresent key, endDate "Present" '
        '→ not archived', () {
      final row = nativeEraActiveRow();
      expect(row.containsKey('isPresent'), isFalse);
      expect(row.containsKey('isArchived'), isFalse);
      final entry = MedicationEntry.fromBlobRow(row)!;
      expect(entry.isArchived, isFalse);
    });

    test('flutter-era row with isPresent:false → isArchived', () {
      final entry = MedicationEntry.fromBlobRow(flutterEraArchivedRow())!;
      expect(entry.isArchived, isTrue);
    });

    test('flutter-era row with isPresent:true → not archived', () {
      final entry = MedicationEntry.fromBlobRow(flutterEraActiveRow())!;
      expect(entry.isArchived, isFalse);
    });
  });

  group('Quick Log active medication names (R63 fix)', () {
    test('native-era archived med (no isPresent, dated endDate) '
        'is EXCLUDED', () {
      final names =
          activeMedicationNamesFromProfile(profileWith([nativeEraArchivedRow()]));
      expect(names, isEmpty);
    });

    test('native-era active med (no isPresent, endDate "Present") '
        'is INCLUDED', () {
      final names =
          activeMedicationNamesFromProfile(profileWith([nativeEraActiveRow()]));
      expect(names, {'native current med'});
    });

    test('flutter-era med with isPresent:false is EXCLUDED', () {
      final names = activeMedicationNamesFromProfile(
          profileWith([flutterEraArchivedRow()]));
      expect(names, isEmpty);
    });

    test('flutter-era med with isPresent:true is INCLUDED', () {
      final names =
          activeMedicationNamesFromProfile(profileWith([flutterEraActiveRow()]));
      expect(names, {'flutter current med'});
    });

    test('both generations together: only the two active meds remain',
        () {
      final names =
          activeMedicationNamesFromProfile(profileWith(bothGenerationRows()));
      expect(names, {'native current med', 'flutter current med'});
    });

    test('deleted med is EXCLUDED even when isPresent:true', () {
      final row = flutterEraActiveRow()
        ..['name'] = 'Deleted Current Med'
        ..['isDeleted'] = true;
      final names = activeMedicationNamesFromProfile(profileWith([row]));
      expect(names, isEmpty);
    });

    test('null / missing profile yields no names (no crash)', () {
      expect(activeMedicationNamesFromProfile(null), isEmpty);
      expect(activeMedicationNamesFromProfile(const {}), isEmpty);
    });
  });

  group('agreement: Quick Log set == shared model, row for row', () {
    test('every fixture row: in Quick Log set ⟺ model says active '
        'and not deleted', () {
      final rows = bothGenerationRows();
      final names = activeMedicationNamesFromProfile(profileWith(rows));
      for (final row in rows) {
        final entry = MedicationEntry.fromBlobRow(row)!;
        final modelSaysActive = !entry.isArchived && !entry.isDeleted;
        expect(
          names.contains(entry.name.toLowerCase()),
          modelSaysActive,
          reason: 'row id=${row['id']} isArchived=${entry.isArchived}',
        );
      }
      // And the model's own active filter agrees on the name set.
      final modelActiveNames = activeMedicationEntries(
              parseMedicationBlob(rows))
          .map((e) => e.name.toLowerCase())
          .toSet();
      expect(names, modelActiveNames);
    });
  });

  group('downstream effect: recentSuggestions', () {
    QuickLogEntry medEntry(int id, String body) => QuickLogEntry(
          id: id,
          categoryId: 8,
          body: body,
          chips: '',
          manualText: '',
          timestamp: id,
        );

    test('archived meds (both generations) produce no medication '
        'recent suggestions; active meds (both) still do', () {
      final names =
          activeMedicationNamesFromProfile(profileWith(bothGenerationRows()));
      final entries = [
        medEntry(1, 'Took Native Ended Med 10mg'),
        medEntry(2, 'Took Native Current Med 10mg'),
        medEntry(3, 'Took Flutter Ended Med 5mg'),
        medEntry(4, 'Took Flutter Current Med 5mg'),
      ];
      final out = recentSuggestions(
        entries,
        activeMedicationNames: names,
        medicationCategoryId: 8,
      );
      expect(out.map((e) => e.id).toList(), [2, 4]);
    });
  });
}
