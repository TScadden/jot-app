import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';

/// Standalone streak home-screen widget (Nov 18, 2026): the Dart
/// half of the contract — pushStreak's saves carry the EXISTING
/// payload keys verbatim and the streak drain now updates BOTH
/// providers (vitals untouched: its pushes still update only the
/// vitals provider) — plus source-level pins for the native half
/// (manifest receiver, provider info, verbatim keys in Kotlin).
/// The merged-APK manifest proof is a release-stage artifact
/// check, not a unit test.
void main() {
  DateTime at(int y, int m, int d, [int h = 12]) => DateTime(y, m, d, h);

  StreakState stateWith(Set<String> counted) => StreakState(
        seeded: true,
        seededCurrent: 0,
        seededBest: 68,
        countedDays: counted,
        lastEvaluatedDay: '2026-11-18',
        accrualMonth: '2026-11',
      );

  Set<String> daysThrough(int last) => {
        for (var d = 1; d <= last; d++)
          '2026-11-${d.toString().padLeft(2, '0')}',
      };

  group('WidgetSync streak drain — provider updates', () {
    late Map<String, Object?> saved;
    late int updates;

    setUp(() {
      saved = {};
      updates = 0;
      WidgetSync.debugSetBridge(
        save: (key, value) async {
          saved[key] = value;
        },
        update: () async {
          updates++;
        },
      );
    });

    tearDown(WidgetSync.debugResetBridge);

    test('pushStreak saves the payload keys verbatim and updates '
        'BOTH providers (vitals banner + standalone streak)', () async {
      await WidgetSync.pushStreak(
        stateWith(daysThrough(17)),
        signedIn: true,
        nickname: 'Tyson',
        now: at(2026, 11, 18, 9),
      );
      expect(saved[WidgetSync.keyStreakCount], '17');
      expect(saved[WidgetSync.keyStreakTodayDone], isFalse);
      expect(saved[WidgetSync.keyStreakPose], 'peek');
      expect(saved[WidgetSync.keyStreakName], 'Tyson');
      expect(saved[WidgetSync.keyStreakGreeting], 'Hey Tyson.');
      expect(
        saved[WidgetSync.keyStreakSubline],
        "Finish today's Daily Summary when you're ready to lock in day 18.",
      );
      // One update for VitalsWidgetProvider (its banner face) +
      // one for StreakWidgetProvider (the standalone widget).
      expect(updates, 2);
    });

    test('the qualified provider names are the shipped classes',
        () {
      expect(
        WidgetSync.qualifiedStreakProviderName,
        'com.notel.notel.playground.flutter.StreakWidgetProvider',
      );
      expect(WidgetSync.streakProviderName, 'StreakWidgetProvider');
      // Vitals naming untouched.
      expect(
        WidgetSync.qualifiedProviderName,
        'com.notel.notel.playground.flutter.VitalsWidgetProvider',
      );
    });

    test('signed-out streak payload carries no numbers', () {
      final p = WidgetSync.buildStreakPayload(
        stateWith(daysThrough(18)),
        signedIn: false,
        nickname: 'Tyson',
        now: at(2026, 11, 18, 9),
      );
      expect(p.signedIn, isFalse);
      expect(p.count, '');
      expect(p.greeting, '');
      expect(p.subline, '');
    });
  });

  group('native streak widget — source pins', () {
    String read(String path) => File(path).readAsStringSync();
    const androidMain = 'android/app/src/main';

    test('manifest registers StreakWidgetProvider with the '
        'appwidget meta-data, vitals receiver intact', () {
      final manifest = read('$androidMain/AndroidManifest.xml');
      expect(manifest, contains('android:name=".StreakWidgetProvider"'));
      expect(manifest, contains('@xml/streak_widget_info'));
      expect(manifest, contains('android:name=".VitalsWidgetProvider"'));
      expect(manifest, contains('@xml/vitals_widget_info'));
    });

    test('streak_widget_info: wide 4x2, resizable, 30-min rollover '
        'period (platform minimum)', () {
      final info = read('$androidMain/res/xml/streak_widget_info.xml');
      expect(info, contains('android:targetCellWidth="4"'));
      expect(info, contains('android:targetCellHeight="2"'));
      expect(info, contains('android:resizeMode="horizontal|vertical"'));
      expect(info, contains('android:updatePeriodMillis="1800000"'));
      expect(info, contains('@layout/streak_widget'));
    });

    test('the Kotlin provider reads the EXISTING payload keys '
        'verbatim and both peek bitmaps', () {
      final kt = read(
        '$androidMain/kotlin/com/notel/notel/playground/flutter/'
        'StreakWidgetProvider.kt',
      );
      for (final key in [
        'widget_signed_in',
        'widget_streak_count',
        'widget_streak_today_done',
        'widget_streak_pose',
        'widget_streak_greeting',
        'widget_streak_subline',
      ]) {
        expect(kt, contains(key), reason: 'missing payload key $key');
      }
      expect(kt, contains('R.drawable.bandit_peek'));
      expect(kt, contains('R.drawable.bandit_peek_cheer'));
      expect(kt, contains('R.drawable.ic_widget_flame_grey'));
    });

    test('layouts: values face binds every payload view; the '
        'signed-out face has no number views', () {
      final values = read('$androidMain/res/layout/streak_widget.xml');
      for (final id in [
        'streak_widget_count',
        'streak_widget_flame',
        'streak_widget_greeting',
        'streak_widget_subline',
        'streak_widget_bandit',
      ]) {
        expect(values, contains('@+id/$id'), reason: 'missing $id');
      }
      final signedOut =
          read('$androidMain/res/layout/streak_widget_signed_out.xml');
      expect(signedOut, isNot(contains('streak_widget_count')));
      expect(signedOut, contains('Open Tabs to sign in'));
    });

    test('the pre-rendered peek bitmaps exist in drawable-nodpi',
        () {
      for (final name in [
        'bandit_peek.png',
        'bandit_peek_cheer.png',
        'ic_widget_flame_grey.png',
      ]) {
        final f = File('$androidMain/res/drawable-nodpi/$name');
        expect(f.existsSync(), isTrue, reason: '$name missing');
        expect(f.lengthSync(), greaterThan(0));
      }
    });
  });
}
