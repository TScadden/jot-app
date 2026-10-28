import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingDayStart;
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/intake_logging.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Phase 1 item 4 — salt & fluid tracking (spec §9 test plan).
/// Numbers in test names map to the spec's §9 items.

const _owner = 'founder@example.com';

Map<String, dynamic> _catJson(int id, String name) => {
      'id': id,
      'name': name,
      'icon': 'circle',
      'colorHex': '#4ECDC4',
      'isDefault': true,
      'sortOrder': 0,
    };

/// Hydration resolves BY NAME at a non-1 id.
final _catsHydration = [
  _catJson(7, 'Hydration'),
  _catJson(3, 'Symptoms'),
  _catJson(6, 'Mood & Energy'),
];

/// No Hydration category at all (the surface must hide). Note id 1
/// IS present under another name — intake has no fallback id.
final _catsNoHydration = [
  _catJson(1, 'Symptoms'),
  _catJson(6, 'Mood & Energy'),
];

QuickLogEntry _intakeEntry({
  required int id,
  required IntakeDraft draft,
  int categoryId = 7,
}) =>
    buildIntakeEntry(id: id, categoryId: categoryId, draft: draft);

Map<String, dynamic> _entryJson(QuickLogEntry e) => {
      'id': e.id,
      'categoryId': e.categoryId,
      'body': e.body,
      'chips': e.chips,
      'manualText': e.manualText,
      'timestamp': e.timestamp,
    };

/// Fake server: pull reflects only what a POST actually applied;
/// POSTs are gateable and failable; DELETEs are recorded; EVERY
/// request is logged so tests can assert the §4.3 prohibitions as
/// absence (no category writes, no profile-blob writes).
class _Server {
  _Server(this.entries, {required this.categories, this.failPosts = false});

  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> categories;
  bool failPosts;
  Completer<void>? postGate;
  final List<Map<String, dynamic>> capturedPosts = [];
  final List<int> capturedDeletes = [];
  final List<String> requestLog = [];

