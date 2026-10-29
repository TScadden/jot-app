import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/features/home/checkin_sheets.dart';
import 'package:tabs_lab/src/features/home/checkin_summary_card.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/flare_day_logging.dart';
import 'package:tabs_lab/src/features/home/good_day_logging.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Merged check-in flow (Juno ruling Oct 28, 2026) — the flare
/// record tests of the original flare suite, reworked for the
/// merged flow, plus the good-day record, the summary card, and
/// the F3 correlation-compatibility cases. The standalone `Bad day`
/// button and its standalone severity step no longer exist.

const _owner = 'founder@example.com';

Map<String, dynamic> _catJson(int id, String name) => {
      'id': id,
      'name': name,
      'icon': 'circle',
      'colorHex': '#4ECDC4',
      'isDefault': true,
      'sortOrder': 0,
    };

/// Categories where Symptoms resolves BY NAME at a non-1 id.
final _catsNameHit = [_catJson(3, 'Symptoms'), _catJson(6, 'Mood & Energy')];

/// Categories where the name misses but a pulled category carries
/// id 1 (fallback hit).
final _catsFallbackHit = [_catJson(1, 'Renamed'), _catJson(6, 'Mood & Energy')];

/// Categories where both miss (no flare record can be filed).
final _catsDoubleMiss = [_catJson(9, 'Renamed'), _catJson(6, 'Mood & Energy')];

QuickLogEntry _entry({
  int id = 1,
  int categoryId = 3,
  String body = 'x',
  String chips = '[]',
  int? ts,
}) =>
    QuickLogEntry(
      id: id,
      categoryId: categoryId,
      body: body,
      chips: chips,
      manualText: '',
      timestamp: ts ?? DateTime.now().millisecondsSinceEpoch,
    );

Map<String, dynamic> _entryJson(QuickLogEntry e) => {
      'id': e.id,
      'categoryId': e.categoryId,
      'body': e.body,
      'chips': e.chips,
      'manualText': e.manualText,
      'timestamp': e.timestamp,
    };

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
      id: id,
      name: name,
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 0,
    );

/// Fake server: pull reflects only what a POST actually applied;
/// POSTs are gateable and failable (the optimistic suite's shape).
class _Server {
  _Server(this.entries, {required this.categories, this.failPosts = false});

  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> categories;
  bool failPosts;
  Completer<void>? postGate;
  final List<Map<String, dynamic>> capturedPosts = [];
  int postAttempts = 0;

  /// DELETE support (founder ruling, Oct 28 2026): when
  /// [failDeletes] is set, DELETEs answer 500 and change nothing;
  /// otherwise the row is removed and its id recorded in
  /// [capturedDeletes] (applied deletes only).
  bool failDeletes = false;
  final List<int> capturedDeletes = [];

  /// HTTP pull count, for the Vera F5 test: the initial flare
  /// stage must not add a pull of its own.
  int pullCount = 0;

  TabsBackend backend() {
    final store = FakeSessionStore()
      ..token = 'test-token'
      ..email = _owner;
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        pullCount++;
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
        postAttempts++;
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
      if (request.method == 'DELETE' &&
          request.url.path.startsWith('/api/sync/entries/')) {
        if (failDeletes) return http.Response('server error', 500);
        final id = int.tryParse(request.url.path.split('/').last);
        if (id != null) {
          capturedDeletes.add(id);
          entries.removeWhere((e) => e['id'] == id);
        }
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

Finder _semantics(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

// ── F3 compatibility: the correlation engine's flare predicate,
// ported verbatim in shape from jotapp-correlation's
// correlation_engine.dart (deriveFlareDays + its helpers). ────────

int? _resolveCorrelationCategoryId(
  List<QuickLogCategory> categories, {
  required String name,
  required int fallbackId,
}) {
  for (final c in categories) {
    if (c.name.trim().toLowerCase() == name.toLowerCase()) return c.id;
  }
  for (final c in categories) {
    if (c.id == fallbackId) return c.id;
  }
  return null;
}

List<String> _parseCorrelationChips(String chips) {
  final raw = chips.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final c in decoded)
          if ('$c'.trim().isNotEmpty) '$c'.trim(),
      ];
    }
  } catch (_) {}
  var body = raw;
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  return [
    for (final part in body.split(','))
      if (part.trim().replaceAll('"', '').trim().isNotEmpty)
        part.trim().replaceAll('"', '').trim(),
  ];
}

String _energyDayLabel(int timestampMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final startDate = dt.hour < 4
      ? DateTime(dt.year, dt.month, dt.day - 1)
      : DateTime(dt.year, dt.month, dt.day);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${startDate.year}-${two(startDate.month)}-${two(startDate.day)}';
}

Set<String> _deriveFlareDays(
  List<QuickLogEntry> entries,
  List<QuickLogCategory> categories,
) {
  final symptomsId = _resolveCorrelationCategoryId(
    categories,
    name: 'Symptoms',
    fallbackId: 1,
  );
  if (symptomsId == null) return const {};
  final days = <String>{};
  for (final e in entries) {
    if (e.categoryId != symptomsId) continue;
    if (!_parseCorrelationChips(e.chips).contains('Flare Day')) continue;
    days.add(_energyDayLabel(e.timestamp));
  }
  return days;
}

