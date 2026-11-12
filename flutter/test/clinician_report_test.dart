import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medication_timeline.dart';
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
  Map<int, String>? categoriesMap,
  int userAge = 22,
  String userGender = 'Male',
  double userHeightIn = 0,
  double userWeightLbs = 0,
  List<String> conditions = const ['POTS'],
  List<(String, int)> sleepSeries = const [],
  List<(String, int)> deepSleepSeries = const [],
  List<(String, int)> heartRateSeries = const [],
  List<(String, double)> hrvSeries = const [],
  List<(String, int)> heartRateSpikes = const [],
}) =>
    ReportSnapshot(
      last30Days: true,
      generationTimestampMs: _nowMs,
      logEntries: logEntries,
      categoriesMap: categoriesMap ?? {for (final c in _cats) c.id: c.name},
      userAge: userAge,
      userGender: userGender,
      userHeightIn: userHeightIn,
      userWeightLbs: userWeightLbs,
      conditions: conditions,
      medications: medications,
      sectionMetadata: sectionMetadata,
      sleepSeries: sleepSeries,
      deepSleepSeries: deepSleepSeries,
      heartRateSeries: heartRateSeries,
      hrvSeries: hrvSeries,
      heartRateSpikes: heartRateSpikes,
    );

ClinicianReportCollector _collector({
  Map<String, int>? scores,
  List<MedicationChangeEvent>? events,
  bool eventsFail = false,
  bool scoreFail = false,
  bool categoriesFail = false,
}) =>
    ClinicianReportCollector(
      scoreLoader: () async {
        if (scoreFail) throw StateError('scoreLoader failed');
        return scores ?? _scores60();
      },
      eventsLoader: () async => eventsFail ? null : (events ?? []),
      categoriesLoader: () async {
        if (categoriesFail) throw StateError('categoriesLoader failed');
        return _cats;
      },
    );

