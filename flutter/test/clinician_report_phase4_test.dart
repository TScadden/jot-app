import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';

// ── Report Reliability Phase 4, PR-A — clinician one-pager ──────
// completeness fixtures (the merge gate).
//
// The biometric fixture's values are chosen so every Z3B line is
// byte-identical to a worked example in Juno's Phase 4 ruling
// (~/workspace/report-reliability-phase4/juno-ruling.md, Ruling
// 2), and the Z8 fixture reproduces her Ruling 3 worked example
// byte-exact. Assertions on rendered output run against text
// EXTRACTED FROM THE RENDERED PDF BYTES (the pdfText() pattern
// from report_ai_reliability_phase3_test.dart), not only against
// the clinicianPageLines model.

final int _nowMs = DateTime(2026, 10, 28, 12).millisecondsSinceEpoch;

int _ts(int month, int day, {int hour = 10}) =>
    DateTime(2026, month, day, hour).millisecondsSinceEpoch;

String _key(int month, int day) =>
    '2026-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

const _cats = [
  QuickLogCategory(
      id: 2, name: 'Symptoms', icon: '', colorHex: '', isDefault: true, sortOrder: 0),
  QuickLogCategory(
      id: 3,
      name: 'Migraine Symptoms & Triggers',
      icon: '',
      colorHex: '',
      isDefault: false,
      sortOrder: 1),
  QuickLogCategory(
      id: 4, name: 'Food', icon: '', colorHex: '', isDefault: false, sortOrder: 2),
];

QuickLogEntry _entry(int id, int cat, int ts,
        {String body = '', String chips = ''}) =>
    QuickLogEntry(
        id: id, categoryId: cat, body: body, chips: chips, manualText: '', timestamp: ts);

MedicationEntry _med(String name, String dose,
        {String frequency = 'Once daily',
        String startDate = '',
        String endDate = 'Present',
        bool isPresent = true,
        bool isArchived = false}) =>
    MedicationEntry(
      name: name,
      dose: dose,
      frequency: frequency,
      startDate: startDate,
      endDate: endDate,
      isPresent: isPresent,
      isArchived: isArchived,
      isDeleted: false,
    );

/// Juno's Ruling 2 worked-example series: 24 recorded days each.
/// Sleep 426 min → 7h6m; deep sleep 84 min → 1h24m; HRV 42.0 ms;
/// resting HR 62 bpm; spikes 17 over 9 days (plus 3 sampled
/// zero-count days); BP 9 readings averaging 118/76.
List<(String, int)> _days24(int value) =>
    [for (var d = 1; d <= 24; d++) (_key(10, d), value)];

List<(String, int)> _spikeSeries() => [
      for (var i = 0; i < 9; i++)
        (_key(10, i + 1), const [3, 2, 2, 2, 2, 2, 2, 1, 1][i]),
      (_key(10, 10), 0),
      (_key(10, 11), 0),
      (_key(10, 12), 0),
    ];

List<ReportBpRecord> _bpReadings() => [
      for (var i = 0; i < 9; i++)
        ReportBpRecord(
          const [120, 118, 116, 122, 118, 117, 119, 118, 114][i],
          const [76, 78, 74, 80, 76, 75, 77, 76, 72][i],
          _ts(10, i + 1),
        ),
    ];

const _junoZ3bLines = [
  'Average sleep: 7h6m across 24 days.',
  'Average deep sleep: 1h24m across 24 days.',
  'Average HRV (RMSSD): 42.0 ms across 24 days.',
  'Average resting heart rate: 62 bpm across 24 days.',
  'Heart rate spikes: 17 recorded on 9 days.',
  'Average blood pressure: 118/76 mmHg across 9 readings.',
];

