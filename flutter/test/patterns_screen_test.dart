import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_insight_store.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/features/home/patterns_screen.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Phase 1 item 5 — Patterns surface tests (spec §8).
///
/// Fixtures are hand-built [InsightRecord]s; expected strings are
/// pinned BOTH through correlation_copy.dart and as Juno's verbatim
/// literals, so a paraphrase in either the copy file or the
/// surface fails here.

InsightGroup grp(String label, int n, {double? mean, double? median}) =>
    InsightGroup(label: label, n: n, mean: mean, median: median);

InsightRecord rec({
  required String familyId,
  required String splitId,
  required InsightState state,
  List<InsightGroup> groups = const [],
  List<InsightComponentOutcome> componentOutcomes = const [],
  IncidenceResult? incidence,
  CoOccurrence? coOccurrence,
  String? headerLabel,
  String? subjectName,
  String throughDate = '2026-10-20',
}) =>
    InsightRecord(
      familyId: familyId,
      splitId: splitId,
      windowKey: 'last90',
      state: state,
      groups: groups,
      componentOutcomes: componentOutcomes,
      incidence: incidence,
      coOccurrence: coOccurrence,
      headerLabel: headerLabel,
      subjectName: subjectName,
      computedAtMs: 0,
      throughDate: throughDate,
      inputFingerprint: 'fixture',
    );

InsightRecord f1aNumbers() => rec(
      familyId: 'F1',
      splitId: 'F1a',
      state: InsightState.numbers,
      groups: [
        grp('nights under 6 hours of sleep', 7, mean: 71.4, median: 70),
        grp('nights with 6 or more hours of sleep', 9,
            mean: 80.2, median: 81),
      ],
    );

/// H2-01 harness: [records] may be omitted (null) in favor of
/// [recordsLoader]/[insightStore], and [isUnlimited] may be
/// OMITTED in the tri-state sense — pass `isUnlimited: null`
/// explicitly to exercise the production unknown-gate path
/// (cache seed / own resolution). Omitting the argument keeps
/// the historical explicit-true default the older tests rely on,
/// hence the Object? sentinel: an explicit null is a real value
/// here, not a default. QuickLogCache seeding/reset for the
/// omitted-gate tests goes through its debugReset/applyLoad
/// seams (see the failure-states group below).
Future<void> pumpPatterns(
  WidgetTester tester,
  List<InsightRecord>? records, {
  Object? isUnlimited = true,
  VoidCallback? computeCallback,
  Future<List<InsightRecord>> Function()? recordsLoader,
  Object? insightStore,
  Future<bool?> Function()? membershipLoader,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PatternsScreen(
      records: records,
      recordsLoader: recordsLoader,
      insightStore: insightStore,
      isUnlimited: isUnlimited as bool?,
      membershipLoader: membershipLoader,
      computeCallback: computeCallback,
    ),
  ));
  await tester.pump();
}

/// Duck-typed insight-store fake whose readAll returns a Map
/// (the store's real shape) — triage test (6), first half.
class FakeMapInsightStore {
  Future<Map<String, InsightRecord>> readAll() async =>
      {'F1/F1a': f1aNumbers()};
}

/// Duck-typed insight-store fake whose every read throws —
/// triage test (6), second half.
class FakeThrowingInsightStore {
  Future<dynamic> readAll() async => throw StateError('read failed');
  Future<dynamic> load() async => throw StateError('load failed');
  Future<dynamic> getAll() async => throw StateError('getAll failed');
}

