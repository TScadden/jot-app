import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// F-11 (legal-exposure register Q82) — the in-app open-source
/// licenses surface. Settings must expose a reachable entry that
/// opens Flutter's LicensePage and lists licenses from the
/// LicenseRegistry, so the MIT/BSD/Apache notice duties that
/// travel with the binary are satisfiable in the shipped app.
class _FakeBackend extends TabsBackend {
  _FakeBackend({super.sessionStore});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => {
        'isUnlimited': false,
        'isAdmin': false,
        'nickname': 'Tyson',
        'tag': '1234',
        'profile': const <String, dynamic>{},
        'insights': const [],
      };
}

SettingsStore _fakeStore(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

void main() {
  setUpAll(() {
    // Seed a deterministic license entry so the test proves the
    // page lists registry contents without depending on which
    // packages the test harness happens to bundle.
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(
        ['tabs_test_fixture_package'],
        'MIT License\n\nPermission is hereby granted, free of charge, '
            'to any person obtaining a copy of this software.',
      );
    });
  });

  testWidgets(
      'Settings footer opens the licenses page and lists licenses',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        backend: _FakeBackend(sessionStore: FakeSessionStore()),
        settingsStore: _fakeStore(<String, String>{}),
        notificationService: FakeReminderNotificationService(),
        urlLauncher: (uri) async => true,
      ),
    ));
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('open_source_licenses'));
    expect(entry, findsOneWidget);
    expect(find.text('Open Source Licenses'), findsOneWidget);

    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // The surface is Flutter's LicensePage, showing the app
    // identity and at least the seeded registry entry.
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Tabs'), findsWidgets);
    expect(find.textContaining('tabs_test_fixture_package'),
        findsWidgets);
  });
}
