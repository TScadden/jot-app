import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';

/// Records the URLs the app tries to open instead of launching a browser.
class FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

class FakeHCService extends HealthConnectService {
  int requestPermissionsCalls = 0;

  @override
  Future<bool> hasPersistedConnection() async => false;

  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.notConnected;

  @override
  Future<Set<String>> requestPermissions() async {
    requestPermissionsCalls++;
    return <String>{};
  }
}

Future<void> _pumpConnections(
    WidgetTester tester, FakeHCService service) async {
  await tester.pumpWidget(MaterialApp(
    home: ConnectionsScreen(healthConnectService: service),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('MF-2: tappable legal links', () {
    testWidgets('Terms of Use opens the hosted terms page', (tester) async {
      final fake = FakeUrlLauncher();
      final previous = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fake;
      try {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.ensureVisible(find.text('Terms of Use'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Terms of Use'));
        await tester.pumpAndSettle();
        expect(fake.launched,
            contains('https://api.jottracker.com/terms.html'));
      } finally {
        UrlLauncherPlatform.instance = previous;
      }
    });

    testWidgets('Privacy Policy opens the hosted privacy page',
        (tester) async {
      final fake = FakeUrlLauncher();
      final previous = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fake;
      try {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.ensureVisible(find.text('Privacy Policy'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Privacy Policy'));
        await tester.pumpAndSettle();
        expect(fake.launched,
            contains('https://api.jottracker.com/privacy.html'));
      } finally {
        UrlLauncherPlatform.instance = previous;
      }
    });
  });

  group('MF-3: Health Connect prominent disclosure', () {
    testWidgets('disclosure explains the data before the permission UI',
        (tester) async {
      final service = FakeHCService();
      await _pumpConnections(tester, service);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();

      // The in-app disclosure comes first — no permission call yet.
      expect(find.text('Connect Health Connect?'), findsOneWidget);
      expect(find.textContaining('never sold'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(service.requestPermissionsCalls, 0);
    });

    testWidgets('"Not now" never triggers the permission request',
        (tester) async {
      final service = FakeHCService();
      await _pumpConnections(tester, service);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(service.requestPermissionsCalls, 0);
      expect(find.text('Connect Health Connect?'), findsNothing);
    });

    testWidgets('"Continue" triggers the permission request exactly once',
        (tester) async {
      final service = FakeHCService();
      await _pumpConnections(tester, service);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(service.requestPermissionsCalls, 1);
    });

    testWidgets('showHealthConnectDisclosure returns true/false directly',
        (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showHealthConnectDisclosure(context);
            },
            child: const Text('open'),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });
}
