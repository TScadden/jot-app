// Weekly Report v2 (A3) — the in-app mirror renderers against a
// fixture shaped like the Nov 16–22, 2026 computedMetrics object
// (SPEC §7 expected values): score 45, headline "Harder week than
// his usual.", headache days 2, ivabradine dose with NO frequency
// string anywhere outside the Ruling 8.3 confirmation question.
//
// Every expected string is byte-exact per JUNO-RULINGS-V2.md
// (incl. the P3 addendum: day-count normal "[x.x] days (30-day
// avg, per week)"; BP n=1 normal "[s]/[d] mmHg (single reading,
// Nov 12)").
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/weekly_report_v2.dart';

Map<String, dynamic> _cell(Object? value, int n, String display,
        {String? statistic, int? windowDays}) =>
    {
      'value': value,
      'n': n,
      'display': display,
      'statistic': ?statistic,
      'windowDays': ?windowDays,
    };

const _rowLabels = {
  'dailyScore': 'Daily Score (avg)',
  'flareDays': 'Flare days',
  'headacheDays': 'Headache days',
  'restingHr': 'Resting heart rate',
  'hrv': 'HRV (RMSSD)',
  'sleepVsNeed': 'Sleep vs his need',
  'minutesOver100': 'Minutes over 100 bpm (avg per day)',
  'minutesOver120': 'Minutes over 120 bpm (avg per day)',
  'peakHr': 'Peak heart rate (weekly high)',
  'bloodPressure': 'Blood pressure',
};

/// Row in Mason's landed server shape (reportV2.js): carries the
/// row `label` and the `displayNormal` cell the His normal column
/// prints (for Daily Score that is the 89-day cell, while `normal`
/// keeps the 30-day value).
Map<String, dynamic> _row(
        String key,
        Map<String, dynamic> tw,
        Map<String, dynamic> lw,
        Map<String, dynamic> normal,
        String trend,
        {Map<String, dynamic>? normalLong,
        Map<String, dynamic>? displayNormal}) =>
    {
      'key': key,
      'label': _rowLabels[key],
      'thisWeek': tw,
      'lastWeek': lw,
      'normal': normal,
      'displayNormal': displayNormal ?? normal,
      'normalLong': ?normalLong,
      'trend': trend,
      'trendPrimary': trend,
      'trendSecondary': trend,
    };

/// Mason's sleep cell shape: value is the pct, with the SL-1
/// minute figures as cell-level extras.
Map<String, dynamic> _sleepCell(
        int sleepMinutes, int needMinutes, int pct, String display) =>
    {
      'value': pct,
      'n': 7,
      'display': display,
      'sleepMinutes': sleepMinutes,
      'needMinutes': needMinutes,
      'pct': pct,
      'statistic': 'pctOfNeed',
    };

