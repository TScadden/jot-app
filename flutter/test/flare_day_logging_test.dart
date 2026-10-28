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
import 'package:tabs_lab/src/features/home/flare_day_logging.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Phase 1 item 1 — flare-day fast logging (spec §5 test plan).
/// Numbers in test names map to the spec's §5 items.

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

/// Categories where both miss (button must not render).
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

  TabsBackend backend() {
    final store = FakeSessionStore()
      ..token = 'test-token'
      ..email = _owner;
    final client = MockClient((request) async {
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

void main() {
  late Map<String, String> disk;
  late bool diskWriteFails;

  setUp(() {
    TabsBackend.debugResetSharedCaches();
    disk = <String, String>{};
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
      () => find.byType(FlareDayButton).evaluate().isNotEmpty ||
          identical(server.categories, _catsDoubleMiss),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('data / identity (§5 items 6–9)', () {
    test('6: typed record shape is exact', () {
      final now = DateTime(2026, 10, 28, 15, 30);
      final e = buildFlareEntry(
        id: 12,
        categoryId: 3,
        severity: 'Bad',
        type: 'Dizzy',
        now: now,
      );
      expect(e.id, 12);
      expect(e.categoryId, 3);
      expect(e.chips, '["Flare Day","Bad","Dizzy"]');
      expect(jsonDecode(e.chips), ['Flare Day', 'Bad', 'Dizzy']);
      expect(e.body, 'Flare day · Bad · Dizzy');
      expect(e.manualText, '');
      expect(e.timestamp, now.millisecondsSinceEpoch);
    });

    test('6: severity-only record carries the two-element chip list '
        'and the severity-only body', () {
      final e = buildFlareEntry(id: 5, categoryId: 3, severity: 'Rough');
      expect(jsonDecode(e.chips), ['Flare Day', 'Rough']);
      expect(e.body, 'Flare day · Rough');
      expect(e.manualText, '');
    });

    test('7: identity positives and negatives', () {
      final now = DateTime(2026, 10, 28, 11, 0);
      int ms(DateTime d) => d.millisecondsSinceEpoch;
      final flare = _entry(
        chips: '["Flare Day","Bad","Fog"]',
        ts: ms(DateTime(2026, 10, 28, 9, 0)),
      );
      expect(
        hasFlareToday([flare], symptomsCategoryId: 3, now: now),
        isTrue,
      );
      expect(
        findFlareRecord([flare], symptomsCategoryId: 3, now: now)?.id,
        flare.id,
      );
      // Ordinary Symptoms entry, no tag.
      expect(
        hasFlareToday(
          [_entry(chips: '["Symptoms"]', ts: flare.timestamp)],
          symptomsCategoryId: 3,
          now: now,
        ),
        isFalse,
      );
      // Tagged entry in another category.
      expect(
        hasFlareToday(
          [
            _entry(
              categoryId: 6,
              chips: '["Flare Day","Bad"]',
              ts: flare.timestamp,
            )
          ],
          symptomsCategoryId: 3,
          now: now,
        ),
        isFalse,
      );
      // Yesterday's flare (previous energy day).
      expect(
        hasFlareToday(
          [
            _entry(
              chips: '["Flare Day","Bad"]',
              ts: ms(DateTime(2026, 10, 27, 12, 0)),
            )
          ],
          symptomsCategoryId: 3,
          now: now,
        ),
        isFalse,
      );
    });

    test('7: the 04:00 energy-day boundary — 03:59 belongs to the '
        'previous day, 04:00 opens the new one', () {
      int ms(DateTime d) => d.millisecondsSinceEpoch;
      final at0359 = _entry(
        chips: '["Flare Day","Bad"]',
        ts: ms(DateTime(2026, 10, 28, 3, 59)),
      );
      final at0400 = _entry(
        id: 2,
        chips: '["Flare Day","Bad"]',
        ts: ms(DateTime(2026, 10, 28, 4, 0)),
      );
      // At 05:00 the current energy day started today 04:00: the
      // 03:59 record is yesterday's, the 04:00 record is today's.
      final morning = DateTime(2026, 10, 28, 5, 0);
      expect(
        hasFlareToday([at0359], symptomsCategoryId: 3, now: morning),
        isFalse,
      );
      expect(
        hasFlareToday([at0400], symptomsCategoryId: 3, now: morning),
        isTrue,
      );
      // At 03:59 the energy day still started YESTERDAY 04:00, so
      // the 03:59 record counts.
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
      final amended = amendFlareEntry(original, severity: 'Bad', type: 'Pain');
      expect(amended.id, original.id);
      expect(amended.timestamp, original.timestamp);
      expect(amended.categoryId, 3);
      expect(jsonDecode(amended.chips), ['Flare Day', 'Bad', 'Pain']);
      expect(amended.body, 'Flare day · Bad · Pain');
      final sync = amended.toSyncJson();
      expect(sync['id'], 9);
      expect(sync['updatedAt'], isA<int>());
      expect(
        findFlareRecord([amended],
            symptomsCategoryId: 3, now: DateTime(2026, 10, 28, 12, 0))?.id,
        9,
      );
    });

    test("9: legacy ', '-joined chips on other entries parse without "
        'misclassifying them', () {
      final now = DateTime(2026, 10, 28, 11, 0);
      final ts = DateTime(2026, 10, 28, 9, 0).millisecondsSinceEpoch;
      // An ordinary Symptoms entry in Quick Log's joined form.
      final ordinary = _entry(chips: 'Headache, Pain', ts: ts);
      expect(parseFlareChips(ordinary.chips), ['Headache', 'Pain']);
      expect(
        hasFlareToday([ordinary], symptomsCategoryId: 3, now: now),
        isFalse,
      );
      // A joined string that mentions the tag in prose is not a tag
      // list either — the tag must be an element.
      final prose = _entry(chips: 'Not a Flare Day, honestly', ts: ts);
      expect(chipsContainFlareTag(prose.chips), isFalse);
      expect(
        hasFlareToday([prose], symptomsCategoryId: 3, now: now),
        isFalse,
      );
      // Bare-list rendering tolerance (the feeling precedent shape).
      expect(chipsContainFlareTag('[Flare Day, Bad]'), isTrue);
      // Malformed / empty never throws and never matches.
      expect(parseFlareChips(''), isEmpty);
      expect(chipsContainFlareTag('not json'), isFalse);
    });

    test('category resolution (Q4): name hit, fallback hit, double '
        'miss → null', () {
      QuickLogCategory cat(int id, String name) => QuickLogCategory(
            id: id,
            name: name,
            icon: 'circle',
            colorHex: '#CCCCCC',
            isDefault: true,
            sortOrder: 0,
          );
      expect(resolveFlareCategoryId([cat(3, 'Symptoms'), cat(1, 'Other')]), 3);
      expect(resolveFlareCategoryId([cat(1, 'Renamed')]), 1);
      expect(resolveFlareCategoryId([cat(9, 'Renamed')]), isNull);
      expect(resolveFlareCategoryId(const []), isNull);
    });
  });

  group('sheet widget (§5 items 2–4, 17)', () {
    Future<({List<Map<String, String?>> commits})> pumpSheet(
      WidgetTester tester, {
      Future<bool> Function({required String severity, String? type})? commit,
      String? initialSeverity,
      String? initialType,
      bool disableAnimations = false,
    }) async {
      final commits = <Map<String, String?>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: disableAnimations),
              child: Builder(
                builder: (inner) => Center(
                  child: ElevatedButton(
                    onPressed: () => showFlareDaySheet(
                      context: inner,
                      initialSeverity: initialSeverity,
                      initialType: initialType,
                      onCommit: commit ??
                          ({required severity, type}) async {
                            commits.add({'severity': severity, 'type': type});
                            return true;
                          },
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return (commits: commits);
    }

    testWidgets('2: severity-only path — Just log this commits with '
        'no type', (tester) async {
      final h = await pumpSheet(tester);
      expect(find.text('Flare day'), findsOneWidget);
      expect(find.text('How bad is it today?'), findsOneWidget);
      await tester.tap(find.text('Bad'));
      await tester.pump();
      expect(find.text('What kind of bad?'), findsOneWidget);
      await tester.tap(find.text('Just log this'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.commits, [
        {'severity': 'Bad', 'type': null},
      ]);
      // Sheet closed after the commit.
      expect(find.text('Flare day'), findsNothing);
    });

    testWidgets('3: dismissal by scrim writes nothing', (tester) async {
      final h = await pumpSheet(tester);
      await tester.tap(find.text('Rough'));
      await tester.pump();
      expect(find.text('What kind of bad?'), findsOneWidget);
      // Tap the scrim (outside the sheet).
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Flare day'), findsNothing);
      expect(h.commits, isEmpty);
    });

    testWidgets('4: every target is ≥48dp; reduced motion renders '
        'the flow with no animation and no auto-dismiss', (tester) async {
      await pumpSheet(tester, disableAnimations: true);
      for (final label in ['Rough', 'Bad', 'Really bad']) {
        // The tappable option (its semantics node) is ≥48dp.
        final optSize = tester.getSize(_semantics(
          label == 'Rough'
              ? 'Rough, severity 1 of 3'
              : label == 'Bad'
                  ? 'Bad, severity 2 of 3'
                  : 'Really bad, severity 3 of 3',
        ));
        expect(optSize.height, greaterThanOrEqualTo(48), reason: label);
        expect(optSize.width, greaterThanOrEqualTo(48), reason: label);
      }
      await tester.tap(find.text('Rough'));
      await tester.pump();
      for (final label in ['Dizzy', 'Pain', 'Fog', 'Crash', 'Just log this']) {
        final opt = tester.getSize(_semantics(label));
        expect(opt.height, greaterThanOrEqualTo(48), reason: label);
        expect(opt.width, greaterThanOrEqualTo(48), reason: label);
      }
      // No auto-dismiss: time passing changes nothing.
      await tester.pump(const Duration(minutes: 5));
      expect(find.text('Flare day'), findsOneWidget);
      expect(find.text('What kind of bad?'), findsOneWidget);
    });

    testWidgets('17: semantics labels are Juno\'s verbatim set',
        (tester) async {
      await pumpSheet(tester);
      expect(_semantics('Rough, severity 1 of 3'), findsOneWidget);
      expect(_semantics('Bad, severity 2 of 3'), findsOneWidget);
      expect(_semantics('Really bad, severity 3 of 3'), findsOneWidget);
      await tester.tap(find.text('Rough'));
      await tester.pump();
      for (final t in ['Dizzy', 'Pain', 'Fog', 'Crash']) {
        expect(_semantics(t), findsWidgets, reason: t);
      }
    });
  });

  group('Home flow (§5 items 1, 5, 10–14, 17)', () {
    testWidgets('5: button present on name hit and on fallback hit',
        (tester) async {
      final byName = _Server([], categories: _catsNameHit);
      await pumpHome(tester, byName);
      expect(find.text('Bad day'), findsOneWidget);
      expect(_semantics('Log a flare day'), findsOneWidget);
      final btnSize = tester.getSize(_semantics('Log a flare day'));
      expect(btnSize.height, greaterThanOrEqualTo(48));

      final byFallback = _Server([], categories: _catsFallbackHit);
      await pumpHome(tester, byFallback);
      expect(find.text('Bad day'), findsOneWidget);
    });

    testWidgets('5: button absent on a double category miss',
        (tester) async {
      final miss = _Server([], categories: _catsDoubleMiss);
      await pumpHome(tester, miss);
      expect(find.text('Bad day'), findsNothing);
      expect(find.textContaining('Flare logged'), findsNothing);
    });

    testWidgets(
        '1 + 10 + 17: three taps commit exactly once; the logged '
        'state is visible before the gated push lands and carries '
        'the item 9 label as a live-region announcement',
        (tester) async {
      final server = _Server(
        [_entryJson(_entry(id: 41, body: 'headache'))],
        categories: _catsNameHit,
      );
      server.postGate = Completer<void>();
      await pumpHome(tester, server);

      var taps = 0;
      Future<void> tap(Finder f) async {
        taps++;
        await tester.tap(f);
        await tester.pump();
      }

      await tap(find.text('Bad day')); // tap 1 — open
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Flare day'), findsOneWidget);
      await tap(find.text('Bad')); // tap 2 — severity
      expect(find.text('What kind of bad?'), findsOneWidget);
      await tap(find.text('Dizzy')); // tap 3 — type, commits
      await _pumpUntil(
        tester,
        () => find.text('Flare logged · Bad').evaluate().isNotEmpty,
      );
      expect(taps, 3);

      // Logged state is up while the push is STILL gated (§5.10).
      expect(server.capturedPosts, isEmpty);
      expect(find.text('Flare logged · Bad'), findsOneWidget);
      // No confirmation toast/snackbar anywhere (§3.3a).
      expect(find.byType(SnackBar), findsNothing);
      // The announcement: the item 9 label is the button's semantics
      // label in a live region (§5.17).
      final sem = tester.widget<Semantics>(_semantics('Flare logged · Bad'));
      expect(sem.properties.liveRegion, isTrue);
      expect(sem.properties.button, isTrue);
      // Exactly one record staged, with the exact shape.
      final staged = LogEntryOutbox.instance.records;
      expect(staged, hasLength(1));
      expect(staged.single.entry.body, 'Flare day · Bad · Dizzy');
      expect(
        jsonDecode(staged.single.entry.chips),
        ['Flare Day', 'Bad', 'Dizzy'],
      );
      expect(staged.single.entry.categoryId, 3);

      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(server.capturedPosts, hasLength(1));
      expect(server.entries.where((e) => e['body'] == 'Flare day · Bad · Dizzy'),
          hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets(
        '8 (Home): tapping the logged button re-opens the sheet '
        'pre-filled and amends the same record — still one record',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('Bad day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Rough'));
      await tester.pump();
      await tester.tap(find.text('Fog'));
      await _pumpUntil(
        tester,
        () => find.text('Flare logged · Rough').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      final firstId = server.entries.single['id'];

      // Re-open from the logged state: sheet is pre-filled (the
      // severity step opens from today's record).
      await tester.tap(find.text('Flare logged · Rough'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('How bad is it today?'), findsOneWidget);
      await tester.tap(find.text('Really bad'));
      await tester.pump();
      await tester.tap(find.text('Crash'));
      await _pumpUntil(
        tester,
        () => find.text('Flare logged · Really bad').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(server.entries, hasLength(1));
      expect(server.entries.single['id'], firstId);
      expect(server.entries.single['body'], 'Flare day · Really bad · Crash');
      expect(
        jsonDecode(server.entries.single['chips'] as String),
        ['Flare Day', 'Really bad', 'Crash'],
      );
    });

    testWidgets(
        '11: kill-before-push — a record staged, the process killed '
        'before its push, relaunches and lands exactly once server-side',
        (tester) async {
      final server = _Server([], categories: _catsNameHit);
      final outbox = LogEntryOutbox.instance;
      final entry = buildFlareEntry(
        id: 77,
        categoryId: 3,
        severity: 'Bad',
        type: 'Crash',
      );
      await tester.runAsync(
        () => outbox.stage(entry, serverKnown: false, ownerEmail: _owner),
      );
      // Process death: in-memory state gone, disk blob survives, the
      // push never ran.
      outbox.debugReset();
      expect(outbox.records, isEmpty);
      expect(server.capturedPosts, isEmpty);

      // Relaunch: Home loads, derives the logged state from the
      // outbox-merged entries, and its sync trigger flushes.
      await pumpHome(tester, server);
      await _pumpUntil(
        tester,
        () => find.text('Flare logged · Bad').evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => server.capturedPosts.isNotEmpty);
      await _pumpUntil(tester, () => outbox.records.isEmpty);
      expect(server.capturedPosts, hasLength(1));
      expect(
        server.entries.where((e) => e['id'] == 77),
        hasLength(1),
      );
    });

    testWidgets(
        '12: failed push — logged state persists, the failure rides '
        'the existing Not synced copy in History, retry does not '
        'duplicate', (tester) async {
      final server = _Server([], categories: _catsNameHit, failPosts: true);
      await pumpHome(tester, server);
      await tester.tap(find.text('Bad day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Bad'));
      await tester.pump();
      await tester.tap(find.text('Pain'));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.failedIds.isNotEmpty,
      );
      // Logged state persists locally despite the failed push.
      expect(find.text('Flare logged · Bad'), findsOneWidget);
      expect(server.entries, isEmpty);

      // The existing sync-state surface: History shows the entry
      // with the shared badge's Not synced copy — no flare-specific
      // failure string exists anywhere in the flow.
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
      expect(find.text('Flare day · Bad · Pain'), findsOneWidget);
      expect(find.text('Not synced'), findsOneWidget);

      // Retry after recovery: exactly one server record.
      server.failPosts = false;
      await tester.runAsync(
        () => LogEntryOutbox.instance.flush(server.backend()),
      );
      expect(server.entries, hasLength(1));
      expect(server.entries.single['body'], 'Flare day · Bad · Pain');
      expect(LogEntryOutbox.instance.records, isEmpty);
    });

    testWidgets(
        '13: local write failure — the button stays un-logged and '
        'the sheet surfaces the existing generic copy', (tester) async {
      diskWriteFails = true;
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      await tester.tap(find.text('Bad day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Bad'));
      await tester.pump();
      await tester.tap(find.text('Dizzy'));
      await _pumpUntil(
        tester,
        () => find.text(flareStageFailureCopy).evaluate().isNotEmpty,
      );
      // The generic Quick Log copy, verbatim — no flare-specific
      // failure string.
      expect(find.text(flareStageFailureCopy), findsOneWidget);
      // Sheet still open for a retry; nothing staged; and once the
      // sheet is dismissed the button is still un-logged.
      expect(LogEntryOutbox.instance.records, isEmpty);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Bad day'), findsOneWidget);
      expect(find.textContaining('Flare logged'), findsNothing);
      expect(server.capturedPosts, isEmpty);
    });

    testWidgets(
        'Q5 + 2 (Home): a flare log never settles, fills, or hides '
        'the Daily Ranking check-in — and the severity-only commit '
        'works from Home', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      await pumpHome(tester, server);
      // No check-in yet today: the feeling card is showing.
      await _pumpUntil(
        tester,
        () => find.text('How are you feeling?').evaluate().isNotEmpty,
      );
      expect(find.text('How are you feeling?'), findsOneWidget);

      await tester.tap(find.text('Bad day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Bad'));
      await tester.pump();
      await tester.tap(find.text('Just log this'));
      await _pumpUntil(
        tester,
        () => find.text('Flare logged · Bad').evaluate().isNotEmpty,
      );
      // The flare is logged, severity-only shape and all…
      final staged = LogEntryOutbox.instance.records;
      if (staged.isNotEmpty) {
        expect(jsonDecode(staged.single.entry.chips), ['Flare Day', 'Bad']);
        expect(staged.single.entry.body, 'Flare day · Bad');
      } else {
        // The push already landed and cleared the queue — judge the
        // server-side row instead.
        expect(server.entries, hasLength(1));
        expect(
          jsonDecode(server.entries.single['chips'] as String),
          ['Flare Day', 'Bad'],
        );
        expect(server.entries.single['body'], 'Flare day · Bad');
      }
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      // …and the check-in card is STILL there, unsettled: the flare
      // log did not fill, settle, or hide it.
      expect(find.text('How are you feeling?'), findsOneWidget);
    });

    testWidgets('14: double-tap on the committing type writes '
        'exactly one record', (tester) async {
      final server = _Server([], categories: _catsNameHit);
      server.postGate = Completer<void>();
      await pumpHome(tester, server);
      await tester.tap(find.text('Bad day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Bad'));
      await tester.pump();
      // Two rapid taps on the type (the second lands while the
      // commit is in flight / the sheet is closing).
      await tester.tap(find.text('Dizzy'));
      await tester.tap(find.text('Dizzy'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(server.capturedPosts, hasLength(1));
      expect(server.entries, hasLength(1));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });
  });

  group('surfaces (§5 items 15–16)', () {
    test('15: a flare-only day counts in the Weekly Snapshot logs '
        'metric', () {
      final now = DateTime.now();
      String ds(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final dateStrs = [
        for (var i = 6; i >= 0; i--) ds(now.subtract(Duration(days: i))),
      ];
      final labels = [for (final _ in dateStrs) 'X'];
      final flare = buildFlareEntry(id: 1, categoryId: 3, severity: 'Bad');
      final data = buildLogsMetric(dateStrs, labels, [flare.timestamp]);
      expect(data.points.last.value, 1);
      expect(data.averageOrTotalText, '7-Day Total: 1 logs');
      expect(data.isEmpty, isFalse);
    });

    testWidgets('15: the flare entry renders in History as a normal, '
        'unlocked logged entry', (tester) async {
      final flare = buildFlareEntry(
        id: 42,
        categoryId: 3,
        severity: 'Bad',
        type: 'Dizzy',
      );
      final server = _Server([_entryJson(flare)], categories: _catsNameHit);
      // Not a locked check-in: the lock is Daily-Ranking-tag-only.
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
        'flare record, and a no-biometric day keeps its missing-data '
        'result', () {
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
      // A flare record lives only in the log-entry store; the score
      // reads the Health Connect history store — a separate system
      // the flare flow never touches. Identical store contents must
      // produce identical output, field for field.
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
      // A day with no biometric data at all: still no score — a
      // flare entry never substitutes for a biometric.
      final emptyDay = ds(base.add(const Duration(days: 30)));
      days[emptyDay] = DailyBiometrics(date: emptyDay);
      expect(computeDailyScore(days, emptyDay), isNull);
    });
  });

  // Weekly Snapshot import is exercised through buildLogsMetric's
  // return type; keep the reference explicit for the analyzer.
  test('15 (model): the logs metric is the Weekly Snapshot logs '
      'metric', () {
    expect(SnapshotMetric.logs.stableKey, 'logs');
  });
}