List<String> allRenderedTexts(WidgetTester tester) => [
      for (final w in tester.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ];

void main() {
  testWidgets('S2 sentence is byte-exact for F1a; S3 + S8 + lag line render',
      (tester) async {
    await pumpPatterns(tester, [f1aNumbers()]);
    expect(
      find.text(
          'On nights under 6 hours of sleep (7 days), your Daily Score averaged 71. On nights with 6 or more hours of sleep (9 days), it averaged 80.'),
      findsOneWidget,
    );
    expect(find.text(correlationLagHeader), findsOneWidget);
    expect(find.text('Your score the next day'), findsOneWidget);
    expect(find.text(correlationCaption), findsOneWidget);
    expect(find.text('Last 90 days · through 2026-10-20'), findsOneWidget);
  });

  testWidgets('S3 present on every numbers card', (tester) async {
    await pumpPatterns(tester, [
      f1aNumbers(),
      rec(
        familyId: 'F4',
        splitId: 'F4',
        state: InsightState.numbers,
        groups: [
          grp('days you rated 1 or 2', 6, mean: 66, median: 65),
          grp('days you rated 4 or 5', 10, mean: 78, median: 79),
        ],
      ),
    ]);
    expect(find.text(correlationCaption), findsNWidgets(2));
  });

  testWidgets('detail expansion shows median lines per group',
      (tester) async {
    await pumpPatterns(tester, [f1aNumbers()]);
    expect(find.text('Middle score: 70'), findsNothing);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.text('Middle score: 70'), findsOneWidget);
    expect(find.text('Middle score: 81'), findsOneWidget);
  });

  testWidgets(
      'Vera condition 1: numbers-state component outcomes are NOT '
      'rendered (no Juno-ruled component label exists)', (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F1',
        splitId: 'F1a',
        state: InsightState.numbers,
        groups: [
          grp('nights under 6 hours of sleep', 7, mean: 71.4, median: 70),
          grp('nights with 6 or more hours of sleep', 9,
              mean: 80.2, median: 81),
        ],
        componentOutcomes: [
          InsightComponentOutcome(
            outcomeId: 'scoreSleep',
            state: InsightState.numbers,
            groups: [
              grp('nights under 6 hours of sleep', 7,
                  mean: 55.3, median: 54),
              grp('nights with 6 or more hours of sleep', 9,
                  mean: 91.6, median: 92),
            ],
          ),
        ],
      ),
    ]);
    const primarySentence =
        'On nights under 6 hours of sleep (7 days), your Daily Score averaged 71. On nights with 6 or more hours of sleep (9 days), it averaged 80.';
    expect(find.text(primarySentence), findsOneWidget);
    // Expand the detail section: the primary S2 sentence must still
    // appear exactly once, and no component average or median may
    // appear anywhere in the rendered tree.
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.text(primarySentence), findsOneWidget);
    expect(find.textContaining('averaged'), findsOneWidget);
    final texts = allRenderedTexts(tester).join('\n');
    expect(texts.contains('averaged 55'), isFalse,
        reason: 'component mean A rendered as a Daily Score average');
    expect(texts.contains('averaged 92'), isFalse,
        reason: 'component mean B rendered as a Daily Score average');
    expect(texts.contains('Middle score: 54'), isFalse,
        reason: 'component median A rendered');
    expect(texts.contains('Middle score: 92'), isFalse,
        reason: 'component median B rendered');
    // The primary groups' own medians still render in the expansion.
    expect(find.text('Middle score: 70'), findsOneWidget);
    expect(find.text('Middle score: 81'), findsOneWidget);
  });

  testWidgets(
      'Vera condition 2: S3 caption renders on every card — numbers, '
      'progress, and unavailable', (tester) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPatterns(tester, [
      f1aNumbers(),
      rec(
        familyId: 'F4',
        splitId: 'F4',
        state: InsightState.progress,
        groups: [
          grp('days you rated 1 or 2', 2),
          grp('days you rated 4 or 5', 3),
        ],
      ),
      rec(familyId: 'F2', splitId: '', state: InsightState.unavailable),
    ]);
    expect(find.text(correlationCaption), findsNWidgets(3));
  });

  testWidgets('S6 progress card contains NO average text', (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F1',
        splitId: 'F1a',
        state: InsightState.progress,
        groups: [
          grp('nights under 6 hours of sleep', 3, mean: 63.7, median: 61),
          grp('nights with 6 or more hours of sleep', 4,
              mean: 88.2, median: 87),
        ],
      ),
    ]);
    expect(
      find.text(
          'Not enough days yet. This pattern needs at least 5 days in each group, and 14 days in total. So far: 3 nights under 6 hours of sleep, 4 nights with 6 or more hours of sleep — 7 days in total.'),
      findsOneWidget,
    );
    final texts = allRenderedTexts(tester).join('\n');
    expect(texts.contains('64'), isFalse, reason: 'rounded mean A leaked');
    expect(texts.contains('88'), isFalse, reason: 'rounded mean B leaked');
    expect(texts.contains('averaged'), isFalse);
  });

  testWidgets('S7 forms are byte-exact (F2 and F5 unavailable)',
      (tester) async {
    await pumpPatterns(tester, [
      rec(familyId: 'F2', splitId: '', state: InsightState.unavailable),
      rec(familyId: 'F5', splitId: '', state: InsightState.unavailable),
    ]);
    expect(
      find.text(
          'This pattern needs salt and fluid logging. There is no recorded salt and fluid intake in Tabs yet.'),
      findsOneWidget,
    );
    expect(
      find.text(
          'This pattern needs your medication change history. There are no recorded medication changes in Tabs yet.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'six computed F2 unavailable records collapse to ONE card at the '
      'F2 position (Juno Nov 8 2026, composition (b) points 1-3)',
      (tester) async {
    // Tall viewport: every card must be built by the ListView for
    // the position assertions to be measurable.
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPatterns(tester, [
      rec(
        familyId: 'F3',
        splitId: 'F3',
        state: InsightState.progress,
        groups: [
          grp('days you logged a flare', 0),
          grp('days with no flare logged', 89),
        ],
      ),
      for (final split in [
        'sodium-migraine',
        'fluid-score',
        'sodium-flare',
        'fluid-migraine',
        'sodium-score',
        'fluid-flare',
      ])
        rec(familyId: 'F2', splitId: split, state: InsightState.unavailable),
      rec(
        familyId: 'F1',
        splitId: 'F1a',
        state: InsightState.progress,
        groups: [
          grp('nights under 6 hours of sleep', 3),
          grp('nights with 6 or more hours of sleep', 4),
        ],
      ),
    ]);
    // The S7 sentence renders exactly once for the whole family,
    // and exactly three cards render in total (one S3 caption per
    // card): F1 progress, the collapsed F2 card, F3 progress.
    expect(
      find.text(
          'This pattern needs salt and fluid logging. There is no recorded salt and fluid intake in Tabs yet.'),
      findsOneWidget,
    );
    expect(find.text(correlationCaption), findsNWidgets(3));
    // The collapsed card carries NO split header (Juno (b) point 3:
    // neither header alone heads a card standing for the family).
    expect(find.text('Fluid target'), findsNothing);
    expect(find.text('Sodium target'), findsNothing);
    // The withdrawn Oct 28 F2 form renders nowhere.
    final texts = allRenderedTexts(tester).join('\n');
    expect(texts.contains('which is not in Tabs yet'), isFalse);
    // The collapsed card occupies the F2 family's fixed position:
    // after the F1 card, before the F3 card (Juno (b) point 3 /
    // R1 fixed order).
    double dyOf(String needle) =>
        tester.getTopLeft(find.textContaining(needle).first).dy;
    final f1Dy = dyOf('nights under 6 hours of sleep');
    final f2Dy = dyOf('There is no recorded salt and fluid intake');
    final f3Dy = dyOf('days you logged a flare');
    expect(f2Dy, greaterThan(f1Dy));
    expect(f3Dy, greaterThan(f2Dy));
  });

  testWidgets(
      'F2 progress cards carry exactly their own split header '
      '(Juno Nov 8 2026, composition (b) point 2)', (tester) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    InsightRecord f2Progress(String split, int a, int b) => rec(
          familyId: 'F2',
          splitId: split,
          state: InsightState.progress,
          groups: [
            grp('days your logged intake reached your target', a),
            grp('days your logged intake was below your target', b),
          ],
        );
    await pumpPatterns(tester, [
      rec(
        familyId: 'F1',
        splitId: 'F1a',
        state: InsightState.progress,
        groups: [
          grp('nights under 6 hours of sleep', 3),
          grp('nights with 6 or more hours of sleep', 4),
        ],
      ),
      f2Progress('fluid-score', 1, 2),
      f2Progress('sodium-score', 1, 3),
      f2Progress('fluid-flare', 2, 2),
      f2Progress('sodium-flare', 2, 3),
      f2Progress('fluid-migraine', 3, 2),
      f2Progress('sodium-migraine', 3, 3),
    ]);
    // Three fluid cards, three sodium cards; the F1 progress card
    // carries neither header (headers are F2-only).
    expect(find.text('Fluid target'), findsNWidgets(3));
    expect(find.text('Sodium target'), findsNWidgets(3));
    // Headers interleave in fixed engine order (fluid split before
    // sodium split within each outcome kind), each heading its own
    // card — a swapped header would break the sequence.
    double headerDy(String text, int i) =>
        tester.getTopLeft(find.text(text).at(i)).dy;
    final sequence = [
      headerDy('Fluid target', 0),
      headerDy('Sodium target', 0),
      headerDy('Fluid target', 1),
      headerDy('Sodium target', 1),
      headerDy('Fluid target', 2),
      headerDy('Sodium target', 2),
    ];
    for (var i = 1; i < sequence.length; i++) {
      expect(sequence[i], greaterThan(sequence[i - 1]),
          reason: 'split headers out of order: $sequence');
    }
    // The first header stands below the F1 card's sentence: no
    // header was added to the non-F2 card above it.
    final f1Dy = tester
        .getTopLeft(find.textContaining('nights under 6 hours of sleep').first)
        .dy;
    expect(sequence.first, greaterThan(f1Dy));
  });

  testWidgets('disclaimer renders exactly once, title + intro present',
      (tester) async {
    await pumpPatterns(tester, [f1aNumbers()]);
    expect(
      find.text(
          'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition.'),
      findsOneWidget,
    );
    expect(find.text('Patterns in your records'), findsWidgets);
    expect(find.text(correlationIntro), findsOneWidget);
  });

  testWidgets('fixed order: scrambled input renders F1→F5 engine order',
      (tester) async {
    // Tall viewport: all eleven cards must be built by the
    // ListView for their positions to be measurable.
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    InsightRecord progress(String family, String split, String tag) => rec(
          familyId: family,
          splitId: split,
          state: InsightState.progress,
          groups: [grp('label-$tag-a', 1), grp('label-$tag-b', 2)],
        );
    final scrambled = [
      progress('F4', 'F4', 'f4'),
      progress('F2', 'sodium-migraine', 'f2sm'),
      progress('F1', 'F1b', 'f1b'),
      progress('F5', '', 'f5x'),
      progress('F2', 'fluid-score', 'f2fs'),
      progress('F3', 'F3', 'f3'),
      progress('F2', 'sodium-flare', 'f2sf'),
      progress('F1', 'F1a', 'f1a'),
      progress('F2', 'fluid-migraine', 'f2fm'),
      progress('F2', 'sodium-score', 'f2ss'),
      progress('F2', 'fluid-flare', 'f2ff'),
    ];
    await pumpPatterns(tester, scrambled);
    double dyOf(String needle) =>
        tester.getTopLeft(find.textContaining(needle).first).dy;
    // F5's S6 uses its pinned labels, not the fixture labels.
    final order = <double>[
      dyOf('label-f1a-a'),
      dyOf('label-f1b-a'),
      dyOf('label-f2fs-a'),
      dyOf('label-f2ss-a'),
      dyOf('label-f2ff-a'),
      dyOf('label-f2sf-a'),
      dyOf('label-f2fm-a'),
      dyOf('label-f2sm-a'),
      dyOf('label-f3-a'),
      dyOf('label-f4-a'),
      dyOf('scored days before the change'),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i], greaterThan(order[i - 1]),
          reason: 'card $i rendered out of fixed order: $order');
    }
  });

  testWidgets('F5 numbers card: Draft 4 rows + Draft 5 note, no S8',
      (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F5',
        splitId: '',
        state: InsightState.numbers,
        headerLabel: 'Started Example',
        groups: [
          grp('before', 10, mean: 70.4, median: 69),
          grp('after', 11, mean: 75.3, median: 76),
        ],
      ),
    ]);
    expect(find.text('Started Example'), findsOneWidget);
    expect(find.text('Average Daily Score, 14 days before'), findsOneWidget);
    expect(find.text('70 · 10 scored days'), findsOneWidget);
    expect(find.text('Average Daily Score, 14 days after'), findsOneWidget);
    expect(find.text('75 · 11 scored days'), findsOneWidget);
    expect(
      find.text(
          'The day of the change counts in the "after" window for starts and dose changes, and in the "before" window for stops.'),
      findsOneWidget,
    );
    expect(find.textContaining('Last 90 days'), findsNothing);
    expect(find.text(correlationCaption), findsOneWidget);
  });

  testWidgets('F5 header falls back to subjectName', (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F5',
        splitId: '',
        state: InsightState.numbers,
        subjectName: 'Example Med',
        groups: [grp('before', 8, mean: 60), grp('after', 9, mean: 62)],
      ),
    ]);
    expect(find.text('Example Med'), findsOneWidget);
  });

  testWidgets(
      'F2 incidence card: S4 flare byte-exact, split header, no % anywhere',
      (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F2',
        splitId: 'fluid-flare',
        state: InsightState.numbers,
        groups: [grp('hit', 8), grp('missed', 9)],
        incidence: const IncidenceResult(x: 3, n: 8, y: 5, m: 9),
      ),
    ]);
    expect(find.text('Fluid target'), findsOneWidget);
    expect(
      find.text(
          'A flare was logged on 3 of the 8 days after days your logged intake reached your target, and on 5 of the 9 days after days your logged intake was below your target.'),
      findsOneWidget,
    );
    expect(find.text(correlationCaption), findsOneWidget);
    expect(find.text('Last 90 days · through 2026-10-20'), findsOneWidget);
    for (final text in allRenderedTexts(tester)) {
      expect(text.contains('%'), isFalse, reason: '% in rendered: $text');
    }
  });

  testWidgets('F3 numbers card renders S5 co-occurrence line',
      (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F3',
        splitId: 'F3',
        state: InsightState.numbers,
        groups: [
          grp('days with a flare logged', 6, mean: 62, median: 60),
          grp('days without a flare logged', 12, mean: 77, median: 78),
        ],
        coOccurrence: const CoOccurrence(
          confounderLabel: 'sleep',
          groupADays: 'flare',
          groupBDays: 'no-flare',
          valueA: 352,
          valueB: 390,
        ),
      ),
    ]);
    expect(
      find.text(
          'On the flare days, sleep also averaged 5h52m, compared with 6h30m on the no-flare days.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'gating (spec test 9, surface half): not unlimited omits numbers, keeps progress',
      (tester) async {
    await pumpPatterns(
      tester,
      [
        f1aNumbers(),
        rec(
          familyId: 'F4',
          splitId: 'F4',
          state: InsightState.progress,
          groups: [grp('days you rated 1 or 2', 2), grp('days you rated 4 or 5', 3)],
        ),
      ],
      isUnlimited: false,
    );
    final texts = allRenderedTexts(tester).join('\n');
    expect(texts.contains('averaged 71'), isFalse);
    expect(texts.contains('averaged 80'), isFalse);
    expect(find.textContaining('Not enough days yet.'), findsOneWidget);
    // No locked/teaser copy: nothing beyond the ruled strings.
    expect(find.textContaining('Unlock'), findsNothing);
    expect(find.textContaining('Premium'), findsNothing);
  });

  testWidgets('A7 surface half: stale record renders ORIGINAL throughDate',
      (tester) async {
    await pumpPatterns(tester, [
      rec(
        familyId: 'F4',
        splitId: 'F4',
        state: InsightState.numbers,
        throughDate: '2026-09-01',
        groups: [
          grp('days you rated 1 or 2', 6, mean: 66),
          grp('days you rated 4 or 5', 10, mean: 78),
        ],
      ),
    ]);
    expect(find.text('Last 90 days · through 2026-09-01'), findsOneWidget);
  });

  testWidgets('no compute on open: counting callback stays at zero',
      (tester) async {
    var computeCalls = 0;
    await pumpPatterns(
      tester,
      [f1aNumbers()],
      computeCallback: () => computeCalls++,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(computeCalls, 0);
  });

  testWidgets('empty store renders the global new-user progress state',
      (tester) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPatterns(tester, const []);
    expect(find.text('Patterns in your records'), findsWidgets);
    expect(find.text(correlationIntro), findsOneWidget);
    expect(find.text(correlationSurfaceDisclaimer), findsOneWidget);
    // Zero-count progress cards + the F2 unavailable form.
    expect(find.textContaining('0 nights under 6 hours of sleep'),
        findsOneWidget);
    expect(
      find.text(
          'This pattern needs salt and fluid logging. There is no recorded salt and fluid intake in Tabs yet.'),
      findsOneWidget,
    );
    final texts = allRenderedTexts(tester).join('\n');
    expect(texts.contains('averaged'), isFalse);
  });

  group('failure states (H1-08 / H1-05P / H2-01 triage)', () {
    setUp(() => QuickLogCache.instance.debugReset());
    tearDown(() => QuickLogCache.instance.debugReset());

    InsightRecord f4Progress() => rec(
          familyId: 'F4',
          splitId: 'F4',
          state: InsightState.progress,
          groups: [
            grp('days you rated 1 or 2', 2),
            grp('days you rated 4 or 5', 3),
          ],
        );

    testWidgets(
        '(1) omitted gate + cold cache + numbers via recordsLoader: '
        'pending state with label once, numbers not presented as final; '
        'resolution removes the label in the same update',
        (tester) async {
      final resolution = Completer<bool?>();
      await pumpPatterns(
        tester,
        null,
        isUnlimited: null,
        recordsLoader: () async => [f1aNumbers(), f4Progress()],
        membershipLoader: () => resolution.future,
      );
      // Pending: label exactly once, with a skeleton; numbers
      // held; progress renders normally.
      expect(find.text(correlationMembershipPendingLabel), findsOneWidget);
      expect(find.text('Checking your membership status.'), findsOneWidget);
      expect(find.byType(SkeletonBox), findsWidgets);
      expect(find.textContaining('averaged 71'), findsNothing);
      expect(find.textContaining('Not enough days yet.'), findsOneWidget);
      // Resolve as member: label gone, numbers render.
      resolution.complete(true);
      await tester.pump();
      expect(find.text(correlationMembershipPendingLabel), findsNothing);
      expect(
        find.text(
            'On nights under 6 hours of sleep (7 days), your Daily Score averaged 71. On nights with 6 or more hours of sleep (9 days), it averaged 80.'),
        findsOneWidget,
      );
    });

    testWidgets(
        '(2) omitted gate + cache seeded premium: numbers render, '
        'no pending label', (tester) async {
      QuickLogCache.instance.applyLoad(
        categories: const [],
        recentSuggestions: const [],
        todayCount: 0,
        isUnlimited: true,
        isAdmin: false,
      );
      await pumpPatterns(tester, [f1aNumbers()], isUnlimited: null);
      expect(
        find.text(
            'On nights under 6 hours of sleep (7 days), your Daily Score averaged 71. On nights with 6 or more hours of sleep (9 days), it averaged 80.'),
        findsOneWidget,
      );
      expect(find.text(correlationMembershipPendingLabel), findsNothing);
    });

    testWidgets(
        '(3) omitted gate + cache seeded known non-premium: numbers '
        'omitted, no pending label, no replacement copy', (tester) async {
      QuickLogCache.instance.applyLoad(
        categories: const [],
        recentSuggestions: const [],
        todayCount: 0,
        isUnlimited: false,
        isAdmin: false,
      );
      await pumpPatterns(
        tester,
        [f1aNumbers(), f4Progress()],
        isUnlimited: null,
      );
      expect(find.textContaining('averaged'), findsNothing);
      expect(find.text(correlationMembershipPendingLabel), findsNothing);
      expect(find.textContaining('Not enough days yet.'), findsOneWidget);
      expect(find.textContaining('Premium'), findsNothing);
      expect(find.textContaining('Unlock'), findsNothing);
    });

    testWidgets(
        '(4) recordsLoader throws: Slot 1 error state; placeholder '
        'output and the S7 sentence do NOT render; Try again re-runs '
        'the load and recovers', (tester) async {
      var loadCalls = 0;
      await pumpPatterns(
        tester,
        null,
        recordsLoader: () async {
          loadCalls++;
          if (loadCalls == 1) throw StateError('disk gone');
          return [f1aNumbers()];
        },
      );
      expect(find.text(correlationLoadError), findsOneWidget);
      expect(
        find.text('Could not load your Patterns. Please try again.'),
        findsOneWidget,
      );
      expect(find.text(correlationLoadRetryLabel), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      // No cards at all: every card carries the S3 caption.
      expect(find.text(correlationCaption), findsNothing);
      expect(find.text(correlationUnavailableF2), findsNothing);
      expect(find.textContaining('0 nights under 6 hours of sleep'),
          findsNothing);
      // Retry re-runs the load; success renders the records.
      await tester.tap(find.text(correlationLoadRetryLabel));
      await tester.pump();
      expect(loadCalls, 2);
      expect(find.text(correlationLoadError), findsNothing);
      expect(find.textContaining('averaged 71'), findsOneWidget);
    });

    testWidgets(
        '(5) recordsLoader returns []: placeholder new-user state '
        'renders; an empty result never routes to the error string',
        (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpPatterns(tester, null, recordsLoader: () async => const []);
      expect(find.textContaining('0 nights under 6 hours of sleep'),
          findsOneWidget);
      expect(find.text(correlationUnavailableF2), findsOneWidget);
      expect(find.text(correlationLoadError), findsNothing);
    });

    testWidgets(
        '(6a) insightStore fake readAll returns a Map: records render',
        (tester) async {
      await pumpPatterns(tester, null, insightStore: FakeMapInsightStore());
      expect(find.textContaining('averaged 71'), findsOneWidget);
      expect(find.text(correlationLoadError), findsNothing);
    });

    testWidgets(
        '(6b) insightStore whose readAll/load/getAll all throw: '
        'Slot 1 error state, not placeholder', (tester) async {
      await pumpPatterns(tester, null,
          insightStore: FakeThrowingInsightStore());
      expect(find.text(correlationLoadError), findsOneWidget);
      expect(find.text(correlationLoadRetryLabel), findsOneWidget);
      expect(find.text(correlationCaption), findsNothing);
      expect(find.text(correlationUnavailableF2), findsNothing);
    });

    testWidgets(
        '(7) integration: real CorrelationInsightStore over a corrupt '
        'blob drives the production-shaped screen to the error state, '
        'not the new-user state', (tester) async {
      final store = CorrelationInsightStore.testInstance();
      store.debugSetStore(
        read: (key) async => 'this is not json {{{',
        write: (key, value) async {},
        delete: (key) async {},
      );
      await pumpPatterns(tester, null, insightStore: store);
      expect(find.text(correlationLoadError), findsOneWidget);
      expect(find.text(correlationLoadRetryLabel), findsOneWidget);
      expect(find.text(correlationCaption), findsNothing);
      expect(find.text(correlationUnavailableF2), findsNothing);
      expect(find.textContaining('0 nights under 6 hours of sleep'),
          findsNothing);
    });

    testWidgets(
        '(8) membership-resolution failure (Juno signed follow-up): '
        'Slot 1 error with ZERO cards, NO pending label, NO skeleton; '
        'Try again re-runs BOTH load and resolution, the pending '
        'label may reappear for the fresh check, and both succeeding '
        'recovers to the numbers state', (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var loadCalls = 0;
      var resolveCalls = 0;
      Completer<bool?>? secondResolution;
      await pumpPatterns(
        tester,
        null,
        isUnlimited: null,
        recordsLoader: () async {
          loadCalls++;
          return [
            f1aNumbers(),
            f4Progress(),
            rec(familyId: 'F2', splitId: '', state: InsightState.unavailable),
          ];
        },
        membershipLoader: () {
          resolveCalls++;
          if (resolveCalls == 1) return Future<bool?>.value(null);
          secondResolution = Completer<bool?>();
          return secondResolution!.future;
        },
      );
      await tester.pump();
      // Condition 1+2: Slot 1 verbatim, replacing the card list
      // ENTIRELY — no numbers, no progress, no unavailable, no
      // skeleton (zero S3 captions = zero cards).
      expect(find.text(correlationLoadError), findsOneWidget);
      expect(find.text(correlationLoadRetryLabel), findsOneWidget);
      expect(find.text(correlationCaption), findsNothing);
      expect(find.textContaining('averaged'), findsNothing);
      expect(find.textContaining('Not enough days yet.'), findsNothing);
      expect(find.text(correlationUnavailableF2), findsNothing);
      expect(find.byType(SkeletonBox), findsNothing);
      // Condition 3: the pending label is NOT in/above/alongside
      // the error state.
      expect(find.text(correlationMembershipPendingLabel), findsNothing);
      // Condition 4: retry re-runs both.
      await tester.tap(find.text(correlationLoadRetryLabel));
      await tester.pump();
      expect(loadCalls, 2);
      expect(resolveCalls, 2);
      // The fresh in-flight check is a new pending state: the
      // label may reappear now, and the error is gone.
      expect(find.text(correlationLoadError), findsNothing);
      expect(find.text(correlationMembershipPendingLabel), findsOneWidget);
      // Both succeed → numbers render, label gone.
      secondResolution!.complete(true);
      await tester.pump();
      expect(find.text(correlationMembershipPendingLabel), findsNothing);
      expect(find.textContaining('averaged 71'), findsOneWidget);
      expect(find.textContaining('Not enough days yet.'), findsOneWidget);
    });

    testWidgets(
        '(9) membership resolution timeout counts as failure '
        '(Juno follow-up condition 5): no unbounded pending',
        (tester) async {
      await pumpPatterns(
        tester,
        null,
        isUnlimited: null,
        recordsLoader: () async => [f1aNumbers(), f4Progress()],
        membershipLoader: () => Completer<bool?>().future,
      );
      expect(find.text(correlationMembershipPendingLabel), findsOneWidget);
      // Advance past the screen's 20s resolve bound.
      await tester.pump(const Duration(seconds: 21));
      expect(find.text(correlationMembershipPendingLabel), findsNothing);
      expect(find.text(correlationLoadError), findsOneWidget);
      expect(find.text(correlationLoadRetryLabel), findsOneWidget);
      expect(find.text(correlationCaption), findsNothing);
      expect(find.byType(SkeletonBox), findsNothing);
    });
  });

  group('A6 copy-lint', () {
    // Juno U1: the eight banned patterns, as lint stems.
    const bannedStems = <String>[
      'lowers your score',
      'improves your',
      'was higher because',
      'strongest pattern',
      'strongest',
      'weakest',
      'expect a lower score',
      'try getting more sleep',
      'is working',
      'is not working',
      'failed to hit your target',
    ];

    List<String> allowlistedStrings() => [
          correlationTitle,
          correlationIntro,
          correlationCaption,
          correlationSurfaceDisclaimer,
          correlationLagHeader,
          correlationFluidHeader,
          correlationSodiumHeader,
          correlationUnavailableF2,
          correlationUnavailableF5,
          medWindowBeforeLabel,
          medWindowAfterLabel,
          medWindowRuleNote,
          correlationComparisonSentence(groupALabel: 'group a', groupAN: 5, groupAMean: 70, groupBLabel: 'group b', groupBN: 6, groupBMean: 80),
          correlationMedianLine(70),
          correlationFlareIncidenceSentence(x: 1, n: 5, y: 2, m: 6),
          correlationMigraineIncidenceSentence(x: 1, n: 5, y: 2, m: 6),
          correlationCoOccurrenceSentence(groupADays: 'flare', confounderLabel: 'sleep', valueA: '5h52m', groupBDays: 'no-flare', valueB: '6h30m'),
          correlationProgressSentence(groupALabel: 'group a', groupAN: 1, groupBLabel: 'group b', groupBN: 2),
          correlationWindowLine('2026-10-20'),
        ];

    test('copy constants equal Juno verbatim finals', () {
      expect(correlationTitle, 'Patterns in your records');
      expect(
        correlationIntro,
        'Tabs groups your logged days and averages your Daily Scores for each group. A pattern in your records, not a cause. Other things differed between these days too.',
      );
      expect(
        correlationCaption,
        'A pattern in your records, not a cause. Other things differed between these days too.',
      );
      expect(
        correlationSurfaceDisclaimer,
        'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition.',
      );
      expect(correlationLagHeader, 'Your score the next day');
      expect(correlationFluidHeader, 'Fluid target');
      expect(correlationSodiumHeader, 'Sodium target');
      expect(correlationUnavailableF2,
          'This pattern needs salt and fluid logging. There is no recorded salt and fluid intake in Tabs yet.');
      expect(
        correlationUnavailableF5,
        'This pattern needs your medication change history. There are no recorded medication changes in Tabs yet.',
      );
      expect(correlationLoadError,
          'Could not load your Patterns. Please try again.');
      expect(correlationLoadRetryLabel, 'Try again');
      expect(correlationMembershipPendingLabel,
          'Checking your membership status.');
      expect(correlationStaticStrings, contains(correlationLoadError));
      expect(
          correlationStaticStrings, contains(correlationLoadRetryLabel));
      expect(correlationStaticStrings,
          contains(correlationMembershipPendingLabel));
      expect(medWindowBeforeLabel,
          'Average Daily Score, 14 days before');
      expect(
          medWindowAfterLabel, 'Average Daily Score, 14 days after');
      expect(
        medWindowRuleNote,
        'The day of the change counts in the "after" window for starts and dose changes, and in the "before" window for stops.',
      );
    });

    test('no allowlisted string matches a blocklist pattern; no %', () {
      for (final s in allowlistedStrings()) {
        final lower = s.toLowerCase();
        for (final stem in bannedStems) {
          expect(lower.contains(stem), isFalse,
              reason: 'blocklisted "$stem" in: $s');
        }
        expect(s.contains('%'), isFalse, reason: '% in: $s');
      }
      // The copy file also exposes its blocklist for the lint:
      // every pinned pattern must be present there so the lint
      // set and Juno's U1 set cannot drift apart silently.
      expect(correlationCopyBlocklist, isNotEmpty);
    });

    testWidgets('rendered S2 carries exactly the two means, no delta',
        (tester) async {
      await pumpPatterns(tester, [f1aNumbers()]);
      final s2 = allRenderedTexts(tester)
          .firstWhere((t) => t.startsWith('On nights under 6 hours'));
      // The sentence's derived numbers are exactly the two ns
      // (in the parentheticals) and the two means (after
      // "averaged") — no third derived number such as a delta.
      // (The group labels themselves contain a "6" — hours —
      // which is label text, not a derived number.)
      final ns = RegExp(r'\((\d+) days\)')
          .allMatches(s2)
          .map((m) => m.group(1)!)
          .toList();
      final means = RegExp(r'averaged (\d+)')
          .allMatches(s2)
          .map((m) => m.group(1)!)
          .toList();
      expect(ns, ['7', '9']);
      expect(means, ['71', '80']);
      expect(s2.contains('+'), isFalse);
      expect(RegExp(r'-\s*\d').hasMatch(s2), isFalse,
          reason: 'signed difference pattern in S2: $s2');
      expect(s2.contains('%'), isFalse);
    });

    testWidgets('no rendered string on the surface matches the blocklist',
        (tester) async {
      await pumpPatterns(tester, [
        f1aNumbers(),
        rec(
          familyId: 'F2',
          splitId: 'fluid-flare',
          state: InsightState.numbers,
          groups: [grp('hit', 8), grp('missed', 9)],
          incidence: const IncidenceResult(x: 3, n: 8, y: 5, m: 9),
        ),
        rec(
          familyId: 'F4',
          splitId: 'F4',
          state: InsightState.progress,
          groups: [grp('days you rated 1 or 2', 2), grp('days you rated 4 or 5', 3)],
        ),
      ]);
      for (final text in allRenderedTexts(tester)) {
        final lower = text.toLowerCase();
        for (final stem in bannedStems) {
          expect(lower.contains(stem), isFalse,
              reason: 'blocklisted "$stem" rendered: $text');
        }
        expect(text.contains('%'), isFalse, reason: '% rendered: $text');
      }
    });
  });
}
