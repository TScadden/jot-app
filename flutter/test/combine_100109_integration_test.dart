/// VC 100109 combine — integration tests for the seams the
/// combine wired across the four Phase 1 branches:
///
/// 1. Item 5's F2 reads item 4's REAL target store
///    (IntakeSettings over SettingsStore → the production
///    target-history provider → the engine's classification).
/// 2. Item 5's F5 reads the real medication-event GET path
///    (BackendMedChangeEventProvider over TabsBackend).
/// 3. F5's windows ARE item 2's windows (passthrough battery,
///    including the neighbor-truncation case), and Juno's S9
///    truncation spans land on the record in the numbers state
///    only.
/// 4. The Patterns surface renders the S9 note (Juno
///    micro-ruling, Oct 28 2026).
/// 5. Juno's blank-dose Draft 6 forms + the Vera C1 restore
///    anchor exception on the clinician report surface.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_refresh.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medication_timeline.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/intake_logging.dart';
import 'package:tabs_lab/src/features/home/patterns_screen.dart';
import 'package:tabs_lab/src/features/tools/medication_timeline_strings.dart';

import 'test_helpers.dart';

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DailyBiometrics _bio(String day, int score) =>
    DailyBiometrics(date: day, dailyScore: score);

MedicationChangeEvent _event({
  required String id,
  required String type,
  required String effectiveDate,
  required DateTime recorded,
  String dose = '5 mg',
}) {
  MedicationFieldSnapshot snap({required bool present}) =>
      MedicationFieldSnapshot(
        dose: dose,
        frequency: 'Daily',
        startDate: '',
        endDate: '',
        isPresent: present,
      );
  return MedicationChangeEvent(
    id: id,
    medId: 'm1',
    medName: 'MedA',
    type: type,
    oldSnapshot: snap(present: type != 'start'),
    newSnapshot: snap(present: type != 'stop'),
    effectiveDate: effectiveDate,
    recordedAt: recorded.millisecondsSinceEpoch,
    source: 'tools',
  );
}

MedChangeEventInput _input(MedicationChangeEvent e) =>
    medChangeEventInputFromEvent(e);

