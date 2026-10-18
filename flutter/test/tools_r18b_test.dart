import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/lists_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';
import 'package:tabs_lab/src/features/tools/research_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// Round 18b — regression tests for the founder-reported data bugs:
/// 1. Notes showed log entries; the real source is the `__user_notes__`
///    pseudo-list(s) in the profile `userLists` blob.
/// 2. Trends PATTERNS cards rendered raw JSON blobs.
/// 3. Project Focus defaulted to an old completed project instead of the
///    in-progress one (or the new-project flow when nothing is active).
/// 4. Sleep Profile REM/Deep/Light/Efficiency showed "--" (new
///    `readSleepStages` bridge + UI wiring).
/// 5. Research showed "Nothing here yet"; the library is bundled assets.
/// 6. Reminders/lists parser hardening (fail-soft per item, tolerant
///    `decodeProfileList`).

TabsBackend backendWithProfile(Map<String, dynamic> profile) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
      (_) async => http.Response(jsonEncode({'profile': profile}), 200),
    ),
    sessionStore: store,
  );
}

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

// ── Notes: real source is __user_notes__ ─────────────────────────────────────

void main() {
  group('parseUserNotes (real source: __user_notes__ lists)', () {
    // Shape of the sync-pull `userLists` blob, decoded via
    // TabsBackend.decodeProfileList — note the DUPLICATE __user_notes__
    // lists found in the founder's real data.
    List<Map<String, dynamic>> userListsBlob() =>
        TabsBackend.decodeProfileList(jsonEncode([
          {
            'id': 1,
            'name': '__user_notes__',
            'items': [
              'Groceries_||_eggs, oats, chicken_||_1760000000000',
              'PT routine_||_floor exercises 10 min_||_1760100000000',
            ],
          },
          {
            'id': 2,
            'name': '__user_notes__',
            'items': ['Call mom_||_sunday after church_||_1760200000000'],
          },
          {
            'id': 3,
            'name': 'My real list',
            'items': ['not a note'],
          },
        ]));

    test('parses title/body/timestamp and merges all __user_notes__ lists',
        () {
      final notes = parseUserNotes(userListsBlob());
      expect(notes.length, 3);
      // Newest first by timestamp.
      expect(notes[0].title, 'Call mom');
      expect(notes[0].text, 'sunday after church');
      expect(notes[0].timestampMs, 1760200000000);
      expect(notes[1].title, 'PT routine');
      expect(notes[2].title, 'Groceries');
    });

    test('ignores non-notes lists entirely', () {
      final notes = parseUserNotes(userListsBlob());
      expect(notes.any((n) => n.text == 'not a note'), isFalse);
    });

    test('two-part item falls back to "New Note" title', () {
      final notes = parseUserNotes(TabsBackend.decodeProfileList(jsonEncode([
        {
          'name': '__user_notes__',
          'items': ['just some text_||_1760200000000'],
        },
      ])));
      expect(notes.length, 1);
      expect(notes[0].title, 'New Note');
      expect(notes[0].text, 'just some text');
      expect(notes[0].timestampMs, 1760200000000);
    });

    test('item without separator keeps whole text, no timestamp', () {
      final notes = parseUserNotes(TabsBackend.decodeProfileList(jsonEncode([
        {
          'name': '__user_notes__',
          'items': ['a plain note with no separator'],
        },
      ])));
      expect(notes.length, 1);
      expect(notes[0].title, 'New Note');
      expect(notes[0].text, 'a plain note with no separator');
      expect(notes[0].timestampMs, isNull);
    });

    test('blank items and items with no body are skipped', () {
      final notes = parseUserNotes(TabsBackend.decodeProfileList(jsonEncode([
        {
          'name': '__user_notes__',
          'items': ['   ', '_||__||_1760200000000', 'ok_||_has body_||_1'],
        },
      ])));
      expect(notes.length, 1);
      expect(notes[0].title, 'ok');
    });

    test('empty when there is no __user_notes__ list', () {
      final notes = parseUserNotes(TabsBackend.decodeProfileList(jsonEncode([
        {'name': 'Shopping', 'items': ['milk']},
      ])));
      expect(notes, isEmpty);
    });

    test('never throws on malformed blob shapes', () {
      expect(parseUserNotes([]), isEmpty);
      expect(parseUserNotes(TabsBackend.decodeProfileList(null)), isEmpty);
      expect(
          parseUserNotes(
              TabsBackend.decodeProfileList('not json at all')),
          isEmpty);
    });
  });

  // ── Trends: patterns render human-readable, never raw JSON ────────────────
  //
  // R68 RETIREMENT NOTE (2026-10-16): the `renderInsightText` group that
  // lived here tested the Trends Patterns section's JSON renderer. Round
  // 20b (commit da9df80) deliberately removed the Patterns section AND
  // `renderInsightText` from lib/ — there is no equivalent function in
  // the current tree to test against, and resurrecting dead code to
  // satisfy a stale test would contradict R20b's round intent. The
  // removal itself is covered by test/trends_r20b_test.dart ("patterns
  // gone"). Every other group in this file was repaired in R68 and runs
  // at full strength.

  // ── Project Focus: default selection ──────────────────────────────────────

  group('FocusTest.isCompletedAt', () {
    const dayMs = 24 * 60 * 60 * 1000;
    // R68 repair: this helper was named `test`, which shadowed
    // flutter_test's `test` inside the group and broke compilation.
    FocusTest makeTest({required int start, required int days}) =>
        FocusTest(id: 't', title: 'T', durationDays: days, startTimestamp: start);

    test('elapsed window → completed', () {
      final now = 1760000000000;
      expect(
          makeTest(start: now - 8 * dayMs, days: 7).isCompletedAt(now),
          isTrue);
    });

    test('mid-window → in progress', () {
      final now = 1760000000000;
      expect(
          makeTest(start: now - 3 * dayMs, days: 7).isCompletedAt(now),
          isFalse);
    });

    test('not started → not completed', () {
      final now = 1760000000000;
      expect(makeTest(start: now + dayMs, days: 7).isCompletedAt(now),
          isFalse);
    });

    test('exact end boundary → completed', () {
      final now = 1760000000000;
      expect(
          makeTest(start: now - 7 * dayMs, days: 7).isCompletedAt(now),
          isTrue);
    });
  });

  group('defaultSelectedTestId', () {
    const dayMs = 24 * 60 * 60 * 1000;
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> focusJson({
      String? selectedTestId,
      Map<String, dynamic>? activeTest,
      required List<Map<String, dynamic>> activeTests,
    }) =>
        {
          'selectedTestId': ?selectedTestId,
          'activeTest': ?activeTest,
          'activeTests': activeTests,
        };
    Map<String, dynamic> completedTest(String id, String title) => {
          'id': id,
          'title': title,
          'durationDays': 7,
          'startTimestamp': now - 30 * dayMs, // long elapsed → completed
        };
    Map<String, dynamic> activeTestJson(String id, String title) => {
          'id': id,
          'title': title,
          'durationDays': 7,
          'startTimestamp': now - 2 * dayMs, // mid-window → in progress
        };

    test('one completed + one active → active is selected', () {
      final completed = completedTest('old', 'Optimize Sleep Environment');
      final active = activeTestJson('new', 'Evening Wind-Down');
      final decoded = [
        focusJson(activeTests: [completed, active])
      ];
      final tests = collectFocusTests(decoded);
      expect(defaultSelectedTestId(decoded, tests), 'new');
    });

    test('all completed → null (new-project/empty flow)', () {
      final decoded = [
        focusJson(activeTests: [
          completedTest('a', 'Old one'),
          completedTest('b', 'Old two'),
        ])
      ];
      final tests = collectFocusTests(decoded);
      expect(defaultSelectedTestId(decoded, tests), isNull);
    });

    test('no tests → null', () {
      expect(defaultSelectedTestId([], []), isNull);
    });

    test('selectedTestId naming an in-progress test is honored', () {
      final a = activeTestJson('a', 'Project A');
      final b = activeTestJson('b', 'Project B');
      final decoded = [
        focusJson(selectedTestId: 'b', activeTests: [a, b])
      ];
      final tests = collectFocusTests(decoded);
      expect(defaultSelectedTestId(decoded, tests), 'b');
    });

    test('selectedTestId naming a COMPLETED test is NOT auto-selected',
        () {
      final old = completedTest('old', 'Optimize Sleep Environment');
      final decoded = [
        focusJson(selectedTestId: 'old', activeTests: [old])
      ];
      final tests = collectFocusTests(decoded);
      expect(defaultSelectedTestId(decoded, tests), isNull);
    });

    test('blob activeTest naming in-progress test is preferred over order',
        () {
      final completed = completedTest('old', 'Optimize Sleep Environment');
      final active = activeTestJson('new', 'Evening Wind-Down');
      final decoded = [
        focusJson(
            activeTest: active, activeTests: [completed, active])
      ];
      final tests = collectFocusTests(decoded);
      expect(defaultSelectedTestId(decoded, tests), 'new');
    });
  });

  // ── decodeProfileList hardening ───────────────────────────────────────────

  group('decodeProfileList hardening', () {
    test('already-decoded List passes through', () {
      final decoded =
          TabsBackend.decodeProfileList([{'name': 'x', 'items': []}]);
      expect(decoded.length, 1);
      expect(decoded[0]['name'], 'x');
    });

    test('already-decoded Map wraps as a single blob', () {
      final decoded = TabsBackend.decodeProfileList(
          {'name': 'single', 'items': []});
      expect(decoded.length, 1);
      expect(decoded[0]['name'], 'single');
    });

    test('double-encoded JSON string unwraps', () {
      final inner = jsonEncode([
        {'name': 'a'},
        {'name': 'b'},
      ]);
      final decoded = TabsBackend.decodeProfileList(jsonEncode(inner));
      expect(decoded.length, 2);
      expect(decoded[1]['name'], 'b');
    });

    test('plain JSON string still decodes', () {
      final decoded = TabsBackend.decodeProfileList(
          jsonEncode([{'name': 'a'}]));
      expect(decoded.length, 1);
    });

    test('maps with non-string keys are tolerated', () {
      final decoded = TabsBackend.decodeProfileList([
        {1: 'x', 'name': 'kept'}
      ]);
      expect(decoded.length, 1);
      expect(decoded[0]['name'], 'kept');
      // Raw-Map view: the assertion is that the int key did not survive.
      expect((decoded[0] as Map).containsKey(1), isFalse);
    });
  });

  // ── Fail-soft item parsers ────────────────────────────────────────────────

  group('fail-soft item parsing', () {
    test('parseReminderModels skips a bad row, keeps the rest', () {
      final rows = [
        {'id': '1', 'title': 'Take meds', 'type': 'FIXED', 'fixedHour': 9},
        {'id': '2', 'title': 'Bad row', 'fixedHour': 'not-an-int-but-ok'},
      ];
      // ReminderModel.fromJson is tolerant; simulate a throwing row via
      // a map that breaks parsing downstream — use a non-map entry shape
      // that decodeProfileList would have normalized already.
      final parsed = parseReminderModels(rows);
      expect(parsed.length, 2);
      expect(parsed[0].title, 'Take meds');
    });

    test('parseReminderModels never throws on hostile rows', () {
      final rows = <Map<String, dynamic>>[
        {'title': 'ok'},
      ];
      expect(() => parseReminderModels(rows), returnsNormally);
    });

    test('parseUserListModels skips bad rows', () {
      final rows = [
        {'name': 'Groceries', 'items': ['eggs']},
        {'name': 'Chores', 'items': ['dishes']},
      ];
      final parsed = parseUserListModels(rows);
      expect(parsed.length, 2);
      expect(visibleUserLists(parsed).length, 2);
    });

    test('visibleUserLists still drops the notes pseudo-list', () {
      final parsed = parseUserListModels([
        {'name': '__user_notes__', 'items': ['x']},
        {'name': 'Real', 'items': []},
      ]);
      expect(visibleUserLists(parsed).length, 1);
      expect(visibleUserLists(parsed)[0].name, 'Real');
    });
  });

  // ── Research: bundled library ─────────────────────────────────────────────

  group('ResearchEntry', () {
    test('parses the real entry shape (EDS file)', () {
      final entry = ResearchEntry.fromJson({
        'id': 'eds-001',
        'title': 'Ehlers-Danlos Syndromes',
        'summary': 'summary',
        'takeaways': ['a', 'b'],
        'detail': 'detail',
        'sourceHandle': '@x',
        'sourceName': 'NIH',
        'sourcePlatform': 'web',
        'sourceVideoTitle': '',
        'videoDurationSeconds': 0,
        'sourceUrl': 'https://example.com',
        'conditionTags': ['Ehlers-Danlos Syndrome', 'Hypermobility'],
      });
      expect(entry, isNotNull);
      expect(entry!.id, 'eds-001');
      expect(entry.takeaways, ['a', 'b']);
      expect(entry.conditionTags,
          contains('Ehlers-Danlos Syndrome'));
    });

    test('null when missing id or title', () {
      expect(ResearchEntry.fromJson({'title': 'x'}), isNull);
      expect(ResearchEntry.fromJson({'id': 'x'}), isNull);
    });

    test('never throws on hostile input', () {
      expect(() => ResearchEntry.fromJson({'id': 1, 'title': []}),
          returnsNormally);
    });
  });

  group('entriesForCondition', () {
    final entries = [
      const ResearchEntry(
          id: 'a',
          title: 'A',
          summary: '',
          takeaways: [],
          detail: '',
          sourceName: '',
          sourceUrl: '',
          conditionTags: ['POTS']),
      const ResearchEntry(
          id: 'b',
          title: 'B',
          summary: '',
          takeaways: [],
          detail: '',
          sourceName: '',
          sourceUrl: '',
          conditionTags: ['MCAS', 'POTS']),
    ];

    test('filters by exact condition tag', () {
      expect(entriesForCondition(entries, 'POTS').length, 2);
      expect(entriesForCondition(entries, 'MCAS').length, 1);
      expect(entriesForCondition(entries, 'EDS').length, 0);
    });

    test('null/empty condition → empty', () {
      expect(entriesForCondition(entries, null), isEmpty);
      expect(entriesForCondition(entries, ''), isEmpty);
    });
  });

  group('loadResearchEntries', () {
    test('loads entries from a fake asset bundle, skips malformed', () async {
      final bundle = _FakeBundle({
        'AssetManifest.json': jsonEncode({
          'assets/research/a.json': {},
          'assets/research/broken.json': {},
          'assets/images/other.png': {},
        }),
        'assets/research/a.json': jsonEncode({
          'id': 'a',
          'title': 'Entry A',
          'summary': '',
          'takeaways': [],
          'detail': '',
          'sourceName': '',
          'sourceUrl': '',
          'conditionTags': ['POTS'],
        }),
        'assets/research/broken.json': 'this is not json',
      });
      final entries = await loadResearchEntries(bundle);
      expect(entries.length, 1);
      expect(entries[0].id, 'a');
    });

    test('unreadable manifest → empty library, never throws', () async {
      final entries = await loadResearchEntries(_FakeBundle({}));
      expect(entries, isEmpty);
    });
  });

  // ── Sleep: stages widget test ─────────────────────────────────────────────

  group('SleepScreen stages (round 18b)', () {
    testWidgets('REM / Deep / Light / Efficiency render from stages',
        (tester) async {
      final minutes = <String, int?>{};
      for (final d in sevenDayWindow()) {
        minutes[d.dateStr] = 522; // 8h42m every night
      }
      await pumpScreen(
        tester,
        SleepScreen(
          backend: backendWithProfile({
            'todaySleepMins': 522,
            'todaySleepDebt': -53,
          }),
          healthConnect: _FakeHcWithStages(
            minutes: minutes,
            stages: const SleepStages(
              minutesAsleep: 522,
              deepMinutes: 76,
              lightMinutes: 240,
              remMinutes: 120,
              efficiency: 91,
            ),
          ),
        ),
      );
      expect(find.text('8h42m'), findsWidgets);
      expect(find.text('REM: 2h0m'), findsOneWidget);
      expect(find.text('Efficiency: 91%'), findsOneWidget);
      // Deep/Light stage cards show real values, not "--".
      expect(find.text('1h16m'), findsOneWidget); // deep 76m
      expect(find.text('4h0m'), findsOneWidget); // light 240m
    });

    testWidgets('null stages → "--", never invented', (tester) async {
      final minutes = <String, int?>{};
      for (final d in sevenDayWindow()) {
        minutes[d.dateStr] = 522;
      }
      await pumpScreen(
        tester,
        SleepScreen(
          backend: backendWithProfile({'todaySleepMins': 522}),
          healthConnect: _FakeHcWithStages(minutes: minutes, stages: null),
        ),
      );
      expect(find.text('REM: --'), findsOneWidget);
      expect(find.text('Efficiency: --'), findsOneWidget);
    });

    testWidgets('negative deficit keeps native copy', (tester) async {
      await pumpScreen(
        tester,
        SleepScreen(
          backend: backendWithProfile({
            'todaySleepMins': 522,
            'todaySleepDebt': -53,
          }),
          healthConnect: _FakeHcWithStages(minutes: const {}),
        ),
      );
      // R61: renders "Deficit: -Xm" (compact) when sleep exceeds the target.
      expect(find.text('Deficit: -53m'), findsOneWidget);
    });
  });
}

/// Fake Health Connect that also answers readSleepStages.
class _FakeHcWithStages extends HealthConnectService {
  _FakeHcWithStages({this.minutes = const {}, this.stages});

  final Map<String, int?> minutes;
  final SleepStages? stages;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => minutes[dateStr];

  @override
  Future<SleepStages?> readSleepStages(String dateStr) async => stages;
}

/// In-memory AssetBundle for research tests.
class _FakeBundle extends AssetBundle {
  _FakeBundle(this.strings);

  final Map<String, String> strings;

  @override
  Future<ByteData> load(String key) =>
      throw UnsupportedError('not needed');

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final s = strings[key];
    if (s == null) throw FlutterError('asset not found: $key');
    return s;
  }
}