ReportSnapshot _snapshot({
  List<MedicationEntry> medications = const [],
  List<QuickLogEntry> logEntries = const [],
  Map<String, SectionMetadata> sectionMetadata = const {},
  List<(String, int)> heartRateSeries = const [],
  List<(String, int)> sleepSeries = const [],
  List<(String, int)> deepSleepSeries = const [],
  List<(String, int)> caloriesSeries = const [],
  List<(String, double)> hrvSeries = const [],
  List<(String, int)> heartRateSpikes = const [],
  List<ReportBpRecord> bloodPressureSeries = const [],
  List<String> conditions = const ['POTS'],
}) =>
    ReportSnapshot(
      last30Days: true,
      generationTimestampMs: _nowMs,
      logEntries: logEntries,
      categoriesMap: {for (final c in _cats) c.id: c.name},
      userAge: 22,
      userGender: 'Male',
      conditions: conditions,
      medications: medications,
      sectionMetadata: sectionMetadata,
      heartRateSeries: heartRateSeries,
      sleepSeries: sleepSeries,
      deepSleepSeries: deepSleepSeries,
      caloriesSeries: caloriesSeries,
      hrvSeries: hrvSeries,
      heartRateSpikes: heartRateSpikes,
      bloodPressureSeries: bloodPressureSeries,
    );

ReportSnapshot _bioSnapshot({
  Map<String, SectionMetadata> sectionMetadata = const {},
}) =>
    _snapshot(
      sectionMetadata: sectionMetadata,
      sleepSeries: _days24(426),
      deepSleepSeries: _days24(84),
      hrvSeries: [for (var d = 1; d <= 24; d++) (_key(10, d), 42.0)],
      heartRateSeries: _days24(62),
      heartRateSpikes: _spikeSeries(),
      bloodPressureSeries: _bpReadings(),
    );

ClinicianReportCollector _collector({Map<String, int>? scores}) =>
    ClinicianReportCollector(
      scoreLoader: () async => scores ?? const {},
      eventsLoader: () async => [],
      categoriesLoader: () async => _cats,
    );

Future<ClinicianReportData> _extend(
  ReportSnapshot snapshot, {
  Map<String, int>? scores,
  List<MedicationEntry> allMedications = const [],
}) =>
    _collector(scores: scores)
        .extend(snapshot, allMedications: allMedications);

int _pageCount(List<int> bytes) {
  final text = latin1.decode(bytes);
  return RegExp(r'/Type\s*/Page(?![s\w])').allMatches(text).length;
}

List<String> _lines(ClinicianReportData data, [String? zone]) => [
      for (final l in clinicianPageLines(data))
        if (zone == null || l.zone == zone) l.text,
    ];

/// Extracts the text a generated PDF actually prints: inflate
/// every stream, collect the `(word)` operands of the TJ text
/// operators in order, and join them back into lines of text.
/// (The pdfText() helper pattern from
/// report_ai_reliability_phase3_test.dart, lifted unchanged.)
///
/// Extraction renders use the renderer's default (base-14) font
/// set: the production Roboto subset encodes glyph IDs rather
/// than text in its streams, so raw-stream extraction cannot
/// recover words from it — the same bytes-content, drawn from the
/// same line model, is asserted on the base-14 render, and the
/// production-font render is asserted for page count in each
/// fixture below.
String pdfText(List<int> bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  final inflated = StringBuffer();
  var idx = 0;
  while (true) {
    final s = raw.indexOf('stream', idx);
    if (s < 0) break;
    final e = raw.indexOf('endstream', s);
    if (e < 0) break;
    var start = s + 6;
    if (start < bytes.length && raw[start] == '\r') start++;
    if (start < bytes.length && raw[start] == '\n') start++;
    try {
      inflated.write(
          latin1.decode(ZLibDecoder().convert(bytes.sublist(start, e)),
              allowInvalid: true));
    } catch (_) {
      // Not a compressed stream (fonts/images) — not text.
    }
    idx = e + 9;
  }
  final words = RegExp(r'\((?:[^()\\]|\\.)*\)')
      .allMatches(inflated.toString())
      .map((m) {
    final inner = m.group(0)!;
    return inner.substring(1, inner.length - 1).replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')')
        .replaceAll(r'\\', r'\');
  });
  return words.join(' ');
}

Future<ClinicianPdfFonts> _diskFonts() async =>
    clinicianPdfFontsFromBytes(
      await File('assets/fonts/Roboto-Regular.ttf').readAsBytes(),
      await File('assets/fonts/Roboto-Bold.ttf').readAsBytes(),
    );

