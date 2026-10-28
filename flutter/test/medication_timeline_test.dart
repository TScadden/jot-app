import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medication_timeline.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_summary.dart' show dateStrOf;

import 'test_helpers.dart';

/// Phase 1, item 2b — medication timeline VIEW derivation tests
/// (spec §7 view group, tests 7–17, + the D1 shared floor).
/// Everything drives the PURE layer in
/// `data/medication_timeline.dart` over plain inputs.

DateTime _d(int month, int day) => DateTime(2026, month, day);

MedicationFieldSnapshot _snap({
  String dose = '10 mg',
  String frequency = 'Once daily',
  String startDate = 'Sep 1, 2026',
  String endDate = 'Present',
  bool isPresent = true,
}) =>
    MedicationFieldSnapshot(
      dose: dose,
      frequency: frequency,
      startDate: startDate,
      endDate: endDate,
      isPresent: isPresent,
    );

MedicationChangeEvent _event({
  String id = 'e1',
  String type = 'start',
  String medId = 'm1',
  String medName = 'Med A',
  String? effectiveDate,
  required DateTime recorded,
  MedicationFieldSnapshot? oldS,
  MedicationFieldSnapshot? newS,
}) =>
    MedicationChangeEvent(
      id: id,
      medId: medId,
      medName: medName,
      type: type,
      oldSnapshot: oldS,
      newSnapshot: newS,
      effectiveDate: effectiveDate,
      recordedAt: recorded.millisecondsSinceEpoch,
      source: 'tools',
    );

MedicationEntry _row({
  String id = 'm1',
  String name = 'Med A',
  String startDate = '',
  String endDate = 'Present',
  bool isPresent = true,
  String dose = '10 mg',
  String frequency = 'Once daily',
  bool isDeleted = false,
}) =>
    MedicationEntry(
      id: id,
      name: name,
      startDate: startDate,
      endDate: endDate,
      isPresent: isPresent,
      dose: dose,
      frequency: frequency,
      updatedAt: 0,
      isDeleted: isDeleted,
    );

/// Score map: [values] laid over consecutive days from [start];
/// null = a stored day with no score (or an absent day — use
/// [Map] construction where the distinction matters).
Map<String, int?> _scores(DateTime start, List<int?> values) => {
      for (var i = 0; i < values.length; i++)
        dateStrOf(start.add(Duration(days: i))): values[i],
    };

Map<String, int?> _flatScores(DateTime start, DateTime end, int value) {
  final out = <String, int?>{};
  for (var day = start; !day.isAfter(end); day = day.add(const Duration(days: 1))) {
    out[dateStrOf(day)] = value;
  }
  return out;
}

TimelineMarker _marker(
  TimelineMarkerKind kind,
  DateTime date, {
  String medId = 'm1',
  String medName = 'Med A',
  int recordedAtMs = 0,
}) =>
    TimelineMarker(
      kind: kind,
      medId: medId,
      medName: medName,
      date: date,
      dateDisplay: formatMedArchiveDate(date),
      monthPrecision: false,
      seeded: false,
      doseAtEvent: '10 mg',
      afterDose: '10 mg',
      afterFrequency: 'Once daily',
      afterIsPresent: kind != TimelineMarkerKind.stop,
      recordedAtMs: recordedAtMs,
    );

MedicationTimelineData _build({
  List<MedicationChangeEvent> events = const [],
  List<MedicationEntry> medications = const [],
  Map<String, int?> scores = const {},
  List<QuickLogEntry> entries = const [],
  List<QuickLogCategory> categories = const [],
  DateTime? today,
}) =>
    buildMedicationTimeline(
      events: events,
      medications: medications,
      scoresByDate: scores,
      entries: entries,
      categories: categories,
      today: today ?? _d(10, 28),
    );

