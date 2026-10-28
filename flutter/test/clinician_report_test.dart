import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Fixtures ─────────────────────────────────────────────────────
// Fixed "now": Oct 28, 2026, noon local. The 30-day range is
// Sep 29 – Oct 28, 2026 (device-local day keys).

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

MedicationEntry _med(
  String name,
  String dose, {
  String frequency = 'Once daily',
  String startDate = '',
  String endDate = 'Present',
  bool isPresent = true,
  bool isArchived = false,
  bool isDeleted = false,
}) =>
    MedicationEntry(
      name: name,
      dose: dose,
      frequency: frequency,
      startDate: startDate,
      endDate: endDate,
      isPresent: isPresent,
      isArchived: isArchived,
      isDeleted: isDeleted,
    );

/// Stored scores: Oct 1–Oct 20 at 60, Oct 21–28 unscored in the
/// base map (tests add what they need).
Map<String, int> _scores60() => {
      for (var d = 1; d <= 20; d++) _key(10, d): 60,
      _key(9, 29): 60,
      _key(9, 30): 60,
    };

ReportSnapshot _snapshot({
  List<MedicationEntry> medications = const [],
  List<QuickLogEntry> logEntries = const [],
  Map<String, SectionMetadata> sectionMetadata = const {},
}) =>
    ReportSnapshot(
      last30Days: true,
      generationTimestampMs: _nowMs,
      logEntries: logEntries,
      categoriesMap: {for (final c in _cats) c.id: c.name},
      userAge: 22,
      userGender: 'Male',
      conditions: const ['POTS'],
      medications: medications,
      sectionMetadata: sectionMetadata,
    );

ClinicianReportCollector _collector({
  Map<String, int>? scores,
  List<MedicationChangeEvent>? events,
  bool eventsFail = false,
}) =>
    ClinicianReportCollector(
      scoreLoader: () async => scores ?? _scores60(),
      eventsLoader: () async => eventsFail ? null : (events ?? []),
      categoriesLoader: () async => _cats,
    );

Future<ClinicianReportData> _extend(
  ReportSnapshot snapshot, {
  Map<String, int>? scores,
  List<MedicationChangeEvent>? events,
  bool eventsFail = false,
  List<MedicationEntry> allMedications = const [],
}) =>
    _collector(scores: scores, events: events, eventsFail: eventsFail)
        .extend(snapshot, allMedications: allMedications);

int _pageCount(List<int> bytes) {
  final text = latin1.decode(bytes);
  return RegExp(r'/Type\s*/Page(?![s\w])').allMatches(text).length;
}

List<String> _lines(ClinicianReportData data, [String? zone]) => [
      for (final l in clinicianPageLines(data))
        if (zone == null || l.zone == zone) l.text,
    ];

/// The full-data fixture: two active meds, stored scores, flare
/// days (incl. the 04:00 energy-day boundary), migraine entries,
/// declared-form changes (events fetch returns null).
Future<ClinicianReportData> _fullData() {
  final snapshot = _snapshot(
    medications: [
      _med('Ivabradine', '7.5 mg', frequency: 'Twice daily'),
      _med('BPC-157', '0.5'),
    ],
    logEntries: [
      // Two entries on ONE energy day (Oct 26): one at 15:00 and
      // one at 02:30 the next calendar day (before 04:00).
      _entry(1, 2, _ts(10, 26, hour: 15),
          chips: '["Flare Day", "Bad", "Fog"]'),
      _entry(2, 2, _ts(10, 27, hour: 2),
          chips: '["Flare Day", "Bad", "Fog"]'),
      _entry(3, 2, _ts(10, 20), chips: '["Flare Day", "Rough", "Dizzy"]'),
      _entry(4, 3, _ts(10, 10), body: 'Migraine'),
      _entry(5, 3, _ts(10, 12), body: 'Migraine'),
      _entry(6, 4, _ts(10, 11), body: 'Lunch'),
    ],
  );
  return _extend(
    snapshot,
    eventsFail: true,
    allMedications: [
      _med('Ivabradine', '7.5 mg',
          frequency: 'Twice daily', startDate: 'Oct 5, 2026'),
      _med('BPC-157', '0.5'),
      _med('Escitalopram', '10 mg',
          startDate: 'Sep 1, 2026',
          endDate: 'Oct 16, 2026',
          isPresent: false,
          isArchived: true),
    ],
  );
}

