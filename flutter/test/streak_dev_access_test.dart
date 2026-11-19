import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// Founder ruling (Nov 18, 2026) — the Developer Terminal / dev
/// area is TYSON-ONLY. Acceptance:
/// (a) with the pulled `dev_access` == true, the dev area entry
///     AND the SIM render (same build);
/// (b) with dev_access false or absent — INCLUDING an admin
///     account (isAdmin true) — neither renders (same build).
/// The gate is the account flag from /api/sync/pull, not the
/// admin flag and not a build flavor.
class _FakeBackend extends TabsBackend {
  final Map<String, dynamic> pull;
  _FakeBackend({super.sessionStore, required this.pull});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pull;
}

SettingsStore _fakeStore(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

Map<String, dynamic> _pull({
  bool isAdmin = false,
  bool? devAccess,
  bool devAccessInProfile = true,
}) {
  return {
    'isUnlimited': isAdmin,
    'isAdmin': isAdmin,
    'nickname': 'Tyson',
    'tag': '1234',
    if (!devAccessInProfile && devAccess != null)
      'dev_access': devAccess,
    'profile': <String, dynamic>{
      if (devAccessInProfile && devAccess != null)
        'dev_access': devAccess,
    },
    'insights': const [],
  };
}

void main() {
  group('SettingsProfileData.fromPull — dev_access parsing', () {
    test('true in the profile map → devAccess true', () {
      final d = SettingsProfileData.fromPull(_pull(devAccess: true));
      expect(d.devAccess, isTrue);
    });

    test('true at the pull top level → devAccess true', () {
      final d = SettingsProfileData.fromPull(
        _pull(devAccess: true, devAccessInProfile: false),
      );
      expect(d.devAccess, isTrue);
    });

    test('absent → false; explicit false → false', () {
      expect(SettingsProfileData.fromPull(_pull()).devAccess, isFalse);
      expect(
        SettingsProfileData.fromPull(_pull(devAccess: false)).devAccess,
        isFalse,
      );
    });

    test('an ADMIN pull without dev_access → false (admins who are '
        'not Tyson must not get the dev area)', () {
      final d = SettingsProfileData.fromPull(_pull(isAdmin: true));
      expect(d.isAdmin, isTrue);
      expect(d.devAccess, isFalse);
    });

    test('null body → false', () {
      expect(SettingsProfileData.fromPull(null).devAccess, isFalse);
    });
  });

  group('Settings render — the dev area gate', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      Map<String, dynamic> pull,
    ) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          backend: _FakeBackend(
            sessionStore: FakeSessionStore(),
            pull: pull,
          ),
          settingsStore: _fakeStore(<String, String>{}),
          notificationService: FakeReminderNotificationService(),
          urlLauncher: (uri) async => true,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('(a) dev_access true → Developer Terminal entry '
        'renders, and the SIM renders inside it', (tester) async {
      await pumpSettings(tester, _pull(devAccess: true));
      final entry = find.byKey(const ValueKey('developer_terminal_entry'));
      expect(entry, findsOneWidget);
      expect(find.text('Developer Terminal Options'), findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      // The SIM (Juno §8 label + caption) renders on the page.
      expect(
        find.text('Preview celebration — streak +1 [SIM]'),
        findsOneWidget,
      );
      expect(
        find.text('Simulation only. This does not change your real streak.'),
        findsOneWidget,
      );
    });

    testWidgets('(b) dev_access absent → no dev area entry',
        (tester) async {
      await pumpSettings(tester, _pull());
      expect(
        find.byKey(const ValueKey('developer_terminal_entry')),
        findsNothing,
      );
      expect(find.text('Developer Terminal Options'), findsNothing);
      expect(find.text('Preview celebration — streak +1 [SIM]'),
          findsNothing);
    });

    testWidgets('(b) an ADMIN account without dev_access → no dev '
        'area entry (Dad/Julee/Boston case)', (tester) async {
      await pumpSettings(tester, _pull(isAdmin: true));
      expect(
        find.byKey(const ValueKey('developer_terminal_entry')),
        findsNothing,
      );
      expect(find.text('Developer Terminal Options'), findsNothing);
    });

    testWidgets('(b) dev_access explicitly false → no dev area entry',
        (tester) async {
      await pumpSettings(tester, _pull(devAccess: false));
      expect(
        find.byKey(const ValueKey('developer_terminal_entry')),
        findsNothing,
      );
    });
  });
}
