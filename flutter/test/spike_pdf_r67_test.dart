import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/spike_report_pdf.dart';
import 'package:tabs_lab/src/features/heart/heart_spike_review_screen.dart';

/// Round 67 — Spike Review PDF export tests.
///
/// The pure-logic tests pin native `PdfExporter.exportSpikesToPdf`'s
/// OWN detection (5-minute event window — deliberately different
/// from the review screen's 3-minute gap rule and the Heart card's
/// window count), its duration rule, and the summary's p10 rule.
/// Widget tests run the real screen against save/share seams.

int _ms(int hour, [int minute = 0, int second = 0]) =>
    DateTime(2026, 10, 16, hour, minute, second).millisecondsSinceEpoch;

HrSample _s(int hour, int bpm, [int minute = 0, int second = 0]) =>
    HrSample(timeMs: _ms(hour, minute, second), bpm: bpm);

void main() {
  group('detectSpikePdfEvents (native PdfExporter semantics)', () {
    test('samples within the 5-minute window merge into one event', () {
      // Spike samples at 9:00 and 9:04; a sample at exactly the
      // window end (last spike + 5 min = 9:09) does NOT start a new
      // event (native starts one only strictly AFTER the end).
      final events = detectSpikePdfEvents([
        _s(8, 70),
        _s(9, 120),
        _s(9, 130, 4),
        _s(9, 110, 9),
        _s(10, 65),
      ]);
      expect(events, hasLength(1));
      expect(events.single.peakBpm, 130);
      expect(events.single.startTimeMs, _ms(9));
      // Duration: last spike sample (9:09) - start (9:00) = 9 mins.
      expect(events.single.durationMins, 9);
    });

    test('a spike strictly after the window end starts a new event', () {
      final events = detectSpikePdfEvents([
        _s(9, 120),
        _s(9, 125, 4),
        // Window end is 9:09; 9:09:01 is strictly after -> new event.
        _s(9, 140, 9, 1),
      ]);
      expect(events, hasLength(2));
      expect(events[0].peakBpm, 125);
      expect(events[1].peakBpm, 140);
      // Single-sample event: duration clamps to 1 (native maxOf(1, 0)).
      expect(events[1].durationMins, 1);
    });

    test('below-threshold and zero samples never start events', () {
      final events = detectSpikePdfEvents([
        _s(8, 0),
        _s(9, 99),
        _s(10, 0),
        _s(11, 85),
      ]);
      expect(events, isEmpty);
    });

    test('unsorted input is sorted before detection', () {
      final events = detectSpikePdfEvents([
        _s(9, 130, 4),
        _s(9, 120),
      ]);
      expect(events, hasLength(1));
      expect(events.single.startTimeMs, _ms(9));
      expect(events.single.durationMins, 4);
    });
  });

  group('spikePdfSummary', () {
    test('peak, p10 baseline and delta follow the native rules', () {
      // 10 readings sorted: 50,55,60,65,70,75,80,85,90,150.
      // p10 index = (10 * 0.10).toInt() = 1 -> 55. Delta = 150 - 55.
      final samples = [
        _s(8, 50), _s(8, 55, 5), _s(8, 60, 10), _s(8, 65, 15),
        _s(8, 70, 20), _s(8, 75, 25), _s(8, 80, 30), _s(8, 85, 35),
        _s(8, 90, 40), _s(9, 150),
      ];
      final events = detectSpikePdfEvents(samples);
      final summary = spikePdfSummary(samples, events)!;
      expect(summary.peakBpm, 150);
      expect(summary.baselineP10, 55);
      expect(summary.deltaBpm, 95);
      expect(summary.totalEvents, 1);
    });

    test('zero readings are excluded from the summary (founder rule)',
        () {
      // Without the zero filter the sorted list would start with 0
      // and p10 would collapse; with it, p10 index lands on a real
      // reading.
      final samples = [_s(8, 0), _s(8, 60), _s(9, 140)];
      final summary =
          spikePdfSummary(samples, detectSpikePdfEvents(samples))!;
      expect(summary.baselineP10, 60);
      expect(summary.peakBpm, 140);
    });

    test('no valid readings -> null summary', () {
      expect(spikePdfSummary([_s(8, 0)], const []), isNull);
      expect(spikePdfSummary(const [], const []), isNull);
    });
  });

  group('pagination', () {
    SpikePdfEvent ev(int i) =>
        SpikePdfEvent(startTimeMs: i, peakBpm: 120, durationMins: 1);

    test('empty -> no pages', () {
      expect(paginateSpikePdfEvents(const []), isEmpty);
    });

    test('29 events fit on the first page', () {
      final pages =
          paginateSpikePdfEvents([for (var i = 0; i < 29; i++) ev(i)]);
      expect(pages, hasLength(1));
      expect(pages.single, hasLength(29));
    });

    test('30 events spill one onto a continuation page', () {
      final pages =
          paginateSpikePdfEvents([for (var i = 0; i < 30; i++) ev(i)]);
      expect(pages, hasLength(2));
      expect(pages[0], hasLength(29));
      expect(pages[1], hasLength(1));
    });
  });

  group('buildSpikeReportPdfBytes', () {
    test('produces a real PDF with the native title and summary',
        () async {
      final bytes = await buildSpikeReportPdfBytes(
        samples: [_s(8, 60), _s(9, 130), _s(9, 135, 2)],
        dateStr: '2026-10-16',
        exportedAt: DateTime(2026, 10, 16, 14, 5),
      );
      expect(bytes.length, greaterThan(1000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(spikePdfFileName('2026-10-16'),
          'Tabs 2026-10-16 HR spikes.pdf');
      expect(spikePdfStamp(DateTime(2026, 10, 16, 14, 5)),
          '2026-10-16 14:05');
    });

    test('a 35-event day builds a two-page PDF without throwing',
        () async {
      // 35 isolated spikes, one per hour across two days of samples
      // (the exporter works on whatever series it is handed).
      final samples = <HrSample>[
        _s(8, 60),
        for (var i = 0; i < 35; i++)
          HrSample(
              timeMs: _ms(9) + i * 3600000, bpm: 120 + (i % 5)),
      ];
      final bytes = await buildSpikeReportPdfBytes(
        samples: samples,
        dateStr: '2026-10-16',
        exportedAt: DateTime(2026, 10, 16, 14, 5),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(detectSpikePdfEvents(samples), hasLength(35));
    });
  });

  group('HeartSpikeReviewScreen export action', () {
    Future<void> pumpScreen(
      WidgetTester tester, {
      required List<HrSample> samples,
      Future<String> Function(List<int>, String)? savePdf,
      Future<void> Function(List<int>, String)? sharePdf,
    }) async {
      // Phone-sized surface: the saved SnackBar (and its Share
      // action) renders below the default 800x600 test surface and
      // cannot be tapped there.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: HeartSpikeReviewScreen(
          samples: samples,
          dateStr: '2026-10-16',
          savePdf: savePdf,
          sharePdf: sharePdf,
          now: () => DateTime(2026, 10, 16, 14, 5),
        ),
      ));
      await tester.pump();
    }

    testWidgets('download saves the PDF and offers Share',
        (tester) async {
      String? savedName;
      List<int>? savedBytes;
      String? sharedName;
      await pumpScreen(
        tester,
        samples: [_s(8, 60), _s(9, 130)],
        savePdf: (bytes, name) async {
          savedBytes = bytes;
          savedName = name;
          return '/docs/$name';
        },
        sharePdf: (bytes, name) async {
          sharedName = name;
        },
      );

      await tester.tap(find.byIcon(Icons.download));
      // Let the export future land AND the SnackBar entry animation
      // settle — tapping Share mid-entry targets a point still
      // translated below the surface edge.
      await tester.pumpAndSettle();

      expect(savedName, 'Tabs 2026-10-16 HR spikes.pdf');
      expect(savedBytes, isNotNull);
      expect(savedBytes!.length, greaterThan(1000));
      expect(find.text('Spike report saved'), findsOneWidget);

      await tester.tap(find.text('Share'));
      await tester.pump();
      expect(sharedName, 'Tabs 2026-10-16 HR spikes.pdf');
    });

    testWidgets('no spike events -> native message, nothing saved',
        (tester) async {
      var saves = 0;
      await pumpScreen(
        tester,
        samples: [_s(8, 60), _s(9, 80)],
        savePdf: (bytes, name) async {
          saves++;
          return '/docs/$name';
        },
      );

      await tester.tap(find.byIcon(Icons.download));
      await tester.pump();

      expect(saves, 0);
      expect(find.text('No spike events to export'), findsOneWidget);
    });
  });
}
