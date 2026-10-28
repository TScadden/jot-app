import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/setup_loading_screen.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';

/// Founder finding (Oct 28, 2026): on the 'Welcome to Tabs' setup
/// screen the content "was all on the left then randomly centered
/// itself."
///
/// Root cause: Scaffold hands its body LOOSE constraints, and a
/// Column under loose cross-axis constraints sizes itself to its
/// widest child. On this screen the widest child changes over time —
/// the title/status texts during loading (the status text even
/// wobbles as its ellipsis dots cycle), then the full-width
/// 'Start keeping Tabs' button when finalize completes — so the
/// under-wide column hugged the left padding, drifted with the dots,
/// and snapped to true center when the button arrived.
///
/// These tests pin the fixed behavior: the column is full width and
/// every element is at its settled position on the FIRST frame, and
/// nothing moves horizontally at any later stage (dot ticks, the
/// Bandit asset decoding, or the finish state arriving).
OnboardingStore _store(Map<String, String> map) => OnboardingStore.withStorage(
  read: (k) async => map[k],
  write: (k, v) async => map[k] = v,
  delete: (k) async => map.remove(k),
);

class _Backend extends TabsBackend {
  @override
  Future<List<String>?> generateCategories(String userContext) async => null;
  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => const [];
  @override
  Future<bool> postLogCategories(List<QuickLogCategory> cats) async => true;
  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;
}

void main() {
  testWidgets('setup loading paints centered on the first frame and never '
      'shifts horizontally', (tester) async {
    // A surface where the real texts are narrower than the screen,
    // like the founder's phone — the regime where the bug showed.
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const screenCenterX = 300.0; // 600 / 2
    const contentWidth = 552.0; // 600 - 2 * 24 padding

    await tester.pumpWidget(
      MaterialApp(
        home: SetupLoadingScreen(
          onNavigateMain: () {},
          onboardingStore: _store({}),
          backend: _Backend(),
        ),
      ),
    );

    final column = find.descendant(
      of: find.byType(SetupLoadingScreen),
      matching: find.byType(Column),
    );
    final title = find.text('Welcome to Tabs');
    final mascot = find.byType(CoachMascotFigure);
    final logo = find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName.contains('ic_tabs_note'),
    );

    void expectSettled(String stage) {
      expect(
        tester.getSize(column).width,
        contentWidth,
        reason: '$stage: column must be full width from the first frame',
      );
      expect(
        tester.getCenter(title).dx,
        screenCenterX,
        reason: '$stage: title must be at screen center',
      );
      expect(
        tester.getCenter(logo).dx,
        screenCenterX,
        reason: '$stage: logo must be at screen center',
      );
      expect(
        tester.getCenter(mascot).dx,
        screenCenterX,
        reason: '$stage: mascot must be at screen center',
      );
      // Bandit occupies its real box (84 tall, 438:512 art aspect)
      // from the first frame — no zero-width pop-in after decode.
      expect(
        tester.getSize(mascot),
        const Size(84 * 438 / 512, 84),
        reason: '$stage: mascot box must be its settled size',
      );
    }

    // FIRST FRAME — before any async work, asset decode, or timer.
    expectSettled('first frame');

    // Dot ticks: the status ellipsis must not drag the layout.
    await tester.pump(const Duration(milliseconds: 600));
    expectSettled('after dot tick 1');
    await tester.pump(const Duration(milliseconds: 600));
    expectSettled('after dot tick 2');

    // Let the Bandit asset actually decode, then paint again.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expectSettled('after bandit decode');

    // Finalize completes: status text swaps and the button arrives.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Start keeping Tabs'), findsOneWidget);
    expect(find.text('Your profile is all set up!'), findsOneWidget);
    expectSettled('after finish');
  });
}