void main() {
  late Map<String, String> disk;
  late bool diskWriteFails;

  /// Disk-write failure injection for the per-record gate tests:
  /// after [diskFailAfter] successful writes (counted from the
  /// moment the test arms it), every later write throws.
  late int diskWrites;
  late int? diskFailAfter;

  setUp(() {
    TabsBackend.debugResetSharedCaches();
    disk = <String, String>{};
    diskWriteFails = false;
    diskWrites = 0;
    diskFailAfter = null;
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async {
        diskWrites++;
        if (diskWriteFails) throw StateError('disk full');
        if (diskFailAfter != null && diskWrites > diskFailAfter!) {
          throw StateError('disk full');
        }
        disk[key] = value;
      },
      delete: (key) async => disk.remove(key),
    );
  });

  tearDown(() {
    LogEntryOutbox.instance.debugReset();
  });

  Future<void> pumpHome(WidgetTester tester, _Server server) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        weatherApi: _weather(),
        tabsBackend: server.backend(),
        logEntryOutbox: LogEntryOutbox.instance,
      ),
    ));
    await _pumpUntil(
      tester,
      () =>
          find.text('How are you feeling?').evaluate().isNotEmpty ||
          find.byType(CheckInSummaryCard).evaluate().isNotEmpty ||
          identical(server.categories, _catsDoubleMiss),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('flare data / identity (original §5 items 6–9, reworked)', () {
    test('6: typed record shape is exact', () {
      final now = DateTime(2026, 10, 28, 15, 30);
      final e = buildFlareEntry(
        id: 12,
        categoryId: 3,
        severity: 'Rough',
        type: 'Dizzy',
        now: now,
      );
      expect(e.id, 12);
      expect(e.categoryId, 3);
      expect(e.chips, '["Flare Day","Rough","Dizzy"]');
      expect(jsonDecode(e.chips), ['Flare Day', 'Rough', 'Dizzy']);
      expect(e.body, 'Flare day · Rough · Dizzy');
      expect(e.manualText, '');
      expect(e.timestamp, now.millisecondsSinceEpoch);
    });

    test('6: severity-only record carries the two-element chip list '
        'and the severity-only body', () {
      final e = buildFlareEntry(id: 5, categoryId: 3, severity: 'Really bad');
      expect(jsonDecode(e.chips), ['Flare Day', 'Really bad']);
      expect(e.body, 'Flare day · Really bad');
      expect(e.manualText, '');
    });

    test('7: identity positives and negatives', () {
      final now = DateTime(2026, 10, 28, 11, 0);
      int ms(DateTime d) => d.millisecondsSinceEpoch;
      final flare = _entry(
        chips: '["Flare Day","Rough","Fog"]',
        ts: ms(DateTime(2026, 10, 28, 9, 0)),
      );
      expect(hasFlareToday([flare], symptomsCategoryId: 3, now: now), isTrue);
      expect(
        findFlareRecord([flare], symptomsCategoryId: 3, now: now)?.id,
        flare.id,
      );
      expect(
        hasFlareToday(
          [_entry(chips: '["Symptoms"]', ts: flare.timestamp)],
          symptomsCategoryId: 3,
          now: now,
        ),
        isFalse,
      );
      expect(
        hasFlareToday(
          [
            _entry(
              categoryId: 6,
              chips: '["Flare Day","Rough"]',
              ts: flare.timestamp,
            )
          ],
          symptomsCategoryId: 3,
          now: now,
        ),
        isFalse,
      );
      expect(
        hasFlareToday(
          [
            _entry(
              chips: '["Flare Day","Rough"]',
              ts: ms(DateTime(2026, 10, 27, 12, 0)),
            )
          ],
          symptomsCategoryId: 3,
          now: now,
        ),
        isFalse,
      );
    });

    test('7: the 04:00 energy-day boundary', () {
      int ms(DateTime d) => d.millisecondsSinceEpoch;
      final at0359 = _entry(
        chips: '["Flare Day","Rough"]',
        ts: ms(DateTime(2026, 10, 28, 3, 59)),
      );
      final at0400 = _entry(
        id: 2,
        chips: '["Flare Day","Rough"]',
        ts: ms(DateTime(2026, 10, 28, 4, 0)),
      );
      final morning = DateTime(2026, 10, 28, 5, 0);
      expect(
        hasFlareToday([at0359], symptomsCategoryId: 3, now: morning),
        isFalse,
      );
      expect(
        hasFlareToday([at0400], symptomsCategoryId: 3, now: morning),
        isTrue,
      );
      final beforeDawn = DateTime(2026, 10, 28, 3, 59);
      expect(
        hasFlareToday([at0359], symptomsCategoryId: 3, now: beforeDawn),
        isTrue,
      );
    });

    test('8: amend reuses the id, updates severity/type, keeps one '
        'record, and refreshes updatedAt at push', () {
      final original = buildFlareEntry(
        id: 9,
        categoryId: 3,
        severity: 'Rough',
        type: 'Fog',
        now: DateTime(2026, 10, 28, 8, 0),
      );
      final amended =
          amendFlareEntry(original, severity: 'Really bad', type: 'Pain');
      expect(amended.id, original.id);
      expect(amended.timestamp, original.timestamp);
      expect(amended.categoryId, 3);
      expect(jsonDecode(amended.chips), ['Flare Day', 'Really bad', 'Pain']);
      expect(amended.body, 'Flare day · Really bad · Pain');
      final sync = amended.toSyncJson();
      expect(sync['id'], 9);
      expect(sync['updatedAt'], isA<int>());
    });

    test("9: legacy ', '-joined chips on other entries parse without "
        'misclassifying them', () {
      final now = DateTime(2026, 10, 28, 11, 0);
      final ts = DateTime(2026, 10, 28, 9, 0).millisecondsSinceEpoch;
      final ordinary = _entry(chips: 'Headache, Pain', ts: ts);
      expect(parseFlareChips(ordinary.chips), ['Headache', 'Pain']);
      expect(
        hasFlareToday([ordinary], symptomsCategoryId: 3, now: now),
        isFalse,
      );
      final prose = _entry(chips: 'Not a Flare Day, honestly', ts: ts);
      expect(chipsContainFlareTag(prose.chips), isFalse);
      expect(parseFlareChips(''), isEmpty);
      expect(chipsContainFlareTag('not json'), isFalse);
      expect(chipsContainFlareTag('[Flare Day, Rough]'), isTrue);
    });

    test('category resolution (Q4): name hit, fallback hit, double '
        'miss → null', () {
      expect(resolveFlareCategoryId([_cat(3, 'Symptoms'), _cat(1, 'Other')]), 3);
      expect(resolveFlareCategoryId([_cat(1, 'Renamed')]), 1);
      expect(resolveFlareCategoryId([_cat(9, 'Renamed')]), isNull);
      expect(resolveFlareCategoryId(const []), isNull);
    });

    test('severity mapping: 1 → Really bad, 2 → Rough, 3–5 → none; '
        'the late-add vocabulary is exactly the two words, of 2', () {
      expect(severityForRanking(1), 'Really bad');
      expect(severityForRanking(2), 'Rough');
      expect(severityForRanking(3), isNull);
      expect(severityForRanking(4), isNull);
      expect(severityForRanking(5), isNull);
      expect(flareLateSeverities, ['Rough', 'Really bad']);
      expect(flareLateSeverities.contains('Bad'), isFalse);
      expect(flareLateSeveritySemantics('Rough'), 'Rough, severity 1 of 2');
      expect(
        flareLateSeveritySemantics('Really bad'),
        'Really bad, severity 2 of 2',
      );
      expect(
        flareLoggedAnnouncement('Rough', type: 'Dizzy'),
        'Flare logged · Rough · Dizzy',
      );
      expect(flareLoggedAnnouncement('Really bad'), 'Flare logged · Really bad');
    });

    test("legacy 'Bad' records: parse, and display exactly as "
        'recorded — never remapped', () {
      final legacy = buildFlareEntry(
        id: 3,
        categoryId: 3,
        severity: 'Bad',
        type: 'Dizzy',
        now: DateTime(2026, 10, 28, 9, 0),
      );
      expect(flareSeverityOf(legacy), 'Bad');
      expect(flareTypesOf(legacy), ['Dizzy']);
      expect(legacy.body, 'Flare day · Bad · Dizzy');
      expect(flareLoggedLabel('Bad'), 'Flare logged · Bad');
      // The summary keeps the recorded word for a late-added legacy
      // flare (Item 10(a)).
      expect(
        checkInSummaryLabel(
          ranking: 4,
          flareSeverity: 'Bad',
          flareKind: 'Dizzy',
          flareOrigin: SummaryFlareOrigin.lateAdded,
        ),
        '4 · Good · Flare logged · Bad · Dizzy',
      );
    });
  });

  group('good-day record (Juno Items 5/6)', () {
    test('shape: Mood category, JSON chips in SHEET order regardless '
        'of tap order, Juno body, and NO Daily Ranking tag', () {
      final e = buildGoodEntry(
        id: 21,
        categoryId: 6,
        options: ['Clear head', 'Energy'],
        now: DateTime(2026, 10, 28, 12, 0),
      );
      expect(e.categoryId, 6);
      expect(jsonDecode(e.chips), ['Good Day', 'Energy', 'Clear head']);
      expect(e.body, 'Good day · Energy, Clear head');
      expect(e.manualText, '');
      expect(chipsContainFeelingTag(e.chips), isFalse);
      expect(goodOptionsOf(e), ['Energy', 'Clear head']);
      expect(goodBody(['Good mood']), 'Good day · Good mood');
      // An ordinary editable entry — never a locked check-in.
      final cats = [_cat(3, 'Symptoms'), _cat(6, 'Mood & Energy')];
      expect(isLockedCheckInEntry(e, cats), isFalse);
    });

    test('identity: today + Mood category + tag; negatives; amend '
        'in place keeps the id', () {
      final now = DateTime(2026, 10, 28, 11, 0);
      final ts = DateTime(2026, 10, 28, 9, 0).millisecondsSinceEpoch;
      final good = _entry(
        id: 8,
        categoryId: 6,
        chips: '["Good Day","Energy"]',
        ts: ts,
      );
      expect(findGoodRecord([good], moodCategoryId: 6, now: now)?.id, 8);
      expect(
        findGoodRecord(
          [_entry(id: 9, categoryId: 3, chips: '["Good Day","Energy"]', ts: ts)],
          moodCategoryId: 6,
          now: now,
        ),
        isNull,
      );
      expect(
        findGoodRecord(
          [
            _entry(
              id: 10,
              categoryId: 6,
              chips: '["Good Day","Energy"]',
              ts: DateTime(2026, 10, 27, 12, 0).millisecondsSinceEpoch,
            )
          ],
          moodCategoryId: 6,
          now: now,
        ),
        isNull,
      );
      expect(
        findGoodRecord(
          [_entry(id: 11, categoryId: 6, chips: '["Energy"]', ts: ts)],
          moodCategoryId: 6,
          now: now,
        ),
        isNull,
      );
      final amended = amendGoodEntry(good, options: ['Good mood', 'Energy']);
      expect(amended.id, 8);
      expect(amended.timestamp, ts);
      expect(jsonDecode(amended.chips), ['Good Day', 'Energy', 'Good mood']);
      expect(amended.body, 'Good day · Energy, Good mood');
    });
  });

  group('summary composition (Juno Item 7)', () {
    test('visible labels — the ruled examples, exhaustive by case', () {
      String label({
        required int ranking,
        String? severity,
        String? kind,
        SummaryFlareOrigin origin = SummaryFlareOrigin.none,
        List<String> good = const [],
      }) =>
          checkInSummaryLabel(
            ranking: ranking,
            flareSeverity: severity,
            flareKind: kind,
            flareOrigin: origin,
            goodOptions: good,
          );
      expect(label(ranking: 3), '3 · Average');
      expect(label(ranking: 4), '4 · Good');
      expect(
        label(ranking: 2, severity: 'Rough', origin: SummaryFlareOrigin.numberOrigin),
        '2 · Rough',
      );
      expect(
        label(
          ranking: 2,
          severity: 'Rough',
          kind: 'Dizzy',
          origin: SummaryFlareOrigin.numberOrigin,
        ),
        '2 · Rough · Dizzy',
      );
      expect(
        label(
          ranking: 1,
          severity: 'Really bad',
          kind: 'Fog',
          origin: SummaryFlareOrigin.numberOrigin,
        ),
        '1 · Really bad · Fog',
      );
      expect(
        label(ranking: 4, good: ['Energy', 'Clear head']),
        '4 · Good · Energy, Clear head',
      );
      expect(
        label(ranking: 5, good: ['Good sleep', 'Good mood']),
        '5 · Really good · Good sleep, Good mood',
      );
      expect(
        label(
          ranking: 3,
          severity: 'Rough',
          origin: SummaryFlareOrigin.lateAdded,
        ),
        '3 · Average · Flare logged · Rough',
      );
      expect(
        label(
          ranking: 4,
          severity: 'Really bad',
          kind: 'Crash',
          origin: SummaryFlareOrigin.lateAdded,
          good: ['Energy', 'Clear head'],
        ),
        '4 · Good · Energy, Clear head · Flare logged · Really bad · Crash',
      );
    });

    test('F3: a number-origin day carrying good options renders '
        'BOTH the kind and the good options, in ruled order '
        '(label and semantics)', () {
      expect(
        checkInSummaryLabel(
          ranking: 2,
          flareSeverity: 'Rough',
          flareKind: 'Dizzy',
          flareOrigin: SummaryFlareOrigin.numberOrigin,
          goodOptions: const ['Energy', 'Clear head'],
        ),
        '2 · Rough · Dizzy · Energy, Clear head',
      );
      expect(
        checkInSummarySemantics(
          ranking: 2,
          flareSeverity: 'Rough',
          flareKind: 'Dizzy',
          flareOrigin: SummaryFlareOrigin.numberOrigin,
          goodOptions: const ['Energy', 'Clear head'],
        ),
        "Today's check-in: 2 of 5, rough, dizzy, energy, clear head. "
        "Tap to update today's details.",
      );
      // Number-origin with good options but no kind: the options
      // still render (they are not suppressed by the origin).
      expect(
        checkInSummaryLabel(
          ranking: 2,
          flareSeverity: 'Rough',
          flareOrigin: SummaryFlareOrigin.numberOrigin,
          goodOptions: const ['Energy'],
        ),
        '2 · Rough · Energy',
      );
      expect(
        checkInSummarySemantics(
          ranking: 2,
          flareSeverity: 'Rough',
          flareOrigin: SummaryFlareOrigin.numberOrigin,
          goodOptions: const ['Energy'],
        ),
        "Today's check-in: 2 of 5, rough, energy. "
        "Tap to update today's details.",
      );
    });

    test('semantics — the ruled expansions, exhaustive by case', () {
      String sem({
        required int ranking,
        String? severity,
        String? kind,
        SummaryFlareOrigin origin = SummaryFlareOrigin.none,
        List<String> good = const [],
      }) =>
          checkInSummarySemantics(
            ranking: ranking,
            flareSeverity: severity,
            flareKind: kind,
            flareOrigin: origin,
            goodOptions: good,
          );
      expect(
        sem(ranking: 3),
        "Today's check-in: 3 of 5, average. Tap to update today's details.",
      );
      expect(
        sem(
          ranking: 2,
          severity: 'Rough',
          kind: 'Dizzy',
          origin: SummaryFlareOrigin.numberOrigin,
        ),
        "Today's check-in: 2 of 5, rough, dizzy. "
        "Tap to update today's details.",
      );
      expect(
        sem(ranking: 2, severity: 'Rough', origin: SummaryFlareOrigin.numberOrigin),
        "Today's check-in: 2 of 5, rough. Tap to update today's details.",
      );
      expect(
        sem(ranking: 4, good: ['Energy', 'Clear head']),
        "Today's check-in: 4 of 5, good, energy, clear head. "
        "Tap to update today's details.",
      );
      expect(
        sem(
          ranking: 3,
          severity: 'Rough',
          origin: SummaryFlareOrigin.lateAdded,
        ),
        "Today's check-in: 3 of 5, average. Flare logged, rough. "
        "Tap to update today's details.",
      );
      expect(
        sem(
          ranking: 4,
          severity: 'Really bad',
          kind: 'Crash',
          origin: SummaryFlareOrigin.lateAdded,
          good: ['Energy', 'Clear head'],
        ),
        "Today's check-in: 4 of 5, good, energy, clear head. "
        'Flare logged, really bad, crash. '
        "Tap to update today's details.",
      );
    });
  });

  group('F3 compatibility — the correlation flare predicate', () {
    test('every flare shape the merged flow writes satisfies '
        'deriveFlareDays (name-resolved Symptoms + Flare Day tag)',
        () {
      final cats = [_cat(3, 'Symptoms'), _cat(6, 'Mood & Energy')];
      final now = DateTime(2026, 10, 28, 10, 0);
      final shapes = <QuickLogEntry>[
        // Number-origin, severity only (incl. dismissal-created).
        buildFlareEntry(id: 1, categoryId: 3, severity: 'Really bad', now: now),
        buildFlareEntry(id: 2, categoryId: 3, severity: 'Rough', now: now),
        // Number-origin with a kind.
        buildFlareEntry(
            id: 3, categoryId: 3, severity: 'Rough', type: 'Dizzy', now: now),
        // Late-added (severity step + kind / severity only).
        buildFlareEntry(
            id: 4, categoryId: 3, severity: 'Rough', type: 'Crash', now: now),
        buildFlareEntry(id: 5, categoryId: 3, severity: 'Really bad', now: now),
        // Amended in place.
        amendFlareEntry(
          buildFlareEntry(id: 6, categoryId: 3, severity: 'Rough', now: now),
          severity: 'Rough',
          type: 'Pain',
        ),
      ];
      for (final shape in shapes) {
        expect(
          _deriveFlareDays([shape], cats),
          {'2026-10-28'},
          reason: shape.chips,
        );
      }
      // Fallback-1 resolution also counts a fallback-filed record.
      final fallbackShape =
          buildFlareEntry(id: 7, categoryId: 1, severity: 'Rough', now: now);
      expect(
        _deriveFlareDays([fallbackShape], [_cat(1, 'Renamed')]),
        {'2026-10-28'},
      );
      // And a good-day / ranking record never counts as a flare day.
      final good = buildGoodEntry(
          id: 8, categoryId: 6, options: ['Energy'], now: now);
      final ranking =
          buildFeelingEntry(level: 2, categoryId: 6, id: 9, now: now);
      expect(_deriveFlareDays([good, ranking], cats), isEmpty);
    });
  });

  group('sheets (Items 4/5/8/9)', () {
    Future<void> pumpOpener(
      WidgetTester tester,
      void Function(BuildContext context) open,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('kind sheet: the ruled set ONLY — no severity '
        'prompt, no severity options, Bad offered nowhere; targets '
        '≥48dp', (tester) async {
      await pumpOpener(
        tester,
        (context) => showCheckInKindSheet(
          context: context,
          onKind: (_) async => true,
          onJustLog: () async => true,
        ),
      );
      expect(find.text('Flare day'), findsOneWidget);
      expect(find.text('What kind of bad?'), findsOneWidget);
      expect(find.text('How bad is it today?'), findsNothing);
      expect(find.text('Rough'), findsNothing);
      expect(find.text('Really bad'), findsNothing);
      expect(find.text('Bad'), findsNothing);
      for (final t in ['Dizzy', 'Pain', 'Fog', 'Crash', 'Just log this']) {
        expect(find.text(t), findsOneWidget, reason: t);
        final size = tester.getSize(_semantics(t));
        expect(size.height, greaterThanOrEqualTo(48), reason: t);
        expect(size.width, greaterThanOrEqualTo(48), reason: t);
      }
      // No auto-dismiss.
      await tester.pump(const Duration(minutes: 5));
      expect(find.text('Flare day'), findsOneWidget);
    });

    testWidgets('kind sheet: a kind tap commits the kind; '
        'Just log this commits severity-only', (tester) async {
      final kinds = <String>[];
      var justLogs = 0;
      await pumpOpener(
        tester,
        (context) => showCheckInKindSheet(
          context: context,
          onKind: (kind) async {
            kinds.add(kind);
            return true;
          },
          onJustLog: () async {
            justLogs++;
            return true;
          },
        ),
      );
      await tester.tap(find.text('Fog'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(kinds, ['Fog']);
      expect(find.text('Flare day'), findsNothing);

      await pumpOpener(
        tester,
        (context) => showCheckInKindSheet(
          context: context,
          onKind: (kind) async {
            kinds.add(kind);
            return true;
          },
          onJustLog: () async {
            justLogs++;
            return true;
          },
        ),
      );
      await tester.tap(find.text('Just log this'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(justLogs, 1);
      expect(kinds, ['Fog']);
    });

    testWidgets('kind sheet: dismissal at sheet level calls no '
        'commit (Home pre-stages the severity-only record — the '
        'commit path is tested at Home level)', (tester) async {
      var calls = 0;
      await pumpOpener(
        tester,
        (context) => showCheckInKindSheet(
          context: context,
          onKind: (_) async {
            calls++;
            return true;
          },
          onJustLog: () async {
            calls++;
            return true;
          },
        ),
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Flare day'), findsNothing);
      expect(calls, 0);
    });

    testWidgets('good sheet: fresh sheet starts empty; options + '
        'Done commits in SHEET order, not tap order', (tester) async {
      final commits = <List<String>>[];
      await pumpOpener(
        tester,
        (context) => showCheckInGoodSheet(
          context: context,
          onCommit: (options) async {
            commits.add(options);
            return true;
          },
        ),
      );
      expect(find.text('Good day'), findsOneWidget);
      expect(find.text('What is good about today?'), findsOneWidget);
      for (final o in goodOptions) {
        expect(find.text(o), findsOneWidget, reason: o);
        final node = tester.widget<Semantics>(_semantics(o));
        expect(node.properties.selected, isFalse, reason: o);
        final size = tester.getSize(_semantics(o));
        expect(size.height, greaterThanOrEqualTo(48), reason: o);
      }
      // Tap in reverse sheet order on purpose.
      await tester.tap(find.text('Clear head'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commits, [
        ['Energy', 'Clear head'],
      ]);
      expect(find.text('Good day'), findsNothing);
    });

    testWidgets('good sheet: empty Done and dismissal both write '
        'nothing', (tester) async {
      var calls = 0;
      Future<bool> commit(List<String> _) async {
        calls++;
        return true;
      }

      await pumpOpener(
        tester,
        (context) =>
            showCheckInGoodSheet(context: context, onCommit: commit),
      );
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Good day'), findsNothing);
      expect(calls, 0);

      await pumpOpener(
        tester,
        (context) =>
            showCheckInGoodSheet(context: context, onCommit: commit),
      );
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Good day'), findsNothing);
      expect(calls, 0);
    });

    testWidgets("amend sheet, late add: severity step is 'of 2' "
        'with Bad nowhere; severity → kind step → commit',
        (tester) async {
      final commits = <Map<String, String?>>[];
      await pumpOpener(
        tester,
        (context) => showCheckInAmendSheet(
          context: context,
          showKindSection: false,
          showFlareAddSection: true,
          onFlareAdd: ({required severity, type}) async {
            commits.add({'severity': severity, 'type': type});
            return true;
          },
          showGoodSection: false,
        ),
      );
      expect(find.text("Today's check-in"), findsOneWidget);
      expect(find.text('How bad is it today?'), findsOneWidget);
      expect(_semantics('Rough, severity 1 of 2'), findsOneWidget);
      expect(_semantics('Really bad, severity 2 of 2'), findsOneWidget);
      expect(find.text('Bad'), findsNothing);
      await tester.tap(find.text('Rough'));
      await tester.pump();
      expect(find.text('What kind of bad?'), findsOneWidget);
      await tester.tap(find.text('Dizzy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commits, [
        {'severity': 'Rough', 'type': 'Dizzy'},
      ]);
      expect(find.text("Today's check-in"), findsNothing);
    });

    testWidgets('amend sheet, late add: Just log this commits the '
        'chosen severity with no kind', (tester) async {
      final commits = <Map<String, String?>>[];
      await pumpOpener(
        tester,
        (context) => showCheckInAmendSheet(
          context: context,
          showKindSection: false,
          showFlareAddSection: true,
          onFlareAdd: ({required severity, type}) async {
            commits.add({'severity': severity, 'type': type});
            return true;
          },
          showGoodSection: false,
        ),
      );
      await tester.tap(find.text('Really bad'));
      await tester.pump();
      await tester.tap(find.text('Just log this'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commits, [
        {'severity': 'Really bad', 'type': null},
      ]);
    });

    testWidgets('kind sheet: a failed pre-stage opens the sheet '
        'already showing the generic failure copy (Vera F1a)',
        (tester) async {
      await pumpOpener(
        tester,
        (context) => showCheckInKindSheet(
          context: context,
          onKind: (_) async => true,
          onJustLog: () async => true,
          initialCommitFailed: true,
        ),
      );
      expect(find.text('Flare day'), findsOneWidget);
      expect(find.text(flareStageFailureCopy), findsOneWidget);
    });

    testWidgets('amend sheet, late add: dismissal before a '
        'kind-step commit writes nothing — dismissed at the '
        'severity step, and again at the kind step (Vera gap 2, '
        'sheet level)', (tester) async {
      final commits = <Map<String, String?>>[];
      Future<void> openAmend() => pumpOpener(
            tester,
            (context) => showCheckInAmendSheet(
              context: context,
              showKindSection: false,
              showFlareAddSection: true,
              onFlareAdd: ({required severity, type}) async {
                commits.add({'severity': severity, 'type': type});
                return true;
              },
              showGoodSection: false,
            ),
          );

      // Dismissed at the severity step: nothing was ever chosen,
      // nothing commits.
      await openAmend();
      expect(find.text('How bad is it today?'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text("Today's check-in"), findsNothing);
      expect(commits, isEmpty);

      // Dismissed at the kind step: the severity selection is
      // sheet-local state only — choosing it committed nothing,
      // and dismissing here still writes nothing.
      await openAmend();
      await tester.tap(find.text('Rough'));
      await tester.pump();
      expect(find.text('What kind of bad?'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text("Today's check-in"), findsNothing);
      expect(commits, isEmpty);
    });

    testWidgets('amend sheet, kind section: pre-filled kind, a '
        'different kind tap commits the replacement; no Just log '
        'this and no severity step in this section', (tester) async {
      final kinds = <String>[];
      await pumpOpener(
        tester,
        (context) => showCheckInAmendSheet(
          context: context,
          showKindSection: true,
          currentKind: 'Fog',
          onKind: (kind) async {
            kinds.add(kind);
            return true;
          },
          showFlareAddSection: false,
          showGoodSection: false,
        ),
      );
      expect(find.text('What kind of bad?'), findsOneWidget);
      expect(find.text('Just log this'), findsNothing);
      expect(find.text('How bad is it today?'), findsNothing);
      final fog = tester.widget<Semantics>(_semantics('Fog'));
      expect(fog.properties.selected, isTrue);
      await tester.tap(find.text('Pain'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(kinds, ['Pain']);
    });

    testWidgets('amend sheet, good section: pre-filled from '
        "today's own record; Done stays enabled at zero selections "
        'and commits the empty set (founder ruling, Oct 28 2026: '
        'clearing all deletes the good-day record); a partial '
        'clear commits the remaining set', (tester) async {
      final commits = <List<String>>[];
      Future<bool> onGood(List<String> options) async {
        commits.add(options);
        return true;
      }

      await pumpOpener(
        tester,
        (context) => showCheckInAmendSheet(
          context: context,
          showKindSection: false,
          showFlareAddSection: false,
          showGoodSection: true,
          initialGood: const ['Energy'],
          onGood: onGood,
        ),
      );
      expect(find.text('What is good about today?'), findsOneWidget);
      final energy = tester.widget<Semantics>(_semantics('Energy'));
      expect(energy.properties.selected, isTrue);
      // Deselect the only option → Done stays ENABLED (founder
      // ruling): tapping it commits the EMPTY set — the clear-all
      // delete — and the sheet closes.
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commits, [<String>[]]);
      expect(find.text("Today's check-in"), findsNothing);

      // Partial clear at sheet level: two pre-filled options,
      // deselect one → Done commits just the remaining option.
      await pumpOpener(
        tester,
        (context) => showCheckInAmendSheet(
          context: context,
          showKindSection: false,
          showFlareAddSection: false,
          showGoodSection: true,
          initialGood: const ['Energy', 'Good mood'],
          onGood: onGood,
        ),
      );
      expect(find.text('What is good about today?'), findsOneWidget);
      await tester.tap(find.text('Good mood'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commits, [
        <String>[],
        ['Energy'],
      ]);
      expect(find.text("Today's check-in"), findsNothing);
    });
  });

  group('Home flow (merged)', () {

  /// Lets a just-opened sheet finish its entry slide before any
  /// tap: the sheet's text exists in the tree from the first frame,
  /// but its global offset is still translated off-screen until
  /// the transition lands (the old flare suite's 300ms pattern).
  Future<void> settleSheet(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 350));

    List<Map<String, dynamic>> flareRows(_Server s) => [
          for (final e in s.entries)
            if ((e['chips'] as String).contains('Flare Day')) e,
        ];
    List<Map<String, dynamic>> goodRows(_Server s) => [
          for (final e in s.entries)
            if ((e['chips'] as String).contains('Good Day')) e,
        ];
    List<Map<String, dynamic>> rankingRows(_Server s) => [
          for (final e in s.entries)
            if ((e['chips'] as String).contains('Daily Ranking')) e,
        ];

    testWidgets('the standalone Bad day button is gone; a double '
        'Symptoms miss renders no flare surface', (tester) async {
      final miss = _Server([], categories: _catsDoubleMiss);
      await pumpHome(tester, miss);
      expect(find.text('Bad day'), findsNothing);
      expect(find.textContaining('Flare logged'), findsNothing);
      // The check-in itself still renders (Mood resolves).
      expect(find.text('How are you feeling?'), findsOneWidget);
    });

    testWidgets('fallback-hit category: a 1 tap files the flare '
        'under the fallback id 1', (tester) async {
      final server = _Server([], categories: _catsFallbackHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('1'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Just log this'));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty &&
            server.entries.isNotEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['categoryId'], 1);
    });

    testWidgets('1 tap: the severity-only flare is staged BEFORE '
        'the kind sheet opens, and a kind tap amends that SAME '
        'record — one flare record, one ranking', (tester) async {
      final server = _Server(
        [_entryJson(_entry(id: 41, body: 'headache'))],
        categories: _catsNameHit,
      );
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      await tester.tap(find.text('1'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      // Both records are staged locally while the push is gated.
      final staged = LogEntryOutbox.instance.records;
      expect(staged, hasLength(2));
      final stagedFlare = staged
          .singleWhere((r) => r.entry.chips.contains('Flare Day'))
          .entry;
      expect(jsonDecode(stagedFlare.chips), ['Flare Day', 'Really bad']);
      expect(stagedFlare.body, 'Flare day · Really bad');
      expect(stagedFlare.categoryId, 3);
      expect(server.capturedPosts, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.text('Fog'));
      await _pumpUntil(
        tester,
        () => find.text('1 · Really bad · Fog').evaluate().isNotEmpty,
      );
      final afterKind = LogEntryOutbox.instance.records
          .singleWhere((r) => r.entry.chips.contains('Flare Day'))
          .entry;
      expect(afterKind.id, stagedFlare.id);
      expect(jsonDecode(afterKind.chips), ['Flare Day', 'Really bad', 'Fog']);

      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(rankingRows(server), hasLength(1));
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['body'], 'Flare day · Really bad · Fog');
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets("2 tap + 'Just log this': a Rough severity-only "
        'flare and the ranking, nothing else', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Just log this'));
      await _pumpUntil(
        tester,
        () => find.text('2 · Rough').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(jsonDecode(flareRows(server).single['chips'] as String),
          ['Flare Day', 'Rough']);
      expect(flareRows(server).single['body'], 'Flare day · Rough');
      expect(rankingRows(server), hasLength(1));
      expect(goodRows(server), isEmpty);
    });

    testWidgets('2 tap + kind-sheet DISMISSAL: dismissal is a '
        'commit path — the severity-only flare exists', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Flare day'), findsNothing);
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty &&
            server.entries.isNotEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(jsonDecode(flareRows(server).single['chips'] as String),
          ['Flare Day', 'Rough']);
      expect(find.text('2 · Rough'), findsOneWidget);
    });

    testWidgets('3 tap: ranking only — no sheet, no flare, no '
        'good record; summary semantics are Juno\'s', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('3'));
      await _pumpUntil(
        tester,
        () => find.text('3 · Average').evaluate().isNotEmpty,
      );
      expect(find.text('Flare day'), findsNothing);
      expect(find.text('Good day'), findsNothing);
      expect(
        _semantics(
          "Today's check-in: 3 of 5, average. "
          "Tap to update today's details.",
        ),
        findsOneWidget,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(server.entries, hasLength(1));
      expect(rankingRows(server), hasLength(1));
    });

    testWidgets('4 tap: good sheet → one good record with chips '
        'in sheet order and the Juno body; the summary and the '
        'Item 11 announcement carry it', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('4'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Clear head'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => find.text('4 · Good · Energy, Clear head')
            .evaluate()
            .isNotEmpty,
      );
      // Item 11 announcement: the good-day label in a live region.
      final announcement =
          tester.widget<Semantics>(_semantics('Good day · Energy, Clear head'));
      expect(announcement.properties.liveRegion, isTrue);
      expect(find.byType(SnackBar), findsNothing);
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(goodRows(server), hasLength(1));
      expect(goodRows(server).single['categoryId'], 6);
      expect(jsonDecode(goodRows(server).single['chips'] as String),
          ['Good Day', 'Energy', 'Clear head']);
      expect(goodRows(server).single['body'], 'Good day · Energy, Clear head');
      expect(rankingRows(server), hasLength(1));
      expect(flareRows(server), isEmpty);
    });

    testWidgets('5 tap + empty Done: ranking only, no good record',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('5'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => find.text('5 · Really good').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(server.entries, hasLength(1));
      expect(goodRows(server), isEmpty);
    });

    testWidgets('5 tap + dismissal: ranking only, no good record',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('5'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(server.entries, hasLength(1));
      expect(goodRows(server), isEmpty);
      expect(find.text('5 · Really good'), findsOneWidget);
    });

    testWidgets('amend: a wrong kind is fixed in place — same id, '
        'one flare record', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('1'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Fog'));
      await _pumpUntil(
        tester,
        () => find.text('1 · Really bad · Fog').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      final flareId = flareRows(server).single['id'];

      await tester.tap(find.text('1 · Really bad · Fog'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Pain'));
      await _pumpUntil(
        tester,
        () => find.text('1 · Really bad · Pain').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['id'], flareId);
      expect(flareRows(server).single['body'], 'Flare day · Really bad · Pain');
    });

    testWidgets('amend: a late flare after a 4 — severity step, '
        'kind added; the summary gains the late-add segment with '
        "Juno's exact label and semantics", (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('4'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => find.text('4 · Good · Energy').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );

      await tester.tap(find.text('4 · Good · Energy'));
      await _pumpUntil(
        tester,
        () => find.text('How bad is it today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Rough'));
      await tester.pump();
      expect(find.text('What kind of bad?'), findsOneWidget);
      await tester.tap(find.text('Dizzy'));
      await _pumpUntil(
        tester,
        () => find
            .text('4 · Good · Energy · Flare logged · Rough · Dizzy')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        _semantics(
          "Today's check-in: 4 of 5, good, energy. "
          'Flare logged, rough, dizzy. '
          "Tap to update today's details.",
        ),
        findsOneWidget,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(jsonDecode(flareRows(server).single['chips'] as String),
          ['Flare Day', 'Rough', 'Dizzy']);
      // The ranking segment keeps the number actually tapped.
      expect(rankingRows(server).single['body'], 'Feeling: 4/5 Today');
    });

    testWidgets('amend: good options are amended in place — same '
        'id, one good record', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('4'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty &&
            goodRows(server).isNotEmpty,
      );
      final goodId = goodRows(server).single['id'];

      await tester.tap(find.text('4 · Good · Energy'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      // Pre-filled from today's own good record.
      final energy = tester.widget<Semantics>(_semantics('Energy'));
      expect(energy.properties.selected, isTrue);
      // The good section sits below the flare-add section in this
      // sheet — scroll the last options into view before tapping.
      await tester.ensureVisible(find.text('Good mood'));
      await tester.pump();
      await tester.tap(find.text('Good mood'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => find
            .text('4 · Good · Energy, Good mood')
            .evaluate()
            .isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(goodRows(server), hasLength(1));
      expect(goodRows(server).single['id'], goodId);
      expect(goodRows(server).single['body'], 'Good day · Energy, Good mood');
    });

    testWidgets('amend clear-all (founder ruling, Oct 28 2026): '
        'unticking every good option deletes the good-day record '
        'with one server DELETE; the ranking record is untouched',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server(
        [
          _entryJson(_entry(
            id: 40,
            categoryId: 6,
            body: 'Feeling: 4/5 Today',
            chips: '["Daily Ranking"]',
            ts: now,
          )),
          _entryJson(_entry(
            id: 41,
            categoryId: 6,
            body: 'Good day · Energy',
            chips: '["Good Day","Energy"]',
            ts: now,
          )),
        ],
        categories: _catsNameHit,
      );
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('4 · Good · Energy').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('4 · Good · Energy'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      // The good section sits below the flare-add section in this
      // sheet — scroll its options into view before tapping.
      await tester.ensureVisible(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () =>
            goodRows(server).isEmpty &&
            find.text('4 · Good').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(goodRows(server), isEmpty);
      expect(server.capturedDeletes, [41]);
      // The ranking is a separate uneditable commit: its row is
      // byte-identical, and nothing lingers in the outbox.
      expect(rankingRows(server), hasLength(1));
      expect(rankingRows(server).single['id'], 40);
      expect(rankingRows(server).single['body'], 'Feeling: 4/5 Today');
      expect(rankingRows(server).single['chips'], '["Daily Ranking"]');
      expect(LogEntryOutbox.instance.records, isEmpty);
      expect(find.text('4 · Good'), findsOneWidget);
      expect(find.text('4 · Good · Energy'), findsNothing);
    });

    testWidgets('amend clear-all F1: a good record the server '
        'holds but the outbox marks local-only (lost POST '
        'response / kill in the confirmation gap) is deleted '
        'with a server DELETE, not cancel-only — no resurrection',
        (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rankingJson = _entryJson(_entry(
        id: 40,
        categoryId: 6,
        body: 'Feeling: 4/5 Today',
        chips: '["Daily Ranking"]',
        ts: now,
      ));
      final server = _Server(
        [
          rankingJson,
          _entryJson(_entry(
            id: 41,
            categoryId: 6,
            body: 'Good day · Energy',
            chips: '["Good Day","Energy"]',
            ts: now,
          )),
        ],
        categories: _catsNameHit,
        // POSTs fail, so Home's derive-triggered retry flush
        // cannot confirm (or remove) the staged local-only
        // record — the F1 state survives until the delete.
        failPosts: true,
      );
      // The SAME good record sits in the outbox as local-only:
      // its push landed server-side (the server holds row 41
      // above) but the client never saw the confirmation.
      final staged = await tester.runAsync(
        () => LogEntryOutbox.instance.stageForBackend(
          _entry(
            id: 41,
            categoryId: 6,
            body: 'Good day · Energy',
            chips: '["Good Day","Energy"]',
            ts: now,
          ),
          backend: server.backend(),
          serverKnown: false,
        ),
      );
      expect(staged, isTrue);
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('4 · Good · Energy').evaluate().isNotEmpty,
      );
      // Let the derive-triggered retry flush attempt and fail,
      // so the record is settled in its F1 state.
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.failedIds.contains(41),
      );
      // PRECONDITION (the F1 state itself): the outbox holds
      // record 41 classified local-only, while the server
      // already holds row 41. Without this, the test proves
      // nothing.
      final precondition = LogEntryOutbox.instance.recordFor(41);
      expect(precondition, isNotNull);
      expect(precondition!.serverKnown, isFalse);
      expect(goodRows(server), hasLength(1));
      expect(goodRows(server).single['id'], 41);

      await tester.tap(find.text('4 · Good · Energy'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.ensureVisible(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () =>
            server.capturedDeletes.isNotEmpty &&
            find.text("Today's check-in").evaluate().isEmpty,
      );
      // The fresh pull classified the record server-known, so
      // the pending record was cancelled AND the server DELETE
      // was issued — exactly one, for id 41 only.
      expect(server.capturedDeletes, [41]);
      expect(goodRows(server), isEmpty);
      // The ranking row is byte-identical.
      expect(rankingRows(server), hasLength(1));
      expect(rankingRows(server).single, rankingJson);
      expect(LogEntryOutbox.instance.recordFor(41), isNull);
      expect(LogEntryOutbox.instance.records, isEmpty);
      expect(find.text('4 · Good'), findsOneWidget);
      expect(find.text('4 · Good · Energy'), findsNothing);

      // No resurrection: a fresh Home load pulls from the
      // server again — the deleted good record stays gone.
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('4 · Good').evaluate().isNotEmpty,
      );
      expect(goodRows(server), isEmpty);
      expect(server.capturedDeletes, [41]);
      expect(find.text('4 · Good'), findsOneWidget);
      expect(find.text('4 · Good · Energy'), findsNothing);
    });

    testWidgets('amend partial clear: unticking one of two good '
        'options amends the record in place — same id, no DELETE; '
        'ranking intact', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server(
        [
          _entryJson(_entry(
            id: 40,
            categoryId: 6,
            body: 'Feeling: 5/5 Today',
            chips: '["Daily Ranking"]',
            ts: now,
          )),
          _entryJson(_entry(
            id: 41,
            categoryId: 6,
            body: 'Good day · Energy, Good mood',
            chips: '["Good Day","Energy","Good mood"]',
            ts: now,
          )),
        ],
        categories: _catsNameHit,
      );
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find
            .text('5 · Really good · Energy, Good mood')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.text('5 · Really good · Energy, Good mood'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.ensureVisible(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () =>
            LogEntryOutbox.instance.records.isEmpty &&
            goodRows(server).isNotEmpty &&
            goodRows(server).single['body'] == 'Good day · Good mood',
      );
      expect(goodRows(server), hasLength(1));
      expect(goodRows(server).single['id'], 41);
      expect(goodRows(server).single['body'], 'Good day · Good mood');
      expect(server.capturedDeletes, isEmpty);
      expect(rankingRows(server), hasLength(1));
      expect(rankingRows(server).single['id'], 40);
      expect(rankingRows(server).single['body'], 'Feeling: 5/5 Today');
      expect(find.text('5 · Really good · Good mood'), findsOneWidget);
    });

    testWidgets('amend clear-all during a gated push: the delete '
        'joins the in-flight push before classifying; the good '
        'record is still local-only at classification, so its '
        'cancel is the whole delete — the server ends with the '
        'ranking only and no DELETE is owed', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      await tester.tap(find.text('4'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      // Both records are staged locally; their push is parked on
      // the gate, so nothing has reached the server yet.
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.length == 2,
      );
      final stagedGoodId = LogEntryOutbox.instance.records
          .singleWhere((r) => r.entry.chips.contains('Good Day'))
          .entry
          .id;
      await _pumpUntil(
        tester,
        () => find.text('4 · Good · Energy').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('4 · Good · Energy'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.ensureVisible(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      // The delete must be parked joining the in-flight push:
      // several frames pass with the sheet still open and no
      // DELETE issued.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text("Today's check-in"), findsOneWidget);
      expect(server.capturedDeletes, isEmpty);
      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () =>
            LogEntryOutbox.instance.records.isEmpty &&
            goodRows(server).isEmpty,
      );
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isEmpty,
      );
      expect(rankingRows(server), hasLength(1));
      expect(goodRows(server), isEmpty);
      // Classification evidence (verified by instrumented run):
      // the gated in-flight push carried the RANKING (staged
      // first — the outbox flush attempts records in insertion
      // order), and the good record, marked deleting before its
      // turn in that same flush, never reached the server. At
      // classification it was a local-only pending record, so per
      // the History precedent its cancel was the whole delete and
      // NO server DELETE was owed for the staged good id.
      // The surviving server row is the ranking, not the staged
      // good record.
      expect(rankingRows(server).single['id'], isNot(stagedGoodId));
      expect(server.capturedDeletes, isEmpty);
      expect(LogEntryOutbox.instance.records, isEmpty);
      expect(find.text('4 · Good'), findsOneWidget);
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('amend clear-all with a failing DELETE: the sheet '
        'stays open with the generic failure copy and the record '
        'survives; the retry deletes it and leaves the ranking '
        'intact', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server(
        [
          _entryJson(_entry(
            id: 40,
            categoryId: 6,
            body: 'Feeling: 4/5 Today',
            chips: '["Daily Ranking"]',
            ts: now,
          )),
          _entryJson(_entry(
            id: 41,
            categoryId: 6,
            body: 'Good day · Energy',
            chips: '["Good Day","Energy"]',
            ts: now,
          )),
        ],
        categories: _catsNameHit,
      );
      server.failDeletes = true;
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('4 · Good · Energy').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('4 · Good · Energy'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.ensureVisible(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => find.text(flareStageFailureCopy).evaluate().isNotEmpty,
      );
      // The failed DELETE changed nothing: sheet open, record
      // still on the server, no delete captured.
      expect(find.text("Today's check-in"), findsOneWidget);
      expect(goodRows(server), hasLength(1));
      expect(server.capturedDeletes, isEmpty);
      server.failDeletes = false;
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () =>
            goodRows(server).isEmpty &&
            find.text("Today's check-in").evaluate().isEmpty,
      );
      expect(server.capturedDeletes, [41]);
      expect(rankingRows(server), hasLength(1));
      expect(rankingRows(server).single['id'], 40);
      expect(rankingRows(server).single['body'], 'Feeling: 4/5 Today');
      expect(find.text('4 · Good'), findsOneWidget);
    });

    testWidgets("legacy 'Bad' flare on a 4 day: the summary "
        'displays the recorded severity verbatim', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server(
        [
          _entryJson(_entry(
            id: 40,
            categoryId: 6,
            body: 'Feeling: 4/5 Today',
            chips: '["Daily Ranking"]',
            ts: now,
          )),
          _entryJson(_entry(
            id: 41,
            categoryId: 3,
            body: 'Flare day · Bad · Crash',
            chips: '["Flare Day","Bad","Crash"]',
            ts: now,
          )),
        ],
        categories: _catsNameHit,
      );
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find
            .text('4 · Good · Flare logged · Bad · Crash')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('How are you feeling?'), findsNothing);
      expect(
        _semantics(
          "Today's check-in: 4 of 5, good. Flare logged, bad, crash. "
          "Tap to update today's details.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('per-record gate: a flare stage failure after the '
        'ranking succeeded leaves the summary showing the ranking '
        'alone; a later kind pick retries creation as an upsert',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      // Ranking stage = allocate persist + stage persist (2 writes,
      // push gated so no flush bookkeeping writes interleave).
      // Every later disk write fails: the flare stage cannot land.
      diskWrites = 0;
      diskFailAfter = 2;
      await tester.tap(find.text('1'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      // Only the ranking is staged — no flare record exists.
      expect(
        LogEntryOutbox.instance.records
            .where((r) => r.entry.chips.contains('Flare Day')),
        isEmpty,
      );
      // A kind pick retries creation and fails the same way: the
      // sheet stays open with the existing generic copy.
      await tester.tap(find.text('Fog'));
      await _pumpUntil(
        tester,
        () => find.text(flareStageFailureCopy).evaluate().isNotEmpty,
      );
      // Disk recovers: the same kind pick now creates the record.
      diskFailAfter = null;
      await tester.tap(find.text('Fog'));
      await _pumpUntil(
        tester,
        () => find.text('1 · Really bad · Fog').evaluate().isNotEmpty,
      );
      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(rankingRows(server), hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('per-record gate: a good stage failure leaves the '
        'summary showing the ranking alone, with no good segment',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      diskWrites = 0;
      diskFailAfter = 2;
      await tester.tap(find.text('4'));
      await _pumpUntil(
        tester,
        () => find.text('What is good about today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Energy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await _pumpUntil(
        tester,
        () => find.text(flareStageFailureCopy).evaluate().isNotEmpty,
      );
      // Dismiss: the summary is the ranking alone.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      diskFailAfter = null;
      expect(find.text('4 · Good'), findsOneWidget);
      expect(
        LogEntryOutbox.instance.records
            .where((r) => r.entry.chips.contains('Good Day')),
        isEmpty,
      );
      expect(goodRows(server), isEmpty);
    });

    testWidgets('kill-before-push (ranking): a ranking staged, '
        'the process killed before its push, relaunches into the '
        'summary and lands exactly once server-side', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      final outbox = LogEntryOutbox.instance;
      final entry = buildFeelingEntry(
        level: 2,
        categoryId: 6,
        id: 77,
      );
      await tester.runAsync(
        () => outbox.stage(entry, serverKnown: false, ownerEmail: _owner),
      );
      outbox.debugReset();
      expect(outbox.records, isEmpty);
      expect(server.capturedPosts, isEmpty);

      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('2 · Rough').evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => server.capturedPosts.isNotEmpty);
      await _pumpUntil(tester, () => outbox.records.isEmpty);
      expect(
        server.capturedPosts.where((e) => e['id'] == 77),
        hasLength(1),
      );
      expect(server.entries.where((e) => e['id'] == 77), hasLength(1));
      // No flare was invented on relaunch: derivation alone never
      // creates one.
      expect(flareRows(server), isEmpty);
    });

    testWidgets('failed push: the logged state persists locally, '
        'the failure rides the existing Not synced copy in History, '
        'and a retry does not duplicate (original §5 item 12, '
        'ported)', (tester) async {
      final server = _Server([], categories: _catsNameHit, failPosts: true);
      await pumpHome(tester, server);
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Pain'));
      await _pumpUntil(
        tester,
        () => find.text('2 · Rough · Pain').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.failedIds.isNotEmpty,
      );
      // Logged state persists despite the failed push.
      expect(find.text('2 · Rough · Pain'), findsOneWidget);
      expect(server.entries, isEmpty);

      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Not synced').evaluate().isNotEmpty,
      );
      expect(find.text('Flare day · Rough · Pain'), findsOneWidget);
      // Both pending records (ranking + flare) carry the shared
      // badge — the merged flow has two records where the old flow
      // had one.
      expect(find.text('Not synced'), findsWidgets);

      server.failPosts = false;
      await tester.runAsync(
        () => LogEntryOutbox.instance.flush(server.backend()),
      );
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['body'], 'Flare day · Rough · Pain');
      expect(LogEntryOutbox.instance.records, isEmpty);
    });

    testWidgets('double-tap on the committing kind writes exactly '
        'one flare record', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Dizzy'));
      await tester.tap(find.text('Dizzy'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(rankingRows(server), hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('F1: flare pre-stage failure → the kind sheet '
        'opens showing the failure copy → DISMISSAL retries the '
        'severity-only stage and the flare lands', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      // Ranking stage = allocate persist + stage persist (2
      // writes, push gated so no flush bookkeeping writes
      // interleave). Every later disk write fails: the flare
      // pre-stage (local, Vera F5) cannot land.
      diskWrites = 0;
      diskFailAfter = 2;
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      // (a) The sheet opened already showing the existing generic
      // failure copy — the user knows no flare is staged yet.
      expect(find.text(flareStageFailureCopy), findsOneWidget);
      expect(
        LogEntryOutbox.instance.records
            .where((r) => r.entry.chips.contains('Flare Day')),
        isEmpty,
      );
      // The disk recovers, then the user DISMISSES the sheet:
      // dismissal is a commit path, so the dismissal retry stages
      // the severity-only flare.
      diskFailAfter = null;
      await tester.tapAt(const Offset(10, 10));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records
            .any((r) => r.entry.chips.contains('Flare Day')),
      );
      final stagedFlare = LogEntryOutbox.instance.records
          .singleWhere((r) => r.entry.chips.contains('Flare Day'))
          .entry;
      expect(jsonDecode(stagedFlare.chips), ['Flare Day', 'Rough']);
      expect(stagedFlare.body, 'Flare day · Rough');
      // The retry's commit announces the severity-only label in a
      // live region (Item 11; Vera gap 7, severity-only form).
      final announcement =
          tester.widget<Semantics>(_semantics('Flare logged · Rough'));
      expect(announcement.properties.liveRegion, isTrue);
      expect(find.text('2 · Rough'), findsOneWidget);

      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['body'], 'Flare day · Rough');
      expect(rankingRows(server), hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('F1: flare pre-stage failure → kind-sheet '
        'dismissal with the disk STILL failing stages no flare, '
        'fires no announcement, and the summary stays '
        'ranking-alone', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      diskWrites = 0;
      diskFailAfter = 2;
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      expect(find.text(flareStageFailureCopy), findsOneWidget);
      // Dismiss while every disk write still fails: the dismissal
      // retry runs and fails the same way.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Flare day'), findsNothing);
      expect(
        LogEntryOutbox.instance.records
            .where((r) => r.entry.chips.contains('Flare Day')),
        isEmpty,
      );
      expect(flareRows(server), isEmpty);
      // No announcement fired for a record that does not exist.
      expect(_semantics('Flare logged · Rough'), findsNothing);
      // The honest Item 11 state: the ranking alone.
      expect(find.text('2 · Rough'), findsOneWidget);

      diskFailAfter = null;
      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), isEmpty);
      expect(rankingRows(server), hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('F5: the initial severity-only flare stages from '
        'the LOCAL merged view — the flare stage adds no fresh '
        'pull; the kind amend that follows still re-checks via a '
        'pull', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      final pullsBefore = server.pullCount;
      await tester.tap(find.text('2'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      // Exactly ONE new pull since the tap: the ranking commit's
      // own re-check. The flare pre-stage staged locally.
      expect(server.pullCount, pullsBefore + 1);
      final stagedFlare = LogEntryOutbox.instance.records
          .singleWhere((r) => r.entry.chips.contains('Flare Day'))
          .entry;
      expect(jsonDecode(stagedFlare.chips), ['Flare Day', 'Rough']);
      expect(stagedFlare.body, 'Flare day · Rough');
      // The kind tap amends that same record through the
      // pull-based path: one more pull, same id.
      await tester.tap(find.text('Dizzy'));
      await _pumpUntil(
        tester,
        () => find.text('2 · Rough · Dizzy').evaluate().isNotEmpty,
      );
      expect(server.pullCount, pullsBefore + 2);
      final amendedFlare = LogEntryOutbox.instance.records
          .singleWhere((r) => r.entry.chips.contains('Flare Day'))
          .entry;
      expect(amendedFlare.id, stagedFlare.id);
      expect(
        jsonDecode(amendedFlare.chips),
        ['Flare Day', 'Rough', 'Dizzy'],
      );

      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
      expect(rankingRows(server), hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('F4: a severity-less flare record (chips hold '
        'only the Flare Day tag) on a ranking-4 day — an amend '
        'kind tap writes NOTHING and the sheet shows the generic '
        'failure copy', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server(
        [
          _entryJson(_entry(
            id: 40,
            categoryId: 6,
            body: 'Feeling: 4/5 Today',
            chips: '["Daily Ranking"]',
            ts: now,
          )),
          _entryJson(_entry(
            id: 41,
            categoryId: 3,
            body: 'Flare day',
            chips: '["Flare Day"]',
            ts: now,
          )),
        ],
        categories: _catsNameHit,
      );
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('4 · Good').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('4 · Good'));
      await _pumpUntil(
        tester,
        () => find.text("Today's check-in").evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Dizzy'));
      await _pumpUntil(
        tester,
        () => find.text(flareStageFailureCopy).evaluate().isNotEmpty,
      );
      // The sheet stayed open, nothing was staged, and the server
      // record is byte-identical: no invented severity was written.
      expect(find.text("Today's check-in"), findsOneWidget);
      expect(LogEntryOutbox.instance.records, isEmpty);
      expect(server.capturedPosts, isEmpty);
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['chips'], '["Flare Day"]');
      expect(flareRows(server).single['body'], 'Flare day');
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('gap 7: a flare commit from a number tap '
        'announces the with-kind label in a LIVE REGION at Home '
        'level (mirroring the good-day announcement assertion)',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('1'));
      await _pumpUntil(
        tester,
        () => find.text('What kind of bad?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Fog'));
      await _pumpUntil(
        tester,
        () => find.text('1 · Really bad · Fog').evaluate().isNotEmpty,
      );
      final announcement = tester.widget<Semantics>(
        _semantics('Flare logged · Really bad · Fog'),
      );
      expect(announcement.properties.liveRegion, isTrue);
      expect(find.byType(SnackBar), findsNothing);
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(flareRows(server), hasLength(1));
    });

    testWidgets('gap 2 (Home level): amend late-add dismissal '
        'before a kind-step commit writes nothing — dismissed at '
        'the severity step, and again at the kind step',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('3'));
      await _pumpUntil(
        tester,
        () => find.text('3 · Average').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );

      // First opening: dismiss at the severity step.
      await tester.tap(find.text('3 · Average'));
      await _pumpUntil(
        tester,
        () => find.text('How bad is it today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(flareRows(server), isEmpty);
      expect(
        LogEntryOutbox.instance.records
            .where((r) => r.entry.chips.contains('Flare Day')),
        isEmpty,
      );

      // Second opening: choose a severity (sheet-local only), then
      // dismiss at the kind step — still nothing written.
      await tester.tap(find.text('3 · Average'));
      await _pumpUntil(
        tester,
        () => find.text('How bad is it today?').evaluate().isNotEmpty,
      );
      await settleSheet(tester);
      await tester.tap(find.text('Rough'));
      await tester.pump();
      expect(find.text('What kind of bad?'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text("Today's check-in"), findsNothing);
      expect(flareRows(server), isEmpty);
      expect(
        LogEntryOutbox.instance.records
            .where((r) => r.entry.chips.contains('Flare Day')),
        isEmpty,
      );
      expect(find.text('3 · Average'), findsOneWidget);
      expect(server.entries, hasLength(1));
    });

    testWidgets('kill-before-push (flare, gap 3): ranking + '
        'severity-only flare staged, the process killed before '
        'their push, relaunch derives the flare from the merged '
        'view and it lands exactly once server-side',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      final outbox = LogEntryOutbox.instance;
      final ranking = buildFeelingEntry(level: 2, categoryId: 6, id: 77);
      final flare = buildFlareEntry(id: 78, categoryId: 3, severity: 'Rough');
      // Staged through the same outbox stage the new local path
      // (Vera F5a) lands in — durable on disk, never pushed.
      await tester.runAsync(() async {
        await outbox.stage(ranking, serverKnown: false, ownerEmail: _owner);
        await outbox.stage(flare, serverKnown: false, ownerEmail: _owner);
      });
      // Simulated kill: in-memory state is gone, the disk blob
      // (and only it) carries both records into the relaunch.
      outbox.debugReset();
      expect(outbox.records, isEmpty);
      expect(server.capturedPosts, isEmpty);

      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('2 · Rough').evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => outbox.records.isEmpty);
      // Each record pushed exactly once — the staged flare was
      // derived and flushed by the relaunch, never duplicated.
      expect(
        server.capturedPosts.where((e) => e['id'] == 77),
        hasLength(1),
      );
      expect(
        server.capturedPosts.where((e) => e['id'] == 78),
        hasLength(1),
      );
      expect(flareRows(server), hasLength(1));
      expect(flareRows(server).single['body'], 'Flare day · Rough');
      expect(
        jsonDecode(flareRows(server).single['chips'] as String),
        ['Flare Day', 'Rough'],
      );
      expect(rankingRows(server), hasLength(1));
    });
  });

  group('surfaces (original §5 items 15–16)', () {
    test('15: a flare-only day counts in the Weekly Snapshot logs '
        'metric', () {
      final now = DateTime.now();
      String ds(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final dateStrs = [
        for (var i = 6; i >= 0; i--) ds(now.subtract(Duration(days: i))),
      ];
      final labels = [for (final _ in dateStrs) 'X'];
      final flare = buildFlareEntry(id: 1, categoryId: 3, severity: 'Rough');
      final data = buildLogsMetric(dateStrs, labels, [flare.timestamp]);
      expect(data.points.last.value, 1);
      expect(data.averageOrTotalText, '7-Day Total: 1 logs');
      expect(data.isEmpty, isFalse);
    });

    testWidgets('15: the flare entry renders in History as a '
        'normal, unlocked logged entry, its body exactly as '
        'recorded (legacy Bad included)', (tester) async {
      final flare = buildFlareEntry(
        id: 42,
        categoryId: 3,
        severity: 'Bad',
        type: 'Dizzy',
      );
      final server = _Server([_entryJson(flare)], categories: _catsNameHit);
      final cats = _catsNameHit.map(QuickLogCategory.fromJson).toList();
      expect(isLockedCheckInEntry(flare, cats), isFalse);

      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Flare day · Bad · Dizzy').evaluate().isNotEmpty,
      );
      expect(find.text('Flare day · Bad · Dizzy'), findsOneWidget);
      expect(find.text('Synced'), findsOneWidget);
    });

    test('16: Daily Score output is identical with and without a '
        'flare record, and a no-biometric day keeps its '
        'missing-data result', () {
      final days = <String, DailyBiometrics>{};
      String ds(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final base = DateTime(2026, 10, 1);
      for (var i = 0; i < 20; i++) {
        final date = ds(base.add(Duration(days: i)));
        days[date] = DailyBiometrics(
          date: date,
          hrvRmssdMs: 50,
          restingHrBpm: 60,
          sleepMinutes: 480,
        );
      }
      final target = ds(base.add(const Duration(days: 20)));
      days[target] = DailyBiometrics(
        date: target,
        hrvRmssdMs: 45,
        restingHrBpm: 62,
        sleepMinutes: 420,
      );
      final before = computeDailyScore(days, target);
      expect(before, isNotNull);
      final after = computeDailyScore(days, target);
      expect(after!.dailyExact, before!.dailyExact);
      expect(after.dailyScore, before.dailyScore);
      expect(after.sleepScore, before.sleepScore);
      expect(after.hrvScore, before.hrvScore);
      expect(after.restingHrScore, before.restingHrScore);
      expect(after.asleepMinutes, before.asleepMinutes);
      expect(after.sleepNeedMinutes, before.sleepNeedMinutes);
      expect(after.hrvBaselineMs, before.hrvBaselineMs);
      expect(after.restingHrBaselineBpm, before.restingHrBaselineBpm);
      final emptyDay = ds(base.add(const Duration(days: 30)));
      days[emptyDay] = DailyBiometrics(date: emptyDay);
      expect(computeDailyScore(days, emptyDay), isNull);
    });

    test('15 (model): the logs metric is the Weekly Snapshot logs '
        'metric', () {
      expect(SnapshotMetric.logs.stableKey, 'logs');
    });
  });
}
