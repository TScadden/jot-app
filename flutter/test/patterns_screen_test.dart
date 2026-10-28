import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/features/home/patterns_screen.dart';

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

Future<void> pumpPatterns(
  WidgetTester tester,
  List<InsightRecord> records, {
  bool isUnlimited = true,
  VoidCallback? computeCallback,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PatternsScreen(
      records: records,
      isUnlimited: isUnlimited,
      computeCallback: computeCallback,
    ),
  ));
  await tester.pump();
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
          'This pattern needs salt and fluid logging, which is not in Tabs yet.'),
      findsOneWidget,
    );
    expect(
      find.text(
          'This pattern needs your medication change history. There are no recorded medication changes in Tabs yet.'),
      findsOneWidget,
    );
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
    await pumpPatterns(tester, const []);
    expect(find.text('Patterns in your records'), findsWidgets);
    expect(find.text(correlationIntro), findsOneWidget);
    expect(find.text(correlationSurfaceDisclaimer), findsOneWidget);
    // Zero-count progress cards + the F2 unavailable form.
    expect(find.textContaining('0 nights under 6 hours of sleep'),
        findsOneWidget);
    expect(
      find.text(
          'This pattern needs salt and fluid logging, which is not in Tabs yet.'),
      findsOneWidget,
    );
    final texts = allRenderedTexts(tester).join('\n');
    expect(texts.contains('averaged'), isFalse);
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
          'This pattern needs salt and fluid logging, which is not in Tabs yet.');
      expect(
        correlationUnavailableF5,
        'This pattern needs your medication change history. There are no recorded medication changes in Tabs yet.',
      );
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
