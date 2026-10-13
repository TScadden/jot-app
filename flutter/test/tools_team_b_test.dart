import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/body_info_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// Round 18 (Team B) — tool screens with real data.
///
/// Conventions: MockClient for the backend (per tabs_backend_test.dart),
/// a fake HealthConnectService subclass for the sleep reads. Every test
/// pumps the real widget: parsing, empty states, auth failure, and the
/// founder's zero-is-a-failed-read rule are all covered.

TabsBackend _backendWithProfile(Map<String, dynamic> profile,
    {int status = 200}) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
      (_) async =>
          http.Response(jsonEncode({'profile': profile}), status),
    ),
    sessionStore: store,
  );
}

TabsBackend _backendUnauthorized() {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
      (_) async => http.Response('{"error":"bad token"}', 401),
    ),
    sessionStore: store,
  );
}

TabsBackend _backendNoToken() {
  return TabsBackend(
    client: MockClient((_) async => http.Response('{}', 200)),
    sessionStore: FakeSessionStore(),
  );
}

/// Fake Health Connect: injectable connected flag + per-day sleep minutes.
class FakeHealthConnect extends HealthConnectService {
  FakeHealthConnect({
    this.connected = true,
    this.minutes = const {},
  });

  final bool connected;
  final Map<String, int?> minutes;

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<int?> readSleepMinutes(String dateStr) async =>
      minutes[dateStr];
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  // ── Project Focus ──────────────────────────────────────────────────

  group('ProjectFocusScreen', () {
    Map<String, dynamic> sampleFocusPayload() {
      final now = DateTime.now();
      final start = now.subtract(const Duration(days: 2));
      final twoDaysAgo = _dateStr(now.subtract(const Duration(days: 2)));
      final yesterday = _dateStr(now.subtract(const Duration(days: 1)));
      final test = {
        'id': 'test_1',
        'title': 'Magnesium for sleep',
        'desc': 'Take 200mg magnesium 30 min before bed',
        'durationDays': 7,
        'startTimestamp': start.millisecondsSinceEpoch,
        'logs': {twoDaysAgo: true, yesterday: false},
        'measureMetric': 'sleepMins',
      };
      return {
        'focusState': jsonEncode({
          'activeTests': [test],
          'activeTest': test,
          'selectedTestId': 'test_1',
          'currentSubView': 'details',
        }),
      };
    }

    testWidgets('renders the active test with progress and log history',
        (tester) async {
      await _pump(
        tester,
        ProjectFocusScreen(
            backend: _backendWithProfile(sampleFocusPayload())),
      );
      expect(find.text('Project Focus'), findsOneWidget);
      expect(find.text('Magnesium for sleep'), findsWidgets);
      expect(find.text('Day 3 of 7'), findsOneWidget);
      // Log history: one ✓ and one ✗ day from the sample logs.
      expect(find.text('✓'), findsOneWidget);
      expect(find.text('✗'), findsOneWidget);
      // Legend row.
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Missed'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
    });

    testWidgets('empty blob → honest empty state, never invented',
        (tester) async {
      await _pump(
        tester,
        ProjectFocusScreen(backend: _backendWithProfile({'focusState': '{}'})),
      );
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);
      expect(find.text('Magnesium for sleep'), findsNothing);
    });

    testWidgets('auth failure (401) → honest empty, no crash',
        (tester) async {
      await _pump(
        tester,
        ProjectFocusScreen(backend: _backendUnauthorized()),
      );
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);
    });