/// The production font set, read from the asset files on disk
/// (tests run with the package root as CWD). The renderer takes
/// fonts as input so it never touches rootBundle itself.
Future<ClinicianPdfFonts> _diskFonts() async =>
    clinicianPdfFontsFromBytes(
      await File('assets/fonts/Roboto-Regular.ttf').readAsBytes(),
      await File('assets/fonts/Roboto-Bold.ttf').readAsBytes(),
    );

void main() {

  group('Golden / render (spec §8 tests 1–4)', () {
    test('1. full-data fixture renders exactly 1 page', () async {
      final data = await _fullData();
      // The founder sample renders with the production font set.
      final bytes =
          await buildClinicianPdfBytes(data, fonts: await _diskFonts());
      expect(bytes.length, greaterThan(3000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(_pageCount(bytes), 1);
      // Kept sample for the founder (synthetic data only).
      final dir = Directory('${Directory.systemTemp.path}/clinician-sample');
      await dir.create(recursive: true);
      await File('${dir.path}/clinician_report_sample.pdf')
          .writeAsBytes(bytes);
    });

    test('2. content determinism: same data, same lines and page count',
        () async {
      final a = await _fullData();
      final b = await _fullData();
      expect(_lines(a), _lines(b));
      final bytesA = await buildClinicianPdfBytes(a);
      final bytesB = await buildClinicianPdfBytes(b);
      expect(_pageCount(bytesA), _pageCount(bytesB));
    });

    test('3. golden stability: the full-data line model is pinned', () async {
      final data = await _fullData();
      expect(_lines(data), [
        'Tabs Clinician Report',
        startsWith('Report range: Last 30 days (30 days) · Generated: '),
        'Age 22 · Male · Conditions: POTS',
        'Medications',
        'Ivabradine 7.5 mg (Twice daily)',
        'BPC-157 0.5 (Once daily)',
        'Daily Score',
        startsWith('Latest score: 60 on Oct 20 · Average over scored days: 60'),
        'Daily Score recorded on 22 of 30 days in this range.',
        'Flare days and migraines',
        'Flare days: 2',
        'Rough 1 · Bad 1',
        'Migraine entries: 2',
        'Most logged categories: Symptoms (3), Migraine Symptoms & Triggers (2), Food (1)',
        'Medication changes',
        'Oct 16, 2026 — Stopped Escitalopram · Date as entered in Tabs',
        'Oct 5, 2026 — Started Ivabradine · 7.5 mg · Date as entered in Tabs',
        'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. Information in this report is from your own logs. Consult a healthcare professional.',
        'Generated by Tabs · Last 30 days',
      ]);
    });

    test('3b. the TTF font is embedded, so the mandated em dash '
        'actually prints (Helvetica drops it)', () async {
      final data = await _fullData();
      final bytes =
          await buildClinicianPdfBytes(data, fonts: await _diskFonts());
      final text = latin1.decode(bytes);
      // An embedded TrueType subset rides in a FontFile2 stream;
      // the base-14 Helvetica path has none.
      expect(text, contains('/FontFile2'));
      // And the Z5 change lines still carry the verbatim em dash
      // in the line model the renderer draws from.
      expect(_lines(data, 'Z5').any((l) => l.contains('—')), isTrue);
    });

    test('4. empty-data fixture: honest empties, reserved zones absent, 1 page',
        () async {
      final data = await _extend(_snapshot(), scores: const {});
      final lines = _lines(data);
      expect(lines, contains('No active medications recorded.'));
      expect(lines, contains('No flare days recorded in this range.'));
      expect(lines, contains('No migraine entries recorded in this range.'));
      expect(lines, contains('Not enough data to display chart'));
      expect(lines,
          contains('Daily Score recorded on 0 of 30 days in this range.'));
      expect(lines, isNot(contains('Medication changes')));
      expect(lines, isNot(contains('Salt and fluids')));
      final bytes = await buildClinicianPdfBytes(data);
      expect(_pageCount(bytes), 1);
    });
  });

  group('Snapshot completeness gate (spec §8 tests 5–7)', () {
    test('5. coverage counts STORED scores only; an unscored day is a gap',
        () async {
      // Scores exist for 22 of 30 days; the other 8 days simply
      // have no stored score (their biometrics are irrelevant —
      // the loader contract is stored scores only).
      final data = await _extend(_snapshot());
      expect(data.scoredDays, 22);
      expect(
          _lines(data, 'Z3'),
          contains(
              'Daily Score recorded on 22 of 30 days in this range.'));
      expect(data.dailyScoreSeries.map((e) => e.$1),
          isNot(contains(_key(10, 25))));
    });

    test('6. below minimum: a single stored score prints as a dated value, '
        'never a trend', () async {
      final data =
          await _extend(_snapshot(), scores: {_key(10, 15): 73});
      final z3 = _lines(data, 'Z3');
      expect(z3, contains('Latest score: 73 on Oct 15'));
      expect(z3.join(' '), isNot(contains('Average over scored days')));
      expect(z3,
          contains('Daily Score recorded on 1 of 30 days in this range.'));
    });

    test('7. renderer isolation: bytes build from the data object alone',
        () async {
      final data = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final bytes = await buildClinicianPdfBytes(data);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(_pageCount(bytes), 1);
    });
  });

  group('Medication integrity — R5 (spec §8 tests 8–10)', () {
    test('8. printed list equals the verified active list exactly', () {
      final source = [
        _med('Ivabradine', '7.5 mg', frequency: 'Twice daily'),
        _med('Escitalopram', '10 mg',
            isPresent: false, isArchived: true, endDate: 'Oct 16, 2026'),
        _med('Deleted Med', '1 mg', isDeleted: true),
        _med('Ended Med', '2 mg', isPresent: false, endDate: 'Oct 1, 2026'),
      ];
      // The production filter path (collector applies the same).
      final active = activeMedicationEntries(source);
      final data = ClinicianReportData(
        snapshot: _snapshot(medications: active),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(data, 'Z2'),
          ['Medications', 'Ivabradine 7.5 mg (Twice daily)']);
    });

    test('9. archived mid-range: not active in Z2, a declared stop in Z5',
        () async {
      final esc = _med('Escitalopram', '10 mg',
          startDate: 'Sep 1, 2026',
          endDate: 'Oct 16, 2026',
          isPresent: false,
          isArchived: true);
      final data = await _extend(
        _snapshot(medications: activeMedicationEntries([esc])),
        eventsFail: true,
        allMedications: [esc],
      );
      expect(_lines(data, 'Z2'),
          ['Medications', 'No active medications recorded.']);
      expect(
          _lines(data, 'Z5'),
          contains(
              'Oct 16, 2026 — Stopped Escitalopram · Date as entered in Tabs'));
    });

    test('10. cap integrity: 25 active meds print cap + correct overflow',
        () {
      final meds = [
        for (var i = 1; i <= 25; i++) _med('Med $i', '1 mg'),
      ];
      final data = ClinicianReportData(
        snapshot: _snapshot(medications: meds),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z2 = _lines(data, 'Z2');
      expect(z2.length, 1 + clinicianMedicationCap + 1);
      expect(z2.last, '+19 more — full list in the Tabs app.');
      // The R5 diff still accounts for the FULL list:
      // printed (6) + overflow (19) == 25.
      expect(clinicianMedicationCap + 19, meds.length);
    });
  });

  group('Degradation (spec §8 tests 11–13)', () {
    test('11. pre-2a declared form; never derived from Took Med entries',
        () async {
      final snapshot = _snapshot(logEntries: [
        _entry(1, 2, _ts(10, 10), body: 'Took Med — Ivabradine 7.5 mg'),
      ]);
      final data = await _extend(
        snapshot,
        eventsFail: true,
        allMedications: [
          _med('Ivabradine', '7.5 mg', startDate: 'Oct 5, 2026'),
        ],
      );
      expect(data.medChangesCaptured, isFalse);
      final z5 = _lines(data, 'Z5');
      expect(
          z5,
          contains(
              'Oct 5, 2026 — Started Ivabradine · 7.5 mg · Date as entered in Tabs'));
      // The Took Med entry (Oct 10) produced no change line.
      expect(z5.where((l) => l.contains('—')).length, 1);
    });

    test('12. pre-item-4: no salt/fluid zone, no target line, no zeros',
        () async {
      final data = await _fullData();
      final lines = _lines(data);
      expect(lines, isNot(contains('Salt and fluids')));
      expect(lines.where((l) => l.startsWith('Targets recorded in Tabs')),
          isEmpty);
    });

    test('13. Health Connect denied: Z8 discloses it', () async {
      final snapshot = _snapshot(sectionMetadata: {
        'sleep': const SectionMetadata(
            'sleep', DataSourceStatus.permissionDenied, 0),
      });
      final data = await _extend(snapshot);
      expect(
          _lines(data, 'Z8'),
          contains(
              'Data availability: Sleep: Unavailable. Permission not granted.'));
    });
  });

  group('Latency and save/share (spec §8 tests 14–16)', () {
    test('14. pipeline: no AI call; sync-pull failure still produces the page',
        () async {
      final backend = _FakeBackend()..pullFails = true;
      final pipeline = ClinicianReportPipeline(
        collector: ReportDataCollector(
            backend: backend, hc: _FakeHcDisconnected()),
        clinicianCollector: _collector(),
      );
      List<int>? savedBytes;
      final outcome = await pipeline.generate(
        selectedCategories: _cats,
        last30Days: true,
        profile: const ReportProfileInput(),
        renderPdf: buildClinicianPdfBytes,
        savePdf: (bytes, name) async {
          savedBytes = bytes;
          return '/tmp/$name';
        },
        now: DateTime(2026, 10, 28, 12),
      );
      expect(outcome, isA<ReportReady>());
      expect(backend.aiCalls, 0);
      expect((outcome as ReportReady).isRawFallback, isFalse);
      expect(_pageCount(savedBytes!), 1);
    });

    test('15. Downloads contract: same bytes, failure carried not fatal',
        () async {
      final backend = _FakeBackend();
      final pipeline = ClinicianReportPipeline(
        collector: ReportDataCollector(
            backend: backend, hc: _FakeHcDisconnected()),
        clinicianCollector: _collector(),
      );
      List<int>? appBytes;
      List<int>? downloadsBytes;
      final outcome = await pipeline.generate(
        selectedCategories: _cats,
        last30Days: true,
        profile: const ReportProfileInput(),
        renderPdf: buildClinicianPdfBytes,
        savePdf: (bytes, name) async {
          appBytes = bytes;
          return '/tmp/$name';
        },
        saveToDownloads: (bytes, name) async {
          downloadsBytes = bytes;
          return false;
        },
        now: DateTime(2026, 10, 28, 12),
      );
      expect(outcome, isA<ReportReady>());
      expect((outcome as ReportReady).downloadsSaved, isFalse);
      expect(downloadsBytes, same(appBytes));
    });

    testWidgets('16. share flow: clinician export shows the confirmation '
        'with the Downloads disclosure', (tester) async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = _FakeBackend();
      final pipeline = ClinicianReportPipeline(
        collector: ReportDataCollector(
            backend: backend, hc: _FakeHcDisconnected()),
        clinicianCollector: _collector(),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            ProgressReportsPage(
              profileData: const SettingsProfileData(),
              backend: backend,
              store: store,
              clinicianPipeline: pipeline,
              savePdf: (bytes, name) async => '/tmp/$name',
              saveToDownloads: (bytes, name) async => true,
              sharePdf: (bytes, name) async {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      // The button sits below the fold of the default test
      // surface — scroll it into the viewport before tapping.
      await tester
          .ensureVisible(find.text('Export Clinician Report (1 page)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export Clinician Report (1 page)'));
      await tester.pumpAndSettle();
      expect(find.text('Share health report'), findsOneWidget);
      expect(
          find.text('A copy was also saved to your Downloads folder.'),
          findsOneWidget);
    });
  });

  group('Declared-form changes (spec §8 tests 17–20)', () {
    test('17. blank or unparseable startDate: no dated line, no failure',
        () async {
      final data = await _extend(
        _snapshot(),
        eventsFail: true,
        allMedications: [
          _med('Blank', '1 mg', startDate: ''),
          _med('Garbage', '1 mg', startDate: 'sometime last spring'),
        ],
      );
      expect(data.medChanges, isEmpty);
      expect(_lines(data), isNot(contains('Medication changes')));
    });

    test('17b. deleted tombstones produce no declared change lines',
        () async {
      final data = await _extend(
        _snapshot(),
        eventsFail: true,
        allMedications: [
          _med('Deleted Start', '1 mg',
              startDate: 'Oct 5, 2026', isDeleted: true),
          _med('Deleted Archived', '1 mg',
              startDate: 'Sep 1, 2026',
              endDate: 'Oct 16, 2026',
              isPresent: false,
              isArchived: true,
              isDeleted: true),
        ],
      );
      expect(data.medChanges, isEmpty);
      expect(_lines(data, 'Z5'), isEmpty);
    });

    test('18. month-precision startDate renders at month precision', () async {
      final data = await _extend(
        _snapshot(),
        eventsFail: true,
        allMedications: [
          _med('MonthMed', '1 mg', startDate: 'October 2026'),
        ],
      );
      final z5 = _lines(data, 'Z5');
      expect(
          z5,
          contains(
              'October 2026 — Started MonthMed · 1 mg · Date as entered in Tabs'));
      expect(z5.join(' '), isNot(contains('Oct 1')));
      expect(z5.join(' '), isNot(contains('October 1')));
    });

    test('19. endDate empty or Present: no stop line', () async {
      final data = await _extend(
        _snapshot(),
        eventsFail: true,
        allMedications: [
          _med('NoEnd', '1 mg',
              isPresent: false, isArchived: true, endDate: ''),
          _med('PresentEnd', '1 mg',
              isPresent: false, isArchived: true, endDate: 'Present'),
        ],
      );
      expect(data.medChanges, isEmpty);
    });

    test('20. archive-stamped endDate carries the declared label', () async {
      final data = await _extend(
        _snapshot(),
        eventsFail: true,
        allMedications: [
          _med('Escitalopram', '10 mg',
              startDate: 'Sep 1, 2026',
              endDate: 'Oct 16, 2026',
              isPresent: false,
              isArchived: true),
        ],
      );
      final line = _lines(data, 'Z5').singleWhere((l) => l.contains('—'));
      expect(line, endsWith('· Date as entered in Tabs'));
      expect(line.toLowerCase(), isNot(contains('stopped on')));
      expect(line, contains('Stopped Escitalopram'));
    });
  });

  group('Captured form + window rules (Juno D1 / Item 2 R2/R4)', () {
    MedicationChangeEvent makeEvent({
      required String type,
      required String name,
      String? effectiveDate,
      int? recordedAt,
      String oldDose = '',
      String newDose = '',
    }) =>
        MedicationChangeEvent(
          id: 'e-$name-$type',
          medId: 'id-$name',
          medName: name,
          type: type,
          oldSnapshot: MedicationFieldSnapshot(
              dose: oldDose,
              frequency: 'Once daily',
              startDate: '',
              endDate: '',
              isPresent: true),
          newSnapshot: MedicationFieldSnapshot(
              dose: newDose,
              frequency: 'Once daily',
              startDate: '',
              endDate: 'Present',
              isPresent: type != 'stop'),
          effectiveDate: effectiveDate,
          recordedAt: recordedAt ?? _ts(10, 14),
          source: 'settings',
        );

    test('captured events replace the declared form; windows print at the '
        'D1 floor with no delta anywhere', () async {
      // Dose change Oct 14; scores 60 for 14 days before (change
      // day in AFTER for dose changes: before = Sep 30–Oct 13,
      // after = Oct 14–27). Give after-window days scores too.
      final scores = {
        for (var d = 29; d <= 30; d++) _key(9, d): 60,
        for (var d = 1; d <= 27; d++) _key(10, d): 60,
      };
      final data = await _extend(
        _snapshot(),
        scores: scores,
        events: [
          makeEvent(
              type: 'dose_change',
              name: 'Ivabradine',
              oldDose: '5 mg',
              newDose: '7.5 mg',
              recordedAt: _ts(10, 14)),
        ],
        allMedications: [
          _med('Ivabradine', '7.5 mg', startDate: 'Oct 5, 2026'),
        ],
      );
      expect(data.medChangesCaptured, isTrue);
      final z5 = _lines(data, 'Z5');
      expect(
          z5,
          contains(
              'Oct 14, 2026 — Ivabradine dose changed from 5 mg to 7.5 mg · Recorded in Tabs'));
      final windowLine = z5.firstWhere((l) => l.startsWith('Average'));
      expect(
          windowLine,
          'Average Daily Score, 14 days before: 60 · 14 scored days. '
          'Average Daily Score, 14 days after: 60 · 14 scored days.');
      // No delta, no arrow, no percent (Item 2 · R2).
      expect(z5.join(' '), isNot(contains('+')));
      expect(z5.join(' '), isNot(contains('%')));
      // The declared start line does NOT also print.
      expect(z5.join(' '), isNot(contains('Date as entered in Tabs')));
    });

    test('below the D1 floor: the change line prints, no averages', () async {
      final data = await _extend(
        _snapshot(),
        scores: {_key(10, 14): 60, _key(10, 15): 61},
        events: [
          makeEvent(
              type: 'dose_change',
              name: 'Ivabradine',
              oldDose: '5 mg',
              newDose: '7.5 mg',
              recordedAt: _ts(10, 14)),
        ],
      );
      final z5 = _lines(data, 'Z5');
      expect(z5.any((l) => l.contains('dose changed')), isTrue);
      expect(z5.any((l) => l.startsWith('Average')), isFalse);
    });

    test('window rule: a stop counts its change day in the BEFORE window',
        () {
      // Scores: Oct 1 (change day) = 90, after-window days at 60.
      // Stop on Oct 14: before = Oct 1..14, after = Oct 15..28.
      final scores = {
        for (var d = 1; d <= 28; d++) _key(10, d): 60,
        _key(10, 14): 90,
      };
      final w = computeMedChangeWindows(
        changeDay: DateTime(2026, 10, 14),
        changeDayInAfter: false,
        scores: scores,
      );
      expect(w, isNotNull);
      // Before average includes the 90: (13*60 + 90)/14 = 62.1.
      expect(w!.before.scoredDays, 14);
      expect(w.before.average, closeTo(62.14, 0.01));
      expect(w.after.scoredDays, 14);
      expect(w.after.average, 60);
    });

    test('S6 required at full coverage too (Juno R4)', () async {
      final scores = {
        for (var d = 29; d <= 30; d++) _key(9, d): 55,
        for (var d = 1; d <= 28; d++) _key(10, d): 55,
      };
      final data = await _extend(_snapshot(), scores: scores);
      expect(
          _lines(data, 'Z3'),
          contains(
              'Daily Score recorded on 30 of 30 days in this range.'));
    });

    test('S10 renders only from its helper with recorded targets', () {
      expect(
        clinicianTargetsLine(
            electrolyteTarget: '6,000 mg electrolytes',
            fluidTarget: '1 gallon of water'),
        'Targets recorded in Tabs: 6,000 mg electrolytes and 1 gallon of water daily.',
      );
    });
  });
}

// ── Fakes ────────────────────────────────────────────────────────

class _FakeBackend extends TabsBackend {
  bool pullFails = false;
  int aiCalls = 0;

  _FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      pullFails ? null : <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => _cats;

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];

  @override
  Future<
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      })> postAiDetailed(String path, Map<String, dynamic> body,
      {Duration? timeoutOverride}) async {
    aiCalls++;
    return (
      statusCode: 200,
      body: {'result': 'unused'},
      serverError: null,
      transportFailure: null,
    );
  }
}

class _FakeHcDisconnected extends HealthConnectService {
  @override
  Future<bool> isConnected() async => false;
}
