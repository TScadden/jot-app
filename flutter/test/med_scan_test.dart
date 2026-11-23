import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:tabs_lab/src/data/med_scan.dart';
import 'package:tabs_lab/src/data/med_scan_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/med_scan_confirm_sheet.dart';
import 'package:tabs_lab/src/features/tools/med_scan_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Med Scan (Nov 22, 2026) — unit coverage for the pure logic
/// (NDC normalization, openFDA/RxNorm parsing, label OCR
/// parsing, name matching, the lookup service's failure
/// discipline) and widget coverage for the HARD SAFETY RULE:
/// the confirm sheet always stands between a scan and a save,
/// and update-vs-add routing follows the match.

void main() {
  group('NDC normalization', () {
    test('UPC-A: strips the GS1 "3" and the check digit', () {
      // "3" + NDC 1234567890 + check digit 5.
      expect(ndcDigitCandidates('312345678905'), contains('1234567890'));
    });

    test('EAN-13 wrapping a UPC-A resolves to the same NDC', () {
      expect(ndcDigitCandidates('0312345678905'), contains('1234567890'));
    });

    test('hyphenated NDC input digitizes to the same candidate', () {
      expect(ndcDigitCandidates('12345-6789-0').first, '1234567890');
    });

    test('queries cover all segmentations, package before product', () {
      final queries = ndcQueriesForBarcode('312345678905');
      final values = queries.map((q) => '${q.field}=${q.value}').toList();
      expect(values, contains('package_ndc=12345-6789-0')); // 5-4-1
      expect(values, contains('package_ndc=1234-5678-90')); // 4-4-2
      expect(values, contains('package_ndc=12345-678-90')); // 5-3-2
      expect(values, contains('product_ndc=12345-6789'));
      expect(values, contains('product_ndc=1234-5678'));
      expect(values, contains('product_ndc=12345-678'));
      // Package queries all precede product queries.
      final lastPackage = values.lastIndexWhere(
        (v) => v.startsWith('package_ndc'),
      );
      final firstProduct = values.indexWhere(
        (v) => v.startsWith('product_ndc'),
      );
      expect(lastPackage, lessThan(firstProduct));
    });

    test('11-digit NDC gets its 5-4-2 package and 5-4 product forms', () {
      final queries = ndcQueriesForBarcode('12345678901');
      final values = queries.map((q) => '${q.field}=${q.value}').toList();
      expect(values, contains('package_ndc=12345-6789-01'));
      expect(values, contains('product_ndc=12345-6789'));
    });

    test('garbage input yields no queries', () {
      expect(ndcQueriesForBarcode('hello'), isEmpty);
      expect(ndcQueriesForBarcode(''), isEmpty);
    });
  });

  group('openFDA response parsing', () {
    final fixture = jsonDecode('''
    {
      "meta": {"results": {"total": 1}},
      "results": [
        {
          "product_ndc": "00008-0831",
          "generic_name": "desvenlafaxine succinate",
          "brand_name": "PRISTIQ",
          "labeler_name": "Wyeth Pharmaceuticals LLC",
          "dosage_form": "TABLET, EXTENDED RELEASE",
          "active_ingredients": [
            {"name": "DESVENLAFAXINE SUCCINATE", "strength": "50 mg"}
          ]
        }
      ]
    }''') as Map<String, dynamic>;

    test('generic name wins over brand; strength and form parsed', () {
      final proposal = parseOpenFdaNdcResponse(fixture)!;
      expect(proposal.name, 'Desvenlafaxine Succinate');
      expect(proposal.dose, '50 mg');
      expect(proposal.form, 'Tablet');
      expect(proposal.source, MedScanSource.barcode);
    });

    test('empty or malformed results parse to null', () {
      expect(parseOpenFdaNdcResponse({'results': []}), isNull);
      expect(parseOpenFdaNdcResponse({}), isNull);
      expect(
        parseOpenFdaNdcResponse({
          'results': [
            {'foo': 1},
          ],
        }),
        isNull,
      );
    });

    test('dose normalization handles case and per-volume strengths', () {
      expect(normalizeDoseString('50 MG'), '50 mg');
      expect(normalizeDoseString('500 mcg'), '500 mcg');
      expect(normalizeDoseString('10 mg/mL'), '10 mg/mL');
      expect(normalizeDoseString('no strength here'), isNull);
    });
  });

  group('label OCR parsing', () {
    test('founder shape: Desvenlafaxine Succinate ER 50 mg', () {
      final parts = parseMedicationLabelLines(const [
        'Desvenlafaxine Succinate ER 50 mg',
        'Take 1 tablet by mouth once daily',
        'Qty 30',
        'Refills: 2',
      ])!;
      expect(parts.name, 'Desvenlafaxine Succinate ER');
      expect(parts.dose, '50 mg');
    });

    test('founder shape: Ivabradine 7.5 mg', () {
      final parts = parseMedicationLabelLines(const [
        'Ivabradine 7.5 mg',
        'Take 1 tablet by mouth twice daily',
      ])!;
      expect(parts.name, 'Ivabradine');
      expect(parts.dose, '7.5 mg');
      expect(parts.form, 'Tablet');
    });

    test('bare-decimal dose (peptide shape) is captured', () {
      final parts = parseMedicationLabelLines(const [
        'BPC-157 0.05',
        'Inject as directed',
      ])!;
      expect(parts.name, 'BPC-157');
      expect(parts.dose, '0.05');
    });

    test('all-caps label line is display-cased, ER keeps its caps', () {
      final parts = parseMedicationLabelLines(const [
        'DESVENLAFAXINE SUCCINATE ER 50 MG TABLETS',
      ])!;
      expect(parts.name, 'Desvenlafaxine Succinate ER');
      expect(parts.dose, '50 mg');
      expect(parts.form, 'Tablet');
    });

    test('pharmacy furniture alone identifies nothing', () {
      expect(
        parseMedicationLabelLines(const [
          'Take 1 tablet by mouth daily',
          'Qty 30',
          'Refills: 2',
          'Discard after 01/2027',
        ]),
        isNull,
      );
      expect(parseMedicationLabelLines(const []), isNull);
    });
  });

  group('name matching', () {
    MedicationEntry entry(
      String name, {
      String dose = '50 mg',
      bool archived = false,
      bool deleted = false,
    }) => MedicationEntry(
      id: 'id-$name',
      name: name,
      dose: dose,
      startDate: 'Oct 1, 2026',
      isPresent: !archived,
      endDate: archived ? 'Nov 1, 2026' : 'Present',
      isDeleted: deleted,
    );

    test('salt and ER differences still match (update, not add)', () {
      final entries = [entry('Desvenlafaxine Succinate ER')];
      final match = findConfidentMedicationMatch('Desvenlafaxine', entries);
      expect(match, isNotNull);
      expect(match!.name, 'Desvenlafaxine Succinate ER');
    });

    test('strength difference still matches — the dose is the update', () {
      final entries = [entry('Ivabradine', dose: '5 mg')];
      final match = findConfidentMedicationMatch(
        'Ivabradine 7.5 mg',
        // The matcher takes names; strength in the scanned
        // string is normalized away before comparison.
        entries,
      );
      expect(match, isNotNull);
    });

    test('a different drug does not match', () {
      final entries = [entry('Desvenlafaxine Succinate ER')];
      expect(findConfidentMedicationMatch('Metformin', entries), isNull);
    });

    test('deleted entries never match', () {
      final entries = [entry('Ivabradine', deleted: true)];
      expect(findConfidentMedicationMatch('Ivabradine', entries), isNull);
    });

    test('duplicate active entries with the same core are ambiguous', () {
      final entries = [entry('Ivabradine'), entry('Ivabradine')];
      expect(findConfidentMedicationMatch('Ivabradine', entries), isNull);
    });

    test('a unique archived match still resolves', () {
      final entries = [entry('Ivabradine', archived: true)];
      expect(findConfidentMedicationMatch('Ivabradine', entries), isNotNull);
    });
  });

  group('DrugLookupService', () {
    test('walks candidates until openFDA answers', () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        if (request.url.queryParameters['search'] ==
            'package_ndc:"12345-6789-0"') {
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'generic_name': 'ivabradine hydrochloride',
                  'dosage_form': 'TABLET',
                  'active_ingredients': [
                    {'name': 'IVABRADINE', 'strength': '5 mg'},
                  ],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{"error":{"code":"NOT_FOUND"}}', 404);
      });
      final proposal = await DrugLookupService(client: client)
          .lookupBarcode('312345678905');
      expect(proposal, isNotNull);
      expect(proposal!.name, 'Ivabradine Hydrochloride');
      expect(proposal.dose, '5 mg');
      expect(requested.first.host, 'api.fda.gov');
    });

    test('a 429 stops the openFDA walk immediately', () async {
      var fdaRequests = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'api.fda.gov') {
          fdaRequests++;
          return http.Response('rate limited', 429);
        }
        return http.Response('{}', 404);
      });
      final proposal = await DrugLookupService(client: client)
          .lookupBarcode('312345678905');
      expect(proposal, isNull);
      expect(fdaRequests, 1);
    });

    test('RxNorm fallback names the drug when openFDA misses', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'api.fda.gov') {
          return http.Response('{"error":{"code":"NOT_FOUND"}}', 404);
        }
        if (request.url.path.contains('ndcstatus')) {
          return http.Response(
            jsonEncode({
              'ndcStatus': {'rxcui': '1234567', 'status': 'ACTIVE'},
            }),
            200,
          );
        }
        if (request.url.path.contains('properties')) {
          return http.Response(
            jsonEncode({
              'properties': {'name': 'Ivabradine 5 MG Oral Tablet'},
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final proposal = await DrugLookupService(client: client)
          .lookupBarcode('312345678905');
      expect(proposal, isNotNull);
      expect(proposal!.name, 'Ivabradine');
      expect(proposal.dose, '5 mg');
      expect(proposal.form, 'Tablet');
    });

    test('total failure resolves to null, never throws', () async {
      final client = MockClient((request) async {
        throw http.ClientException('offline');
      });
      expect(
        await DrugLookupService(client: client).lookupBarcode('312345678905'),
        isNull,
      );
    });
  });

  group('MedScanConfirmSheet (never save silently)', () {
    testWidgets('add mode: nothing is produced until Save is tapped', (
      tester,
    ) async {
      final harness = _SheetHarness(
        proposal: const MedScanProposal(
          name: 'Desvenlafaxine Succinate',
          dose: '50 mg',
          form: 'Tablet',
          source: MedScanSource.barcode,
        ),
        matchedEntry: null,
      );
      await tester.pumpWidget(harness);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // The sheet is up with the proposal prefilled — and no
      // result exists yet: opening the sheet saved nothing.
      expect(find.byKey(const ValueKey('med_scan_name')), findsOneWidget);
      expect(harness.result, isNull);
      // Juno §4 ADD copy + §6 barcode footer, byte-exact.
      expect(find.text('Check and save this medication'), findsOneWidget);
      expect(
        find.text(
          'We filled in what the scan found. Check each field — you can edit anything.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Nothing is saved yet. Nothing is added until you tap Save.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Barcode lookups send only the barcode number to openFDA and RxNorm to find the medication name. No personal information is sent.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('med_scan_name')))
            .controller!
            .text,
        'Desvenlafaxine Succinate',
      );
      // Start date defaults to TODAY in add mode.
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('med_scan_start_date')),
            )
            .controller!
            .text,
        formatMedArchiveDate(DateTime.now()),
      );

      await tester.tap(find.byKey(const ValueKey('med_scan_save')));
      await tester.pumpAndSettle();
      expect(harness.result, isNotNull);
      expect(harness.result!.updateExisting, isFalse);
      expect(harness.result!.target, isNull);
      expect(harness.result!.name, 'Desvenlafaxine Succinate');
      expect(harness.result!.dose, '50 mg');
      expect(harness.result!.startDate, formatMedArchiveDate(DateTime.now()));
    });

    testWidgets('cancel produces no save request', (tester) async {
      final harness = _SheetHarness(
        proposal: const MedScanProposal(
          name: 'Ivabradine',
          dose: '7.5 mg',
          source: MedScanSource.labelPhoto,
        ),
        matchedEntry: null,
      );
      await tester.pumpWidget(harness);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('med_scan_cancel')));
      await tester.pumpAndSettle();
      expect(harness.result, isNull);
      expect(harness.completed, isTrue);
    });

    testWidgets(
      'update mode leads with the existing entry and keeps its start date',
      (tester) async {
        final existing = MedicationEntry(
          id: 'med-1',
          name: 'Desvenlafaxine Succinate ER',
          dose: '25 mg',
          startDate: 'Oct 1, 2026',
          frequency: 'Once daily',
        );
        final harness = _SheetHarness(
          proposal: const MedScanProposal(
            name: 'Desvenlafaxine Succinate',
            dose: '50 mg',
            form: 'Tablet',
            source: MedScanSource.barcode,
          ),
          matchedEntry: existing,
        );
        await tester.pumpWidget(harness);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // Juno §4: the UPDATE title names the EXISTING entry —
        // its saved name and dose, not the scanned values.
        expect(
          find.text('Update Desvenlafaxine Succinate ER 25 mg?'),
          findsOneWidget,
        );
        expect(
          find.text(
            'This matches a medication you already saved. Saving will update that entry, not add a new one. Check each field — you can edit anything.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Nothing is changed yet. Your saved entry stays as it is until you tap Save.',
          ),
          findsOneWidget,
        );
        // Name seeds from the EXISTING entry (no silent rename),
        // dose from the scan (the point of the update), start
        // date from the entry (no silent history rewrite).
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('med_scan_name')))
              .controller!
              .text,
          'Desvenlafaxine Succinate ER',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('med_scan_dose')))
              .controller!
              .text,
          '50 mg',
        );
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('med_scan_start_date')),
              )
              .controller!
              .text,
          'Oct 1, 2026',
        );

        await tester.tap(find.byKey(const ValueKey('med_scan_save')));
        await tester.pumpAndSettle();
        expect(harness.result, isNotNull);
        expect(harness.result!.updateExisting, isTrue);
        expect(identical(harness.result!.target, existing), isTrue);
        expect(harness.result!.startDate, 'Oct 1, 2026');
        expect(harness.result!.dose, '50 mg');
      },
    );

    testWidgets('"Add as new instead" reroutes an update to an add', (
      tester,
    ) async {
      final existing = MedicationEntry(
        id: 'med-1',
        name: 'Ivabradine',
        dose: '5 mg',
        startDate: 'Oct 1, 2026',
      );
      final harness = _SheetHarness(
        proposal: const MedScanProposal(
          name: 'Ivabradine',
          dose: '7.5 mg',
          source: MedScanSource.barcode,
        ),
        matchedEntry: existing,
      );
      await tester.pumpWidget(harness);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('med_scan_add_as_new')));
      await tester.pumpAndSettle();
      expect(find.text('Check and save this medication'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('med_scan_save')));
      await tester.pumpAndSettle();
      expect(harness.result, isNotNull);
      expect(harness.result!.updateExisting, isFalse);
      expect(harness.result!.target, isNull);
      // Add mode re-seeds the start date to today.
      expect(harness.result!.startDate, formatMedArchiveDate(DateTime.now()));
    });

    testWidgets('save is disabled while the dose is blank', (tester) async {
      final harness = _SheetHarness(
        proposal: const MedScanProposal(
          name: 'Ivabradine',
          dose: '',
          source: MedScanSource.labelPhoto,
        ),
        matchedEntry: null,
      );
      await tester.pumpWidget(harness);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final saveButton = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('med_scan_save')),
      );
      expect(saveButton.onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('med_scan_dose')),
        '7.5 mg',
      );
      await tester.pumpAndSettle();
      final enabledButton = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('med_scan_save')),
      );
      expect(enabledButton.onPressed, isNotNull);
    });
  });

  group('MedScanStore (rationale flag)', () {
    test('unseen by default; seen after marking; round-trips', () async {
      final mem = <String, String>{};
      final store = MedScanStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
      );
      expect(await store.rationaleSeen(), isFalse);
      await store.markRationaleSeen();
      expect(await store.rationaleSeen(), isTrue);
    });
  });

  group('MedScanScreen camera rationale (Juno §3/§8.1)', () {
    MedScanStore fakeStore(Map<String, String> mem) => MedScanStore.withStorage(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
    );

    testWidgets('first use: rationale shows BEFORE any camera widget exists; '
        'Not now leaves without starting the camera', (tester) async {
      final mem = <String, String>{};
      await tester.pumpWidget(
        MaterialApp(home: MedScanScreen(store: fakeStore(mem))),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'To scan, Tabs needs camera access. The camera is used only to read a medication barcode or label on this phone.',
        ),
        findsOneWidget,
      );
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      // The camera widget has NOT been built — no system prompt
      // can have fired.
      expect(find.byType(MobileScanner), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('med_scan_rationale_not_now')),
      );
      await tester.pumpAndSettle();
      // The flag is only written by Continue.
      expect(mem.containsKey(MedScanStore.rationaleSeenKey), isFalse);
    });

    testWidgets('Continue records the rationale and leaves the gate', (
      tester,
    ) async {
      final mem = <String, String>{};
      await tester.pumpWidget(
        MaterialApp(home: MedScanScreen(store: fakeStore(mem))),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('med_scan_rationale_continue')),
      );
      await tester.pumpAndSettle();
      expect(mem[MedScanStore.rationaleSeenKey], 'true');
      expect(
        find.text(
          'To scan, Tabs needs camera access. The camera is used only to read a medication barcode or label on this phone.',
        ),
        findsNothing,
      );
    });

    testWidgets('returning user: no rationale', (tester) async {
      final mem = <String, String>{MedScanStore.rationaleSeenKey: 'true'};
      await tester.pumpWidget(
        MaterialApp(home: MedScanScreen(store: fakeStore(mem))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Continue'), findsNothing);
      expect(
        find.text(
          'To scan, Tabs needs camera access. The camera is used only to read a medication barcode or label on this phone.',
        ),
        findsNothing,
      );
    });
  });

  group('MedicationsScreen entry point', () {
    testWidgets('the Scan medication action is on the screen', (tester) async {
      final backend = _EmptyProfileBackend();
      await tester.pumpWidget(
        MaterialApp(home: MedicationsScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scan_medication')), findsOneWidget);
      expect(find.text('Scan medication'), findsOneWidget);
    });
  });
}

/// Pumps [showMedScanConfirmSheet] from a button and records
/// the outcome. The harness records the sheet's result in
/// mutable fields by design.
// ignore: must_be_immutable
class _SheetHarness extends StatelessWidget {
  _SheetHarness({required this.proposal, required this.matchedEntry});

  final MedScanProposal proposal;
  final MedicationEntry? matchedEntry;

  MedScanSaveRequest? result;
  bool completed = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showMedScanConfirmSheet(
                  context,
                  proposal: proposal,
                  matchedEntry: matchedEntry,
                );
                completed = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal backend fake: an empty profile (no medications).
class _EmptyProfileBackend extends TabsBackend {
  _EmptyProfileBackend()
    : super(sessionStore: FakeSessionStore()..token = 'tok');

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => <String, dynamic>{
    'medications': '[]',
  };

  @override
  void invalidateSyncPull() {}
}