    testWidgets('no token → honest empty, no crash', (tester) async {
      await _pump(
        tester,
        ProjectFocusScreen(backend: _backendNoToken()),
      );
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);
    });

    testWidgets('malformed focusState → honest empty, no crash',
        (tester) async {
      await _pump(
        tester,
        ProjectFocusScreen(
            backend: _backendWithProfile({'focusState': 'not-json{{'})),
      );
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);
    });

    test('FocusTest.fromJson tolerates malformed test maps', () {
      expect(FocusTest.fromJson({}), isNull);
      expect(FocusTest.fromJson({'title': 'x'}), isNull);
      expect(
          FocusTest.fromJson({
            'title': 'x',
            'durationDays': 'seven',
            'startTimestamp': 1
          }),
          isNull);
      final t = FocusTest.fromJson({
        'title': 'Magnesium',
        'durationDays': 7,
        'startTimestamp': 1000,
        'logs': {'2026-10-09': true, 'bad': 'nope'},
      });
      expect(t, isNotNull);
      expect(t!.logs, {'2026-10-09': true});
    });

    test('collectFocusTests dedupes activeTest + activeTests', () {
      final test = {
        'id': 'a',
        'title': 'T',
        'durationDays': 7,
        'startTimestamp': 1000,
      };
      final out = collectFocusTests([
        {
          'activeTests': [test],
          'activeTest': test,
        }
      ]);
      expect(out.length, 1);
    });
  });

  // ── Sleep ──────────────────────────────────────────────────────────

  group('SleepScreen', () {
    Map<String, int?> sampleMinutes() {
      final map = <String, int?>{};
      for (final d in sevenDayWindow()) {
        map[d.dateStr] = 450; // 7h30m every night
      }
      return map;
    }

    testWidgets('connected: hero + recent nights from real reads',
        (tester) async {
      final minutes = sampleMinutes();
      await _pump(
        tester,
        SleepScreen(
          backend: _backendWithProfile({
            'todaySleepMins': 450,
            'todaySleepDebt': -90,
          }),
          healthConnect: FakeHealthConnect(minutes: minutes),
        ),
      );
      expect(find.text('Sleep Profile'), findsOneWidget);
      expect(find.text('Time Asleep Today'), findsOneWidget);
      expect(find.text('7h 30m'), findsWidgets);
      expect(find.text('Deficit: -1h 30m'), findsOneWidget);
      expect(find.text('Recent Nights'), findsOneWidget);
      expect(find.text('7-Day Average: 7h 30m'), findsOneWidget);
    });

    testWidgets('HC not connected → "--", never invented', (tester) async {
      await _pump(
        tester,
        SleepScreen(
          backend: _backendWithProfile({}),
          healthConnect: FakeHealthConnect(connected: false),
        ),
      );
      expect(find.text('Sleep Analysis'), findsOneWidget);
      expect(find.text("Today's sleep: --"), findsOneWidget);
      expect(find.text('Recent Nights'), findsNothing);
    });

    testWidgets('zero minutes are failed reads → "--"', (tester) async {
      final minutes = <String, int?>{};
      for (final d in sevenDayWindow()) {
        minutes[d.dateStr] = 0; // failed reads, not real sleep
      }
      await _pump(
        tester,
        SleepScreen(
          backend: _backendWithProfile({}),
          healthConnect: FakeHealthConnect(minutes: minutes),
        ),
      );
      expect(find.text('Not enough sleep data yet'), findsOneWidget);
      // Every recent-night row renders "--", never "0m".
      expect(find.text('0m'), findsNothing);
      expect(find.text('--'), findsWidgets);
    });

    testWidgets('auth failure → profile fields "--", HC nights still show',
        (tester) async {
      final minutes = sampleMinutes();
      await _pump(
        tester,
        SleepScreen(
          backend: _backendUnauthorized(),
          healthConnect: FakeHealthConnect(minutes: minutes),
        ),
      );
      // Hero falls back to today's HC read; deficit unknown → "--".
      expect(find.text('7h 30m'), findsWidgets);
      expect(find.text('Deficit: --'), findsOneWidget);
    });
  });

  // ── Body Info ──────────────────────────────────────────────────────

  group('BodyInfoScreen', () {
    testWidgets('renders conditions from the profile blob',
        (tester) async {
      await _pump(
        tester,
        BodyInfoScreen(
          backend: _backendWithProfile({
            'conditions': jsonEncode(['POTS', {'name': 'MCAS'}]),
          }),
        ),
      );
      expect(find.text('Body Info & Impact Map'), findsOneWidget);
      expect(find.text('POTS'), findsOneWidget);
      expect(find.text('MCAS'), findsOneWidget);
      expect(find.text('2 Active'), findsOneWidget);
      expect(find.text('2 conditions tracked'), findsOneWidget);
    });

    testWidgets('empty conditions → "All Body Zones Normal"',
        (tester) async {
      await _pump(
        tester,
        BodyInfoScreen(backend: _backendWithProfile({'conditions': '[]'})),
      );
      expect(find.text('All Body Zones Normal'), findsOneWidget);
      expect(find.text('All body zones normal'), findsOneWidget);
    });

    testWidgets('auth failure → honest empty, no crash', (tester) async {
      await _pump(
        tester,
        BodyInfoScreen(backend: _backendUnauthorized()),
      );
      expect(find.text('All Body Zones Normal'), findsOneWidget);
    });

    testWidgets('malformed blob → honest empty, no crash', (tester) async {
      await _pump(
        tester,
        BodyInfoScreen(
            backend: _backendWithProfile({'conditions': '{{bad'})),
      );
      expect(find.text('All Body Zones Normal'), findsOneWidget);
    });

    test('collectConditions dedupes and skips blank names', () {
      final out = collectConditions([
        {'name': 'POTS'},
        {'name': 'pots'}, // duplicate, case-insensitive
        {'name': '  '},
        {'title': 'hEDS'},
      ]);
      expect(out.map((c) => c.name), ['POTS', 'hEDS']);
    });
  });

  // ── Medications ────────────────────────────────────────────────────

  group('MedicationsScreen', () {
    Map<String, dynamic> sampleMedsPayload() => {
          'medications': jsonEncode([
            {
              'name': 'Pyridostigmine',
              'dose': '60mg',
              'frequency': '3x daily',
              'startDate': 'Sep 1, 2026',
              'isPresent': true,
            },
            {
              // "As prescribed" is not a real dose → not-set line.
              'name': 'Escitalopram',
              'dose': 'As prescribed',
              'frequency': 'Daily',
              'isPresent': true,
            },
            {
              'name': 'Carvedilol',
              'dose': 'As prescribed',
              'frequency': 'Daily',
              'isPresent': false,
              'endDate': 'Aug 20, 2026',
            },
          ]),
        };

    testWidgets('renders active + archived meds from the blob',
        (tester) async {
      await _pump(
        tester,
        MedicationsScreen(
            backend: _backendWithProfile(sampleMedsPayload())),
      );
      expect(find.text('Medications & Side Effects'), findsOneWidget);
      expect(find.text('2 Active Medication(s)'), findsOneWidget);
      expect(find.text('Pyridostigmine'), findsOneWidget);
      expect(find.text('60mg  •  3x daily'), findsOneWidget);
      expect(find.text('Started Sep 1, 2026'), findsOneWidget);
      expect(find.text('Escitalopram'), findsOneWidget);
      // "As prescribed" is not a real dose → dose line shows not set.
      expect(find.text('Dose not set  •  Daily'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
      // Archived section sits below the fold in the test viewport —
      // scroll it into view like a real user would.
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('Carvedilol'), findsOneWidget);
      expect(find.text('Ended Aug 20, 2026'), findsOneWidget);
    });

    testWidgets('empty blob → "No Active Medications"', (tester) async {
      await _pump(
        tester,
        MedicationsScreen(
            backend: _backendWithProfile({'medications': '[]'})),
      );
      expect(find.text('No Active Medications'), findsOneWidget);
    });

    testWidgets('auth failure → honest empty, no crash', (tester) async {
      await _pump(
        tester,
        MedicationsScreen(backend: _backendUnauthorized()),
      );
      expect(find.text('No Active Medications'), findsOneWidget);
    });

    testWidgets('malformed blob → honest empty, no crash', (tester) async {
      await _pump(
        tester,
        MedicationsScreen(
            backend: _backendWithProfile({'medications': 'nope['})),
      );
      expect(find.text('No Active Medications'), findsOneWidget);
    });

    test('MedicationEntry parsing honors isPresent/isArchived', () {
      final present = MedicationEntry.fromBlobRow({
        'name': 'Ivabradine',
        'dose': '7.5mg',
        'isPresent': true,
      });
      expect(present, isNotNull);
      expect(present!.isArchived, isFalse);
      expect(present.frequency, 'Once daily'); // default

      final ended = MedicationEntry.fromBlobRow({
        'name': 'Old Med',
        'isPresent': false,
        'endDate': 'Jan 1, 2026',
      });
      expect(ended, isNotNull);
      expect(ended!.isArchived, isTrue);

      expect(MedicationEntry.fromBlobRow({'name': '  '}), isNull);
    });

    test('isDoseValid mirrors the native rule', () {
      final valid = MedicationEntry(
        name: 'A',
        dose: '60mg',
        frequency: 'Daily',
        startDate: 'Sep 1, 2026',
        isPresent: true,
      );
      final asPrescribed = MedicationEntry(
        name: 'B',
        dose: 'As prescribed',
        frequency: 'Daily',
        startDate: 'Sep 1, 2026',
        isPresent: true,
      );
      final noStart = MedicationEntry(
        name: 'C',
        dose: '60mg',
        frequency: 'Daily',
        isPresent: true,
      );
      expect(isDoseValid(valid), isTrue);
      expect(isDoseValid(asPrescribed), isFalse);
      expect(isDoseValid(noStart), isFalse);
    });
  });
}
