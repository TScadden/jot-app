import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/billing_models.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medication_timeline.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_summary.dart' show dateStrOf;
import 'package:tabs_lab/src/features/tools/medication_timeline_screen.dart';
import 'package:tabs_lab/src/features/tools/medication_timeline_strings.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Phase 1, item 2b — widget + copy-lint tests (spec §7 tests 15
/// + panel rendering; Juno's item 2 rulings: R2 no-delta, R5
/// disclaimer, D1 floor states).

DateTime _d(int month, int day) => DateTime(2026, month, day);

MedicationTimelineData _panelData({required bool floorMet}) {
  final scores = <String, int?>{};
  void fill(DateTime start, List<int?> values) {
    for (var i = 0; i < values.length; i++) {
      scores[dateStrOf(start.add(Duration(days: i)))] = values[i];
    }
  }

  if (floorMet) {
    fill(_d(10, 1), [40, 50, null, ...List.filled(11, 60)]);
    fill(_d(10, 15), List.filled(14, 70));
  } else {
    // 3 scored before, 4 scored after — real counts, below floor.
    fill(_d(10, 1), [60, 60, 60, ...List.filled(11, null)]);
    fill(_d(10, 15), [70, 70, 70, 70, ...List.filled(10, null)]);
  }
  return buildMedicationTimeline(
    events: const [],
    medications: const [],
    scoresByDate: scores,
    entries: const [],
    categories: const [],
    today: _d(10, 28),
  );
}

TimelineMarker _panelMarker({bool seeded = false}) => TimelineMarker(
      kind: TimelineMarkerKind.start,
      medId: 'm1',
      medName: 'Med A',
      date: _d(10, 15),
      dateDisplay: 'Oct 15, 2026',
      monthPrecision: false,
      seeded: seeded,
      doseAtEvent: '10 mg',
      afterDose: '10 mg',
      afterFrequency: 'Once daily',
      afterIsPresent: true,
      recordedAtMs: _d(10, 15).millisecondsSinceEpoch,
    );

/// A panel-ready data object whose marker list contains [marker]
/// so windowsFor resolves its (empty) neighbor set identically
/// to the screen's use.
MedicationTimelineData _dataWithMarker(
    MedicationTimelineData base, TimelineMarker marker) {
  return MedicationTimelineData(
    markers: [marker],
    days: base.days,
    rangeStart: base.rangeStart,
    rangeEnd: base.rangeEnd,
    skippedSeedCount: 0,
    lanes: const [],
    scoresByDate: base.scoresByDate,
  );
}

/// Mutable per-path control for the parameterized backend mock
/// (H2-02): each endpoint's status / throw behavior can be set
/// before the pump and flipped mid-test (the Try-again cases).
class _BackendControl {
  bool unlimited = true;
  int pullStatus = 200;
  bool pullThrows = false;
  int eventsStatus = 200;
  bool eventsThrows = false;

  /// Events list empty AND pull carrying an empty medication
  /// list / no entries / no categories (a genuinely empty
  /// history, successfully loaded).
  bool emptyHistory = false;
}

// ── Billing fakes ──────────────────────────────────────────────
// Copied verbatim from billing_takeover_test.dart (the
// FakeBillingStore / FakeBillingBackend pair) for the H2-02
// gate tests — importing another test file crashes the test
// compiler, so the fakes are reused by copy, exactly as defined
// there.
class FakeBillingStore implements BillingStore {
  final List<String> log;
  FakeBillingStore(this.log);

  bool available = true;
  List<BillingProduct> catalog = const [];
  List<BillingPurchase> owned = const [];
  bool launchResult = true;
  Object? queryError;
  Object? completeError;

  final List<Set<String>> queriedProductIdSets = [];

  final StreamController<List<BillingPurchase>> updates =
      StreamController<List<BillingPurchase>>.broadcast();

  @override
  Future<bool> isAvailable() async {
    log.add('store.isAvailable');
    return available;
  }

  @override
  Stream<List<BillingPurchase>> get purchaseUpdates => updates.stream;