Future<ClinicianReportData> _extend(
  ReportSnapshot snapshot, {
  Map<String, int>? scores,
  List<MedicationChangeEvent>? events,
  bool eventsFail = false,
  bool scoreFail = false,
  bool categoriesFail = false,
  List<MedicationEntry> allMedications = const [],
}) =>
    _collector(
      scores: scores,
      events: events,
      eventsFail: eventsFail,
      scoreFail: scoreFail,
      categoriesFail: categoriesFail,
    ).extend(snapshot, allMedications: allMedications);

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
  // Report Reliability Phase 1 harness note: with the collector's
  // isConnected() gate deleted, collect() always runs the union
  // load — which reads the shared history store. Like
  // progress_report_r66_test.dart, install an in-memory backing
  // on the singleton and reset it per test so no case touches the
  // secure-storage platform channel (whose replies cannot land
  // inside a widget test's fake-async zone; at base the gate had
  // kept collect() from ever reaching the store).
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

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
      expect(lines, contains('Medication changes'));
      expect(lines,
          contains('No medication changes recorded in audit period'));
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

    test('13. Health Connect stale: Z8 discloses it truthfully', () async {
      // RE-PIN (Report Reliability Phase 1): this test previously
      // pinned Z8 printing 'Unavailable. Permission not granted.'
      // for a sleep section the collector had blanket-denied via
      // the isConnected() gate — a false denial (no read was ever
      // attempted). The gate is deleted; the state that replaces
      // it for a granted-but-blocked read is `stale`, and Z8 must
      // print Juno's ruled stale line (SIGN, Phase 1), byte-exact.
      final snapshot = _snapshot(sectionMetadata: {
        'sleep': const SectionMetadata('sleep', DataSourceStatus.stale, 0),
      });
      final data = await _extend(snapshot);
      expect(
          _lines(data, 'Z8'),
          contains(
              'Data availability: Sleep: Unavailable. Permission shown as granted, but read blocked.'));
    });

    test('13b. a TRUE per-metric denial still prints the denial line in Z8',
        () async {
      // Phase 1 keeps permissionDenied for the one case where it
      // is true: the metric's own permission is missing from the
      // live granted set and its read failed.
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

    // VC 100109 combine — Q7 premium gate tests (the merge gate
    // from the item-3 build's Vera conditions).
    testWidgets('16b. premium gate: non-premium cannot generate the '
        'one-page clinician report', (tester) async {
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
              clinicianPremiumCheck: () async => false,
              savePdf: (bytes, name) async => '/tmp/$name',
              saveToDownloads: (bytes, name) async => true,
              sharePdf: (bytes, name) async {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      final buttonFinder = find.ancestor(
        of: find.text('Export Clinician Report (1 page)'),
        matching: find.byType(OutlinedButton),
      );
      expect(buttonFinder, findsOneWidget);
      // Locked: the button is disabled and carries the lock icon.
      expect(tester.widget<OutlinedButton>(buttonFinder).onPressed,
          isNull);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      // A tap attempt generates nothing: no share confirmation.
      await tester.ensureVisible(find.text('Export Clinician Report (1 page)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export Clinician Report (1 page)'),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Share health report'), findsNothing);
    });

    testWidgets('16c. premium gate: a failed entitlement check is '
        'fail-closed (locked, no generation)', (tester) async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = _FakeBackend();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            ProgressReportsPage(
              profileData: const SettingsProfileData(),
              backend: backend,
              store: store,
              clinicianPremiumCheck: () async =>
                  throw StateError('membership unreachable'),
              savePdf: (bytes, name) async => '/tmp/$name',
              saveToDownloads: (bytes, name) async => true,
              sharePdf: (bytes, name) async {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      final buttonFinder = find.ancestor(
        of: find.text('Export Clinician Report (1 page)'),
        matching: find.byType(OutlinedButton),
      );
      expect(tester.widget<OutlinedButton>(buttonFinder).onPressed,
          isNull);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
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
      expect(_lines(data), contains('Medication changes'));
      expect(_lines(data),
          contains('No medication changes recorded in audit period'));
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
      expect(_lines(data, 'Z5'), contains('Medication changes'));
      expect(_lines(data, 'Z5'),
          contains('No medication changes recorded in audit period'));
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
      // Dose change Oct 14; scores 60 throughout (change day in
      // AFTER for dose changes: before nominally Sep 30–Oct 13,
      // after = Oct 14–27). The medication list below declares
      // an Oct 5 start, which the panel seeds and which now
      // bounds Z5 identically (Juno condition): the before
      // window truncates at the declared start's regimen,
      // Oct 5–13 = 9 scored days, average unchanged at 60
      // because every scored day is 60.
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
          'Average Daily Score, 14 days before: 60 · 9 scored days. '
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

    test('window rule: a stop counts its change day in the BEFORE window '
        '(UNIFIED semantics — supersedes the old duplicate computation)',
        () async {
      // UPDATED for the Z5 unification: this test previously
      // drove the private `computeMedChangeWindows` duplicate
      // and expected its one-decimal average (62.14). Z5 now
      // runs item 2's computeMedicationWindows, so the same
      // fixture yields the panel's whole-number average (62).
      // Scores: Oct 14 (change day) = 90, all other days 60.
      // Stop on Oct 14: before = Oct 1..14, after = Oct 15..28.
      final scores = <String, int?>{
        for (var d = 1; d <= 28; d++) _key(10, d): 60,
        _key(10, 14): 90,
      };
      final data = await _extend(
        _snapshot(),
        scores: {for (final e in scores.entries) e.key: e.value!},
        events: [
          makeEvent(
              type: 'stop',
              name: 'Ivabradine',
              oldDose: '7.5 mg',
              recordedAt: _ts(10, 14)),
        ],
      );
      final change = data.medChanges.single;
      // Before average includes the 90: (13*60 + 90)/14 = 62.14,
      // printed by the panel (and now by Z5) as the whole number 62.
      expect(change.beforeWindow!.scoredDays, 14);
      expect(change.beforeWindow!.average, 62);
      expect(change.afterWindow!.scoredDays, 14);
      expect(change.afterWindow!.average, 60);
      final z5 = _lines(data, 'Z5');
      expect(
        z5,
        contains('Average Daily Score, 14 days before: 62 · 14 scored '
            'days. Average Daily Score, 14 days after: 60 · 14 scored days.'),
      );
      expect(z5.join(' '), isNot(contains('62.1')));
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

  group('Z5 unification: PDF windows ARE the item 2 panel windows', () {
    MedicationChangeEvent ev({
      required String id,
      required String type,
      required DateTime recorded,
      String? effectiveDate,
    }) =>
        MedicationChangeEvent(
          id: id,
          medId: 'm1',
          medName: 'MedA',
          type: type,
          oldSnapshot: const MedicationFieldSnapshot(
              dose: '5 mg',
              frequency: 'Once daily',
              startDate: '',
              endDate: '',
              isPresent: true),
          newSnapshot: MedicationFieldSnapshot(
              dose: '5 mg',
              frequency: 'Once daily',
              startDate: '',
              endDate: '',
              isPresent: type != 'stop'),
          effectiveDate: effectiveDate,
          recordedAt: recorded.millisecondsSinceEpoch,
          source: 'settings',
        );

    // The panel surface for the same fixture: item 2's timeline
    // derivation over the same events, the same medication list
    // (its seeded rows included), and the same stored-score map,
    // read through its §5 handoff (changeSummaries), which runs
    // the identical windowsFor the panel renders.
    MedicationTimelineData panel(
            List<MedicationChangeEvent> events, Map<String, int?> scores,
            {List<MedicationEntry> medications = const []}) =>
        buildMedicationTimeline(
          events: events,
          medications: medications,
          scoresByDate: scores,
          entries: const [],
          categories: const [],
          today: DateTime(2026, 10, 28),
        );

    void expectAgreement(
      List<MedicationChangeEvent> events,
      Map<String, int?> scores, {
      List<MedicationEntry> medications = const [],
      required DateTime rangeStart,
      required DateTime rangeEnd,
    }) {
      final changes = deriveCapturedMedChanges(
        events,
        medications: medications,
        scores: scores,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );
      final data = panel(events, scores, medications: medications);
      // Z5 prints CAPTURED changes only — seeded panel markers
      // bound the windows but produce no Z5 line — so agreement
      // is asserted over the panel's captured summaries.
      final summaries = data
          .changeSummaries(data.rangeStart, data.rangeEnd)
          .where((s) => !s.seeded)
          .toList();
      expect(changes.length, summaries.length);
      for (final summary in summaries) {
        // Match on day AND change kind (the Z5 label carries the
        // kind) — two changes can share one day.
        bool matches(ClinicianMedChange c) =>
            c.day == summary.date &&
            switch (summary.eventType) {
              'start' => c.label.startsWith('Started'),
              'stop' => c.label.startsWith('Stopped'),
              'dose_change' => c.label.contains('dose changed'),
              'frequency_change' => c.label.contains('schedule changed'),
              'restore' => c.label.startsWith('Restarted'),
              _ => false,
            };
        final change = changes.singleWhere(matches);
        expect(change.beforeWindow?.average, summary.windows.beforeAverage,
            reason: 'before average for ${summary.eventType} '
                'on ${summary.date}');
        expect(change.afterWindow?.average, summary.windows.afterAverage,
            reason: 'after average for ${summary.eventType} '
                'on ${summary.date}');
        if (summary.windows.floorMet) {
          expect(change.beforeWindow?.scoredDays,
              summary.windows.beforeScoredDays);
          expect(change.afterWindow?.scoredDays,
              summary.windows.afterScoredDays);
        } else {
          expect(change.beforeWindow, isNull);
          expect(change.afterWindow, isNull);
        }
      }
    }

    test('neighboring change inside the window truncates at the REGIMEN '
        'boundary (11 scored days — the old anchor-exclusive duplicate '
        'gave 10)', () {
      final events = [
        ev(
            id: 'e-start',
            type: 'start',
            effectiveDate: 'Sep 10, 2026',
            recorded: DateTime(2026, 9, 10, 9)),
        ev(
            id: 'e-stop',
            type: 'stop',
            effectiveDate: 'Sep 20, 2026',
            recorded: DateTime(2026, 9, 20, 9)),
      ];
      final scores = <String, int?>{
        for (var d = 1; d <= 9; d++) _key(9, d): 60,
        for (var d = 10; d <= 19; d++) _key(9, d): 70,
        _key(9, 20): 75,
        for (var d = 21; d <= 30; d++) _key(9, d): 50,
        for (var d = 1; d <= 4; d++) _key(10, d): 50,
      };
      final changes = deriveCapturedMedChanges(
        events,
        medications: const [],
        scores: scores,
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 10, 31),
      );
      final start = changes.singleWhere((c) => c.day == DateTime(2026, 9, 10));
      // Before: Sep 1–9 (series edge clips Aug 27 start) = 9 × 60.
      expect(start.beforeWindow, (average: 60, scoredDays: 9));
      // After: Sep 10–20 — the stop day belongs to the stop's
      // BEFORE regimen, so the start's after window runs THROUGH
      // Sep 20: (10×70 + 75) / 11 = 70.45 → whole number 70.
      expect(start.afterWindow, (average: 70, scoredDays: 11));
      final stop = changes.singleWhere((c) => c.day == DateTime(2026, 9, 20));
      // Before: Sep 10–20 (bounded below by the start's regimen).
      expect(stop.beforeWindow, (average: 70, scoredDays: 11));
      // After: Sep 21 – Oct 4 = 14 × 50.
      expect(stop.afterWindow, (average: 50, scoredDays: 14));
      expectAgreement(events, scores,
          rangeStart: DateTime(2026, 9, 1), rangeEnd: DateTime(2026, 10, 31));
    });

    test('change-day ownership + non-whole average: dose change day '
        'counts in AFTER and 53.57 prints as the panel whole number 54',
        () {
      final events = [
        ev(
            id: 'e-dose',
            type: 'dose_change',
            recorded: DateTime(2026, 10, 14, 9)),
      ];
      final scores = <String, int?>{
        for (var d = 1; d <= 13; d++) _key(10, d): 50,
        _key(10, 14): 100, // the change day itself
        for (var d = 15; d <= 28; d++) _key(10, d): 50,
      };
      final changes = deriveCapturedMedChanges(
        events,
        medications: const [],
        scores: scores,
        rangeStart: DateTime(2026, 10, 1),
        rangeEnd: DateTime(2026, 10, 31),
      );
      final change = changes.single;
      // Before: Oct 1–13 (series edge) = 13 × 50 — the 100 on the
      // change day is NOT in the before window.
      expect(change.beforeWindow, (average: 50, scoredDays: 13));
      // After: Oct 14–27 = (100 + 13×50) / 14 = 53.57 → 54.
      expect(change.afterWindow, (average: 54, scoredDays: 14));
      expectAgreement(events, scores,
          rangeStart: DateTime(2026, 10, 1), rangeEnd: DateTime(2026, 10, 31));
    });

    test('same-day neighboring changes bound each other: the D1 floor '
        'fails identically on both surfaces (no Z5 averages)', () {
      final events = [
        ev(
            id: 'e-dose',
            type: 'dose_change',
            recorded: DateTime(2026, 10, 15, 9)),
        ev(
            id: 'e-stop',
            type: 'stop',
            effectiveDate: 'Oct 15, 2026',
            recorded: DateTime(2026, 10, 15, 18)),
      ];
      final scores = <String, int?>{
        for (var d = DateTime(2026, 9, 20);
            !d.isAfter(DateTime(2026, 11, 15));
            d = DateTime(d.year, d.month, d.day + 1))
          _key(d.month, d.day): 60,
      };
      final data = panel(events, scores);
      final dose = data.markers
          .firstWhere((m) => m.kind == TimelineMarkerKind.doseChange);
      final stop = data.markers
          .firstWhere((m) => m.kind == TimelineMarkerKind.stop);
      // The panel's own spans: each window is cut to the single
      // shared day by the other change.
      expect(data.windowsFor(dose, 14).afterSpanDays, 1);
      expect(data.windowsFor(stop, 14).beforeSpanDays, 1);
      expect(data.windowsFor(dose, 14).floorMet, isFalse);
      expect(data.windowsFor(stop, 14).floorMet, isFalse);
      final changes = deriveCapturedMedChanges(
        events,
        medications: const [],
        scores: scores,
        rangeStart: DateTime(2026, 10, 1),
        rangeEnd: DateTime(2026, 10, 31),
      );
      expect(changes, hasLength(2));
      for (final change in changes) {
        expect(change.beforeWindow, isNull);
        expect(change.afterWindow, isNull);
      }
      expectAgreement(events, scores,
          rangeStart: DateTime(2026, 10, 1), rangeEnd: DateTime(2026, 10, 31));
    });

    test('boundary fixture (Juno condition): a declared (seeded) start '
        'inside a captured dose change\'s before-window bounds Z5 '
        'exactly as the panel bounds it', () {
      // Juno's divergence shape: MedA's declared start is Sep 1
      // (seeded from the medication list, never captured) and a
      // captured dose change lands Sep 10. The panel bounds the
      // dose change's before-window at Sep 1 (9 days); a
      // captured-only bounding set ran the full 14 days across
      // the start.
      final medications = [
        MedicationEntry(
          id: 'm1',
          name: 'MedA',
          dose: '5 mg',
          frequency: 'Once daily',
          startDate: 'Sep 1, 2026',
          endDate: 'Present',
          isPresent: true,
        ),
      ];
      final events = [
        ev(
            id: 'e-dose',
            type: 'dose_change',
            recorded: DateTime(2026, 9, 10, 9)),
      ];
      // Scores arranged so the bounding CHANGES the result: the
      // five pre-start days (Aug 27–31) score 100, the bounded
      // before-window days (Sep 1–9) score 50, the after window
      // (Sep 10–23) scores 70. Unbounded, the before average
      // would be (5×100 + 9×50) / 14 = 67.86 → 68 over 14 scored
      // days; bounded, it is 50 over 9 scored days.
      final scores = <String, int?>{
        for (var d = 27; d <= 31; d++) _key(8, d): 100,
        for (var d = 1; d <= 9; d++) _key(9, d): 50,
        for (var d = 10; d <= 23; d++) _key(9, d): 70,
      };
      final changes = deriveCapturedMedChanges(
        events,
        medications: medications,
        scores: scores,
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 10, 31),
      );
      // The seeded start is bounding ONLY: it prints no Z5 line
      // in captured form — the one printed change is the
      // captured dose change.
      expect(changes, hasLength(1));
      final change = changes.single;
      expect(change.captured, isTrue);
      expect(change.day, DateTime(2026, 9, 10));
      expect(change.label, contains('dose changed'));
      // Bounded values: before Sep 1–9 = 9 × 50; after
      // Sep 10–23 = 14 × 70. Floor outcome: MET (9 ≥ 5,
      // 14 ≥ 5, 23 ≥ 14) — averages exist at all only because
      // the floor is met on the bounded counts.
      expect(change.beforeWindow, (average: 50, scoredDays: 9));
      expect(change.afterWindow, (average: 70, scoredDays: 14));
      // The fixture is bounding-sensitive: over a captured-only
      // marker set the same computation gives the divergent
      // before result (68 over 14) Juno flagged.
      final capturedOnly = computeMedicationWindows(
        marker: capturedTimelineMarker(events.single)!,
        allMarkers: [capturedTimelineMarker(events.single)!],
        scoresByDate: scores,
        windowDays: 14,
      );
      expect(capturedOnly.beforeAverage, 68);
      expect(capturedOnly.beforeScoredDays, 14);
      // Panel agreement over the identical inputs (averages,
      // scored-day counts, floor outcome), with the panel's
      // seeded summary present and marked seeded.
      final data = panel(events, scores, medications: medications);
      final summaries =
          data.changeSummaries(data.rangeStart, data.rangeEnd);
      final seededSummary = summaries.singleWhere((s) => s.seeded);
      expect(seededSummary.eventType, 'start');
      expect(seededSummary.date, DateTime(2026, 9, 1));
      final capturedSummary = summaries.singleWhere((s) => !s.seeded);
      expect(capturedSummary.windows.floorMet, isTrue);
      expect(capturedSummary.windows.beforeAverage, 50);
      expect(capturedSummary.windows.beforeScoredDays, 9);
      expect(capturedSummary.windows.afterAverage, 70);
      expect(capturedSummary.windows.afterScoredDays, 14);
      expectAgreement(events, scores,
          medications: medications,
          rangeStart: DateTime(2026, 9, 1),
          rangeEnd: DateTime(2026, 10, 31));
    });
  });

  group('Phase 4 truth matrix, part 1', () {
    test(
        '(1) extend with scoreFail: dailyScore has status error and Z8 discloses it',
        () async {
      final data = await _extend(_snapshot(), scoreFail: true);
      expect(data.snapshot.sectionMetadata['dailyScore']?.status,
          DataSourceStatus.error);
      final z8 = _lines(data, 'Z8');
      expect(
          z8.any((l) => l.contains(
              'Daily Score: Unavailable. Data could not be retrieved.')),
          isTrue);
      expect(
          z8,
          contains(
              'Data availability: Daily Score: Unavailable. Data could not be retrieved.'));
    });

    test(
        '(2) extend score status: empty scores give noData, default scores give success with recordCount',
        () async {
      final noData = await _extend(_snapshot(), scores: const {});
      expect(noData.snapshot.sectionMetadata['dailyScore']?.status,
          DataSourceStatus.noData);

      final success = await _extend(_snapshot());
      expect(success.snapshot.sectionMetadata['dailyScore']?.status,
          DataSourceStatus.success);
      expect(success.snapshot.sectionMetadata['dailyScore']?.recordCount,
          success.scoredDays);
    });

    test(
        '(3) extend with categoriesFail: resolution falls back to snapshot categoriesMap',
        () async {
      final snapshot = _snapshot(
        categoriesMap: const {99: 'Migraine Symptoms & Triggers'},
        logEntries: [
          _entry(1, 99, _ts(10, 10)),
          _entry(2, 99, _ts(10, 12)),
        ],
      );
      final data = await _extend(snapshot, categoriesFail: true);
      expect(data.categoriesLoadFailed, isTrue);
      expect(data.migraineCount, 2);
    });

    test(
        '(4) Z1: all demographic fields absent gives Patient profile details not recorded',
        () {
      final data = ClinicianReportData(
        snapshot: _snapshot(
          userAge: 0,
          userGender: '',
          userHeightIn: 0,
          userWeightLbs: 0,
          conditions: const [],
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(data, 'Z1'),
          contains('Patient profile details not recorded'));
    });

    test(
        '(5) Z2: medications status error gives Medication records unavailable, success gives No active medications recorded.',
        () {
      final errorData = ClinicianReportData(
        snapshot: _snapshot(
          medications: const [],
          sectionMetadata: const {
            'medications':
                SectionMetadata('medications', DataSourceStatus.error, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(errorData, 'Z2'),
          contains('Medication records unavailable'));

      final successData = ClinicianReportData(
        snapshot: _snapshot(
          medications: const [],
          sectionMetadata: const {
            'medications':
                SectionMetadata('medications', DataSourceStatus.success, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(successData, 'Z2'),
          contains('No active medications recorded.'));
    });

    test(
        '(6) Z4: logs error gives only Log entries unavailable; categoriesLoadFailed gives Categories could not be retrieved.; empty top gives No category entries recorded in this range.',
        () {
      final logsErrorData = ClinicianReportData(
        snapshot: _snapshot(
          sectionMetadata: const {
            'logs': SectionMetadata('logs', DataSourceStatus.error, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 3,
        flareSeverityMix: const {'Rough': 3},
        migraineCount: 2,
        topCategories: const [(name: 'Symptoms', count: 3)],
      );
      expect(_lines(logsErrorData, 'Z4'), [
        'Flare days and migraines',
        'Log entries unavailable',
      ]);

      final catFailData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
        categoriesLoadFailed: true,
      );
      expect(_lines(catFailData, 'Z4'),
          contains('Categories could not be retrieved.'));

      final emptyTopData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
        categoriesLoadFailed: false,
      );
      expect(_lines(emptyTopData, 'Z4'),
          contains('No category entries recorded in this range.'));
    });

    test(
        '(7) Z5: empty medChanges has heading and A4; medChangesCaptured true with null windows has Insufficient score data; false does not',
        () {
      final emptyChangesData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z5Empty = _lines(emptyChangesData, 'Z5');
      expect(z5Empty, contains('Medication changes'));
      expect(z5Empty,
          contains('No medication changes recorded in audit period'));

      final change = ClinicianMedChange(
        day: DateTime(2026, 10, 10),
        dateLabel: 'Oct 10, 2026',
        label: 'Started Ivabradine',
        captured: true,
        beforeWindow: null,
        afterWindow: null,
      );
      final capturedNullWindowsData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: [change],
        medChangesCaptured: true,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z5Captured = _lines(capturedNullWindowsData, 'Z5');
      expect(z5Captured,
          contains('Insufficient score data for 14-day comparison'));

      final declaredNullWindowsData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: [change],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z5Declared = _lines(declaredNullWindowsData, 'Z5');
      expect(z5Declared,
          isNot(contains('Insufficient score data for 14-day comparison')));
    });
  });

  group('Phase 4 truth matrix, part 2', () {
    test('(1) Sleep zone status matrix for total sleep', () {
      final sampleSleep = [(_key(10, 20), 480), (_key(10, 21), 420)];

      final successData = ClinicianReportData(
        snapshot: _snapshot(
          sleepSeries: sampleSleep,
          sectionMetadata: const {
            'sleep': SectionMetadata('sleep', DataSourceStatus.success, 2),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z9Success = _lines(successData, 'Z9');
      expect(
          z9Success.any((l) => l.startsWith('Sleep Duration: average')), isTrue);

      final storedData = ClinicianReportData(
        snapshot: _snapshot(
          sleepSeries: sampleSleep,
          sectionMetadata: const {
            'sleep': SectionMetadata('sleep', DataSourceStatus.storedOnly, 2),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z9Stored = _lines(storedData, 'Z9');
      expect(
          z9Stored.any((l) => l.startsWith('Sleep Duration: average')), isTrue);

      final noData = ClinicianReportData(
        snapshot: _snapshot(
          sleepSeries: const [],
          sectionMetadata: const {
            'sleep': SectionMetadata('sleep', DataSourceStatus.noData, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(noData, 'Z9'), contains('No sleep recorded in this range.'));

      for (final status in [
        DataSourceStatus.permissionDenied,
        DataSourceStatus.stale,
        DataSourceStatus.error,
      ]) {
        final failureData = ClinicianReportData(
          snapshot: _snapshot(
            sleepSeries: sampleSleep,
            sectionMetadata: {
              'sleep': SectionMetadata('sleep', status, 0),
            },
          ),
          dailyScoreSeries: const [],
          medChanges: const [],
          medChangesCaptured: false,
          flareDays: 0,
          flareSeverityMix: const {},
          migraineCount: 0,
          topCategories: const [],
        );
        expect(
          _lines(failureData, 'Z9'),
          contains('Sleep data could not be retrieved for this period.'),
        );
      }

      final emptySuccessData = ClinicianReportData(
        snapshot: _snapshot(
          sleepSeries: const [],
          sectionMetadata: const {
            'sleep': SectionMetadata('sleep', DataSourceStatus.success, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z9EmptySuccess = _lines(emptySuccessData, 'Z9');
      expect(z9EmptySuccess, contains('No sleep recorded in this range.'));
      expect(z9EmptySuccess.any((l) => l.startsWith('Sleep Duration:')), isFalse);
    });

    test(
        '(2) Deep sleep independence: sleep success with data plus deepSleep status error gives sleep summary and deep sleep unavailable',
        () {
      final data = ClinicianReportData(
        snapshot: _snapshot(
          sleepSeries: [(_key(10, 20), 480)],
          deepSleepSeries: const [],
          sectionMetadata: const {
            'sleep': SectionMetadata('sleep', DataSourceStatus.success, 1),
            'deepSleep':
                SectionMetadata('deepSleep', DataSourceStatus.error, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z9 = _lines(data, 'Z9');
      expect(z9.any((l) => l.startsWith('Sleep Duration: average')), isTrue);
      expect(z9,
          contains('Deep sleep data could not be retrieved for this period.'));
    });

    test('(3) HRV zone: success with data, noData, and error', () {
      final successData = ClinicianReportData(
        snapshot: _snapshot(
          hrvSeries: [(_key(10, 20), 45.0)],
          sectionMetadata: const {
            'hrv': SectionMetadata('hrv', DataSourceStatus.success, 1),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z10Success = _lines(successData, 'Z10');
      expect(
          z10Success.any((l) => l.startsWith('HRV (RMSSD): average')), isTrue);

      final noDataReport = ClinicianReportData(
        snapshot: _snapshot(
          hrvSeries: const [],
          sectionMetadata: const {
            'hrv': SectionMetadata('hrv', DataSourceStatus.noData, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(noDataReport, 'Z10'),
          contains('No HRV (RMSSD) recorded in this range.'));

      final errorData = ClinicianReportData(
        snapshot: _snapshot(
          hrvSeries: const [],
          sectionMetadata: const {
            'hrv': SectionMetadata('hrv', DataSourceStatus.error, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(errorData, 'Z10'),
          contains('HRV (RMSSD) data could not be retrieved for this period.'));
    });

    test('(4) Heart Rate zone: resting HR and spike status matrix', () {
      final hrData = ClinicianReportData(
        snapshot: _snapshot(
          heartRateSeries: [(_key(10, 20), 72), (_key(10, 21), 74)],
          heartRateSpikes: [
            (_key(10, 20), 0),
            (_key(10, 21), 0),
            (_key(10, 22), 0),
          ],
          sectionMetadata: const {
            'heartRate':
                SectionMetadata('heartRate', DataSourceStatus.success, 2),
            'hrSpikes':
                SectionMetadata('hrSpikes', DataSourceStatus.success, 3),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      final z11 = _lines(hrData, 'Z11');
      expect(z11.any((l) => l.startsWith('Resting Heart Rate: average')), isTrue);
      expect(z11, contains('Resting Heart Rate'));
      expect(_lines(hrData).any((l) => l.contains('Avg Heart Rate')), isFalse);

      expect(z11, contains('HR Spikes (>=100 BPM): 0 recorded across 3 days'));
      expect(z11,
          isNot(contains('No heart rate spike data recorded in this range.')));

      final spikesNoData = ClinicianReportData(
        snapshot: _snapshot(
          heartRateSpikes: const [],
          sectionMetadata: const {
            'hrSpikes':
                SectionMetadata('hrSpikes', DataSourceStatus.noData, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(spikesNoData, 'Z11'),
          contains('No heart rate spike data recorded in this range.'));

      final spikesError = ClinicianReportData(
        snapshot: _snapshot(
          heartRateSpikes: const [],
          sectionMetadata: const {
            'hrSpikes':
                SectionMetadata('hrSpikes', DataSourceStatus.error, 0),
          },
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
      );
      expect(_lines(spikesError, 'Z11'),
          contains('HR spike data could not be retrieved for this period.'));
    });

    test(
        '(5) Patterns zone: comparison sentence, empty patterns, and patternsLoadFailed',
        () {
      const groupA = InsightGroup(label: '8+ hrs sleep', n: 12, mean: 78.5);
      const groupB = InsightGroup(label: '<7 hrs sleep', n: 10, mean: 55.0);
      final record = InsightRecord(
        familyId: 'F1',
        splitId: 'F1a',
        windowKey: 'last90d',
        state: InsightState.numbers,
        groups: const [groupA, groupB],
        computedAtMs: _nowMs,
        throughDate: _key(10, 28),
        inputFingerprint: 'fp',
      );

      final dataWithPatterns = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
        patternInsights: [record],
        patternsLoadFailed: false,
      );

      final expectedSentence = correlationComparisonSentence(
        groupALabel: groupA.label,
        groupAN: groupA.n,
        groupAMean: groupA.mean!,
        groupBLabel: groupB.label,
        groupBN: groupB.n,
        groupBMean: groupB.mean!,
      );

      expect(_lines(dataWithPatterns, 'Z12'), contains(expectedSentence));

      final emptyPatternsData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
        patternInsights: const [],
        patternsLoadFailed: false,
      );
      expect(_lines(emptyPatternsData, 'Z12'),
          contains('No patterns detected for this period'));

      final failedPatternsData = ClinicianReportData(
        snapshot: _snapshot(),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
        patternInsights: const [],
        patternsLoadFailed: true,
      );
      expect(_lines(failedPatternsData, 'Z12'),
          contains('Patterns data could not be retrieved.'));
    });

    test(
        '(6) Geometry pins: maximally populated fixture and all-unavailable fixture both render to 1 page',
        () async {
      final baseData = await _fullData();
      final populatedData = ClinicianReportData(
        snapshot: _snapshot(
          medications: [
            _med('Ivabradine', '7.5 mg', frequency: 'Twice daily'),
            _med('BPC-157', '0.5'),
            _med('Propranolol', '20 mg'),
            _med('Midodrine', '5 mg'),
            _med('Fludrocortisone', '0.1 mg'),
          ],
          logEntries: baseData.snapshot.logEntries,
          sleepSeries: [for (var d = 1; d <= 20; d++) (_key(10, d), 480)],
          deepSleepSeries: [for (var d = 1; d <= 20; d++) (_key(10, d), 90)],
          heartRateSeries: [for (var d = 1; d <= 20; d++) (_key(10, d), 72)],
          hrvSeries: [for (var d = 1; d <= 20; d++) (_key(10, d), 45.0)],
          heartRateSpikes: [for (var d = 1; d <= 20; d++) (_key(10, d), 1)],
          sectionMetadata: const {
            'medications':
                SectionMetadata('medications', DataSourceStatus.success, 5),
            'dailyScore':
                SectionMetadata('dailyScore', DataSourceStatus.success, 22),
            'logs': SectionMetadata('logs', DataSourceStatus.success, 6),
            'sleep': SectionMetadata('sleep', DataSourceStatus.success, 20),
            'deepSleep':
                SectionMetadata('deepSleep', DataSourceStatus.success, 20),
            'heartRate':
                SectionMetadata('heartRate', DataSourceStatus.success, 20),
            'hrv': SectionMetadata('hrv', DataSourceStatus.success, 20),
            'hrSpikes':
                SectionMetadata('hrSpikes', DataSourceStatus.success, 20),
          },
        ),
        dailyScoreSeries: baseData.dailyScoreSeries,
        medChanges: baseData.medChanges,
        medChangesCaptured: baseData.medChangesCaptured,
        flareDays: baseData.flareDays,
        flareSeverityMix: baseData.flareSeverityMix,
        migraineCount: baseData.migraineCount,
        topCategories: baseData.topCategories,
        patternInsights: [
          InsightRecord(
            familyId: 'F1',
            splitId: 'F1a',
            windowKey: 'last90d',
            state: InsightState.numbers,
            groups: const [
              InsightGroup(label: '8+ hrs sleep', n: 12, mean: 78.5),
              InsightGroup(label: '<7 hrs sleep', n: 10, mean: 55.0),
            ],
            computedAtMs: _nowMs,
            throughDate: _key(10, 28),
            inputFingerprint: 'fp',
          ),
        ],
      );
      final maxBytes = await buildClinicianPdfBytes(populatedData);
      expect(_pageCount(maxBytes), 1);

      const allSections = [
        'medications',
        'dailyScore',
        'logs',
        'sleep',
        'deepSleep',
        'heartRate',
        'hrv',
        'hrSpikes',
        'bloodPressure',
        'documents',
        'conditions',
        'calories',
      ];
      final errorMetadata = {
        for (final k in allSections)
          k: SectionMetadata(k, DataSourceStatus.error, 0),
      };

      final allUnavailableData = ClinicianReportData(
        snapshot: _snapshot(
          medications: const [],
          logEntries: const [],
          sectionMetadata: errorMetadata,
          sleepSeries: const [],
          deepSleepSeries: const [],
          heartRateSeries: const [],
          hrvSeries: const [],
          heartRateSpikes: const [],
        ),
        dailyScoreSeries: const [],
        medChanges: const [],
        medChangesCaptured: false,
        flareDays: 0,
        flareSeverityMix: const {},
        migraineCount: 0,
        topCategories: const [],
        patternInsights: const [],
        patternsLoadFailed: true,
      );
      final unavailBytes = await buildClinicianPdfBytes(allUnavailableData);
      expect(_pageCount(unavailBytes), 1);
    });
  });
}

// ── Fakes ────────────────────────────────────────────────────────

class _FakeBackend extends TabsBackend {
  bool pullFails = false;
  int aiCalls = 0;

  _FakeBackend() : super(sessionStore: FakeSessionStore());

  // VC 100109 combine (itemized): the Q7 premium gate resolves
  // through fetchMembership by default; the flow tests exercise
  // generation as a premium user, so the fake reports unlimited.
  // The gate's own tests use the page's clinicianPremiumCheck
  // seam instead.
  @override
  Future<({bool isUnlimited, bool isAdmin})> fetchMembership() async =>
      (isUnlimited: true, isAdmin: false);

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

  // Phase 1: the collector no longer consults isConnected() — it
  // always runs the union load. This fake therefore answers the
  // range reads in-memory too (empty, no failure recorded: a
  // disconnected device's sections are noData, and the platform
  // channel is never touched from a widget test's fake-async
  // zone). getMissingPermissions reports the full required set,
  // which is what "disconnected" means for the live granted set.
  @override
  Future<Set<String>> getMissingPermissions() async =>
      HealthConnectService.requiredPermissions;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
}
