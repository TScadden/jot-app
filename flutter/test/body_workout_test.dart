import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/body_figure_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/workout_table.dart';
import 'package:tabs_lab/src/features/tools/body_info_screen.dart';
import 'package:tabs_lab/src/features/tools/body_workout.dart';

import 'test_helpers.dart';

/// Body revamp + workout layer (Nov 20, 2026): the on-device parser
/// against the SHIPPED table asset, the zone derivation, the
/// founder-ruled figure default, and a screen smoke test.

/// Drags the screen's ListView up until [finder] matches (lazy
/// list children below the fold are not built until scrolled to).
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 6 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
}

WorkoutTable shippedTable() {
  final raw = File('assets/body/workout_table.json').readAsStringSync();
  return WorkoutTable.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

void main() {
  group('WorkoutTable.parse (shipped table)', () {
    final table = shippedTable();

    test('"leg workout 3 sets" resolves to legs at 3-set intensity', () {
      final p = table.parse('leg workout 3 sets');
      expect(p.matched, isTrue);
      expect(p.label, 'Legs');
      expect(p.sets, 3);
      expect(p.intensity, 1.0);
      expect(
        p.primaryZones,
        containsAll(<String>[
          'quad_l',
          'quad_r',
          'hamstring_l',
          'hamstring_r',
          'calf_l',
          'calf_r',
          'glutes',
        ]),
      );
    });

    test('region words: chest, back, arms, shoulders, core, full body', () {
      expect(table.parse('chest day').primaryZones, contains('chest'));
      expect(
        table.parse('back workout').primaryZones,
        containsAll(<String>['back', 'traps']),
      );
      expect(
        table.parse('arms').primaryZones,
        containsAll(<String>['bicep_l', 'tricep_r', 'forearm_l']),
      );
      expect(
        table.parse('shoulder day').primaryZones,
        containsAll(<String>['shoulder_l', 'shoulder_r']),
      );
      expect(table.parse('core').primaryZones, contains('core'));
      final full = table.parse('full body workout');
      expect(full.label, 'Full Body');
      expect(
        full.primaryZones,
        containsAll(<String>['chest', 'quad_l', 'core', 'back']),
      );
    });

    test('gym shorthand: push, pull, upper, lower', () {
      final push = table.parse('push day');
      expect(push.label, 'Push');
      expect(
        push.primaryZones,
        containsAll(<String>['chest', 'tricep_l', 'shoulder_r']),
      );
      final pull = table.parse('pull workout');
      expect(pull.label, 'Pull');
      expect(pull.primaryZones, containsAll(<String>['back', 'bicep_l']));
      expect(pull.secondaryZones, contains('forearm_l'));
      final upper = table.parse('upper body');
      expect(upper.primaryZones, containsAll(<String>['chest', 'back']));
      expect(upper.secondaryZones, contains('core'));
      final lower = table.parse('lower body');
      expect(lower.primaryZones, containsAll(<String>['quad_l', 'glutes']));
    });

    test('named exercises: primary strong, secondary mild', () {
      final bench = table.parse('bench press');
      expect(bench.label, 'Bench Press');
      expect(bench.primaryZones, contains('chest'));
      expect(
        bench.secondaryZones,
        containsAll(<String>['tricep_l', 'shoulder_r']),
      );
      expect(bench.secondaryZones, isNot(contains('chest')));

      final squats = table.parse('squats');
      expect(
        squats.primaryZones,
        containsAll(<String>['quad_l', 'quad_r', 'glutes']),
      );
      expect(squats.secondaryZones, contains('hamstring_l'));

      final deadlift = table.parse('deadlift');
      expect(
        deadlift.primaryZones,
        containsAll(<String>['back', 'hamstring_l', 'glutes']),
      );

      final curls = table.parse('bicep curls');
      expect(curls.primaryZones, containsAll(<String>['bicep_l', 'bicep_r']));
      expect(curls.secondaryZones, contains('forearm_l'));
    });

    test('span containment: "leg raises" is core, not legs', () {
      final p = table.parse('leg raises');
      expect(p.primaryZones, contains('core'));
      expect(p.primaryZones, isNot(contains('quad_l')));
    });

    test('span containment: "push ups" beats the "push" shorthand', () {
      final p = table.parse('push ups');
      expect(p.label, 'Push Ups');
      expect(p.primaryZones, contains('chest'));
      expect(p.secondaryZones, contains('core'));
    });

    test('sets extraction: "3 sets", "4x12", bare minutes, hours', () {
      expect(table.parse('squats 3 sets').sets, 3);
      expect(table.parse('bench 4x12').sets, 4);
      expect(table.parse('bench 4x12').intensity, 1.15);
      final run = table.parse('30 min run');
      expect(run.minutes, 30);
      expect(run.primaryZones, contains('quad_l'));
      expect(table.parse('cycling 1.5 h').minutes, 90);
      expect(table.parse('leg workout 5 sets').intensity, 1.3);
      expect(table.parse('leg workout 1 set').intensity, 0.7);
    });

    test('effort words scale intensity', () {
      expect(table.parse('light leg workout').intensity, 0.65);
      expect(table.parse('easy yoga').intensity, 0.65);
      expect(table.parse('heavy squats').intensity, 1.35);
      expect(table.parse('hard run 30 min').intensity, greaterThan(1.2));
    });

    test('unmatched text yields zero zones — never guessed', () {
      for (final text in [
        'ate pizza and watched a movie',
        'felt great today',
        'took a nap',
        '',
      ]) {
        final p = table.parse(text);
        expect(p.matched, isFalse, reason: text);
        expect(p.primaryZones, isEmpty, reason: text);
        expect(p.secondaryZones, isEmpty, reason: text);
        expect(p.label, isNull, reason: text);
      }
    });
  });

  group('evaluateBodyWorkouts', () {
    final table = shippedTable();
    final now = DateTime.now().millisecondsSinceEpoch;
    QuickLogEntry entry({
      required int id,
      required String body,
      String chips = '',
      required int ageHours,
    }) => QuickLogEntry(
      id: id,
      categoryId: 1,
      body: body,
      chips: chips,
      manualText: '',
      timestamp: now - ageHours * 60 * 60 * 1000,
    );

    test('only Workout-chip entries light zones', () {
      final plain = entry(id: 1, body: 'leg workout 3 sets', ageHours: 1);
      final state = evaluateBodyWorkouts([plain], table, now);
      expect(state.zones, isEmpty);
      expect(state.recentEntries, isEmpty);
    });

    test('a fresh 3-set leg workout lights the leg zones strongly', () {
      final e = entry(
        id: 1,
        body: 'leg workout 3 sets',
        chips: 'Workout',
        ageHours: 1,
      );
      final state = evaluateBodyWorkouts([e], table, now);
      expect(state.zones['quad_l']?.alpha, greaterThan(0.5));
      expect(state.zones['quad_l']?.primary, isTrue);
      expect(state.recentEntries, hasLength(1));
      expect(state.recentEntries.single.parsed.detailLabel, '3 sets');
    });

    test('secondary zones light weaker than primary zones', () {
      final e = entry(
        id: 1,
        body: 'bench press',
        chips: 'Workout',
        ageHours: 0,
      );
      final state = evaluateBodyWorkouts([e], table, now);
      expect(
        state.zones['chest']!.alpha,
        greaterThan(state.zones['tricep_l']!.alpha),
      );
    });

    test('fade: default session is gone by 49h; 5 sets lasts past 60h', () {
      final standard = entry(
        id: 1,
        body: 'leg workout 3 sets',
        chips: 'Workout',
        ageHours: 49,
      );
      expect(evaluateBodyWorkouts([standard], table, now).zones, isEmpty);
      final big = entry(
        id: 2,
        body: 'leg workout 5 sets',
        chips: 'Workout',
        ageHours: 60,
      );
      final state = evaluateBodyWorkouts([big], table, now);
      expect(state.zones['quad_l'], isNotNull);
    });

    test('a Workout-chip entry with unmatched text lights nothing', () {
      final e = entry(
        id: 1,
        body: 'felt great today',
        chips: 'Workout',
        ageHours: 1,
      );
      final state = evaluateBodyWorkouts([e], table, now);
      expect(state.zones, isEmpty);
      expect(state.recentEntries, isEmpty);
    });

    test('symptom text on a non-workout entry never lights workout zones', () {
      final e = entry(id: 1, body: 'my leg is sore', ageHours: 1);
      expect(evaluateBodyWorkouts([e], table, now).zones, isEmpty);
    });
  });

  group('figure resolution (founder ruling, Nov 20, 2026)', () {
    test('unknown gender defaults to the MAN figure', () {
      expect(
        resolveBodyFigure(override: null, profileGender: null),
        BodyFigureVariant.male,
      );
      expect(
        resolveBodyFigure(override: null, profileGender: ''),
        BodyFigureVariant.male,
      );
      expect(
        resolveBodyFigure(override: null, profileGender: 'prefer not to say'),
        BodyFigureVariant.male,
      );
    });

    test('known gender gives the matching figure', () {
      expect(
        resolveBodyFigure(override: null, profileGender: 'Female'),
        BodyFigureVariant.female,
      );
      expect(
        resolveBodyFigure(override: null, profileGender: 'woman'),
        BodyFigureVariant.female,
      );
      expect(
        resolveBodyFigure(override: null, profileGender: 'f'),
        BodyFigureVariant.female,
      );
      expect(
        resolveBodyFigure(override: null, profileGender: 'Male'),
        BodyFigureVariant.male,
      );
      expect(
        resolveBodyFigure(override: null, profileGender: 'man'),
        BodyFigureVariant.male,
      );
    });

    test('"female" resolves female, never male (contains trap)', () {
      expect(figureVariantFromGender('female'), BodyFigureVariant.female);
    });

    test('the manual switch overrides everything', () {
      expect(
        resolveBodyFigure(
          override: BodyFigureVariant.female,
          profileGender: 'male',
        ),
        BodyFigureVariant.female,
      );
      expect(
        resolveBodyFigure(
          override: BodyFigureVariant.male,
          profileGender: 'female',
        ),
        BodyFigureVariant.male,
      );
    });

    test('store round-trips the override; junk reads as no override', () async {
      String? saved;
      final store = BodyFigureStore(
        read: (_) async => saved,
        write: (_, v) async => saved = v,
      );
      expect(await store.loadOverride(), isNull);
      await store.saveOverride(BodyFigureVariant.female);
      expect(await store.loadOverride(), BodyFigureVariant.female);
      saved = 'junk';
      expect(await store.loadOverride(), isNull);
    });
  });

  group('BodyInfoScreen workout layer (smoke)', () {
    setUp(TabsBackend.debugResetSharedCaches);

    TabsBackend backendWithPull(Map<String, dynamic> pull) {
      final store = FakeSessionStore()..token = 'tok';
      return TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/ai/body-impacts') {
            return http.Response('{"result":{"impacts":[]}}', 200);
          }
          return http.Response(jsonEncode(pull), 200);
        }),
        sessionStore: store,
      );
    }

    testWidgets('workout row renders and figure card is present', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pull = <String, dynamic>{
        'profile': {'conditions': '[]', 'gender': 'female'},
        'entries': [
          {
            'id': 5,
            'categoryId': 1,
            'body': 'leg workout 3 sets',
            'chips': 'Workout',
            'manualText': '',
            'timestamp': now - 60 * 60 * 1000,
          },
        ],
        'categories': [
          {'id': 3, 'name': 'Exercise', 'isDefault': false},
          {'id': 1, 'name': 'Notes', 'isDefault': true},
        ],
      };
      await tester.pumpWidget(
        MaterialApp(home: BodyInfoScreen(backend: backendWithPull(pull))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Body Impact Visualizer'), findsOneWidget);
      expect(find.text('Worked'), findsOneWidget);
      await scrollTo(tester, find.text('Log a Workout'));
      await scrollTo(tester, find.text('Legs — Workout'));
      // The workout row must not trigger the empty state.
      expect(find.text('All Body Zones Normal'), findsNothing);
    });

    testWidgets('chip tap logs a Workout entry via the entries upsert', (
      tester,
    ) async {
      final posted = <Map<String, dynamic>>[];
      final store = FakeSessionStore()..token = 'tok';
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/sync/entries' &&
              request.method == 'POST') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final list = body['entries'] as List;
            posted.addAll(list.cast<Map<String, dynamic>>());
            return http.Response('{"ok":true}', 200);
          }
          if (request.url.path == '/api/ai/body-impacts') {
            return http.Response('{"result":{"impacts":[]}}', 200);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'profile': {'conditions': '[]'},
              'entries': const [],
              'categories': [
                {'id': 3, 'name': 'Exercise', 'isDefault': false},
                {'id': 1, 'name': 'Notes', 'isDefault': true},
              ],
            }),
            200,
          );
        }),
        sessionStore: store,
      );
      await tester.pumpWidget(
        MaterialApp(home: BodyInfoScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Legs'));
      await tester.tap(find.text('Legs'));
      await tester.pumpAndSettle();
      expect(posted, hasLength(1));
      expect(posted.single['body'], 'Legs workout');
      expect(posted.single['chips'], 'Workout');
      expect(posted.single['categoryId'], 3);
      expect(find.text('Workout logged — zones are lit.'), findsOneWidget);
      await scrollTo(tester, find.text('Legs — Workout'));
    });

    testWidgets(
      'persisted figure override beats a slower profile load (race)',
      (tester) async {
        // Stored override: female. Profile gender: male. Storage is
        // local and resolves first; the network pull is delayed —
        // the override must still be the figure after the load
        // lands (founder ruling: override > profile > man).
        const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'read') return 'female';
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final store = FakeSessionStore()..token = 'tok';
        final backend = TabsBackend(
          client: MockClient((request) async {
            await Future<void>.delayed(const Duration(seconds: 1));
            if (request.url.path == '/api/ai/body-impacts') {
              return http.Response('{"result":{"impacts":[]}}', 200);
            }
            return http.Response(
              jsonEncode(<String, dynamic>{
                'profile': {'conditions': '[]', 'gender': 'male'},
                'entries': const [],
                'categories': const [],
              }),
              200,
            );
          }),
          sessionStore: store,
        );
        await tester.pumpWidget(
          MaterialApp(home: BodyInfoScreen(backend: backend)),
        );
        await tester.pumpAndSettle();
        Finder baseImage(String name) => find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName == 'assets/body/$name',
        );
        expect(baseImage('female_front_base.png'), findsOneWidget);
        expect(baseImage('male_front_base.png'), findsNothing);
      },
    );

    testWidgets('chip tap with a failed sync pull aborts with no POST', (
      tester,
    ) async {
      var posts = 0;
      final store = FakeSessionStore()..token = 'tok';
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/sync/entries' &&
              request.method == 'POST') {
            posts++;
            return http.Response('{"ok":true}', 200);
          }
          // Every pull fails: the write path must abort visibly
          // BEFORE any id math or POST (the settled entry-write
          // invariant from the Daily Summary race package).
          return http.Response('server error', 500);
        }),
        sessionStore: store,
      );
      await tester.pumpWidget(
        MaterialApp(home: BodyInfoScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Legs'));
      await tester.tap(find.text('Legs'));
      await tester.pumpAndSettle();
      expect(posts, 0);
      await scrollTo(
        tester,
        find.text('Could not sync — check your connection and try again.'),
      );
    });
  });
}