void main() {
  group('backend read path (contract + fromJson)', () {
    TabsBackend backendWith(MockClient client) {
      final store = FakeSessionStore()..token = 'tok';
      return TabsBackend(client: client, sessionStore: store);
    }

    setUp(TabsBackend.debugResetSharedCaches);

    test('fromJson round-trips the client contract shape', () {
      final original = _event(
        type: 'dose_change',
        effectiveDate: null,
        recorded: _d(10, 20),
        oldS: _snap(dose: '5 mg'),
        newS: _snap(dose: '10 mg'),
      );
      final parsed = MedicationChangeEvent.fromJson(original.toJson());
      expect(parsed.id, original.id);
      expect(parsed.medId, 'm1');
      expect(parsed.medName, 'Med A');
      expect(parsed.type, 'dose_change');
      expect(parsed.oldSnapshot, original.oldSnapshot);
      expect(parsed.newSnapshot, original.newSnapshot);
      expect(parsed.effectiveDate, isNull);
      expect(parsed.recordedAt, original.recordedAt);
      expect(parsed.source, 'tools');
    });

    test('fromJson tolerates a string recordedAt and null snapshots', () {
      final parsed = MedicationChangeEvent.fromJson({
        'id': 'e9',
        'medId': 'm2',
        'medName': 'Med B',
        'type': 'stop',
        'old': null,
        'new': null,
        'effectiveDate': 'Oct 16, 2026',
        'recordedAt': '${_d(10, 16).millisecondsSinceEpoch}',
        'source': 'settings',
      });
      expect(parsed.recordedAt, _d(10, 16).millisecondsSinceEpoch);
      expect(parsed.oldSnapshot, isNull);
      expect(parsed.effectiveDate, 'Oct 16, 2026');
    });

    test('fetchMedicationChangeEvents parses the contract body, oldest first',
        () async {
      final backend = backendWith(MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/sync/medication-events');
        return http.Response(
          jsonEncode({
            'success': true,
            'events': [
              _event(
                id: 'e1',
                type: 'start',
                effectiveDate: 'Oct 1, 2026',
                recorded: _d(10, 1),
                newS: _snap(),
              ).toJson(),
              _event(
                id: 'e2',
                type: 'stop',
                effectiveDate: 'Oct 16, 2026',
                recorded: _d(10, 16),
                oldS: _snap(),
                newS: _snap(endDate: 'Oct 16, 2026', isPresent: false),
              ).toJson(),
              {'bogus': true},
            ],
          }),
          200,
        );
      }));
      final events = await backend.fetchMedicationChangeEvents();
      // The bogus row parses tolerantly into an empty event; the
      // two real events keep their order and fields.
      expect(events, isNotNull);
      expect(events!.length, 3);
      expect(events[0].type, 'start');
      expect(events[0].newSnapshot?.dose, '10 mg');
      expect(events[1].type, 'stop');
      expect(events[1].newSnapshot?.isPresent, isFalse);
    });

    // VC 100109 combine (itemized): the read path was unified
    // with item 3's nullable contract — failure shapes now read
    // as NULL (a failed fetch), distinguishable from a genuinely
    // empty history; the timeline screen maps null to its empty
    // state at its call site.
    test('fetchMedicationChangeEvents → null on failure shapes', () async {
      final http500 = backendWith(
          MockClient((_) async => http.Response('nope', 500)));
      expect(await http500.fetchMedicationChangeEvents(), isNull);

      final notSuccess = backendWith(MockClient((_) async =>
          http.Response(jsonEncode({'success': false, 'events': []}), 200)));
      expect(await notSuccess.fetchMedicationChangeEvents(), isNull);

      final noEvents = backendWith(MockClient((_) async =>
          http.Response(jsonEncode({'success': true}), 200)));
      expect(await noEvents.fetchMedicationChangeEvents(), isNull);
    });
  });

  group('window averages (test 7)', () {
    test('mean over scored days only; nulls skipped; counts exact', () {
      final scores = <String, int?>{
        // Before window Oct 1–14: 40, 50, null, then 60 × 11.
        ..._scores(_d(10, 1), [40, 50, null, ...List.filled(11, 60)]),
        // After window Oct 15–28: 70 × 14.
        ..._scores(_d(10, 15), List.filled(14, 70)),
      };
      final data = _build(
        events: [
          _event(
            type: 'start',
            effectiveDate: 'Oct 15, 2026',
            recorded: _d(10, 15),
            newS: _snap(),
          ),
        ],
        scores: scores,
      );
      final marker = data.markers.single;
      final result = data.windowsFor(marker, 14);
      expect(result.beforeSpanDays, 14);
      expect(result.beforeScoredDays, 13);
      expect(result.beforeAverage, 58); // 750 / 13 = 57.69 → 58
      expect(result.afterSpanDays, 14);
      expect(result.afterScoredDays, 14);
      expect(result.afterAverage, 70);
      expect(result.floorMet, isTrue);
    });

    test('zero-scored-day window → below-floor state, never a 0 average', () {
      final scores = <String, int?>{
        // Before window days exist in the series but carry NO
        // scores (null = missing data).
        ..._scores(_d(10, 1), List.filled(14, null)),
        ..._scores(_d(10, 15), List.filled(14, 70)),
      };
      final data = _build(
        events: [
          _event(
            type: 'start',
            effectiveDate: 'Oct 15, 2026',
            recorded: _d(10, 15),
            newS: _snap(),
          ),
        ],
        scores: scores,
      );
      final result = data.windowsFor(data.markers.single, 14);
      expect(result.beforeScoredDays, 0);
      expect(result.floorMet, isFalse);
      expect(result.beforeAverage, isNull);
      expect(result.afterAverage, isNull); // no partial averages
    });
  });

  group('change-day rule (test 9)', () {
    // Change day Oct 15 carries a distinctive 100; every other
    // day in range is 50.
    Map<String, int?> scores() {
      final map = _flatScores(_d(9, 20), _d(11, 15), 50);
      map[dateStrOf(_d(10, 15))] = 100;
      return map;
    }

    for (final type in ['start', 'dose_change', 'frequency_change']) {
      test('$type counts the change day in the AFTER window', () {
        final data = _build(
          events: [
            _event(
              type: type,
              effectiveDate: type == 'start' ? 'Oct 15, 2026' : null,
              recorded: _d(10, 15),
              oldS: _snap(dose: '5 mg'),
              newS: _snap(),
            ),
          ],
          scores: scores(),
        );
        final result = data.windowsFor(data.markers.single, 14);
        expect(result.beforeAverage, 50); // Oct 1–14, no 100
        expect(result.afterAverage, 54); // (100 + 13×50) / 14
      });
    }

    test('restore counts the change day in the AFTER window and anchors '
        'on recordedAt (its effectiveDate is the erased stop date)', () {
      final data = _build(
        events: [
          _event(
            type: 'restore',
            effectiveDate: 'Oct 1, 2026', // the preserved stop date
            recorded: _d(10, 15),
            oldS: _snap(endDate: 'Oct 1, 2026', isPresent: false),
            newS: _snap(),
          ),
        ],
        scores: scores(),
      );
      final marker = data.markers.single;
      expect(marker.date, _d(10, 15)); // NOT Oct 1
      final result = data.windowsFor(marker, 14);
      expect(result.beforeAverage, 50);
      expect(result.afterAverage, 54);
    });

    test('stop counts the change day in the BEFORE window', () {
      final data = _build(
        events: [
          _event(
            type: 'stop',
            effectiveDate: 'Oct 15, 2026',
            recorded: _d(10, 15),
            oldS: _snap(),
            newS: _snap(endDate: 'Oct 15, 2026', isPresent: false),
          ),
        ],
        scores: scores(),
      );
      final result = data.windowsFor(data.markers.single, 14);
      expect(result.beforeAverage, 54); // Oct 2–15 includes the 100
      expect(result.afterAverage, 50); // Oct 16–29
    });
  });

  group('truncation (test 8)', () {
    test('window clipped by the stored-series edge; stated span is the '
        'days actually averaged', () {
      // Series starts Oct 10; the change is Oct 15, window 14.
      final scores = _flatScores(_d(10, 10), _d(11, 10), 60);
      final data = _build(
        events: [
          _event(
            type: 'start',
            effectiveDate: 'Oct 15, 2026',
            recorded: _d(10, 15),
            newS: _snap(),
          ),
        ],
        scores: scores,
      );
      final result = data.windowsFor(data.markers.single, 14);
      expect(result.beforeSpanDays, 5); // Oct 10–14 only
      expect(result.beforeScoredDays, 5);
      expect(result.afterSpanDays, 14);
      expect(result.floorMet, isTrue); // 5 + 14 ≥ 14, each ≥ 5
    });

    test('window clipped at a neighboring same-med change', () {
      final scores = _flatScores(_d(9, 1), _d(11, 30), 60);
      final data = _build(
        events: [
          _event(
            id: 'e1',
            type: 'start',
            effectiveDate: 'Oct 1, 2026',
            recorded: _d(10, 1),
            newS: _snap(dose: '5 mg'),
          ),
          _event(
            id: 'e2',
            type: 'dose_change',
            recorded: _d(10, 11),
            oldS: _snap(dose: '5 mg'),
            newS: _snap(dose: '10 mg'),
          ),
        ],
        scores: scores,
      );
      final start = data.markers.firstWhere((m) => m.kind == TimelineMarkerKind.start);
      final dose = data.markers.firstWhere((m) => m.kind == TimelineMarkerKind.doseChange);
      // Start's after window: Oct 1–14 wanted, cut at Oct 10 (the
      // dose change's before-regimen end) → span 10.
      expect(data.windowsFor(start, 14).afterSpanDays, 10);
      // Dose change's before window: Sep 27–Oct 10 wanted, cut at
      // Oct 1 (the start's after-regimen start) → span 10.
      expect(data.windowsFor(dose, 14).beforeSpanDays, 10);
    });

    test('a neighboring change to a DIFFERENT med does not truncate', () {
      final scores = _flatScores(_d(9, 1), _d(11, 30), 60);
      final data = _build(
        events: [
          _event(
            id: 'e1',
            type: 'start',
            effectiveDate: 'Oct 1, 2026',
            recorded: _d(10, 1),
            newS: _snap(dose: '5 mg'),
          ),
          _event(
            id: 'e2',
            type: 'dose_change',
            medId: 'm2',
            medName: 'Med B',
            recorded: _d(10, 11),
            oldS: _snap(dose: '5 mg'),
            newS: _snap(dose: '10 mg'),
          ),
        ],
        scores: scores,
      );
      final start = data.markers.firstWhere((m) => m.medId == 'm1');
      expect(data.windowsFor(start, 14).afterSpanDays, 14);
    });
  });

  group('D1 shared floor matrix', () {
    // Start marker at Oct 15; scored days are placed by count in
    // each window, the rest of the series present-but-unscored.
    TimelineWindowResult floorCase(
      int beforeScored,
      int afterScored, {
      int windowDays = 14,
    }) {
      final changeDay = _d(10, 15);
      final seriesStart = changeDay.subtract(const Duration(days: 45));
      final seriesEnd = changeDay.add(const Duration(days: 45));
      final scores = <String, int?>{};
      for (var day = seriesStart;
          !day.isAfter(seriesEnd);
          day = day.add(const Duration(days: 1))) {
        scores[dateStrOf(day)] = null;
      }
      // Window day lists per the change-day rule (start kind).
      final beforeEnd = changeDay.subtract(const Duration(days: 1));
      final beforeStart = beforeEnd.subtract(Duration(days: windowDays - 1));
      for (var i = 0; i < beforeScored; i++) {
        scores[dateStrOf(beforeStart.add(Duration(days: i)))] = 60;
      }
      for (var i = 0; i < afterScored; i++) {
        scores[dateStrOf(changeDay.add(Duration(days: i)))] = 60;
      }
      final marker = _marker(TimelineMarkerKind.start, changeDay);
      return computeMedicationWindows(
        marker: marker,
        allMarkers: [marker],
        scoresByDate: scores,
        windowDays: windowDays,
      );
    }

    test('floor met exactly (5 before / 9 after = 14 total) renders', () {
      final r = floorCase(5, 9);
      expect(r.floorMet, isTrue);
      expect(r.beforeAverage, 60);
      expect(r.afterAverage, 60);
      expect(r.beforeScoredDays, 5);
      expect(r.afterScoredDays, 9);
    });

    test('4 in a window does not render even at total 14', () {
      final r = floorCase(4, 10);
      expect(r.floorMet, isFalse);
      expect(r.beforeAverage, isNull);
      expect(r.afterAverage, isNull);
    });

    test('6 / 7 (total 13) does not render', () {
      final r = floorCase(6, 7);
      expect(r.floorMet, isFalse);
      expect(r.beforeAverage, isNull);
    });

    test('5 / 5 (total 10) does not render', () {
      expect(floorCase(5, 5).floorMet, isFalse);
    });

    test('0 scored days in a window does not render', () {
      final r = floorCase(0, 14);
      expect(r.floorMet, isFalse);
      expect(r.beforeScoredDays, 0);
      expect(r.beforeAverage, isNull);
    });

    test('floor holds identically at window 7 (7 + 7 = 14 renders)', () {
      final r = floorCase(7, 7, windowDays: 7);
      expect(r.floorMet, isTrue);
      expect(r.beforeSpanDays, 7);
      expect(r.afterSpanDays, 7);
    });

    test('floor holds identically at window 30', () {
      final r = floorCase(5, 9, windowDays: 30);
      expect(r.floorMet, isTrue);
      expect(floorCase(4, 20, windowDays: 30).floorMet, isFalse);
      expect(floorCase(6, 7, windowDays: 30).floorMet, isFalse);
    });
  });

  group('declared-date parsing + seeds (tests 10–11)', () {
    test('exact declared dates place exactly; display is verbatim', () {
      final data = _build(medications: [
        _row(startDate: 'Oct 13, 2026'),
      ]);
      final marker = data.markers.single;
      expect(marker.kind, TimelineMarkerKind.start);
      expect(marker.date, _d(10, 13));
      expect(marker.dateDisplay, 'Oct 13, 2026');
      expect(marker.monthPrecision, isFalse);
      expect(marker.seeded, isTrue);
    });

    test('month-only places on the 1st with month precision carried', () {
      final data = _build(medications: [
        _row(startDate: 'Jun 2026'),
      ]);
      final marker = data.markers.single;
      expect(marker.date, DateTime(2026, 6, 1));
      expect(marker.monthPrecision, isTrue);
      // The render string is the recorded string verbatim —
      // never a fake-exact day.
      expect(marker.dateDisplay, 'Jun 2026');
    });

    test('captured month-precision effectiveDate renders verbatim too', () {
      final data = _build(events: [
        _event(
          type: 'start',
          effectiveDate: 'Jun 2026',
          recorded: _d(10, 20),
          newS: _snap(startDate: 'Jun 2026'),
        ),
      ]);
      final marker = data.markers.single;
      expect(marker.date, DateTime(2026, 6, 1));
      expect(marker.monthPrecision, isTrue);
      expect(marker.dateDisplay, 'Jun 2026');
      expect(marker.seeded, isFalse);
    });

    test('blank and unparseable declared dates produce no marker and are '
        'counted in the skipped-seed count', () {
      final data = _build(medications: [
        _row(id: 'a', name: 'Blank', startDate: ''),
        _row(id: 'b', name: 'Gibberish', startDate: 'sometime last spring'),
        _row(
          id: 'c',
          name: 'ArchivedNoEnd',
          startDate: 'Sep 1, 2026',
          endDate: '',
          isPresent: false,
        ),
      ]);
      // Only ArchivedNoEnd's start seeds. Skips: Blank start,
      // Gibberish start, ArchivedNoEnd's blank end = 3.
      expect(data.markers.length, 1);
      expect(data.markers.single.medName, 'ArchivedNoEnd');
      expect(data.skippedSeedCount, 3);
    });

    test('archived row seeds both a start and a stop', () {
      final data = _build(medications: [
        _row(startDate: 'Sep 1, 2026', endDate: 'Oct 16, 2026', isPresent: false),
      ]);
      expect(data.markers.length, 2);
      expect(data.markers[0].kind, TimelineMarkerKind.start);
      expect(data.markers[1].kind, TimelineMarkerKind.stop);
      expect(data.markers[1].date, _d(10, 16));
      expect(data.markers.every((m) => m.seeded), isTrue);
    });

    test('deleted rows seed nothing', () {
      final data = _build(medications: [
        _row(startDate: 'Sep 1, 2026', isDeleted: true),
      ]);
      expect(data.markers, isEmpty);
    });

    test('captured marker suppresses the matching seed (captured wins)', () {
      final data = _build(
        events: [
          _event(
            type: 'start',
            effectiveDate: 'Oct 1, 2026',
            recorded: _d(10, 1),
            newS: _snap(startDate: 'Oct 1, 2026'),
          ),
        ],
        medications: [_row(startDate: 'Oct 1, 2026')],
      );
      expect(data.markers.length, 1);
      expect(data.markers.single.seeded, isFalse);
    });

    test('a seed with a DIFFERENT declared date is not suppressed', () {
      final data = _build(
        events: [
          _event(
            type: 'start',
            effectiveDate: 'Oct 2, 2026',
            recorded: _d(10, 2),
            newS: _snap(startDate: 'Oct 2, 2026'),
          ),
        ],
        medications: [_row(startDate: 'Oct 1, 2026')],
      );
      expect(data.markers.length, 2);
    });

    test('a captured restore renders even though the row endDate was '
        'erased by the unarchive', () {
      final data = _build(
        events: [
          _event(
            id: 'e1',
            type: 'stop',
            effectiveDate: 'Oct 10, 2026',
            recorded: _d(10, 10),
            oldS: _snap(),
            newS: _snap(endDate: 'Oct 10, 2026', isPresent: false),
          ),
          _event(
            id: 'e2',
            type: 'restore',
            effectiveDate: 'Oct 10, 2026',
            recorded: _d(10, 20),
            oldS: _snap(endDate: 'Oct 10, 2026', isPresent: false),
            newS: _snap(),
          ),
        ],
        // The live row is active again; its endDate is 'Present'
        // — the stop exists ONLY in the captured events.
        medications: [_row(startDate: 'Sep 1, 2026')],
      );
      final kinds = data.markers.map((m) => m.kind).toList();
      expect(kinds, contains(TimelineMarkerKind.stop));
      expect(kinds, contains(TimelineMarkerKind.restore));
      final restore =
          data.markers.firstWhere((m) => m.kind == TimelineMarkerKind.restore);
      expect(restore.date, _d(10, 20));
      expect(restore.seeded, isFalse);
      // The captured stop is not seeded (the row carries no end).
      final stop =
          data.markers.firstWhere((m) => m.kind == TimelineMarkerKind.stop);
      expect(stop.seeded, isFalse);
    });

    test('delete and dates_edit events are NOT markers', () {
      final data = _build(events: [
        _event(id: 'e1', type: 'delete', recorded: _d(10, 5), oldS: _snap()),
        _event(
          id: 'e2',
          type: 'dates_edit',
          recorded: _d(10, 6),
          oldS: _snap(),
          newS: _snap(startDate: 'Sep 2, 2026'),
        ),
      ]);
      expect(data.markers, isEmpty);
    });
  });

  group('calendar-continuous axis + series (tests 13–14, 16)', () {
    const categories = [
      QuickLogCategory(
        id: 1,
        name: 'Symptoms',
        icon: 'circle',
        colorHex: '#CCCCCC',
        isDefault: true,
        sortOrder: 0,
      ),
    ];

    QuickLogEntry entry(int id, int categoryId, String chips, DateTime day) =>
        QuickLogEntry(
          id: id,
          categoryId: categoryId,
          body: 'entry',
          chips: chips,
          manualText: '',
          timestamp: day.millisecondsSinceEpoch,
        );

    test('unscored days are explicit gaps on a continuous axis', () {
      final scores = <String, int?>{
        ..._scores(_d(10, 1), [60, 62]),
        dateStrOf(_d(10, 3)): null, // stored, unscored
        // Oct 4 absent from the map entirely.
        ..._scores(_d(10, 5), [70, 71, 72]),
      };
      final data = _build(scores: scores, today: _d(10, 7));
      expect(data.days.length, 7); // Oct 1–7, none omitted
      expect(data.days.map((d) => d.date),
          [for (var i = 0; i < 7; i++) _d(10, 1).add(Duration(days: i))]);
      expect(data.days[2].score, isNull); // Oct 3 gap
      expect(data.days[3].score, isNull); // Oct 4 gap
      expect(data.days[0].score, 60);
      expect(data.days[6].score, 72);
    });

    test('flare / migraine / symptom-count series derive from entries', () {
      final data = _build(
        scores: _flatScores(_d(10, 1), _d(10, 7), 60),
        categories: categories,
        entries: [
          entry(1, 1, '["Flare Day"]', _d(10, 2)),
          entry(2, 1, '["Migraine attack"]', _d(10, 3)),
          entry(3, 1, '[]', _d(10, 4)),
          entry(4, 1, '[]', _d(10, 4)),
          // A flare chip outside the Symptoms category is not a
          // flare day.
          entry(5, 9, '["Flare Day"]', _d(10, 5)),
        ],
        today: _d(10, 7),
      );
      final byDate = {for (final d in data.days) dateStrOf(d.date): d};
      expect(byDate[dateStrOf(_d(10, 2))]!.isFlareDay, isTrue);
      expect(byDate[dateStrOf(_d(10, 3))]!.isMigraineDay, isTrue);
      expect(byDate[dateStrOf(_d(10, 4))]!.symptomLogCount, 2);
      expect(byDate[dateStrOf(_d(10, 5))]!.isFlareDay, isFalse);
      expect(byDate[dateStrOf(_d(10, 5))]!.symptomLogCount, 0);
    });

    test('multiple same-day changes each render and open their own panel '
        'data (test 14)', () {
      final scores = _flatScores(_d(9, 20), _d(11, 15), 60);
      final morning = DateTime(2026, 10, 15, 9);
      final evening = DateTime(2026, 10, 15, 18);
      final data = _build(
        events: [
          _event(
            id: 'e1',
            type: 'dose_change',
            recorded: morning,
            oldS: _snap(dose: '5 mg'),
            newS: _snap(),
          ),
          _event(
            id: 'e2',
            type: 'stop',
            effectiveDate: 'Oct 15, 2026',
            recorded: evening,
            oldS: _snap(),
            newS: _snap(endDate: 'Oct 15, 2026', isPresent: false),
          ),
        ],
        scores: scores,
      );
      final day =
          data.days.firstWhere((d) => d.date == _d(10, 15));
      expect(day.markers.length, 2);
      final dose = data.markers
          .firstWhere((m) => m.kind == TimelineMarkerKind.doseChange);
      final stop =
          data.markers.firstWhere((m) => m.kind == TimelineMarkerKind.stop);
      final doseResult = data.windowsFor(dose, 14);
      final stopResult = data.windowsFor(stop, 14);
      // The dose change's after window is cut by the evening stop
      // to the change day itself; the stop's before window is cut
      // by the morning dose change the same way. Distinct data.
      expect(doseResult.afterSpanDays, 1);
      expect(doseResult.beforeSpanDays, 14);
      expect(stopResult.beforeSpanDays, 1);
      expect(stopResult.afterSpanDays, 14);
    });

    test('deleted-med events still render with snapshot names (test 16)',
        () {
      final data = _build(
        events: [
          _event(
            type: 'start',
            medId: 'gone',
            medName: 'Old Med',
            effectiveDate: 'Sep 1, 2026',
            recorded: _d(9, 1),
            newS: _snap(),
          ),
        ],
        medications: const [], // the row is gone
      );
      expect(data.markers.single.medName, 'Old Med');
      expect(data.lanes.single.medName, 'Old Med');
    });

    test('lane segments carry the governing snapshot dose · frequency', () {
      final data = _build(
        events: [
          _event(
            id: 'e1',
            type: 'start',
            effectiveDate: 'Oct 1, 2026',
            recorded: _d(10, 1),
            newS: _snap(dose: '5 mg', frequency: 'Once daily'),
          ),
          _event(
            id: 'e2',
            type: 'dose_change',
            recorded: _d(10, 11),
            oldS: _snap(dose: '5 mg', frequency: 'Once daily'),
            newS: _snap(dose: '10 mg', frequency: 'Once daily'),
          ),
          _event(
            id: 'e3',
            type: 'stop',
            effectiveDate: 'Oct 21, 2026',
            recorded: _d(10, 21),
            oldS: _snap(),
            newS: _snap(endDate: 'Oct 21, 2026', isPresent: false),
          ),
        ],
      );
      final lane = data.lanes.single;
      expect(lane.segments.length, 3);
      expect(lane.segments[0].dose, '5 mg');
      expect(lane.segments[0].startDate, _d(10, 1));
      expect(lane.segments[0].endDate, _d(10, 11));
      expect(lane.segments[1].dose, '10 mg');
      expect(lane.segments[1].isPresent, isTrue);
      expect(lane.segments[2].isPresent, isFalse); // after the stop
    });
  });

  group('purity + handoff contract (tests 12, 17)', () {
    test('derivation is pure: inputs unmodified (score series is read-only '
        'by construction)', () {
      final scores = _flatScores(_d(9, 1), _d(11, 30), 60);
      final scoresCopy = Map<String, int?>.of(scores);
      final events = [
        _event(
          type: 'start',
          effectiveDate: 'Oct 15, 2026',
          recorded: _d(10, 15),
          newS: _snap(),
        ),
      ];
      final data = _build(events: events, scores: scores);
      data.windowsFor(data.markers.single, 14);
      data.changeSummaries(data.rangeStart, data.rangeEnd);
      expect(scores, scoresCopy);
      expect(events.length, 1);
    });

    test('test 17: the §5 handoff list equals the panel computation for '
        'the same inputs', () {
      final scores = <String, int?>{
        ..._scores(_d(10, 1), [40, 50, null, ...List.filled(11, 60)]),
        ..._scores(_d(10, 15), List.filled(14, 70)),
        ..._scores(_d(10, 29), List.filled(20, 65)),
      };
      final data = _build(
        events: [
          _event(
            id: 'e1',
            type: 'start',
            effectiveDate: 'Oct 15, 2026',
            recorded: _d(10, 15),
            newS: _snap(),
          ),
          _event(
            id: 'e2',
            type: 'dose_change',
            medId: 'm2',
            medName: 'Med B',
            recorded: _d(10, 20),
            oldS: _snap(dose: '2 mg'),
            newS: _snap(dose: '4 mg'),
          ),
        ],
        medications: [_row(id: 'm3', name: 'Med C', startDate: 'Oct 5, 2026')],
        scores: scores,
        today: _d(11, 17),
      );
      final summaries =
          data.changeSummaries(data.rangeStart, data.rangeEnd, windowDays: 14);
      expect(summaries.length, data.markers.length);
      for (final summary in summaries) {
        final marker = data.markers.firstWhere((m) =>
            m.date == summary.date &&
            m.medName == summary.medName &&
            m.kind.eventType == summary.eventType);
        expect(summary.dateDisplay, marker.dateDisplay);
        expect(summary.doseAtEvent, marker.doseAtEvent);
        expect(summary.seeded, marker.seeded);
        final panel = data.windowsFor(marker, 14);
        expect(summary.windows.beforeSpanDays, panel.beforeSpanDays);
        expect(summary.windows.afterSpanDays, panel.afterSpanDays);
        expect(summary.windows.beforeScoredDays, panel.beforeScoredDays);
        expect(summary.windows.afterScoredDays, panel.afterScoredDays);
        expect(summary.windows.beforeAverage, panel.beforeAverage);
        expect(summary.windows.afterAverage, panel.afterAverage);
      }
      // Spot-check the handoff values themselves.
      final startSummary =
          summaries.firstWhere((s) => s.eventType == 'start' && !s.seeded);
      expect(startSummary.medName, 'Med A');
      expect(startSummary.doseAtEvent, '10 mg');
      expect(startSummary.windows.beforeAverage, 58);
      expect(startSummary.windows.afterAverage, 70);
      final seededSummary = summaries.firstWhere((s) => s.seeded);
      expect(seededSummary.medName, 'Med C');
      expect(seededSummary.eventType, 'start');
    });
  });
}