  @override
  Future<List<BillingProduct>> queryProducts(Set<String> productIds) async {
    log.add('store.queryProducts');
    queriedProductIdSets.add(Set<String>.of(productIds));
    if (queryError != null) throw queryError!;
    return catalog;
  }

  @override
  Future<bool> launchPurchase(BillingProduct product, BillingOffer offer) async {
    log.add('store.launch:${product.id}:${offer.offerToken}');
    return launchResult;
  }

  @override
  Future<List<BillingPurchase>> queryOwnedPurchases() async {
    log.add('store.queryOwned');
    return owned;
  }

  @override
  Future<void> completePurchase(BillingPurchase purchase) async {
    log.add('store.complete:${purchase.purchaseToken}');
    if (completeError != null) throw completeError!;
  }

  void emit(List<BillingPurchase> purchases) => updates.add(purchases);
}

class FakeBillingBackend implements BillingBackend {
  final List<String> log;
  FakeBillingBackend(this.log);

  BillingVerifyOutcome verifyOutcome = const BillingVerifyOutcome(
      success: true, isUnlimited: true);
  bool? syncResult = false;
  Object? verifyError;
  Object? syncError;

  Completer<void>? verifyGate;
  final List<String> verifiedTokens = [];
  final List<List<String>> syncedTokenLists = [];

  @override
  Future<BillingVerifyOutcome> verifyPurchase({
    required String productId,
    required String purchaseToken,
    int quantity = 1,
  }) async {
    log.add('backend.verify:$productId:$purchaseToken:$quantity');
    verifiedTokens.add(purchaseToken);
    if (verifyGate != null) await verifyGate!.future;
    if (verifyError != null) throw verifyError!;
    return verifyOutcome;
  }

  @override
  Future<bool?> syncSubscriptions(List<String> activeTokens) async {
    log.add('backend.sync:$activeTokens');
    syncedTokenLists.add(List.of(activeTokens));
    if (syncError != null) throw syncError!;
    return syncResult;
  }
}

List<String> _allTexts(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .toList();
}