void main() {
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  group('Derivations (model, derived once in extend)', () {
    test('summaries derive from the snapshot series in extend()',
        () async {
      final data = await _extend(_bioSnapshot());
      expect(data.sleepSummary!.recordedDays, 24);
      expect(data.sleepSummary!.average, 426);
      expect(data.sleepSummary!.latest, 426);
      expect(data.sleepSummary!.latestDayKey, _key(10, 24));
      expect(data.deepSleepSummary!.average, 84);
      expect(data.hrvSummary!.average, 42.0);
      expect(data.restingHeartRateSummary!.average, 62);
      expect(data.heartRateSpikeSummary!.recordedDays, 12);
      expect(data.heartRateSpikeSummary!.totalSpikes, 17);
      expect(data.heartRateSpikeSummary!.daysWithSpikes, 9);
      expect(data.bloodPressureSummary!.readingCount, 9);
      expect(data.bloodPressureSummary!.averageSystolic, 118);
      expect(data.bloodPressureSummary!.averageDiastolic, 76);
      expect(data.bloodPressureSummary!.latestSystolic, 114);
      // Calories are not carried onto the clinician page (Juno
      // Ruling 2: not in the ruled set) — the model has no
      // calories summary even when the snapshot carries a series.
      final withCalories = await _extend(_snapshot(
        caloriesSeries: _days24(2100),
      ));
      expect(withCalories.sleepSummary, isNull);
    });

    test('zero rule: a 0 biometric day is a failed read, never averaged',
        () {
      final s = summarizeClinicianIntSeries([
        (_key(10, 1), 426),
        (_key(10, 2), 0),
        (_key(10, 3), 432),
      ]);
      expect(s!.recordedDays, 2);
      expect(s.average, 429);
      expect(summarizeClinicianIntSeries([(_key(10, 1), 0)]), isNull);
      expect(summarizeClinicianDoubleSeries(const []), isNull);
      expect(summarizeClinicianSpikes(const []), isNull);
      expect(summarizeClinicianBloodPressure(const []), isNull);
    });

    test('all-zero spike series is real data and renders both slots at 0',
        () async {
      final data = await _extend(_snapshot(
        heartRateSpikes: [(_key(10, 1), 0), (_key(10, 2), 0)],
      ));
      expect(data.heartRateSpikeSummary, isNotNull);
      expect(_lines(data, 'Z3B'),
          ['Biometrics', 'Heart rate spikes: 0 recorded on 0 days.']);
    });
  });

  group('Ruled line formats (Juno Ruling 2, byte-exact)', () {
    test('the biometric fixture lines ARE Juno\'s worked examples',
        () async {
      final data = await _extend(_bioSnapshot());
      expect(_lines(data, 'Z3B'), ['Biometrics', ..._junoZ3bLines]);
      expect(data.sleepSummary, isNotNull);
      // Zone placement: Z3B sits between Z3 and Z4, capped at
      // heading + six lines by construction.
      final zones = [for (final l in clinicianPageLines(data)) l.zone];
      expect(zones.indexOf('Z3B'), greaterThan(zones.lastIndexOf('Z3')));
      expect(zones.indexOf('Z3B'), lessThan(zones.indexOf('Z4')));
      expect(_lines(data, 'Z3B').length, lessThanOrEqualTo(7));
    });

    test('singular forms: 1 day / 1 reading, byte-exact', () async {
      final data = await _extend(_snapshot(
        sleepSeries: [(_key(10, 5), 426)],
        heartRateSpikes: [(_key(10, 5), 1)],
        bloodPressureSeries: [ReportBpRecord(118, 76, _ts(10, 5))],
      ));
      expect(
          _lines(data, 'Z3B'),
          containsAll([
            'Average sleep: 7h6m across 1 day.',
            'Heart rate spikes: 1 recorded on 1 day.',
            'Average blood pressure: 118/76 mmHg across 1 reading.',
          ]));
      expect(_lines(data, 'Z3B').join(' '), isNot(contains('1 days')));
      expect(_lines(data, 'Z3B').join(' '), isNot(contains('1 readings')));
    });

    test('slot conversions: sleep rounds, HR and BP truncate (buildHealthSummary parity)',
        () async {
      final data = await _extend(_snapshot(
        // Mean 425.5 min rounds to 426 → 7h6m (truncation: 7h5m).
        sleepSeries: [(_key(10, 1), 425), (_key(10, 2), 426)],
        // Mean 62.5 bpm truncates to 62 (rounding: 63).
        heartRateSeries: [(_key(10, 1), 62), (_key(10, 2), 63)],
        // Systolic mean 118.5 truncates to 118 (rounding: 119).
        bloodPressureSeries: [
          ReportBpRecord(118, 76, _ts(10, 1)),
          ReportBpRecord(119, 76, _ts(10, 2)),
        ],
      ));
      final z3b = _lines(data, 'Z3B');
      expect(z3b, contains('Average sleep: 7h6m across 2 days.'));
      expect(z3b,
          contains('Average resting heart rate: 62 bpm across 2 days.'));
      expect(z3b,
          contains('Average blood pressure: 118/76 mmHg across 2 readings.'));
    });

    test('no latest, no range, no zones wording anywhere in the zone',
        () async {
      final data = await _extend(_bioSnapshot());
      final zone = _lines(data, 'Z3B').join(' ');
      expect(zone.toLowerCase(), isNot(contains('latest')));
      expect(zone.toLowerCase(), isNot(contains('range')));
      expect(zone.toLowerCase(), isNot(contains('zone')));
      expect(zone, isNot(contains('Avg Heart Rate')));
    });
  });

  group('Zone omission + Z8 (Juno Rulings 3 and 4)', () {
    test('a metric with an empty series produces NO zone line; '
        'storedOnly renders its summary normally', () async {
      final data = await _extend(_bioSnapshot(sectionMetadata: {
        'sleep': const SectionMetadata(
            'sleep', DataSourceStatus.storedOnly, 24),
        'hrv': const SectionMetadata('hrv', DataSourceStatus.noData, 0),
      }));
      // Sleep is storedOnly: its series is present, so the zone
      // renders its summary — and NO availability text appears
      // inside the zone for any metric.
      final z3b = _lines(data, 'Z3B');
      expect(z3b, contains('Average sleep: 7h6m across 24 days.'));
      expect(z3b.join(' '), isNot(contains('Available')));
      expect(z3b.join(' '), isNot(contains('No data recorded')));
      // HRV's series is present in this fixture too, so it
      // renders; drop the series and it must vanish from the zone.
      final noHrv = await _extend(_snapshot(
        sleepSeries: _days24(426),
        sectionMetadata: const {
          'hrv': SectionMetadata('hrv', DataSourceStatus.noData, 0),
        },
      ));
      expect(_lines(noHrv, 'Z3B'),
          ['Biometrics', 'Average sleep: 7h6m across 24 days.']);
      expect(_lines(noHrv, 'Z8'),
          contains('Data availability: Hrv: No data recorded'));
    });

    test('Z8 worked example (Ruling 3): available first, byte-exact',
        () async {
      // Canonical order in the map puts bloodPressure FIRST; the
      // available group (success + storedOnly) must still print
      // before it, in canonical order within the group.
      final data = await _extend(_snapshot(sectionMetadata: {
        'bloodPressure': const SectionMetadata(
            'bloodPressure', DataSourceStatus.permissionDenied, 0),
        'sleep':
            const SectionMetadata('sleep', DataSourceStatus.success, 24),
        'hrv': const SectionMetadata(
            'hrv', DataSourceStatus.storedOnly, 18),
      }));
      expect(
          _lines(data, 'Z8'),
          contains(
              'Data availability: Sleep: Available (24 records); '
              'Hrv: Available from stored history (18 records); '
              'BloodPressure: Unavailable. Permission not granted.'));
    });

    test('Z8 renders when every section succeeded (no suppression)',
        () async {
      final data = await _extend(_snapshot(sectionMetadata: {
        'sleep':
            const SectionMetadata('sleep', DataSourceStatus.success, 24),
        'hrv': const SectionMetadata('hrv', DataSourceStatus.success, 24),
      }));
      expect(
          _lines(data, 'Z8'),
          contains('Data availability: Sleep: Available (24 records); '
              'Hrv: Available (24 records)'));
    });

    test('Phase 1 unavailable strings stay byte-identical in Z8',
        () async {
      final data = await _extend(_snapshot(sectionMetadata: {
        'sleep': const SectionMetadata('sleep', DataSourceStatus.stale, 0),
        'hrv': const SectionMetadata(
            'hrv', DataSourceStatus.permissionDenied, 0),
        'heartRate':
            const SectionMetadata('heartRate', DataSourceStatus.error, 0),
        'deepSleep':
            const SectionMetadata('deepSleep', DataSourceStatus.noData, 0),
      }));
      final z8 = _lines(data, 'Z8')
          .firstWhere((l) => l.startsWith('Data availability:'));
      expect(
          z8,
          'Data availability: Sleep: Unavailable. Permission shown as '
          'granted, but read blocked.; Hrv: Unavailable. Permission not '
          'granted.; HeartRate: Unavailable. Data could not be '
          'retrieved.; DeepSleep: No data recorded');
    });
  });

  group('Rendered-PDF fixtures (text extracted from the bytes)', () {
    test('biometric-bearing fixture: zone renders the fixture\'s real '
        'values in the extracted text; exactly 1 page', () async {
      final data = await _extend(_bioSnapshot(sectionMetadata: {
        'sleep':
            const SectionMetadata('sleep', DataSourceStatus.success, 24),
        'hrv': const SectionMetadata(
            'hrv', DataSourceStatus.storedOnly, 24),
      }));
      final prodBytes =
          await buildClinicianPdfBytes(data, fonts: await _diskFonts());
      expect(_pageCount(prodBytes), 1);
      final bytes = await buildClinicianPdfBytes(data);
      expect(_pageCount(bytes), 1);
      final text = pdfText(bytes);
      expect(text, contains('Biometrics'));
      for (final line in _junoZ3bLines) {
        expect(text, contains(line), reason: 'extracted text: $line');
      }
      // storedOnly provenance is disclosed in Z8, in the bytes.
      expect(text,
          contains('Hrv: Available from stored history (24 records)'));
    });

    test('no-biometric fixture: zone absent from the extracted text, '
        'Z8 carries the honest unavailable lines; exactly 1 page',
        () async {
      final data = await _extend(_snapshot(sectionMetadata: {
        'bloodPressure': const SectionMetadata(
            'bloodPressure', DataSourceStatus.noData, 0),
        'sleep': const SectionMetadata('sleep', DataSourceStatus.stale, 0),
        'hrv': const SectionMetadata(
            'hrv', DataSourceStatus.permissionDenied, 0),
      }));
      expect(_lines(data, 'Z3B'), isEmpty);
      final prodBytes =
          await buildClinicianPdfBytes(data, fonts: await _diskFonts());
      expect(_pageCount(prodBytes), 1);
      final bytes = await buildClinicianPdfBytes(data);
      expect(_pageCount(bytes), 1);
      final text = pdfText(bytes);
      // No silent gap: the zone is absent AND Z8 speaks.
      expect(text, isNot(contains('Biometrics')));
      expect(text, isNot(contains('Average sleep')));
      expect(text, contains('Data availability:'));
      expect(text, contains('BloodPressure: No data recorded'));
      expect(
          text,
          contains(
              'Sleep: Unavailable. Permission shown as granted, but read blocked.'));
      expect(text, contains('Hrv: Unavailable. Permission not granted.'));
    });

    test('maximal fixture: all zones populated, biometrics present, '
        'full metadata — exactly 1 page', () async {
      final snapshot = _snapshot(
        medications: [
          _med('Ivabradine', '7.5 mg', frequency: 'Twice daily'),
          _med('BPC-157', '0.5'),
        ],
        logEntries: [
          _entry(1, 2, _ts(10, 26, hour: 15),
              chips: '["Flare Day", "Bad", "Fog"]'),
          _entry(2, 2, _ts(10, 20), chips: '["Flare Day", "Rough", "Dizzy"]'),
          _entry(3, 3, _ts(10, 10), body: 'Migraine'),
          _entry(4, 4, _ts(10, 11), body: 'Lunch'),
        ],
        sectionMetadata: const {
          'logs': SectionMetadata('logs', DataSourceStatus.success, 4),
          'conditions':
              SectionMetadata('conditions', DataSourceStatus.success, 1),
          'medications':
              SectionMetadata('medications', DataSourceStatus.success, 2),
          'documents':
              SectionMetadata('documents', DataSourceStatus.success, 0),
          'bloodPressure': SectionMetadata(
              'bloodPressure', DataSourceStatus.success, 9),
          'sleep': SectionMetadata('sleep', DataSourceStatus.success, 24),
          'deepSleep':
              SectionMetadata('deepSleep', DataSourceStatus.success, 24),
          'heartRate':
              SectionMetadata('heartRate', DataSourceStatus.success, 24),
          'hrv': SectionMetadata('hrv', DataSourceStatus.storedOnly, 24),
          'calories':
              SectionMetadata('calories', DataSourceStatus.noData, 0),
          'hrSpikes':
              SectionMetadata('hrSpikes', DataSourceStatus.success, 12),
        },
        sleepSeries: _days24(426),
        deepSleepSeries: _days24(84),
        hrvSeries: [for (var d = 1; d <= 24; d++) (_key(10, d), 42.0)],
        heartRateSeries: _days24(62),
        heartRateSpikes: _spikeSeries(),
        bloodPressureSeries: _bpReadings(),
      );
      final scores = {
        for (var d = 1; d <= 20; d++) _key(10, d): 60,
        _key(9, 29): 60,
        _key(9, 30): 60,
      };
      // The events loader fails (null), so Z5 renders its
      // declared form — the true maximal page.
      final maximal = await ClinicianReportCollector(
        scoreLoader: () async => scores,
        eventsLoader: () async => null,
        categoriesLoader: () async => _cats,
      ).extend(snapshot, allMedications: [
        _med('Ivabradine', '7.5 mg',
            frequency: 'Twice daily', startDate: 'Oct 5, 2026'),
        _med('Escitalopram', '10 mg',
            startDate: 'Sep 1, 2026',
            endDate: 'Oct 16, 2026',
            isPresent: false,
            isArchived: true),
      ]);
      expect(maximal.medChanges, isNotEmpty);
      expect(_lines(maximal, 'Z3B').length, 7);
      final prodBytes =
          await buildClinicianPdfBytes(maximal, fonts: await _diskFonts());
      expect(_pageCount(prodBytes), 1);
      final bytes = await buildClinicianPdfBytes(maximal);
      expect(_pageCount(bytes), 1);
      final text = pdfText(bytes);
      expect(text, contains('Biometrics'));
      expect(text, contains('Average sleep: 7h6m across 24 days.'));
      expect(text, contains('Data availability:'));
    });
  });

  group('hasAnyData (Phase 4 definition)', () {
    test('biometrics-ONLY fixture (no logs, no scores, no meds) is data',
        () async {
      final data = await _extend(_snapshot(
        conditions: const [],
        sleepSeries: _days24(426),
      ));
      expect(data.snapshot.logEntries, isEmpty);
      expect(data.dailyScoreSeries, isEmpty);
      expect(data.snapshot.medications, isEmpty);
      expect(data.hasAnyData, isTrue);
    });

    test('a directly built data object carrying only a biometric '
        'summary is not empty; a fully empty one is', () {
      final emptySnapshot = _snapshot(conditions: const []);
      ClinicianReportData build({ClinicianMetricSummary? sleep}) =>
          ClinicianReportData(
            snapshot: emptySnapshot,
            dailyScoreSeries: const [],
            medChanges: const [],
            medChangesCaptured: false,
            flareDays: 0,
            flareSeverityMix: const {},
            migraineCount: 0,
            topCategories: const [],
            sleepSummary: sleep,
          );
      expect(build().hasAnyData, isFalse);
      expect(
          build(sleep: summarizeClinicianIntSeries([(_key(10, 1), 426)]))
              .hasAnyData,
          isTrue);
    });

    test('stored scores alone make hasAnyData true', () async {
      final data = await _extend(
        _snapshot(conditions: const []),
        scores: {_key(10, 15): 73},
      );
      expect(data.hasAnyData, isTrue);
    });
  });
}