  TabsBackend backend() {
    final store = FakeSessionStore()
      ..token = 'test-token'
      ..email = _owner;
    final client = MockClient((request) async {
      requestLog.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': categories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path == '/api/sync/entries' && request.method == 'POST') {
        final gate = postGate;
        if (gate != null) await gate.future;
        if (failPosts) return http.Response('server error', 500);
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        final rows = (decoded['entries'] as List).cast<Map<String, dynamic>>();
        capturedPosts.addAll(rows);
        for (final row in rows) {
          final i = entries.indexWhere((e) => e['id'] == row['id']);
          if (i >= 0) {
            entries[i] = {...entries[i], ...row};
          } else {
            entries.add(row);
          }
        }
        return http.Response('{"ok":true}', 200);
      }
      if (request.url.path.startsWith('/api/sync/entries/') &&
          request.method == 'DELETE') {
        final id = int.parse(request.url.path.split('/').last);
        capturedDeletes.add(id);
        entries.removeWhere((e) => e['id'] == id);
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }
}

WeatherApiClient _weather() => WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200,
          );
        }
        return http.Response(
          '{"current":{"temperature_2m":70.0,"weather_code":2,"is_day":1}}',
          200,
        );
      }),
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 300,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Map<String, String> disk;
  late Map<String, String> settingsDisk;
  late bool diskWriteFails;

  SettingsStore settingsStore() => SettingsStore.withStorage(
        read: (key) async => settingsDisk[key],
        write: (key, value) async => settingsDisk[key] = value,
        delete: (key) async => settingsDisk.remove(key),
      );

  setUp(() {
    TabsBackend.debugResetSharedCaches();
    disk = <String, String>{};
    settingsDisk = <String, String>{};
    diskWriteFails = false;
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async {
        if (diskWriteFails) throw StateError('disk full');
        disk[key] = value;
      },
      delete: (key) async => disk.remove(key),
    );
  });

  tearDown(() {
    LogEntryOutbox.instance.debugReset();
  });

  Future<void> pumpHome(
    WidgetTester tester,
    _Server server, {
    bool expectCard = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        weatherApi: _weather(),
        tabsBackend: server.backend(),
        logEntryOutbox: LogEntryOutbox.instance,
        settingsStore: settingsStore(),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.text('Salt & water').evaluate().isNotEmpty || !expectCard,
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('payload & derivation (§9 items 1–4)', () {
    test('1: payload round-trip is exact; mixed-kind totals are '
        'exact integer sums; bodies are Juno U1 patterns', () {
      const payload = IntakePayload(
        kind: 'Water',
        fluidMl: 473,
      );
      expect(jsonDecode(payload.encode()), {'v': 1, 'kind': 'Water', 'fluidMl': 473});
      final parsed = IntakePayload.tryParse(payload.encode());
      expect(parsed?.kind, 'Water');
      expect(parsed?.fluidMl, 473);
      expect(parsed?.sodiumMg, isNull);

      final day = DateTime(2026, 10, 28, 12, 0);
      DateTime at(int h) => DateTime(2026, 10, 28, h);
      final entries = [
        _intakeEntry(
          id: 1,
          draft: IntakeDraft(kind: 'Water', fluidMl: 473, time: at(8)),
        ),
        _intakeEntry(
          id: 2,
          draft: IntakeDraft(
            kind: 'Electrolyte drink',
            fluidMl: 355,
            sodiumMg: 500,
            time: at(10),
          ),
        ),
        _intakeEntry(
          id: 3,
          draft: IntakeDraft(
            kind: 'Salt',
            sodiumMg: 393,
            saltMg: 1000,
            time: at(11),
          ),
        ),
        _intakeEntry(
          id: 4,
          draft: IntakeDraft(kind: 'Water', fluidMl: 250, time: at(13)),
        ),
      ];
      expect(entries[0].body, 'Water · 16 fl oz');
      expect(entries[1].body, 'Electrolyte drink · 500 mg sodium');
      expect(entries[2].body, 'Salt · 1 g');
      expect(entries[0].chips, '["Intake","Water"]');
      final totals = intakeTotalsForDay(entries, now: day);
      expect(totals.fluidMl, 473 + 355 + 250);
      expect(totals.sodiumMg, 500 + 393);
      expect(totals.eventCount, 4);
      expect(totals.excludedCount, 0);
      expect(totals.hasData, isTrue);
    });

    test('2: corrupt/absent payloads are excluded AND counted; '
        'untagged free-text contributes nothing (§5.4)', () {
      final day = DateTime(2026, 10, 28, 12, 0);
      final ts = DateTime(2026, 10, 28, 9).millisecondsSinceEpoch;
      QuickLogEntry raw({
        required int id,
        required String chips,
        required String manualText,
        String body = 'x',
      }) =>
          QuickLogEntry(
            id: id,
            categoryId: 7,
            body: body,
            chips: chips,
            manualText: manualText,
            timestamp: ts,
          );
      final entries = [
        // Tagged, corrupt payload.
        raw(id: 1, chips: '["Intake","Water"]', manualText: 'not json'),
        // Tagged, absent payload.
        raw(id: 2, chips: '["Intake","Salt"]', manualText: ''),
        // Tagged, wrong payload version.
        raw(
          id: 3,
          chips: '["Intake","Water"]',
          manualText: '{"v":2,"kind":"Water","fluidMl":500}',
        ),
        // Untagged free text mentioning water/salt — never parsed.
        raw(
          id: 4,
          chips: '[]',
          manualText: '',
          body: 'drank 16 oz water and took salt pills',
        ),
        // Payload-shaped manualText but NO reserved tag.
        raw(
          id: 5,
          chips: '["Daily Ranking"]',
          manualText: '{"v":1,"kind":"Water","fluidMl":500}',
        ),
      ];
      final totals = intakeTotalsForDay(entries, now: day);
      expect(totals.eventCount, 0);
      expect(totals.excludedCount, 3);
      expect(totals.fluidMl, 0);
      expect(totals.sodiumMg, 0);
      // Zero EVENTS = no-data, never a zero-total day (§5.2).
      expect(totals.hasData, isFalse);
    });

    test("3: legacy ', '-joined chips carrying the tag parse; "
        'JSON list parses; bare-list parses', () {
      expect(parseIntakeChips('Intake, Water'), ['Intake', 'Water']);
      expect(parseIntakeChips('["Intake","Salt"]'), ['Intake', 'Salt']);
      expect(parseIntakeChips('[Intake, Water]'), ['Intake', 'Water']);
      expect(parseIntakeChips(''), isEmpty);
      expect(parseIntakeChips('not json'), ['not json']);
      final legacy = QuickLogEntry(
        id: 1,
        categoryId: 7,
        body: 'Water · 16 fl oz',
        chips: 'Intake, Water',
        manualText: '{"v":1,"kind":"Water","fluidMl":473}',
        timestamp: DateTime(2026, 10, 28, 9).millisecondsSinceEpoch,
      );
      expect(isIntakeEntry(legacy), isTrue);
      final totals =
          intakeTotalsForDay([legacy], now: DateTime(2026, 10, 28, 12));
      expect(totals.fluidMl, 473);
      expect(totals.eventCount, 1);
      // A joined string that merely mentions the word in prose is
      // not the tag.
      final prose = QuickLogEntry(
        id: 2,
        categoryId: 7,
        body: 'x',
        chips: 'Not an Intake entry, honestly',
        manualText: '',
        timestamp: legacy.timestamp,
      );
      expect(isIntakeEntry(prose), isFalse);
    });

    test('4: salt→sodium at the constant, applied once; sodium as '
        'entered; one event never double-counted', () {
      expect(saltMgToSodiumMg(1000), 393);
      expect(saltMgToSodiumMg(2000), 786);
      expect(saltMgToSodiumMg(500), 197);
      final day = DateTime(2026, 10, 28, 12, 0);
      DateTime at(int h) => DateTime(2026, 10, 28, h);
      final saltEntered = _intakeEntry(
        id: 1,
        draft: IntakeDraft(
          kind: 'Salt',
          sodiumMg: saltMgToSodiumMg(1000),
          saltMg: 1000,
          time: at(9),
        ),
      );
      // The payload carries BOTH saltMg (declared input) and the
      // converted sodiumMg; derivation reads sodiumMg only — the
      // salt grams are never ALSO converted and added.
      var totals = intakeTotalsForDay([saltEntered], now: day);
      expect(totals.sodiumMg, 393);
      final sodiumEntered = _intakeEntry(
        id: 2,
        draft: IntakeDraft(kind: 'Salt', sodiumMg: 500, time: at(10)),
      );
      totals = intakeTotalsForDay([saltEntered, sodiumEntered], now: day);
      expect(totals.sodiumMg, 393 + 500);
    });
  });

  group('day & target logic (§9 items 5–8)', () {
    test('5: energy-day boundary — 03:59 and 04:00 land on '
        'different intake days', () {
      final before = _intakeEntry(
        id: 1,
        draft: IntakeDraft(
          kind: 'Water',
          fluidMl: 100,
          time: DateTime(2026, 10, 28, 3, 59),
        ),
      );
      final after = _intakeEntry(
        id: 2,
        draft: IntakeDraft(
          kind: 'Water',
          fluidMl: 200,
          time: DateTime(2026, 10, 28, 4, 0),
        ),
      );
      final entries = [before, after];
      // Midday Oct 28: the current energy day opened at 04:00.
      expect(
        intakeTotalsForDay(entries, now: DateTime(2026, 10, 28, 12)).fluidMl,
        200,
      );
      // 03:30 Oct 28: the energy day still opened Oct 27 04:00.
      expect(
        intakeTotalsForDay(entries, now: DateTime(2026, 10, 28, 3, 30))
            .fluidMl,
        100,
      );
      expect(
        intakeTotalsForDayStart(entries,
                dayStart: DateTime(2026, 10, 27, 4))
            .eventCount,
        1,
      );
      expect(
        intakeTotalsForDayStart(entries,
                dayStart: DateTime(2026, 10, 28, 4))
            .eventCount,
        1,
      );
    });

    test('6: a zero-event day is a no-data verdict — excluded from '
        'hit/miss, never a zero total', () {
      final totals = intakeTotalsForDay(const [], now: DateTime(2026, 10, 28, 12));
      expect(totals.hasData, isFalse);
      expect(totals.eventCount, 0);
      final summary = summarizeIntake(
        entries: const [],
        startDay: DateTime(2026, 10, 26, 12),
        endDay: DateTime(2026, 10, 28, 12),
        targets: [
          IntakeTargetVersion(
            fluidTargetMl: 100,
            sodiumTargetMg: 100,
            effectiveFromDayMs:
                DateTime(2026, 10, 26, 4).millisecondsSinceEpoch,
          ),
        ],
      );
      expect(summary.daysWithData, 0);
      expect(summary.fluidHitDays, 0);
      expect(summary.sodiumHitDays, 0);
      expect(summary.perDay, isEmpty);
    });

    test("7: a target edited effective today doesn't change "
        "yesterday's verdict", () {
      DateTime at(int d, int h) => DateTime(2026, 10, d, h);
      final entries = [
        _intakeEntry(
          id: 1,
          draft: IntakeDraft(kind: 'Water', fluidMl: 1500, time: at(27, 10)),
        ),
        _intakeEntry(
          id: 2,
          draft: IntakeDraft(kind: 'Water', fluidMl: 1500, time: at(28, 10)),
        ),
      ];
      final v1 = IntakeTargetVersion(
        fluidTargetMl: 1000,
        effectiveFromDayMs: at(27, 4).millisecondsSinceEpoch,
      );
      final v2 = IntakeTargetVersion(
        fluidTargetMl: 2000,
        effectiveFromDayMs: at(28, 4).millisecondsSinceEpoch,
      );
      final versions = [v1, v2];
      expect(
        intakeTargetsInForce(versions, dayStart: at(27, 4))?.fluidTargetMl,
        1000,
      );
      expect(
        intakeTargetsInForce(versions, dayStart: at(28, 4))?.fluidTargetMl,
        2000,
      );
      final summary = summarizeIntake(
        entries: entries,
        startDay: at(27, 12),
        endDay: at(28, 12),
        targets: versions,
      );
      expect(summary.perDay, hasLength(2));
      // Yesterday: 1500 >= 1000 (the target then in force) = hit.
      expect(summary.perDay[0].fluidHit, isTrue);
      // Today: 1500 < 2000 (the edited target) = miss.
      expect(summary.perDay[1].fluidHit, isFalse);
      expect(summary.fluidHitDays, 1);
    });

    test('8: exactly-at-target = hit, one below = miss, fluid and '
        'sodium independent', () {
      DateTime at(int d, int h) => DateTime(2026, 10, d, h);
      final targets = [
        IntakeTargetVersion(
          fluidTargetMl: 500,
          sodiumTargetMg: 400,
          effectiveFromDayMs: at(27, 4).millisecondsSinceEpoch,
        ),
      ];
      final entries = [
        // Day A: fluid exactly at target, sodium one below.
        _intakeEntry(
          id: 1,
          draft: IntakeDraft(
            kind: 'Electrolyte drink',
            fluidMl: 500,
            sodiumMg: 399,
            time: at(27, 10),
          ),
        ),
        // Day B: fluid one below, sodium exactly at target.
        _intakeEntry(
          id: 2,
          draft: IntakeDraft(
            kind: 'Electrolyte drink',
            fluidMl: 499,
            sodiumMg: 400,
            time: at(28, 10),
          ),
        ),
      ];
      final summary = summarizeIntake(
        entries: entries,
        startDay: at(27, 12),
        endDay: at(28, 12),
        targets: targets,
      );
      expect(summary.perDay[0].fluidHit, isTrue);
      expect(summary.perDay[0].sodiumHit, isFalse);
      expect(summary.perDay[1].fluidHit, isFalse);
      expect(summary.perDay[1].sodiumHit, isTrue);
      expect(summary.fluidHitDays, 1);
      expect(summary.sodiumHitDays, 1);
    });
  });

  group('category resolution (Q4 — name only, no fallback)', () {
    test('name hit at any id; a miss is null even when id 1 exists', () {
      QuickLogCategory cat(int id, String name) => QuickLogCategory(
            id: id,
            name: name,
            icon: 'circle',
            colorHex: '#CCCCCC',
            isDefault: true,
            sortOrder: 0,
          );
      expect(resolveIntakeCategoryId([cat(7, 'Hydration')]), 7);
      expect(resolveIntakeCategoryId([cat(9, 'hydration')]), 9);
      expect(resolveIntakeCategoryId([cat(1, 'Symptoms')]), isNull);
      expect(resolveIntakeCategoryId(const []), isNull);
    });
  });

  group('settings: targets + presets persistence', () {
    test('seed is Water 16 fl oz only; stored presets never re-seed; '
        'target versions accumulate by effective day', () async {
      final settings = IntakeSettings(settingsStore());
      final seed = await settings.loadPresets();
      expect(seed[intakeKindWater]?.fluidMl, flOzToMl(16));
      expect(seed[intakeKindWater]?.isConfigured, isTrue);
      expect(seed[intakeKindElectrolyte]?.isConfigured, isNot(true));
      expect(seed[intakeKindSalt]?.isConfigured, isNot(true));
      expect(seed.seedLabelPending, isTrue);

      final flipped = await settings.markSeedLabelShown();
      expect(flipped.seedLabelPending, isFalse);
      final reloaded = await settings.loadPresets();
      expect(reloaded.seedLabelPending, isFalse);
      expect(reloaded[intakeKindWater]?.fluidMl, flOzToMl(16));

      final remembered = await settings.rememberDraft(IntakeDraft(
        kind: 'Electrolyte drink',
        fluidMl: 355,
        sodiumMg: 500,
        time: DateTime(2026, 10, 28, 9),
      ));
      expect(remembered[intakeKindElectrolyte]?.sodiumMg, 500);
      final reloaded2 = await settings.loadPresets();
      expect(reloaded2[intakeKindElectrolyte]?.isConfigured, isTrue);

      expect(await settings.loadTargets(), isEmpty);
      final v = await settings.appendTarget(
        fluidTargetMl: 3785,
        sodiumTargetMg: 6000,
        now: DateTime(2026, 10, 28, 15),
      );
      expect(v, hasLength(1));
      expect(v.single.effectiveFromDayMs,
          feelingDayStart(DateTime(2026, 10, 28, 15)).millisecondsSinceEpoch);
      expect((await settings.loadTargets()).single.sodiumTargetMg, 6000);
    });
  });

  group('totals line (§9 item 13 — model level)', () {
    IntakeDayTotals totalsFor({required int fluid, required int sodium}) =>
        IntakeDayTotals(
          dayStart: DateTime(2026, 10, 28, 4),
          fluidMl: fluid,
          sodiumMg: sodium,
          eventCount: 1,
          excludedCount: 0,
        );

    test('S5 form without targets; S4 form with targets; neither '
        'carries hit/miss language (Juno R2)', () {
      final totals = totalsFor(fluid: 946, sodium: 1500);
      final s5 = intakeTotalsLine(totals: totals, targets: null);
      expect(s5, 'Logged today: 32 fl oz water · 1,500 mg sodium.');
      final s4 = intakeTotalsLine(
        totals: totals,
        targets: const IntakeTargetVersion(
          fluidTargetMl: 3785,
          sodiumTargetMg: 6000,
          effectiveFromDayMs: 0,
        ),
      );
      expect(
        s4,
        'Logged today: 32 fl oz of 128 fl oz water · '
        '1,500 mg of 6,000 mg sodium.',
      );
      for (final line in [s4, s5]) {
        expect(line.toLowerCase(), isNot(contains('hit')));
        expect(line.toLowerCase(), isNot(contains('miss')));
        expect(line.toLowerCase(), isNot(contains('goal')));
      }
    });
  });

  group('editor sheet', () {
    Future<({List<IntakeDraft> drafts})> pumpSheet(
      WidgetTester tester, {
      QuickLogEntry? existing,
      String? initialKind,
    }) async {
      final drafts = <IntakeDraft>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showIntakeEditorSheet(
                  context: context,
                  existing: existing,
                  initialKind: initialKind,
                  onSave: (draft, _) async {
                    drafts.add(draft);
                    return true;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return (drafts: drafts);
    }

    testWidgets('sheet renders Juno S3 labels + the R5 helper verbatim',
        (tester) async {
      await pumpSheet(tester);
      expect(find.text('Log intake'), findsOneWidget);
      expect(find.text('Kind'), findsOneWidget);
      expect(find.text('Water (fl oz)'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text(intakeTimeHelper), findsOneWidget);
      await tester.tap(find.text('Electrolyte drink'));
      await tester.pump();
      expect(find.text('Sodium (mg)'), findsOneWidget);
      await tester.tap(find.text('Salt'));
      await tester.pump();
      expect(find.text('Salt (g)'), findsOneWidget);
      expect(find.text('Sodium (mg)'), findsOneWidget);
    });

    testWidgets('4 (sheet): salt grams compute sodium at the constant; '
        'sodium typed directly is used as entered', (tester) async {
      final h = await pumpSheet(tester, initialKind: 'Salt');
      await tester.enterText(
        find.byKey(const ValueKey('intake_salt_field')),
        '1',
      );
      await tester.pump();
      final sodiumField = tester.widget<TextField>(
        find.byKey(const ValueKey('intake_sodium_field')),
      );
      expect(sodiumField.controller!.text, '393');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.drafts, hasLength(1));
      expect(h.drafts.single.kind, 'Salt');
      expect(h.drafts.single.saltMg, 1000);
      expect(h.drafts.single.sodiumMg, 393);

      // Sodium entered directly: taken as entered, no salt grams.
      final h2 = await pumpSheet(tester, initialKind: 'Salt');
      await tester.enterText(
        find.byKey(const ValueKey('intake_sodium_field')),
        '500',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(h2.drafts.single.sodiumMg, 500);
      expect(h2.drafts.single.saltMg, isNull);
    });

    test('11 (model): editor rewrite keeps the id and rewrites body '
        '+ payload together; totals follow; delete removes the '
        'contribution', () {
      final day = DateTime(2026, 10, 28, 12, 0);
      final original = _intakeEntry(
        id: 9,
        draft: IntakeDraft(
          kind: 'Water',
          fluidMl: 473,
          time: DateTime(2026, 10, 28, 8),
        ),
      );
      final edited = editIntakeEntry(
        original,
        draft: IntakeDraft(
          kind: 'Water',
          fluidMl: 946,
          time: DateTime(2026, 10, 28, 8),
        ),
      );
      expect(edited.id, original.id);
      expect(edited.timestamp, original.timestamp);
      expect(edited.body, 'Water · 32 fl oz');
      expect(IntakePayload.tryParse(edited.manualText)?.fluidMl, 946);
      expect(intakeTotalsForDay([edited], now: day).fluidMl, 946);
      // Deleting the entry removes its contribution entirely.
      expect(intakeTotalsForDay(const [], now: day).hasData, isFalse);
    });
  });

  group('backfill (§9 item 12)', () {
    test('12: a declared past time lands in that time\'s day totals', () {
      final entry = _intakeEntry(
        id: 1,
        draft: IntakeDraft(
          kind: 'Water',
          fluidMl: 473,
          time: DateTime(2026, 10, 27, 23, 30),
        ),
      );
      // The stored timestamp IS the declared time (§5.5).
      expect(
        entry.timestamp,
        DateTime(2026, 10, 27, 23, 30).millisecondsSinceEpoch,
      );
      final now = DateTime(2026, 10, 28, 10, 0);
      expect(intakeTotalsForDay([entry], now: now).eventCount, 0);
      expect(
        intakeTotalsForDay([entry], now: DateTime(2026, 10, 27, 23, 45))
            .fluidMl,
        473,
      );
    });
  });

  group('Z6 summary (§9 item 14)', () {
    test('14: summary shape matches hand-computed expectations; '
        'no-data days are absent from both groups', () {
      DateTime at(int d, int h) => DateTime(2026, 10, d, h);
      final targets = [
        IntakeTargetVersion(
          fluidTargetMl: 500,
          sodiumTargetMg: 400,
          effectiveFromDayMs: at(26, 4).millisecondsSinceEpoch,
        ),
      ];
      final entries = [
        // Oct 26: fluid 600 / sodium 500 — hit / hit.
        _intakeEntry(
          id: 1,
          draft: IntakeDraft(
            kind: 'Electrolyte drink',
            fluidMl: 600,
            sodiumMg: 500,
            time: at(26, 10),
          ),
        ),
        // Oct 27: NO entries — no-data, absent everywhere.
        // Oct 28: fluid 300 / sodium 450 — miss / hit.
        _intakeEntry(
          id: 2,
          draft: IntakeDraft(
            kind: 'Electrolyte drink',
            fluidMl: 300,
            sodiumMg: 450,
            time: at(28, 10),
          ),
        ),
      ];
      final summary = summarizeIntake(
        entries: entries,
        startDay: at(26, 12),
        endDay: at(28, 12),
        targets: targets,
      );
      expect(summary.daysWithData, 2);
      expect(summary.fluidHitDays, 1);
      expect(summary.sodiumHitDays, 2);
      expect(summary.perDay, hasLength(2));
      expect(summary.perDay[0].day, '2026-10-26');
      expect(summary.perDay[0].fluidMl, 600);
      expect(summary.perDay[0].sodiumMg, 500);
      expect(summary.perDay[0].fluidHit, isTrue);
      expect(summary.perDay[0].sodiumHit, isTrue);
      expect(summary.perDay[1].day, '2026-10-28');
      expect(summary.perDay[1].fluidHit, isFalse);
      expect(summary.perDay[1].sodiumHit, isTrue);
      final json = summary.toJson();
      expect(json.keys,
          containsAll(['daysWithData', 'fluidHitDays', 'sodiumHitDays', 'perDay']));
    });
  });

  group('Home flow (§9 items 9–11, 13)', () {
    testWidgets(
        '9: one preset tap stages exactly one entry via the outbox; '
        'a failed push leaves it staged and counted; retry does not '
        'duplicate', (tester) async {
      final server = _Server([], categories: _catsHydration, failPosts: true);
      await pumpHome(tester, server);
      expect(find.text('Salt & water'), findsOneWidget);
      expect(find.text('No intake logged'), findsOneWidget);

      await tester.tap(find.text('+ Water 16 fl oz'));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.failedIds.isNotEmpty,
      );
      // Exactly one entry staged, exact shape.
      final staged = LogEntryOutbox.instance.records;
      expect(staged, hasLength(1));
      expect(staged.single.entry.body, 'Water · 16 fl oz');
      expect(staged.single.entry.categoryId, 7);
      expect(
        IntakePayload.tryParse(staged.single.entry.manualText)?.fluidMl,
        473,
      );
      expect(server.entries, isEmpty);
      // Totals include the staged entry throughout (local truth).
      expect(
        find.text('Logged today: 16 fl oz water · 0 mg sodium.'),
        findsOneWidget,
      );

      // Retry after recovery: exactly one server record.
      server.failPosts = false;
      await tester.runAsync(
        () => LogEntryOutbox.instance.flush(server.backend()),
      );
      expect(server.entries, hasLength(1));
      expect(server.entries.single['body'], 'Water · 16 fl oz');
      expect(LogEntryOutbox.instance.records, isEmpty);
    });

    testWidgets(
        '10: with no Hydration category the surface hides and zero '
        'postLogCategories / profile-blob calls occur', (tester) async {
      final server = _Server([], categories: _catsNoHydration);
      await pumpHome(tester, server, expectCard: false);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Salt & water'), findsNothing);
      expect(find.text('+ Water 16 fl oz'), findsNothing);
      // The §4.3 prohibitions, asserted as absence over every
      // request this flow made.
      expect(
        server.requestLog.where((r) => r.contains('/api/sync/categories')),
        isEmpty,
      );
      expect(
        server.requestLog.where((r) => r.contains('/api/sync/profile')),
        isEmpty,
      );
    });

    testWidgets(
        '11 + 13 (Home): S7 on a no-data day, S5 totals without '
        'targets, editor edit from a card row rewrites the entry, '
        'card Undo removes exactly the last tapped event',
        (tester) async {
      final server = _Server([], categories: _catsHydration);
      await pumpHome(tester, server);
      // No-data day renders S7 — never a manufactured 0 total.
      expect(find.text('No intake logged'), findsOneWidget);
      expect(find.textContaining('Logged today:'), findsNothing);

      await tester.tap(find.text('+ Water 16 fl oz'));
      await _pumpUntil(
        tester,
        () =>
            find
                .text('Logged today: 16 fl oz water · 0 mg sodium.')
                .evaluate()
                .isNotEmpty,
      );
      // S5 form + the Set targets prompt, no target line.
      expect(find.text('Set targets'), findsOneWidget);
      expect(find.text(intakeTargetsProvenance), findsNothing);
      await _pumpUntil(tester, () => server.entries.isNotEmpty);
      final entryId = server.entries.single['id'];

      // Edit from the card row: the editor rewrites body + payload.
      await tester.ensureVisible(find.text('Water · 16 fl oz'));
      await tester.tap(find.text('Water · 16 fl oz'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Log intake'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('intake_water_field')),
        '32',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await _pumpUntil(
        tester,
        () =>
            find
                .text('Logged today: 32 fl oz water · 0 mg sodium.')
                .evaluate()
                .isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () =>
            server.entries.isNotEmpty &&
            IntakePayload.tryParse('${server.entries.single['manualText']}')
                    ?.fluidMl ==
                946,
      );
      expect(server.entries, hasLength(1));
      expect(server.entries.single['id'], entryId);
      expect(server.entries.single['body'], 'Water · 32 fl oz');

      // Undo removes exactly that event.
      await tester.ensureVisible(find.text('Undo'));
      await tester.tap(find.text('Undo'));
      await _pumpUntil(
        tester,
        () => find.text('No intake logged').evaluate().isNotEmpty,
      );
      expect(server.capturedDeletes, contains(entryId));
      expect(server.entries, isEmpty);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('13 (Home): with targets the S4 line and S6 render, '
        'with no hit/miss language', (tester) async {
      settingsDisk[SettingsStore.intakeTargetsKey] = jsonEncode([
        {
          'fluidTargetMl': 3785,
          'sodiumTargetMg': 6000,
          'effectiveFromDay':
              feelingDayStart(DateTime.now()).millisecondsSinceEpoch,
        },
      ]);
      final server = _Server([], categories: _catsHydration);
      await pumpHome(tester, server);
      await tester.tap(find.text('+ Water 16 fl oz'));
      await _pumpUntil(
        tester,
        () => find
            .text('Logged today: 16 fl oz of 128 fl oz water · '
                '0 mg of 6,000 mg sodium.')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text(intakeTargetsProvenance), findsOneWidget);
      expect(find.text('Set targets'), findsNothing);
    });

    testWidgets('R4: the seed label renders at the seed\'s first '
        'presentation only', (tester) async {
      final server = _Server([], categories: _catsHydration);
      await pumpHome(tester, server);
      expect(find.text(intakeSeedLabel), findsOneWidget);
      await _pumpUntil(
        tester,
        () => (settingsDisk[SettingsStore.intakePresetsKey] ?? '')
            .contains('"seedLabelPending":false'),
      );
      // A later presentation of the same store: no label. (Unmount
      // first — pumpWidget with the same widget types would reuse
      // the live State and never re-present.)
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: _weather(),
          tabsBackend: server.backend(),
          logEntryOutbox: LogEntryOutbox.instance,
          settingsStore: settingsStore(),
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Salt & water').evaluate().isNotEmpty,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(intakeSeedLabel), findsNothing);
    });
  });

  group('History guards (§9 item 13)', () {
    final intakeServerEntry = _entryJson(_intakeEntry(
      id: 21,
      draft: IntakeDraft(
        kind: 'Water',
        fluidMl: 473,
        time: DateTime.now().subtract(const Duration(hours: 2)),
      ),
    ));

    test('display text is body only; category change preserves '
        'chips; free-text edit semantics unchanged for other entries',
        () {
      final entry = QuickLogEntry.fromJson(intakeServerEntry);
      // (1) The JSON payload never renders as user copy.
      expect(entryCombinedText(entry), 'Water · 16 fl oz');
      expect(entryCombinedText(entry), isNot(contains('fluidMl')));
      // (3) Category change: categoryId only, chips preserved.
      const symptoms = QuickLogCategory(
        id: 3,
        name: 'Symptoms',
        icon: 'circle',
        colorHex: '#CCCCCC',
        isDefault: true,
        sortOrder: 0,
      );
      final moved = editedEntryCategory(entry, symptoms);
      expect(moved.categoryId, 3);
      expect(moved.chips, entry.chips);
      expect(moved.manualText, entry.manualText);
      // A NON-intake entry keeps the existing replace-chips rule.
      final ordinary = QuickLogEntry(
        id: 5,
        categoryId: 7,
        body: 'note',
        chips: '["Misc"]',
        manualText: '',
        timestamp: entry.timestamp,
      );
      expect(editedEntryCategory(ordinary, symptoms).chips, '["Symptoms"]');
    });

    testWidgets(
        'History shows body without the payload JSON; edit routes '
        'to the intake editor and preserves the payload; category '
        'change preserves chips', (tester) async {
      final server = _Server(
        [Map<String, dynamic>.from(intakeServerEntry)],
        categories: _catsHydration,
      );
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Water · 16 fl oz').evaluate().isNotEmpty,
      );
      expect(find.textContaining('fluidMl'), findsNothing);
      expect(find.textContaining('"kind"'), findsNothing);

      // Open the detail dialog: body only, no payload anywhere.
      await tester.tap(find.text('Water · 16 fl oz'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('fluidMl'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);

      // Edit routes to the intake editor sheet (not free text):
      // changing the amount rewrites body + payload together.
      await tester.tap(find.text('Edit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Log intake'), findsWidgets);
      expect(find.text(intakeTimeHelper), findsOneWidget);
      // The free-text editor's field is nowhere in this flow.
      expect(find.byKey(const ValueKey('entry_text_editor')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('intake_water_field')),
        '20',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await _pumpUntil(
        tester,
        () =>
            server.entries.isNotEmpty &&
            IntakePayload.tryParse('${server.entries.single['manualText']}')
                    ?.fluidMl ==
                591,
      );
      // Payload preserved (rewritten, never cleared), same id.
      expect(server.entries.single['id'], 21);
      expect(server.entries.single['body'], 'Water · 20 fl oz');
      expect(server.entries.single['manualText'], isNotEmpty);

      // Category change from the detail dialog preserves chips.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final dialogOpen =
          find.text('CHANGE CATEGORY').evaluate().isNotEmpty;
      if (!dialogOpen) {
        await tester.tap(find.text('Water · 20 fl oz'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.tap(find.text('SYMPTOMS'));
      await _pumpUntil(
        tester,
        () => server.entries.single['categoryId'] == 3,
      );
      expect(server.entries.single['chips'], '["Intake","Water"]');
      expect(
        IntakePayload.tryParse('${server.entries.single['manualText']}')
            ?.fluidMl,
        591,
      );
    });
  });
}
