import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Round 30 Step 3 — User Profile editors (medications, conditions),
/// Health Connect Auto-Fill, and the Physician Protocols / Knowledge
/// Base text editors. All writes are profile pushes with native's
/// exact shapes (SyncProfileRequest fields, JotApi.kt:248-249).
class FakeHc extends HealthConnectService {
  double? weightKg;
  double? heightCm;

  @override
  Future<double?> readLatestWeightKg() async => weightKg;

  @override
  Future<double?> readLatestHeightCm() async => heightCm;
}

SettingsStore store() => SettingsStore.withStorage(
      read: (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );

Future<void> pumpProfile(
  WidgetTester tester, {
  required r29.FakeSettingsBackend backend,
  FakeHc? hc,
}) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: store(),
        notificationService: FakeReminderNotificationService(),
        healthConnectService: hc,
        urlLauncher: (uri) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> medPull() => r29.pull(profile: {
      'medications': jsonEncode([
        {
          'id': 'm1',
          'name': 'Ivabradine',
          'startDate': 'Sep 2026',
          'endDate': 'Present',
          'isPresent': true,
          'dose': 'As prescribed',
          'frequency': 'Daily',
          'updatedAt': 1,
          'isDeleted': false,
        },
      ]),
      'conditions': jsonEncode(['POTS (Postural Orthostatic Tachycardia Syndrome)']),
    });

void main() {
  group('Medications editor', () {
    testWidgets('rows show the native date-range line', (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = medPull();
      await pumpProfile(tester, backend: backend);
      expect(find.text('Ivabradine'), findsOneWidget);
      expect(find.text('Started: Sep 2026 • Present'), findsOneWidget);
    });

    testWidgets('delete pushes the full list without the entry',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = medPull();
      await pumpProfile(tester, backend: backend);
      await tester.tap(find.byKey(const ValueKey('delete_medication_m1')));
      await tester.pumpAndSettle();
      final push = backend.profilePushes.single;
      expect(jsonDecode(push['medications'] as String), isEmpty);
      expect(find.text('Ivabradine'), findsNothing);
    });

    testWidgets('add pushes a native-shaped medication', (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = medPull();
      await pumpProfile(tester, backend: backend);
      await tester.tap(find.byKey(const ValueKey('add_medication_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('medication_name_field')),
          'Pyridostigmine');
      await tester.enterText(
          find.byKey(const ValueKey('medication_start_field')), 'Oct 2026');
      await tester.tap(find.byKey(const ValueKey('medication_add')));
      await tester.pumpAndSettle();
      final meds = jsonDecode(
          backend.profilePushes.single['medications'] as String) as List;
      expect(meds.length, 2);
      final added = meds.last as Map<String, dynamic>;
      expect(added['name'], 'Pyridostigmine');
      expect(added['startDate'], 'Oct 2026');
      expect(added['endDate'], 'Present');
      expect(added['isPresent'], isTrue);
      expect(added['dose'], 'As prescribed');
      expect(added['frequency'], 'Daily');
      expect(added['isDeleted'], isFalse);
    });
  });

  group('Conditions editor', () {
    testWidgets('chip delete pushes the string-list without it',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = medPull();
      await pumpProfile(tester, backend: backend);
      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pumpAndSettle();
      expect(
          jsonDecode(backend.profilePushes.single['conditions'] as String),
          isEmpty);
    });

    testWidgets('catalog dialog adds a condition with a string push',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      await pumpProfile(tester, backend: backend);
      await tester.tap(find.byKey(const ValueKey('add_condition_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('condition_search_field')), 'hyperadrenergic');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey('condition_option_Hyperadrenergic POTS')));
      await tester.pumpAndSettle();
      expect(
          jsonDecode(backend.profilePushes.single['conditions'] as String),
          ['Hyperadrenergic POTS']);
      await tester.tap(find.byKey(const ValueKey('condition_done')));
      await tester.pumpAndSettle();
      expect(find.text('Hyperadrenergic POTS'), findsWidgets);
    });
  });

  group('Auto-Fill from Health Connect', () {
    testWidgets('latest HC weight/height push rounded like native',
        (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      // 70.3 kg = 154.98 lb → native rounds to 155 lb; 177.8 cm is
      // exactly 70 in, no rounding change.
      final hc = FakeHc()
        ..weightKg = 70.3
        ..heightCm = 177.8;
      await pumpProfile(tester, backend: backend, hc: hc);
      await tester.tap(find.byKey(const ValueKey('auto_fill_button')));
      await tester.pumpAndSettle();
      final push = backend.profilePushes.single;
      expect((push['weightKg'] as double), closeTo(155 / 2.20462, 0.001));
      expect((push['heightCm'] as double), closeTo(177.8, 0.001));
      expect(find.text('Profile updated from Health Connect.'),
          findsOneWidget);
    });

    testWidgets('no HC records: honest message, no push', (tester) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      final hc = FakeHc();
      await pumpProfile(tester, backend: backend, hc: hc);
      await tester.tap(find.byKey(const ValueKey('auto_fill_button')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes, isEmpty);
      expect(find.text('No weight or height found in Health Connect yet.'),
          findsOneWidget);
    });
  });

  group('Protocols + knowledge editors', () {
    Future<void> pumpAi(WidgetTester tester,
        r29.FakeSettingsBackend backend) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: store(),
            notificationService: FakeReminderNotificationService(),
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI & Clinical Advocate'));
      await tester.pumpAndSettle();
    }

    testWidgets('add protocol prepends the native entry format',
        (tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(profile: {
          'userContext': 'my doctor said to track standing tolerance',
          'professionalUpdates': 'From the Doctor (Sep 01, 2026): old note',
        });
      await pumpAi(tester, backend);
      await tester.tap(find.byKey(const ValueKey('add_protocol_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('protocol_note_field')),
          'Increase salt with meals');
      await tester.tap(find.byKey(const ValueKey('protocol_save')));
      await tester.pumpAndSettle();
      final pushed =
          backend.profilePushes.single['professionalUpdates'] as String;
      expect(pushed, startsWith('From the Doctor ('));
      expect(pushed, contains('): Increase salt with meals\n\n'));
      expect(pushed, endsWith('old note'));
    });

    testWidgets('delete protocol + edit fact push joined strings',
        (tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(profile: {
          'userContext': 'doctor follow ups',
          'professionalUpdates': 'u1\n\nu2',
          'knowledgeBase': 'fact one\n\nfact two',
        });
      await pumpAi(tester, backend);
      // Round 64 — Past Updates starts collapsed; expand it first.
      await tester.tap(find.byKey(const ValueKey('past_updates_header')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete_protocol_0')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes.last['professionalUpdates'], 'u2');
      await tester.tap(find.byKey(const ValueKey('edit_fact_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('fact_edit_field')), 'fact 2 revised');
      await tester.tap(find.byKey(const ValueKey('fact_edit_save')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes.last['knowledgeBase'],
          'fact one\n\nfact 2 revised');
    });
  });
}