/// The fixture object, SPEC §1.3 shape, SPEC §7 values.
Map<String, dynamic> fixtureComputedMetrics() => {
      'range': {'start': '2026-11-16', 'end': '2026-11-22', 'days': 7},
      'windows': {
        'lastWeek': {'start': '2026-11-09', 'end': '2026-11-15'},
        'normal': {'start': '2026-10-17', 'end': '2026-11-15', 'days': 30},
        'long': {'start': '2026-08-19', 'end': '2026-11-15', 'days': 89},
      },
      'scorecard': [
        _row('dailyScore', _cell(45, 7, '45'), _cell(66, 7, '66'),
            _cell(62, 30, '62'), 'Worse',
            normalLong: _cell(58, 89, '58 (89-day avg)',
                statistic: 'mean', windowDays: 89),
            displayNormal: _cell(58, 89, '58 (89-day avg)',
                statistic: 'mean', windowDays: 89)),
        _row('flareDays', _cell(4, 7, '4 days'), _cell(1, 7, '1 day'),
            _cell(1.2, 5, '1.2 days (30-day avg, per week)'), 'Worse'),
        _row('headacheDays', _cell(2, 7, '2 days'), _cell(1, 7, '1 day'),
            _cell(0.7, 3, '0.7 days (30-day avg, per week)'), 'Worse'),
        _row('restingHr', _cell(65, 7, '65 bpm'), _cell(60, 7, '60 bpm'),
            _cell(61, 30, '61 bpm'), 'Worse'),
        _row('hrv', _cell(43, 7, '43 ms'), _cell(61, 7, '61 ms'),
            _cell(57, 30, '57 ms'), 'Worse'),
        _row(
            'sleepVsNeed',
            _sleepCell(461, 656, 70, '7h41m (70% of his need)'),
            _sleepCell(480, 650, 74, '8h00m (74% of his need)'),
            {
              'value': 656,
              'n': 7,
              'display': '10h56m (his Sleep Need)',
              'statistic': 'pctOfNeed',
              'needMinutes': 656,
            },
            'Worse'),
        _row('minutesOver100', _cell(106, 7, '106 min'),
            _cell(90, 7, '90 min'),
            _cell(99, 23, '99 min (30-day avg, 23 days of data)'), 'Worse'),
        _row('minutesOver120', _cell(30, 7, '30 min'),
            _cell(32, 7, '32 min'),
            _cell(31, 23, '31 min (30-day avg, 23 days of data)'), 'Same'),
        _row('peakHr', _cell(179, 7, '179 bpm'), _cell(163, 7, '163 bpm'),
            _cell(199, 30, '199 bpm (30-day high, Nov 5)'), 'Mixed'),
        _row(
            'bloodPressure',
            _cell(null, 0, '—'),
            _cell({'systolic': 110, 'diastolic': 80}, 1, '110/80 mmHg'),
            _cell({'systolic': 110, 'diastolic': 80}, 1,
                '110/80 mmHg (single reading, Nov 12)'),
            'No data'),
      ],
      'tally': {
        'worse': 7,
        'better': 0,
        'same': 1,
        'mixed': 1,
        'noData': 1,
        'total': 10,
        'noDataRowLabels': ['blood pressure'],
      },
      'headlineKey': 2,
      'notableCandidates': {
        'worstScoreDay': {'date': '2026-11-17', 'score': 35},
        'highestPeakDay': {'date': '2026-11-17', 'peakHr': 179},
        'longestOver100Day': {'date': '2026-11-17', 'minutesOver100': 294},
        'bestDay': {'date': '2026-11-22', 'score': 55},
      },
      'notableDays': [
        {
          'date': '2026-11-17',
          'slots': ['worstScoreDay', 'highestPeakDay', 'longestOver100Day'],
          'facts': {
            'score': 35,
            'minutesOver100': 294,
            'minutesOver120': 72,
            'peakHr': 179,
            'hrv': 37,
            'rhr': 66,
            'palpitationsText': 'strong palpitations',
          },
        },
        {
          'date': '2026-11-22',
          'slots': ['bestDay'],
          'facts': {'score': 55},
        },
      ],
      'medChanges': {
        'inWindow': <dynamic>[],
        'latestPriorNamed': {
          'drugKey': 'name:desvenlafaxine',
          'drugName': 'Desvenlafaxine',
          'kind': 'doseChange',
          'fromDose': '50mg',
          'toDose': '100mg',
          'fromFrequency': '',
          'toFrequency': '',
          'changeDate': '2026-11-11',
          'dateSource': 'effectiveDate',
          'paired': true,
          'phrasing': 'Desvenlafaxine: dose increased, 50 mg → 100 mg',
        },
        'latestPrior': [
          {
            'drugKey': 'name:desvenlafaxine',
            'drugName': 'Desvenlafaxine',
            'kind': 'doseChange',
            'fromDose': '50mg',
            'toDose': '100mg',
            'fromFrequency': '',
            'toFrequency': '',
            'changeDate': '2026-11-11',
            'dateSource': 'effectiveDate',
            'paired': true,
            'phrasing': 'Desvenlafaxine: dose increased, 50 mg → 100 mg',
          },
          {
            'drugKey': 'mots-c',
            'drugName': 'MOTS-c',
            'kind': 'start',
            'fromDose': '',
            'toDose': '10 mg',
            'fromFrequency': '',
            'toFrequency': '',
            'changeDate': '2026-11-11',
          },
        ],
        'currentMedications': [
          {
            'name': 'Ivabradine',
            'dose': '7.5mg',
            'frequency': '',
            'startDate': '2026-01-01',
            'endDate': '',
            'isPresent': true,
          },
          {
            'name': 'Desvenlafaxine',
            'dose': '100 mg',
            'frequency': 'once daily',
            'startDate': '2026-11-11',
            'endDate': '',
            'isPresent': true,
          },
          {
            'name': 'MOTS-c',
            'dose': '10 mg',
            'frequency': '',
            'startDate': '2026-11-11',
            'endDate': '',
            'isPresent': true,
          },
        ],
      },
      'grid': [
        for (var d = 16; d <= 22; d++)
          {
            'date': '2026-11-$d',
            'score': {'state': 'value', 'value': d == 17 ? 35 : 45},
            'flare': {
              'state': 'value',
              'value': [16, 18, 21, 22].contains(d),
            },
            'headache': {
              'state': 'value',
              'value': [18, 22].contains(d),
            },
            'palpitations': {'state': 'value', 'value': d == 17},
            'feeling': {'state': 'value', 'value': 3},
            'spikeCount': {'state': 'value', 'value': 4},
            'minutesOver100': {
              'state': d == 16 ? 'noSource' : 'value',
              'value': d == 17 ? 294 : 100,
            },
            'peakHr': {'state': 'value', 'value': d == 17 ? 179 : 150},
            'pt': {'state': 'value', 'value': d == 18},
            'coldExposure': {'state': 'noneLogged', 'value': null},
          },
      ],
      'questionAnchors': [
        {
          'kind': 'extremeDay',
          'scorecardKey': 'minutesOver100',
          'date': '2026-11-17',
          'values': {
            'symptom': 'strong palpitations',
            'minutesOver100': '294',
            'peakHr': '179',
          },
        },
        {
          'kind': 'medChangeDelta',
          'scorecardKey': 'dailyScore',
          'date': '2026-11-11',
          'values': {
            'drugName': 'Desvenlafaxine',
            'direction': 'increased',
            'fromDose': '50 mg',
            'toDose': '100 mg',
            'changeDate': '2026-11-11',
            'rangeLabel': 'November 16–22, 2026',
            'metricLabel': 'Daily Score',
            'value': '45',
            'normal': '58',
          },
        },
        {
          'kind': 'motsCStatus',
          'scorecardKey': null,
          'date': null,
          'values': {'itemName': 'MOTS-c', 'dose': '10 mg'},
        },
        {
          'kind': 'blankFrequency',
          'scorecardKey': null,
          'date': null,
          'values': {
            'drugName': 'ivabradine',
            'dose': '7.5 mg',
            'candidateFrequency': 'twice daily',
          },
        },
        {
          'kind': 'sleepVsNeed',
          'scorecardKey': 'sleepVsNeed',
          'date': null,
          'values': {
            'duration': '7h41m',
            'pct': '70',
            'need': '10h56m',
            'shortfall': '3h15m',
          },
        },
      ],
      'charts': {
        'series': {
          'dailyScore': [
            {'date': '2026-11-16', 'value': 40},
            {'date': '2026-11-17', 'value': 35},
            {'date': '2026-11-18', 'value': 35},
            {'date': '2026-11-19', 'value': 48},
            {'date': '2026-11-20', 'value': 50},
            {'date': '2026-11-21', 'value': 52},
            {'date': '2026-11-22', 'value': 55},
          ],
        },
        'normalRef': {'dailyScore': 58},
        'medMarkers': [
          {
            'date': '2026-11-11',
            'label': 'Nov 11: Desvenlafaxine dose 50 mg → 100 mg',
          },
        ],
        'medMarkerLabels': [
          {
            'date': '2026-11-11',
            'label': 'Nov 11: Desvenlafaxine dose 50 mg → 100 mg + MOTS-c started',
          },
        ],
      },
      'correlations': {'text': null, 'lines': <dynamic>[], 'lineCount': 0},
      'nextAppointment': {
        'name': 'Brad Richards',
        'credential': 'PA-C',
        'dateLabel': 'December 7, 2026',
      },
    };