void main() {
  group('MedicationChangePanel (floor met)', () {
    testWidgets('renders label, date, both disclaimers, both averages in '
        'identical form, and the rule note — with NO delta affordance',
        (tester) async {
      final marker = _panelMarker();
      final data = _dataWithMarker(_panelData(floorMet: true), marker);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MedicationChangePanel(marker: marker, data: data)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
      expect(find.text('Oct 15, 2026'), findsOneWidget);
      expect(
          find.text(MedicationTimelineStrings.nonCausationDisclaimer),
          findsOneWidget);
      expect(find.text(MedicationTimelineStrings.screenDisclaimer),
          findsOneWidget);
      expect(find.text('Average Daily Score, 14 days before'), findsOneWidget);
      expect(find.text('58 · 13 scored days'), findsOneWidget);
      expect(
          find.text('Average Daily Score, 14 days after'), findsOneWidget);
      expect(find.text('70 · 14 scored days'), findsOneWidget);
      expect(find.text(MedicationTimelineStrings.ruleNote), findsOneWidget);
      // Captured marker: NO provenance label.
      expect(find.text(MedicationTimelineStrings.seededProvenance),
          findsNothing);

      // R2: no delta anywhere in the rendered panel — no signed
      // difference, no percent, no delta wording.
      for (final text in _allTexts(tester)) {
        expect(text.contains('%'), isFalse, reason: 'percent in: $text');
        expect(RegExp(r'(^|\s)[+-]\d').hasMatch(text), isFalse,
            reason: 'signed delta in: $text');
        expect(text.toLowerCase().contains('difference'), isFalse,
            reason: 'delta wording in: $text');
      }
      // Before renders before after (ordering is fixed, not a
      // contrast): the before label's position is above the
      // after label's.
      final beforeY = tester
          .getTopLeft(find.text('Average Daily Score, 14 days before'))
          .dy;
      final afterY = tester
          .getTopLeft(find.text('Average Daily Score, 14 days after'))
          .dy;
      expect(beforeY < afterY, isTrue);
    });

    testWidgets('seeded marker carries the provenance label', (tester) async {
      final marker = _panelMarker(seeded: true);
      final data = _dataWithMarker(_panelData(floorMet: true), marker);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MedicationChangePanel(marker: marker, data: data)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(MedicationTimelineStrings.seededProvenance),
          findsOneWidget);
    });
  });

  group('MedicationChangePanel (below floor)', () {
    testWidgets('renders the Juno replacement string with the real counts '
        'and NO averages and NO rule note', (tester) async {
      final marker = _panelMarker();
      final data = _dataWithMarker(_panelData(floorMet: false), marker);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MedicationChangePanel(marker: marker, data: data)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
            'Not enough scored days for these windows yet. Before: 3 scored days. After: 4 scored days. Averages show when each window has at least 5 scored days and the two windows have 14 scored days in total.'),
        findsOneWidget,
      );
      expect(find.textContaining('Average Daily Score'), findsNothing);
      expect(find.text(MedicationTimelineStrings.ruleNote), findsNothing);
      // No partial average values leak into the below-floor state.
      expect(find.textContaining('scored days ·'), findsNothing);
      expect(find.text('60 · 3 scored days'), findsNothing);
      expect(find.text('70 · 4 scored days'), findsNothing);
      // Both disclaimers still render.
      expect(
          find.text(MedicationTimelineStrings.nonCausationDisclaimer),
          findsOneWidget);
      expect(find.text(MedicationTimelineStrings.screenDisclaimer),
          findsOneWidget);
    });
  });

  group('copy lint (test 15)', () {
    final stringsSource = File(
            'lib/src/features/tools/medication_timeline_strings.dart')
        .readAsStringSync();
    final screenSource =
        File('lib/src/features/tools/medication_timeline_screen.dart')
            .readAsStringSync();

    test('the strings file carries Juno\'s final verbatim set', () {
      const approved = [
        'Medication timeline',
        'See when your medications started, stopped, or changed, next to your Daily Scores and logged days.',
        'Tabs shows your own records side by side. A change in your scores after a medication change does not mean the medication caused it. What your records mean is a question for you and your clinician.',
        'Average Daily Score, ',
        ' days before',
        ' days after',
        ' scored days',
        'The day of the change counts in the "after" window for starts and dose changes, and in the "before" window for stops.',
        'Started ',
        'Stopped ',
        ' dose changed from ',
        ' schedule changed from ',
        'Restarted ',
        'Date from your medication list',
        'No medication changes in this range.',
        'Not enough scored days for these windows yet. Before: ',
        'Averages show when each window has at least 5 scored days and the two windows have 14 scored days in total.',
        'Daily Score',
        'Flare days',
        'Migraine days',
        'Symptom logs',
        'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition.',
        // Gate / load failure states (Juno ruling, H1-05/H1-06
        // package — verbatim).
        'Could not verify membership. Check your connection and try again.',
        'Could not load your medication timeline. Check your connection and try again.',
        'Try again',
      ];
      for (final s in approved) {
        expect(stringsSource.contains(s), isTrue,
            reason: 'missing approved string fragment: $s');
      }
    });

    test('the superseded Draft 8 empty state is NOT used', () {
      expect(
          stringsSource.contains('Not enough scored days in this window yet.'),
          isFalse);
      expect(
          screenSource.contains('Not enough scored days in this window yet.'),
          isFalse);
    });

    test('no prohibited claim patterns in the strings file', () {
      final lower = stringsSource.toLowerCase();
      for (final banned in [
        'helped',
        'improved',
        'improvement',
        'worsened',
        'is working',
        'not working',
        'strongest',
        'weakest',
        'made worse',
        'because of',
      ]) {
        expect(lower.contains(banned), isFalse,
            reason: 'banned pattern present: $banned');
      }
      expect(stringsSource.contains('%'), isFalse);
    });

    test('no delta affordance in the panel/screen source (R2)', () {
      for (final banned in [
        'arrow_upward',
        'arrow_downward',
        'Icons.trending_up',
        'Icons.trending_down',
      ]) {
        expect(screenSource.contains(banned), isFalse,
            reason: 'delta affordance present: $banned');
      }
    });
  });

  group('MedicationTimelineScreen', () {
    late _FakeStoreIO storeIo;
    late HealthHistoryStore historyStore;

    setUp(() {
      TabsBackend.debugResetSharedCaches();
      storeIo = _FakeStoreIO();
      historyStore = HealthHistoryStore.testInstance();
      historyStore.debugSetStore(
          read: storeIo.read, write: storeIo.write, delete: storeIo.delete);
      historyStore.debugReset();
    });

    Future<void> seedScores() async {
      // Rows Sep 28–Oct 28; scores per the panel scenario:
      // before window (Oct 1–14): 40, 50, unscored, 60 × 11;
      // after window (Oct 15–28): 70.
      final rows = <DailyBiometrics>[];
      for (var day = _d(9, 28);
          !day.isAfter(_d(10, 28));
          day = day.add(const Duration(days: 1))) {
        rows.add(DailyBiometrics(date: dateStrOf(day), restingHrBpm: 60));
      }
      await historyStore.mergeRefresh(rows);
      Future<void> score(DateTime day, int value) =>
          historyStore.persistScore(dateStrOf(day), dailyScore: value);
      await score(_d(10, 1), 40);
      await score(_d(10, 2), 50);
      // Oct 3 deliberately unscored.
      for (var day = _d(10, 4);
          !day.isAfter(_d(10, 14));
          day = day.add(const Duration(days: 1))) {
        await score(day, 60);
      }
      for (var day = _d(10, 15);
          !day.isAfter(_d(10, 28));
          day = day.add(const Duration(days: 1))) {
        await score(day, 70);
      }
    }

    /// The existing mock, parameterized per path (H2-02): the
    /// medication-events endpoint and the sync pull each honor
    /// [control]'s status / throw / empty settings, and the
    /// control can be flipped mid-test for the retry cases.
    TabsBackend backendControlled(_BackendControl control) {
      final session = FakeSessionStore()..token = 'tok';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/medication-events') {
          if (control.eventsThrows) {
            throw StateError('mock transport failure (events)');
          }
          if (control.eventsStatus != 200) {
            return http.Response('nope', control.eventsStatus);
          }
          return http.Response(
            jsonEncode({
              'success': true,
              'events': control.emptyHistory
                  ? <dynamic>[]
                  : [
                      {
                        'id': 'e1',
                        'medId': 'm1',
                        'medName': 'Med A',
                        'type': 'start',
                        'old': null,
                        'new': {
                          'dose': '10 mg',
                          'frequency': 'Once daily',
                          'startDate': 'Oct 15, 2026',
                          'endDate': 'Present',
                          'isPresent': true,
                        },
                        'effectiveDate': 'Oct 15, 2026',
                        'recordedAt': _d(10, 15).millisecondsSinceEpoch,
                        'source': 'tools',
                      },
                    ],
            }),
            200,
          );
        }
        // /api/sync/pull
        if (control.pullThrows) {
          throw StateError('mock transport failure (pull)');
        }
        if (control.pullStatus != 200) {
          return http.Response('nope', control.pullStatus);
        }
        return http.Response(
          jsonEncode({
            'isUnlimited': control.unlimited,
            'isAdmin': false,
            'profile': {
              'medications': control.emptyHistory
                  ? '[]'
                  : jsonEncode([
                      {
                        'id': 'm1',
                        'name': 'Med A',
                        'startDate': 'Oct 15, 2026',
                        'endDate': 'Present',
                        'isPresent': true,
                        'dose': '10 mg',
                        'frequency': 'Once daily',
                        'updatedAt': 0,
                        'isDeleted': false,
                      },
                    ]),
            },
            'entries': <dynamic>[],
            'categories': control.emptyHistory
                ? <dynamic>[]
                : [
                    {
                      'id': 1,
                      'name': 'Symptoms',
                      'icon': 'circle',
                      'colorHex': '#CCCCCC',
                      'isDefault': true,
                      'sortOrder': 0,
                    },
                  ],
          }),
          200,
        );
      });
      return TabsBackend(client: client, sessionStore: session);
    }

    TabsBackend backend({required bool unlimited}) {
      final control = _BackendControl()..unlimited = unlimited;
      return backendControlled(control);
    }

    /// A [BillingService] over the billing takeover fakes (the
    /// FakeBillingStore / FakeBillingBackend copied verbatim
    /// from billing_takeover_test.dart above), NOT yet
    /// initialized or synced — its state starts with
    /// `isUnlimited == null` (unknown).
    ({
      FakeBillingStore store,
      FakeBillingBackend backend,
      BillingService service,
    }) makeBillingService() {
      final log = <String>[];
      final store = FakeBillingStore(log);
      final backend = FakeBillingBackend(log);
      final service = BillingService(
          store: store, backend: backend, isProductionBuild: true);
      return (store: store, backend: backend, service: service);
    }

    MedicationTimelineSeenStore seenStore({required bool seen}) {
      final store = MedicationTimelineSeenStore();
      store.debugSetIO(
        read: (_) async => seen ? '1' : null,
        write: (_, _) async {},
      );
      return store;
    }

    testWidgets('premium user: title, intro, first-open disclaimer, chart '
        'toggles, change row; tapping the row opens the panel',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await seedScores();
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationTimelineScreen(
            backend: backend(unlimited: true),
            historyStore: historyStore,
            seenStore: seenStore(seen: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(MedicationTimelineStrings.title), findsOneWidget);
      expect(find.text(MedicationTimelineStrings.intro), findsOneWidget);
      // First open: the non-causation block renders on the screen.
      expect(find.text(MedicationTimelineStrings.nonCausationDisclaimer),
          findsOneWidget);
      // Series toggles with Juno's Draft 9 labels.
      expect(find.text(MedicationTimelineStrings.toggleDailyScore),
          findsOneWidget);
      expect(find.text(MedicationTimelineStrings.toggleFlareDays),
          findsOneWidget);
      expect(find.text(MedicationTimelineStrings.toggleMigraineDays),
          findsOneWidget);
      expect(find.text(MedicationTimelineStrings.toggleSymptomLogs),
          findsOneWidget);
      // The captured start renders as a change row (its seed is
      // suppressed by dedup — exactly one such row).
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);

      await tester.ensureVisible(find.text('Started Med A · 10 mg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Started Med A · 10 mg'));
      await tester.pumpAndSettle();
      // The panel: disclaimers, averages, rule note.
      expect(find.text(MedicationTimelineStrings.screenDisclaimer),
          findsOneWidget);
      expect(find.text('Average Daily Score, 14 days before'), findsOneWidget);
      expect(find.text('58 · 13 scored days'), findsOneWidget);
      expect(find.text('70 · 14 scored days'), findsOneWidget);
      expect(find.text(MedicationTimelineStrings.ruleNote), findsOneWidget);
    });

    testWidgets('second open: no first-open disclaimer block on the screen',
        (tester) async {
      await seedScores();
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationTimelineScreen(
            backend: backend(unlimited: true),
            historyStore: historyStore,
            seenStore: seenStore(seen: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(MedicationTimelineStrings.nonCausationDisclaimer),
          findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
    });

    testWidgets('non-premium user: locked state, no timeline content',
        (tester) async {
      await seedScores();
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationTimelineScreen(
            backend: backend(unlimited: false),
            historyStore: historyStore,
            seenStore: seenStore(seen: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Started Med A · 10 mg'), findsNothing);
      expect(find.byType(MedicationChangePanel), findsNothing);
    });

    // ── H1-05 / H1-06 / H2-02 — failure states ─────────────────
    // Juno's verbatim strings for the two NEW states (asserted
    // as literals so these tests compile — and fail — against
    // the pre-fix code):
    const unknownMessage =
        'Could not verify membership. Check your connection and try again.';
    const loadErrorMessage =
        'Could not load your medication timeline. Check your connection and try again.';
    const tryAgainLabel = 'Try again';
    const noChanges = 'No medication changes in this range.';

    Future<void> pumpScreen(
      WidgetTester tester, {
      required TabsBackend tabsBackend,
      BillingService? billingService,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await seedScores();
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationTimelineScreen(
            backend: tabsBackend,
            historyStore: historyStore,
            seenStore: seenStore(seen: true),
            billingService: billingService,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
        'H2-02 (1): BillingService state null, server pull says '
        'isUnlimited:true → timeline content, not the lock',
        (tester) async {
      final billing = makeBillingService();
      // Never initialized / synced: the billing state is unknown.
      expect(billing.service.state.isUnlimited, isNull);
      await pumpScreen(
        tester,
        tabsBackend: backend(unlimited: true),
        billingService: billing.service,
      );
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.text(unknownMessage), findsNothing);
    });

    testWidgets('H2-02 (2a): sync resolves true → unlocked and loads',
        (tester) async {
      final billing = makeBillingService();
      billing.backend.syncResult = true;
      await billing.service.syncSubscriptionStatus();
      expect(billing.service.state.isUnlimited, isTrue);
      await pumpScreen(
        tester,
        tabsBackend: backend(unlimited: true),
        billingService: billing.service,
      );
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.text(unknownMessage), findsNothing);
    });

    testWidgets('H2-02 (2b): sync resolves false → locked view',
        (tester) async {
      final billing = makeBillingService();
      billing.backend.syncResult = false;
      await billing.service.syncSubscriptionStatus();
      expect(billing.service.state.isUnlimited, isFalse);
      await pumpScreen(
        tester,
        tabsBackend: backend(unlimited: true),
        billingService: billing.service,
      );
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Started Med A · 10 mg'), findsNothing);
      expect(find.text(unknownMessage), findsNothing);
    });

    testWidgets(
        'H2-02 (2c): stream transition null/false → true unlocks '
        'and loads', (tester) async {
      final billing = makeBillingService();
      billing.backend.syncResult = false;
      await billing.service.syncSubscriptionStatus();
      await pumpScreen(
        tester,
        tabsBackend: backend(unlimited: true),
        billingService: billing.service,
      );
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Started Med A · 10 mg'), findsNothing);

      billing.backend.syncResult = true;
      await billing.service.syncSubscriptionStatus();
      await tester.pumpAndSettle();
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });

    testWidgets(
        'H2-02 (3): Play unavailable (isAvailable false) → unknown '
        'state, not the plain locked view', (tester) async {
      final billing = makeBillingService();
      billing.store.available = false;
      await billing.service.initialize();
      // Play unavailable leaves the status unknown (null).
      expect(billing.service.state.isUnlimited, isNull);
      final control = _BackendControl()..pullStatus = 500;
      await pumpScreen(
        tester,
        tabsBackend: backendControlled(control),
        billingService: billing.service,
      );
      expect(find.text(unknownMessage), findsOneWidget);
      expect(find.text(tryAgainLabel), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsNothing);
    });

    testWidgets(
        'H2-02 (4a): non-billing path, pull 500 → unknown/verify '
        'state, not locked, not timeline; Try again re-checks the '
        'gate and unlocks once the pull is healthy', (tester) async {
      final control = _BackendControl()..pullStatus = 500;
      await pumpScreen(tester, tabsBackend: backendControlled(control));
      expect(find.text(unknownMessage), findsOneWidget);
      expect(find.text(tryAgainLabel), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsNothing);

      control.pullStatus = 200;
      await tester.tap(find.text(tryAgainLabel));
      await tester.pumpAndSettle();
      expect(find.text(unknownMessage), findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
    });

    testWidgets(
        'H2-02 (4b): non-billing path, pull throws → unknown/verify '
        'state, not locked, not timeline', (tester) async {
      final control = _BackendControl()..pullThrows = true;
      await pumpScreen(tester, tabsBackend: backendControlled(control));
      expect(find.text(unknownMessage), findsOneWidget);
      expect(find.text(tryAgainLabel), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsNothing);
    });

    testWidgets(
        'H2-02 (5a): gate unlocked, medication-events 500 with the '
        'pull OK → load-failure state, empty string ABSENT',
        (tester) async {
      final control = _BackendControl()..eventsStatus = 500;
      await pumpScreen(tester, tabsBackend: backendControlled(control));
      expect(find.text(loadErrorMessage), findsOneWidget);
      expect(find.text(tryAgainLabel), findsOneWidget);
      expect(find.text(noChanges), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(
          find.text(MedicationTimelineStrings.toggleDailyScore),
          findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsNothing);
    });

    testWidgets(
        'H2-02 (5b): gate unlocked via billing, BOTH endpoints '
        'failing → load-failure state, empty string ABSENT',
        (tester) async {
      final billing = makeBillingService();
      billing.backend.syncResult = true;
      await billing.service.syncSubscriptionStatus();
      final control = _BackendControl()
        ..eventsStatus = 500
        ..pullStatus = 500;
      await pumpScreen(
        tester,
        tabsBackend: backendControlled(control),
        billingService: billing.service,
      );
      expect(find.text(loadErrorMessage), findsOneWidget);
      expect(find.text(tryAgainLabel), findsOneWidget);
      expect(find.text(noChanges), findsNothing);
      expect(find.text(unknownMessage), findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsNothing);
    });

    testWidgets(
        'H2-02 (5c): gate unlocked, both endpoints 200 empty → '
        'genuinely-empty string PRESENT, no failure state',
        (tester) async {
      final control = _BackendControl()..emptyHistory = true;
      await pumpScreen(tester, tabsBackend: backendControlled(control));
      expect(find.text(noChanges), findsOneWidget);
      expect(find.text(loadErrorMessage), findsNothing);
      expect(find.text(unknownMessage), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });

    testWidgets(
        'H2-02 (6): from the load-failure state, flip the mock '
        'healthy and tap Try again → the timeline renders',
        (tester) async {
      final billing = makeBillingService();
      billing.backend.syncResult = true;
      await billing.service.syncSubscriptionStatus();
      final control = _BackendControl()
        ..eventsStatus = 500
        ..pullStatus = 500;
      await pumpScreen(
        tester,
        tabsBackend: backendControlled(control),
        billingService: billing.service,
      );
      expect(find.text(loadErrorMessage), findsOneWidget);
      expect(find.text('Started Med A · 10 mg'), findsNothing);

      control.eventsStatus = 200;
      control.pullStatus = 200;
      await tester.tap(find.text(tryAgainLabel));
      await tester.pumpAndSettle();
      expect(find.text(loadErrorMessage), findsNothing);
      expect(find.text('Started Med A · 10 mg'), findsOneWidget);
    });

    testWidgets('Medications tool entry opens the timeline screen',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await seedScores();
      // Reuse the timeline mock: MedicationsScreen only needs the
      // pull; the pushed timeline screen is what this asserts.
      final b = backend(unlimited: true);
      await tester.pumpWidget(
        MaterialApp(home: MedicationsScreen(backend: b)),
      );
      await tester.pumpAndSettle();
      expect(find.text(MedicationTimelineStrings.title), findsOneWidget);
      await tester.tap(find.text(MedicationTimelineStrings.title));
      // Bounded pumps, not pumpAndSettle: the pushed screen is
      // constructed by MedicationsScreen with default dependencies
      // (its gate check runs against the real backend, which never
      // resolves under the test clock, so its loading spinner
      // never settles). This test asserts NAVIGATION only; the
      // timeline screen's own states are covered above with
      // injected dependencies.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(MedicationTimelineScreen), findsOneWidget);
    });
  });
}

/// In-memory IO for [HealthHistoryStore.debugSetStore].
class _FakeStoreIO {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}