void main() {
  group('1. F2 reads item 4\'s real target store', () {
    test('stored targets drive the engine\'s hit/missed split',
        () async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final settings = IntakeSettings(store);
      // The founder sets a 2,000 mL fluid target on Oct 1.
      await settings.appendTarget(
        fluidTargetMl: 2000,
        now: DateTime(2026, 10, 1, 10),
      );

      final provider = SettingsIntakeTargetHistoryProvider(
        loadVersions: settings.loadTargets,
      );
      final history = await provider.loadTargetHistory();
      expect(history, hasLength(1));
      expect(history.single.fluidTargetMl, 2000);
      expect(history.single.sodiumTargetMg, isNull);
      expect(history.single.effectiveFromDay, '2026-10-01');

      // Intake on Oct 1..14: even days hit (2,400 mL), odd days
      // miss (400 mL). Next-day scores: 80 after hits, 40 after
      // misses.
      final entries = <QuickLogEntry>[];
      final biometrics = <String, DailyBiometrics>{};
      for (var i = 0; i < 14; i++) {
        final day = DateTime(2026, 10, 1 + i, 12);
        final hit = i.isEven;
        entries.add(QuickLogEntry(
          id: 100 + i,
          categoryId: 7,
          body: 'Water',
          chips: '["Intake", "Water"]',
          manualText:
              jsonEncode({'v': 1, 'kind': 'Water', 'fluidMl': hit ? 2400 : 400}),
          timestamp: day.millisecondsSinceEpoch,
        ));
        final next = DateTime(2026, 10, 2 + i);
        biometrics[_key(next)] = _bio(_key(next), hit ? 80 : 40);
      }

      final records = computeCorrelationInsights(CorrelationInputs(
        biometrics: biometrics,
        entries: entries,
        categories: const [],
        targetHistory: history,
        medEvents: const [],
        nowDayKey: '2026-10-15',
      ));
      final f2 = records.firstWhere(
          (r) => r.familyId == 'F2' && r.splitId == 'fluid-score');
      expect(f2.state, InsightState.numbers);
      expect(f2.groups[0].n, 7); // hit days
      expect(f2.groups[0].mean, 80);
      expect(f2.groups[1].n, 7); // missed days
      expect(f2.groups[1].mean, 40);
    });

    test('no stored targets → empty history (nothing invented)',
        () async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final provider = SettingsIntakeTargetHistoryProvider(
        loadVersions: IntakeSettings(store).loadTargets,
      );
      expect(await provider.loadTargetHistory(), isEmpty);
    });
  });

  group('2. F5 reads the real med-event GET path', () {
    setUp(TabsBackend.debugResetSharedCaches);

    test('contract body adapts to engine inputs; failure → empty',
        () async {
      final backend = TabsBackend(
        client: MockClient((request) async {
          expect(request.url.path, '/api/sync/medication-events');
          return http.Response(
            jsonEncode({
              'success': true,
              'events': [
                _event(
                  id: 'e1',
                  type: 'start',
                  effectiveDate: 'Oct 1, 2026',
                  recorded: DateTime(2026, 10, 1, 9),
                ).toJson(),
              ],
            }),
            200,
          );
        }),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      final provider = BackendMedChangeEventProvider(backend: backend);
      final events = await provider.loadMedChangeEvents();
      expect(events, hasLength(1));
      expect(events.single.type, 'start');
      expect(events.single.medName, 'MedA');
      expect(events.single.newSnapshot?.dose, '5 mg');
      expect(events.single.effectiveDate, 'Oct 1, 2026');

      final failing = TabsBackend(
        client: MockClient((_) async => http.Response('nope', 500)),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      expect(
        await BackendMedChangeEventProvider(backend: failing)
            .loadMedChangeEvents(),
        isEmpty,
      );
    });
  });

  group('3. F5 passthrough battery + S9 record spans', () {
    // Scores: 40 days from Sep 1 2026, all 50 (counts carry the
    // assertions). Start Sep 10, stop Sep 20, same med.
    Map<String, DailyBiometrics> scores() => {
          for (var i = 0; i < 40; i++)
            _key(DateTime(2026, 9, 1 + i)): _bio(
                _key(DateTime(2026, 9, 1 + i)), 50),
        };

    List<MedicationChangeEvent> events() => [
          _event(
            id: 'e-start',
            type: 'start',
            effectiveDate: 'Sep 10, 2026',
            recorded: DateTime(2026, 9, 10, 9),
          ),
          _event(
            id: 'e-stop',
            type: 'stop',
            effectiveDate: 'Sep 20, 2026',
            recorded: DateTime(2026, 9, 20, 9),
          ),
        ];

    test('computeF5Windows equals item 2\'s computation, truncated '
        'and untruncated alike', () {
      final bio = scores();
      final inputs = [for (final e in events()) _input(e)];
      for (final input in inputs) {
        final f5 = computeF5Windows(
          event: input,
          allEvents: inputs,
          biometrics: bio,
        );
        final marker =
            capturedTimelineMarker(medChangeContractEvent(input))!;
        final item2 = computeMedicationWindows(
          marker: marker,
          allMarkers: [
            for (final e in inputs)
              capturedTimelineMarker(medChangeContractEvent(e))!,
          ],
          scoresByDate: scoreMapFromHistoryRows(bio),
          windowDays: 14,
        );
        expect(f5.beforeN, item2.beforeScoredDays);
        expect(f5.afterN, item2.afterScoredDays);
        expect(f5.beforeSpanDays, item2.beforeSpanDays);
        expect(f5.afterSpanDays, item2.afterSpanDays);
        expect(f5.beforeNeighborTruncated, item2.beforeNeighborTruncated);
        expect(f5.afterNeighborTruncated, item2.afterNeighborTruncated);
      }
      // The concrete expectations the equality rests on: the
      // start's after window is cut by the stop to Sep 10..20
      // (11 days, the stop day belongs to the stop's BEFORE
      // regimen — item 2's rule), and the stop's before window
      // is cut by the start to the same 11 days.
      final startF5 = computeF5Windows(
          event: inputs[0], allEvents: inputs, biometrics: bio);
      expect(startF5.afterSpanDays, 11);
      expect(startF5.afterNeighborTruncated, isTrue);
      expect(startF5.beforeNeighborTruncated, isFalse);
      final stopF5 = computeF5Windows(
          event: inputs[1], allEvents: inputs, biometrics: bio);
      expect(stopF5.beforeSpanDays, 11);
      expect(stopF5.beforeNeighborTruncated, isTrue);
      expect(stopF5.afterNeighborTruncated, isFalse);
    });

    test('S9 spans ride the numbers-state records only', () {
      final records = computeCorrelationInsights(CorrelationInputs(
        biometrics: scores(),
        entries: const [],
        categories: const [],
        targetHistory: const [],
        medEvents: [for (final e in events()) _input(e)],
        nowDayKey: '2026-10-10',
      ));
      final start = records.firstWhere((r) => r.splitId == 'e-start');
      expect(start.state, InsightState.numbers);
      expect(start.afterTruncatedSpan, 11);
      expect(start.beforeTruncatedSpan, isNull);
      final stop = records.firstWhere((r) => r.splitId == 'e-stop');
      expect(stop.state, InsightState.numbers);
      expect(stop.beforeTruncatedSpan, 11);
      expect(stop.afterTruncatedSpan, isNull);
      // The record survives a store round-trip with spans intact.
      final restored = InsightRecord.fromJson(start.toJson());
      expect(restored, start);
    });
  });

  group('4. Patterns renders the S9 note', () {
    testWidgets('truncation note renders verbatim beside its window',
        (tester) async {
      final record = InsightRecord(
        familyId: 'F5',
        splitId: 'e-start',
        windowKey: 'event:e-start',
        state: InsightState.numbers,
        groups: const [
          InsightGroup(label: f5GroupALabel, n: 9, mean: 50),
          InsightGroup(label: f5GroupBLabel, n: 11, mean: 50),
        ],
        headerLabel: 'Started MedA · 5 mg',
        subjectName: 'MedA',
        afterTruncatedSpan: 11,
        computedAtMs: 0,
        throughDate: '2026-10-10',
        inputFingerprint: 'test',
      );
      await tester.pumpWidget(MaterialApp(
        home: PatternsScreen(records: [record], isUnlimited: true),
      ));
      await tester.pump();
      expect(
        find.text('The after window is shortened to 11 days. '
            'Another change to MedA happened during the full window.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The before window is shortened'),
        findsNothing,
      );
    });
  });

  group('5. Blank-dose Draft 6 forms + clinician C1 anchor', () {
    test('timeline + patterns label builders drop the separator', () {
      expect(MedicationTimelineStrings.startedLabel('MedA', ''),
          'Started MedA');
      expect(MedicationTimelineStrings.restartedLabel('MedA', ''),
          'Restarted MedA');
      expect(MedicationTimelineStrings.startedLabel('MedA', '5 mg'),
          'Started MedA · 5 mg');
      expect(medChangeStartedLabel('MedA', ''), 'Started MedA');
      expect(medChangeRestartedLabel('MedA', ''), 'Restarted MedA');
      expect(medChangeStartedLabel('MedA', '5 mg'), 'Started MedA · 5 mg');
    });

    test('clinician Z5: blank dose + restore anchors on capture day',
        () {
      final restore = _event(
        id: 'e-restore',
        type: 'restore',
        // The erased stop date rides in effectiveDate (the C1
        // trap); the restart was recorded Oct 17.
        effectiveDate: 'Oct 16, 2026',
        recorded: DateTime(2026, 10, 17, 9),
        dose: '',
      );
      final changes = deriveCapturedMedChanges(
        [restore],
        scores: const {},
        rangeStart: DateTime(2026, 10, 1),
        rangeEnd: DateTime(2026, 10, 31),
      );
      expect(changes, hasLength(1));
      expect(changes.single.day, DateTime(2026, 10, 17));
      expect(changes.single.label, 'Restarted MedA');

      final start = _event(
        id: 'e-start',
        type: 'start',
        effectiveDate: 'Oct 2, 2026',
        recorded: DateTime(2026, 10, 2, 9),
        dose: '',
      );
      final startChanges = deriveCapturedMedChanges(
        [start],
        scores: const {},
        rangeStart: DateTime(2026, 10, 1),
        rangeEnd: DateTime(2026, 10, 31),
      );
      expect(startChanges.single.label, 'Started MedA');
    });
  });
}