void main() {
  final metrics = ComputedMetrics.tryParse(
      jsonDecode(jsonEncode(fixtureComputedMetrics())))!;
  final text = buildWeeklyReportV2Text(metrics);
  final sections = weeklyV2MirrorSections(metrics);
  WeeklyV2Section section(String title) =>
      sections.firstWhere((s) => s.title == title);

  group('parser (SPEC §1.3)', () {
    test('parses the fixture object; absent object parses to null', () {
      expect(metrics.rangeStart, '2026-11-16');
      expect(metrics.scorecard.length, 10);
      expect(metrics.headlineKey, 2);
      expect(ComputedMetrics.tryParse(null), isNull);
      expect(ComputedMetrics.tryParse('nope'), isNull);
    });

    test('title is the Ruling 16.1 snapshot form', () {
      expect(metrics.snapshotTitle, 'Tyson · Weekly snapshot, Nov 16–22, 2026');
    });
  });

  group('Verdict (Rulings 1, 4)', () {
    test('headline is the fixture headline', () {
      expect(metrics.headline, 'Harder week than his usual.');
      expect(section('Verdict').lines.first, 'Harder week than his usual.');
    });

    test('tally sentence accounts for all 10 measures', () {
      expect(
        metrics.tallySentence,
        'Of the 10 measures on the scorecard, 7 are worse, '
        '1 are the same, 1 are mixed, and 1 has no data this week '
        '(blood pressure).',
      );
      // The tally sentence is the verdict block's last sentence
      // before the disclaimer.
      final lines = section('Verdict').lines;
      expect(lines[lines.length - 2], metrics.tallySentence);
      expect(lines.last, weeklyV2Disclaimer);
    });

    test('supporting passage cites scorecard displays only', () {
      final p = metrics.supportingPassage;
      expect(p, contains('His Daily Score averaged 45, against his normal of 58 (89-day avg).'));
      expect(p, contains('He logged 4 flare days.'));
      expect(p, contains('He logged 2 headache days.'));
      for (final banned in [
        'because', 'due to', 'caused', 'led to', 'resulted in',
        'triggered', 'thanks to', 'after starting', 'since starting',
      ]) {
        expect(p.toLowerCase(), isNot(contains(banned)),
            reason: 'banned causal word: $banned');
      }
    });
  });

  group('Scorecard (Rulings 2, 15, P3)', () {
    test('headers and all 10 rows render with server displays', () {
      final lines = section('Scorecard').lines;
      expect(lines.first, 'Metric | This week | Last week | His normal | Trend');
      expect(lines.length, 1 + 10 + 1);
      expect(lines[1],
          'Daily Score (avg) (Better when: higher) | 45 | 66 | 58 (89-day avg) | Worse');
      expect(lines[2],
          'Flare days (Better when: fewer) | 4 days | 1 day | 1.2 days (30-day avg, per week) | Worse');
      expect(lines[3],
          'Headache days (Better when: fewer) | 2 days | 1 day | 0.7 days (30-day avg, per week) | Worse');
      expect(lines[6],
          'Sleep vs his need (Better when: higher (% of his need)) | 7h41m (70% of his need) | 8h00m (74% of his need) | 10h56m (his Sleep Need) | Worse');
      expect(lines[9],
          'Peak heart rate (weekly high) (Better when: lower) | 179 bpm | 163 bpm | 199 bpm (30-day high, Nov 5) | Mixed');
      expect(lines[10],
          'Blood pressure (Better when: lower (both numbers)) | — | 110/80 mmHg | 110/80 mmHg (single reading, Nov 12) | No data');
      expect(lines.last, weeklyV2NormalNote);
    });

    test('P3(a) day-count normal form: one decimal, days plural always', () {
      expect(formatDayCountNormalCell(1.1666), '1.2 days (30-day avg, per week)');
      expect(formatDayCountNormalCell(1.0), '1.0 days (30-day avg, per week)');
      expect(formatDayCountNormalCell(0), '0.0 days (30-day avg, per week)');
    });

    test('P3(b) BP normal form: n=1 single-reading, n>=2 plain, n=0 dash', () {
      expect(
          formatBpNormalCell(
              systolic: 110,
              diastolic: 80,
              readingCount: 1,
              singleReadingShortDate: 'Nov 12'),
          '110/80 mmHg (single reading, Nov 12)');
      expect(
          formatBpNormalCell(systolic: 110, diastolic: 80, readingCount: 3),
          '110/80 mmHg');
      expect(
          formatBpNormalCell(systolic: null, diastolic: null, readingCount: 0),
          '—');
    });
  });

  group('What changed (Ruling 6)', () {
    test('no-changes row + most-recent line + appointment line', () {
      final lines = section('What changed this week').lines;
      expect(lines[0], 'Date | Change | Status');
      expect(lines[1], '— | No medication changes this week. | —');
      expect(
          lines[2],
          'Most recent change before this week: Desvenlafaxine: dose '
          'increased, 50 mg → 100 mg, November 11, 2026.');
      expect(lines[3], 'Next appointment: Brad Richards, PA-C, December 7, 2026.');
      // The paired dose change never reads as a stop.
      expect(text, isNot(contains('Desvenlafaxine: stopped')));
      expect(text, isNot(contains('Stopped Desvenlafaxine')));
    });

    test('MC-5 precedence picks the dose change over the start', () {
      final picked = selectLatestPriorChange(metrics.medChangesLatestPrior);
      expect(picked?.drugName, 'Desvenlafaxine');
      expect(medChangePhrase(picked!),
          'Desvenlafaxine: dose increased, 50 mg → 100 mg');
    });
  });

  group('Notable days (Ruling 13.3)', () {
    test('Nov 17 line is the verified fixture line', () {
      expect(
        section('Notable days').lines.first,
        'Nov 17 — score 35; 294 min over 100 bpm; 72 min over 120 bpm; '
        'peak HR 179 bpm; HRV 37 ms; resting HR 66 bpm; '
        'strong palpitations logged.',
      );
      expect(section('Notable days').lines.length, 2);
    });
  });

  group('Questions for Brad (Rulings 8, 9.3)', () {
    test('title, framing line, and the byte-exact ivabradine question', () {
      final lines = section('Questions for Brad').lines;
      expect(lines.first, 'For Brad Richards, PA-C.');
      expect(lines.length, 1 + 5);
      expect(
        lines[4],
        '4. Can you confirm how often Tyson should take ivabradine '
        '7.5 mg? His medication record lists the dose with no '
        'frequency. Is it twice daily?',
      );
      expect(
        lines[1],
        '1. On November 17, 2026, Tyson logged strong palpitations '
        'and his heart rate was over 100 bpm for 294 minutes, with '
        'a peak of 179 bpm. Should an ECG or any other check be '
        'done for an event like that?',
      );
      expect(
        lines[5],
        '5. Tyson averaged 7h41m of sleep this week, 70% of his '
        'Sleep Need of 10h56m — 3h15m short per night on average. '
        'Is there anything you would change or check about his sleep?',
      );
    });

    test('guard strings: no Dr. Brad, no prescribed peptides, '
        'ivabradine frequency only inside its question', () {
      expect(text, isNot(contains('Dr. Brad')));
      expect(text.toLowerCase(), isNot(contains('prescribed')));
      // "twice daily" occurs exactly once — inside the Ruling 8.3
      // confirmation question, as a question.
      expect('twice daily'.allMatches(text).length, 1);
      final questions = section('Questions for Brad').lines.join('\n');
      expect('twice daily'.allMatches(questions).length, 1);
      // The appendix med list prints ivabradine dose with NO
      // frequency segment.
      expect(text, contains('Ivabradine 7.5mg'));
      expect(text, isNot(contains('Ivabradine 7.5mg (')));
    });
  });

  group('Day by day grid (Ruling 13)', () {
    test('rows in ruled order; dash and n/a are distinct states', () {
      final lines = section('Day by day').lines;
      expect(lines.first,
          'Day | Nov 16 | Nov 17 | Nov 18 | Nov 19 | Nov 20 | Nov 21 | Nov 22');
      final flare = lines.firstWhere((l) => l.startsWith('Flare |'));
      expect(flare, 'Flare | Yes | — | Yes | — | — | Yes | Yes');
      final headache = lines.firstWhere((l) => l.startsWith('Headache |'));
      expect(headache, 'Headache | — | — | Yes | — | — | — | Yes');
      final minutes =
          lines.firstWhere((l) => l.startsWith('Minutes over 100 bpm |'));
      expect(minutes,
          'Minutes over 100 bpm | n/a | 294 | 100 | 100 | 100 | 100 | 100');
      final cold = lines.firstWhere((l) => l.startsWith('Cold exposure |'));
      expect(cold, 'Cold exposure | — | — | — | — | — | — | —');
      expect(lines.last, weeklyV2GridLegend);
      expect(lines.last, contains('It is not a rating of sleep.'));
    });
  });

  group('Appendix + charts lines (Rulings 7, 14)', () {
    test('med list header, marker label, his-usual legend', () {
      final appendix = weeklyV2AppendixSections(metrics);
      final charts = appendix.firstWhere((s) => s.title == 'Charts');
      expect(charts.lines, contains('His usual: 58'));
      expect(
          charts.lines,
          contains(
              'Nov 11: Desvenlafaxine dose 50 mg → 100 mg + MOTS-c started'));
      final app = appendix.firstWhere((s) => s.title == 'Appendix');
      expect(app.lines.first, 'Current Medications and Supplements');
      expect(app.lines, contains('Desvenlafaxine 100 mg (once daily)'));
      expect(app.lines, contains('MOTS-c 10 mg'));
    });
  });

  group('C4 dependency — PT/cold entry shapes (app review)', () {
    // Vera's C4 check: the server's PT/cold grid derivation
    // (reportV2.js) keys on (a) a chip exactly 'PT' or
    // 'Cold Exposure', or (b) body/manual text matching
    // 'physical therapy' / 'cold shower|plunge|exposure'.
    // App-side facts this review confirms from the app code:
    //  * There is NO dedicated PT or cold-exposure feature, preset
    //    or chip anywhere in the app (no 'PT', 'Physical Therapy'
    //    or 'Cold Exposure' string exists in lib/ outside this
    //    package's renderer). PT/cold are logged, when logged, as
    //    free-form Quick Log entries: a user-typed body and/or
    //    free-form chips.
    //  * The app writes an entry's chips as a JSON-encoded list
    //    string (QuickLogEntry.chips; flare_day_logging_test.dart
    //    pins jsonDecode(e.chips) == ['Flare Day', 'Rough', ...]).
    //    The app's own chip parser (parseCorrelationChips, the
    //    mirror of the server's parseChips) reads that shape — and
    //    the comma-joined / bare-list shapes — back to exact chip
    //    strings, so a user chip named PT or Cold Exposure reaches
    //    the server derivation as exactly 'PT' / 'Cold Exposure'.
    //  * Body text is free text: entries like 'cold shower' or
    //    'physical therapy' match the server's text patterns;
    //    a body like 'PT session' with no chip does NOT match
    //    either server pattern — that gap is inherent to the
    //    accepted deviation 5 and is flagged in the PR.
    test('app chip shapes parse to the exact server-checked strings', () {
      expect(parseCorrelationChips('["PT"]'), ['PT']);
      expect(parseCorrelationChips('["Cold Exposure"]'), ['Cold Exposure']);
      expect(parseCorrelationChips('["Flare Day", "PT"]'),
          ['Flare Day', 'PT']);
      expect(parseCorrelationChips('PT, Cold Exposure'),
          ['PT', 'Cold Exposure']);
    });

    test('realistic entry bodies the server text patterns key on', () {
      // The shapes as a user actually writes them in Quick Log
      // free text (Mason's server fixture uses body 'cold shower').
      final ptPattern = RegExp(r'\bphysical therapy\b', caseSensitive: false);
      final coldPattern =
          RegExp(r'\bcold (exposure|shower|plunge)\b', caseSensitive: false);
      expect(ptPattern.hasMatch('physical therapy at home'), isTrue);
      expect(coldPattern.hasMatch('cold shower'), isTrue);
      expect(coldPattern.hasMatch('Cold plunge this morning'), isTrue);
      // The known gap, pinned so it is a decision, not a surprise:
      expect(ptPattern.hasMatch('PT session'), isFalse);
      expect(coldPattern.hasMatch('PT session'), isFalse);
    });
  });

  group('pipeline + PDF parity (A1/A2)', () {
    test('snapshot carries the object through withComputedMetrics', () {
      const snap = ReportSnapshot(
        last30Days: false,
        generationTimestampMs: 0,
        logEntries: [],
        categoriesMap: {},
      );
      final enriched = snap.withComputedMetrics(metrics);
      expect(enriched.computedMetrics?.headline, 'Harder week than his usual.');
      expect(enriched.withSectionStatus('x', DataSourceStatus.success, 1)
          .computedMetrics, isNotNull);
    });

    test('buildReportPdfBytes renders the v2 layout', () async {
      const snap = ReportSnapshot(
        last30Days: false,
        generationTimestampMs: 0,
        logEntries: [],
        categoriesMap: {},
      );
      final bytes = await buildReportPdfBytes(
        snap.withComputedMetrics(metrics),
        aiSummary: 'legacy narrative that must not drive a v2 report',
        isRawFallback: false,
      );
      expect(bytes.length, greaterThan(1000));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
  });
}
