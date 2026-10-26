import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/first_run_sync.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/migration_bundle.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';

import 'test_helpers.dart';

/// TAKEOVER Phase 4 — migration bridge tests (Ivy P0 spec):
/// - Round trip on the REAL store formats: export from a populated
///   fake Lab store → import into a fresh fake production store →
///   every value byte-identical, and the REAL CoachMemoryStore
///   loads the imported blob with the same facts.
/// - The owner-wipe trap: import refuses an owner mismatch and
///   writes nothing; the imported blob loads under its owner.
/// - The Today Plan same-day rule, the sync-stamp exclusion, and
///   the never-exported keys (tokens, caches).
/// - The first-run reminder resync firing exactly once, retrying
///   after failure, and running end-to-end off a fresh pull.

/// In-memory [SecureStore] over a plain map — the same map shape
/// every store test in this repo uses.
class MemorySecureStore implements SecureStore {
  final Map<String, String> map;
  MemorySecureStore(this.map);

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

CoachMemoryStore coachStoreOver(Map<String, String> map) =>
    CoachMemoryStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

KnowledgeExtractionStore knowledgeStoreOver(Map<String, String> map) =>
    KnowledgeExtractionStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

/// Lets fire-and-forget persists (recordFact's background write)
/// land before assertions read the fake disk.
Future<void> flushBackgroundWrites() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<String> diskFactTexts(Map<String, String> map) {
  final decoded =
      jsonDecode(map[MigrationBundleService.coachMemoryKey]!)
          as Map<String, dynamic>;
  return [
    for (final f in decoded['facts'] as List)
      (f as Map)['text'] as String,
  ];
}

const founder = 'founder@example.com';

/// A populated Lab store in the REAL formats (Ivy P0 §1/§4/§5):
/// coach facts written by the real store, the R70 history blob
/// shape, plain-string settings, the real food encyclopedia shape,
/// the tile-order JSON array, the knowledge blob (owner field named
/// `owner`, §1.4), and a same-day Today Plan blob. Decoys that must
/// NEVER be exported sit alongside.
Future<Map<String, String>> populatedLabStore(DateTime today) async {
  final map = <String, String>{};
  final coach = coachStoreOver(map);
  await coach.addFact(
    text: 'Prefers morning check-ins',
    source: 'chat',
    email: founder,
    now: DateTime.fromMillisecondsSinceEpoch(1760000000000),
  );
  await coach.addFact(
    text: 'Knee bothers him on stairs',
    source: 'chat',
    email: founder,
    now: DateTime.fromMillisecondsSinceEpoch(1760000100000),
  );
  // The R70 history blob (health_history_store.dart shape): the
  // accumulated union — HC-window days + CSV-filled gaps, a real 0
  // spikeCount, a double HRV.
  map[MigrationBundleService.healthHistoryKey] = jsonEncode({
    'ownerEmail': founder,
    'lastCaptureMs': 1760000200000,
    'days': {
      '2025-11-02': {
        'restingHrBpm': 61,
        'sleepMinutes': 402,
        'deepSleepMinutes': 71,
        'spikeCount': 3,
        'caloriesKcal': 1790,
        'hrvRmssdMs': 38.25,
      },
      '2026-01-05': {'restingHrBpm': 58, 'spikeCount': 0},
    },
  });
  map['settings_show_nav_labels'] = 'false';
  map['settings_theme_mode'] = 'LIGHT';
  map['settings_user_context_hidden'] = 'false';
  map['settings_checkin_reminder_enabled'] = 'false';
  map['settings_google_calendar_connected'] = 'true';
  map['settings_google_calendar_email'] = founder;
  map['settings_google_account_connected'] = 'true';
  map['settings_google_account_email'] = founder;
  map['progress_report_last_type'] = 'clinical';
  map['progress_report_last_range_30d'] = 'false';
  map['progress_report_last_export_ms'] = '1760000300000';
  map['progress_report_appointment_date'] = '2026-11-09';
  map['progress_report_appointment_type'] = 'health';
  // Bookkeeping — must stay behind.
  map['settings_last_sync_time'] = '1760000400000';
  map[MigrationBundleService.foodHistoryKey] = encodeFoodEncyclopedia({
    'peanuts': FoodCheckResult(
      foodName: 'peanuts',
      levels: [
        FoodTopicLevel(
            topicName: 'Histamine', level: 'High', reasoning: 'fixture'),
      ],
    ),
  });
  map[MigrationBundleService.toolsTileOrderKey] =
      jsonEncode(['sleep', 'habits', 'food']);
  map[MigrationBundleService.knowledgeExtractedKey] = jsonEncode({
    'owner': founder,
    'texts': {'doc-1': 'Extracted cardiology letter text.'},
    'failed': ['doc-2'],
  });
  map[MigrationBundleService.todayPlanKey] = jsonEncode({
    'ownerEmail': founder,
    'date': MigrationBundleService.dateStrOf(today),
    'completedReminderIds': [7],
    'medActions': {'medA|MORNING': 'SNOOZED'},
  });
  // Decoys: credentials + render-seed caches never travel.
  map['auth_token'] = 'secret-access';
  map['refresh_token'] = 'secret-refresh';
  map['user_email'] = founder;
  map['home_data_cache_v1'] = '{"ownerEmail":"$founder"}';
  map['hc_granted_permissions'] = 'android.permission.health.READ_SLEEP';
  return map;
}

void main() {
  // Oct 26, 2026 perf package: the sync-pull cache is STATIC and
  // session-keyed, and the resync cases below reuse the token 'tok'
  // — reset between cases so one case's cached pull body cannot be
  // served to the next case's fresh fake server.
  setUp(TabsBackend.debugResetSharedCaches);
  final fixedNow = DateTime(2026, 10, 16, 12, 30);

  group('export', () {
    test('envelope shape, canonical order, verbatim values, exclusions',
        () async {
      final lab = await populatedLabStore(fixedNow);
      final service = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      final json = await service.buildExportJson(ownerEmail: ' $founder ');
      // Session email is normalized into the envelope.
      final env = jsonDecode(json) as Map<String, dynamic>;
      expect(env['bundle'], 'tabs-lab-migration');
      expect(env['version'], 1);
      expect(env['exportedAt'], fixedNow.millisecondsSinceEpoch);
      expect(env['ownerEmail'], founder);
      final stores = env['stores'] as Map<String, dynamic>;
      // Canonical import order (Ivy §7), exactly the present keys.
      expect(stores.keys.toList(), [
        MigrationBundleService.coachMemoryKey,
        MigrationBundleService.healthHistoryKey,
        ...MigrationBundleService.settingsKeys,
        MigrationBundleService.foodHistoryKey,
        MigrationBundleService.toolsTileOrderKey,
        MigrationBundleService.knowledgeExtractedKey,
        MigrationBundleService.todayPlanKey,
      ]);
      // Verbatim: every exported value IS the stored string.
      for (final e in stores.entries) {
        expect(e.value, lab[e.key], reason: 'verbatim: ${e.key}');
      }
      // Exclusions.
      expect(stores.containsKey('settings_last_sync_time'), isFalse);
      expect(stores.containsKey('auth_token'), isFalse);
      expect(stores.containsKey('refresh_token'), isFalse);
      expect(stores.containsKey('user_email'), isFalse);
      expect(stores.containsKey('home_data_cache_v1'), isFalse);
      expect(stores.containsKey('hc_granted_permissions'), isFalse);
    });

    test('today plan from another day is left behind', () async {
      final lab = await populatedLabStore(fixedNow);
      lab[MigrationBundleService.todayPlanKey] = jsonEncode({
        'ownerEmail': founder,
        'date': '2026-10-15',
        'completedReminderIds': [7],
        'medActions': <String, String>{},
      });
      final service = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      final env = jsonDecode(
          await service.buildExportJson(ownerEmail: founder))
          as Map<String, dynamic>;
      final stores = env['stores'] as Map<String, dynamic>;
      expect(stores.containsKey(MigrationBundleService.todayPlanKey),
          isFalse);
      // Everything else still exports.
      expect(stores.containsKey(MigrationBundleService.coachMemoryKey),
          isTrue);
    });

    test('history store is read-if-present (absent in this base)',
        () async {
      final lab = await populatedLabStore(fixedNow);
      lab.remove(MigrationBundleService.healthHistoryKey);
      final service = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      final env = jsonDecode(
          await service.buildExportJson(ownerEmail: founder))
          as Map<String, dynamic>;
      final stores = env['stores'] as Map<String, dynamic>;
      expect(
          stores.containsKey(MigrationBundleService.healthHistoryKey),
          isFalse);
    });

    test('a hand-edited coach blob with an unknown key travels verbatim',
        () async {
      final lab = await populatedLabStore(fixedNow);
      // Unknown top-level keys are dropped by the store's NEXT
      // persist (Ivy §4) — the BRIDGE must not be what drops them.
      final weird =
          '{"ownerEmail":"$founder","legacyNote":"keep-me","facts":[]}';
      lab[MigrationBundleService.coachMemoryKey] = weird;
      final service = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      final env = jsonDecode(
          await service.buildExportJson(ownerEmail: founder))
          as Map<String, dynamic>;
      expect((env['stores'] as Map)[MigrationBundleService.coachMemoryKey],
          weird);
    });

    test('no account → NO_ACCOUNT; empty store → NOTHING_TO_EXPORT',
        () async {
      final lab = await populatedLabStore(fixedNow);
      final service = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      await expectLater(
        service.buildExportJson(ownerEmail: null),
        throwsA(isA<MigrationException>()
            .having((e) => e.code, 'code', 'NO_ACCOUNT')),
      );
      final empty = MigrationBundleService(
        store: MemorySecureStore(<String, String>{}),
        now: () => fixedNow,
      );
      await expectLater(
        empty.buildExportJson(ownerEmail: founder),
        throwsA(isA<MigrationException>()
            .having((e) => e.code, 'code', 'NOTHING_TO_EXPORT')),
      );
    });
  });

  group('round trip', () {
    test('export → import → identical stores, coach loads identically',
        () async {
      final lab = await populatedLabStore(fixedNow);
      final labCoachFacts = await coachStoreOver(lab).load(founder);
      final exporter = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      final json = await exporter.buildExportJson(ownerEmail: founder);

      final prod = <String, String>{};
      final importer = MigrationBundleService(
        store: MemorySecureStore(prod),
        now: () => fixedNow,
      );
      // Signed in with different case/whitespace — same account.
      final result = await importer.importBundleJson(
        json,
        currentEmail: ' Founder@Example.COM ',
      );
      expect(result.ownerEmail, founder);
      expect(result.exportedAt, fixedNow.millisecondsSinceEpoch);
      expect(result.importedKeys, [
        MigrationBundleService.coachMemoryKey,
        MigrationBundleService.healthHistoryKey,
        ...MigrationBundleService.settingsKeys,
        MigrationBundleService.foodHistoryKey,
        MigrationBundleService.toolsTileOrderKey,
        MigrationBundleService.knowledgeExtractedKey,
        MigrationBundleService.todayPlanKey,
      ]);
      // Byte-identical landing for every key.
      for (final key in result.importedKeys) {
        expect(prod[key], lab[key], reason: 'round trip: $key');
      }
      expect(prod.containsKey('settings_last_sync_time'), isFalse);
      expect(prod.containsKey('auth_token'), isFalse);
      // The REAL coach store loads the imported blob: same facts,
      // same order, same timestamps — and the blob survives the
      // load (no owner wipe under the right account).
      final prodCoach = coachStoreOver(prod);
      final facts = await prodCoach.load(founder);
      expect(facts, labCoachFacts);
      expect(facts.length, 2);
      expect(facts.first.text, 'Knee bothers him on stairs');
      expect(prod.containsKey(MigrationBundleService.coachMemoryKey),
          isTrue);
      // Settings read back through the REAL SettingsStore accessors
      // that exist in this base.
      final settings = SettingsStore.withStorage(
        read: (k) async => prod[k],
        write: (k, v) async => prod[k] = v,
        delete: (k) async => prod.remove(k),
      );
      expect(await settings.getShowNavLabels(), isFalse);
      expect(await settings.getThemeMode(), 'LIGHT');
      expect(await settings.getCheckInReminderEnabled(), isFalse);
      expect(await settings.getGoogleCalendarEmail(), founder);
      // Food history decodes through the REAL decoder.
      final foods =
          decodeFoodEncyclopedia(prod[MigrationBundleService.foodHistoryKey]);
      expect(foods.keys, ['peanuts']);
    });

    test('owner-wipe trap: a different account load wipes — import '
        'ordering is what prevents it', () async {
      // Documents the trap the import order defends against: had
      // anything loaded coach memory for the NEW account before the
      // imported blob landed (or had import stamped the wrong
      // owner), this wipe is what would have eaten the facts.
      final prod = <String, String>{};
      final lab = await populatedLabStore(fixedNow);
      final exporter = MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      );
      final json = await exporter.buildExportJson(ownerEmail: founder);
      await MigrationBundleService(store: MemorySecureStore(prod))
          .importBundleJson(json, currentEmail: founder);
      final facts = await coachStoreOver(prod).load('other@example.com');
      expect(facts, isEmpty);
      expect(prod.containsKey(MigrationBundleService.coachMemoryKey),
          isFalse);
    });
  });

  group('import validation (writes nothing on any refusal)', () {
    Future<void> expectRefusal(
      String json,
      String? currentEmail,
      String code,
    ) async {
      final prod = <String, String>{};
      final importer = MigrationBundleService(
        store: MemorySecureStore(prod),
        now: () => fixedNow,
      );
      await expectLater(
        importer.importBundleJson(json, currentEmail: currentEmail),
        throwsA(isA<MigrationException>()
            .having((e) => e.code, 'code', code)),
      );
      expect(prod, isEmpty, reason: 'a refusal must write nothing');
    }

    test('owner mismatch refuses with a plain explanation', () async {
      final lab = await populatedLabStore(fixedNow);
      final json = await MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      ).buildExportJson(ownerEmail: founder);
      final prod = <String, String>{};
      try {
        await MigrationBundleService(store: MemorySecureStore(prod))
            .importBundleJson(json, currentEmail: 'other@example.com');
        fail('expected an OWNER_MISMATCH refusal');
      } on MigrationException catch (e) {
        expect(e.code, 'OWNER_MISMATCH');
        expect(e.message, contains(founder));
        expect(e.message, contains('other@example.com'));
        expect(e.message, contains('Nothing was imported.'));
      }
      expect(prod, isEmpty);
    });

    test('not signed in refuses', () async {
      final lab = await populatedLabStore(fixedNow);
      final json = await MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      ).buildExportJson(ownerEmail: founder);
      await expectRefusal(json, null, 'NOT_SIGNED_IN');
    });

    test('garbage, wrong bundle, wrong version, damaged entry refuse',
        () async {
      await expectRefusal('not json at all', founder, 'INVALID_FILE');
      await expectRefusal(
        jsonEncode({'bundle': 'something-else', 'version': 1, 'stores': {}}),
        founder,
        'INVALID_FILE',
      );
      await expectRefusal(
        jsonEncode({
          'bundle': 'tabs-lab-migration',
          'version': 2,
          'ownerEmail': founder,
          'stores': {MigrationBundleService.coachMemoryKey: '{}'},
        }),
        founder,
        'UNSUPPORTED_VERSION',
      );
      await expectRefusal(
        jsonEncode({
          'bundle': 'tabs-lab-migration',
          'version': 1,
          'ownerEmail': founder,
          'stores': {MigrationBundleService.coachMemoryKey: 42},
        }),
        founder,
        'INVALID_FILE',
      );
      await expectRefusal(
        jsonEncode({
          'bundle': 'tabs-lab-migration',
          'version': 1,
          'ownerEmail': founder,
          'stores': {'unknown_future_key': 'x'},
        }),
        founder,
        'NOTHING_TO_IMPORT',
      );
    });

    test('unknown store keys are ignored, known keys still import',
        () async {
      final prod = <String, String>{};
      final json = jsonEncode({
        'bundle': 'tabs-lab-migration',
        'version': 1,
        'exportedAt': 1,
        'ownerEmail': founder,
        'stores': {
          'unknown_future_key': 'x',
          MigrationBundleService.toolsTileOrderKey: '["habits"]',
        },
      });
      final result = await MigrationBundleService(
        store: MemorySecureStore(prod),
      ).importBundleJson(json, currentEmail: founder);
      expect(result.importedKeys,
          [MigrationBundleService.toolsTileOrderKey]);
      expect(prod[MigrationBundleService.toolsTileOrderKey], '["habits"]');
      expect(prod.containsKey('unknown_future_key'), isFalse);
    });
  });

  group('stale-mirror regression (Vera BLOCK)', () {
    // Vera's template, reproduced exactly: the store's mirror is
    // warmed for the signed-in account BEFORE the import runs
    // (user opened Coach/History first), then a same-owner bundle
    // is imported in the SAME session. Before the fix, load()
    // early-returned the warm empty mirror forever, and the next
    // persist overwrote the imported blob with it.
    Future<String> founderBundle() async {
      final lab = await populatedLabStore(fixedNow);
      return MigrationBundleService(
        store: MemorySecureStore(lab),
        now: () => fixedNow,
      ).buildExportJson(ownerEmail: founder);
    }

    test('invalidateMirror is mirror-only: the disk blob is '
        'untouched and the next load re-reads it', () async {
      final prod = <String, String>{};
      final coach = coachStoreOver(prod);
      await coach.addFact(
        text: 'Existing fact',
        source: 'chat',
        email: founder,
        now: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      );
      final rawBefore = prod[MigrationBundleService.coachMemoryKey];
      expect(await coach.load(founder), hasLength(1)); // mirror warm
      coach.invalidateMirror();
      // Disk: byte-identical, key not deleted.
      expect(prod[MigrationBundleService.coachMemoryKey], rawBefore);
      // Mirror: cold again (sync reads serve nothing)…
      expect(coach.cachedFacts, isEmpty);
      expect(coach.cachedFactsFor(founder), isEmpty);
      // …and the next load re-reads the surviving blob.
      final facts = await coach.load(founder);
      expect(facts.map((f) => f.text), ['Existing fact']);
    });

    test('pre-warmed coach mirror: import lands in the same '
        'session and recordFact/addFact persists preserve the '
        'imported facts', () async {
      final prod = <String, String>{};
      final coach = coachStoreOver(prod);
      // 1. Pre-warm: production account signed in, Coach/History
      // visited — mirror warm, EMPTY (nothing on disk yet).
      expect(await coach.load(founder), isEmpty);
      expect(coach.cachedFactsFor(founder), isEmpty);
      // 2. Import a valid same-owner bundle (Settings action).
      final json = await founderBundle();
      final result = await MigrationBundleService(
        store: MemorySecureStore(prod),
        now: () => fixedNow,
        coachStore: coach,
      ).importBundleJson(json, currentEmail: founder);
      expect(result.importedKeys,
          contains(MigrationBundleService.coachMemoryKey));
      // 3. SAME session: load() returns the imported facts.
      final facts = await coach.load(founder);
      expect(facts.map((f) => f.text), [
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]);
      expect(coach.cachedFactsFor(founder), facts);
      // 4a. A recordFact persist (the background, mirror-merged
      // path) preserves the imported facts on disk.
      coach.recordFact(
        text: 'Post-import fact',
        source: 'chat',
        email: founder,
        now: DateTime.fromMillisecondsSinceEpoch(1760000200000),
      );
      await flushBackgroundWrites();
      expect(diskFactTexts(prod), [
        'Post-import fact',
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]);
      // 4b. An addFact persist also preserves them.
      final afterAdd = await coach.addFact(
        text: 'Second post-import fact',
        source: 'chat',
        email: founder,
        now: DateTime.fromMillisecondsSinceEpoch(1760000300000),
      );
      expect(afterAdd.map((f) => f.text), [
        'Second post-import fact',
        'Post-import fact',
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]);
      expect(diskFactTexts(prod), afterAdd.map((f) => f.text).toList());
    });

    // Vera probe B (round-2): the interleaving the pre-warm tests
    // above cannot reach — the mutator's FIRST load is still in
    // flight on a gated read when the import lands. The gated read
    // then releases with the pre-import value (null: the disk was
    // empty), and the straddling load hands back its epoch-mismatch
    // discard — the canonical empty list, identical() to the fresh
    // mirror invalidateMirror() just installed. Before the
    // epoch-before-load fix, addFact captured the NEW epoch after
    // the load, the identical() guard passed on that empty base,
    // and its persist overwrote the imported facts on disk.
    test('probe B: a gated in-flight addFact load straddling the '
        'import reloads and merges on top of the imported facts',
        () async {
      final prod = <String, String>{};
      final gate = Completer<void>();
      var reads = 0;
      final coach = CoachMemoryStore.withStorage(
        read: (k) async {
          reads++;
          if (reads == 1) {
            await gate.future;
            return null; // the pre-import value: disk was empty
          }
          return prod[k];
        },
        write: (k, v) async => prod[k] = v,
        delete: (k) async => prod.remove(k),
      );
      // 1. The first addFact starts; its internal load is IN
      // FLIGHT on the gated read.
      final racing = coach.addFact(
        text: 'Race fact',
        source: 'chat',
        email: founder,
        now: DateTime.fromMillisecondsSinceEpoch(1760000500000),
      );
      await flushBackgroundWrites();
      expect(reads, 1);
      // 2. The import runs to completion mid-flight: the imported
      // blob lands on disk and invalidateMirror() fires.
      final json = await founderBundle();
      await MigrationBundleService(
        store: MemorySecureStore(prod),
        now: () => fixedNow,
        coachStore: coach,
      ).importBundleJson(json, currentEmail: founder);
      expect(diskFactTexts(prod), [
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]);
      // 3. The gate releases with the stale pre-import value.
      gate.complete();
      final result = await racing;
      // Semantics: reload-and-reapply — the imported facts
      // survive on disk AND the racing fact is merged on top of
      // them. Imported-data loss is the failure this guards.
      expect(result.map((f) => f.text), [
        'Race fact',
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]);
      expect(diskFactTexts(prod), result.map((f) => f.text).toList());
    });

    test('probe B (deleteAt): a gated in-flight deleteAt load '
        'straddling the import re-applies on the imported facts',
        () async {
      final prod = <String, String>{};
      final gate = Completer<void>();
      var reads = 0;
      final coach = CoachMemoryStore.withStorage(
        read: (k) async {
          reads++;
          if (reads == 1) {
            await gate.future;
            return null; // the pre-import value: disk was empty
          }
          return prod[k];
        },
        write: (k, v) async => prod[k] = v,
        delete: (k) async => prod.remove(k),
      );
      // Same interleaving as probe B, through deleteAt.
      final racing = coach.deleteAt(0, founder);
      await flushBackgroundWrites();
      expect(reads, 1);
      final json = await founderBundle();
      await MigrationBundleService(
        store: MemorySecureStore(prod),
        now: () => fixedNow,
        coachStore: coach,
      ).importBundleJson(json, currentEmail: founder);
      gate.complete();
      final result = await racing;
      // The delete re-applies on the FRESH base: the newest
      // imported fact is removed and the other survives — the
      // stale empty base neither no-ops the delete nor persists
      // emptiness over the import.
      expect(result.map((f) => f.text), ['Prefers morning check-ins']);
      expect(diskFactTexts(prod), ['Prefers morning check-ins']);
    });

    test('production wiring: a default-constructed service '
        'invalidates the CoachMemoryStore singleton', () async {
      final prod = <String, String>{};
      final singleton = CoachMemoryStore.instance;
      singleton.debugSetStore(
        read: (k) async => prod[k],
        write: (k, v) async => prod[k] = v,
        delete: (k) async => prod.remove(k),
      );
      await singleton.clear(); // cold, deterministic start
      // Warm the singleton's mirror (signed in, Coach visited).
      expect(await singleton.load(founder), isEmpty);
      // Settings constructs the service with defaults only.
      final json = await founderBundle();
      await MigrationBundleService(store: MemorySecureStore(prod))
          .importBundleJson(json, currentEmail: founder);
      final facts = await singleton.load(founder);
      expect(facts.map((f) => f.text), [
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]);
      final afterAdd = await singleton.addFact(
        text: 'Singleton post-import fact',
        source: 'chat',
        email: founder,
        now: DateTime.fromMillisecondsSinceEpoch(1760000400000),
      );
      expect(afterAdd.map((f) => f.text), containsAll([
        'Singleton post-import fact',
        'Knee bothers him on stairs',
        'Prefers morning check-ins',
      ]));
      expect(diskFactTexts(prod),
          afterAdd.map((f) => f.text).toList());
      await singleton.clear();
    });

    test('a refused import does NOT invalidate the warmed mirror',
        () async {
      final prod = <String, String>{};
      final coach = coachStoreOver(prod);
      await coach.addFact(
        text: 'Existing fact',
        source: 'chat',
        email: founder,
        now: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      );
      expect(await coach.load(founder), hasLength(1)); // mirror warm
      final json = await founderBundle();
      await expectLater(
        MigrationBundleService(
          store: MemorySecureStore(prod),
          coachStore: coach,
        ).importBundleJson(json, currentEmail: 'other@example.com'),
        throwsA(isA<MigrationException>()
            .having((e) => e.code, 'code', 'OWNER_MISMATCH')),
      );
      // Mirror untouched: the pre-import facts are still served.
      expect(coach.cachedFactsFor(founder).map((f) => f.text),
          ['Existing fact']);
    });

    test('pre-warmed knowledge mirror: import lands in the same '
        'session and a saveText persist preserves the imported '
        'texts', () async {
      final prod = <String, String>{};
      final knowledge = knowledgeStoreOver(prod);
      // Warm the mirror for the account (Settings/Coach visited):
      // loaded, empty.
      await knowledge.load(founder);
      expect(knowledge.textFor('doc-1'), isNull);
      final json = await founderBundle();
      await MigrationBundleService(
        store: MemorySecureStore(prod),
        now: () => fixedNow,
        knowledgeStore: knowledge,
      ).importBundleJson(json, currentEmail: founder);
      // Same session: the imported extracted text now loads.
      await knowledge.load(founder);
      expect(knowledge.textFor('doc-1'),
          'Extracted cardiology letter text.');
      const doc1 = KnowledgeDocumentMeta(
        id: 'doc-1',
        name: 'letter.pdf',
        mimeType: 'application/pdf',
        createdAt: 1,
      );
      expect(knowledge.joinedCachedTextsFor(founder, [doc1]),
          'Extracted cardiology letter text.');
      // A whole-mirror persist preserves the imported text.
      await knowledge.saveText('doc-9', 'Brand new extraction.');
      final decoded = jsonDecode(
              prod[MigrationBundleService.knowledgeExtractedKey]!)
          as Map<String, dynamic>;
      final texts = decoded['texts'] as Map;
      expect(texts['doc-1'], 'Extracted cardiology letter text.');
      expect(texts['doc-9'], 'Brand new extraction.');
    });
  });

  group('first-run reminder resync', () {
    test('fires exactly once across calls and instances', () async {
      final map = <String, String>{};
      var runs = 0;
      Future<void> resync() async => runs++;
      final gate = FirstRunReminderResync(
        store: MemorySecureStore(map),
        resync: resync,
      );
      expect(await gate.runOnce(), isTrue);
      expect(await gate.runOnce(), isFalse);
      // A new instance (next launch) over the same store: still done.
      final nextLaunch = FirstRunReminderResync(
        store: MemorySecureStore(map),
        resync: resync,
      );
      expect(await nextLaunch.runOnce(), isFalse);
      expect(runs, 1);
      expect(map[FirstRunReminderResync.doneKey],
          FirstRunReminderResync.doneValue);
    });

    test('a failed resync stamps nothing and retries next time',
        () async {
      final map = <String, String>{};
      var attempts = 0;
      final gate = FirstRunReminderResync(
        store: MemorySecureStore(map),
        resync: () async {
          attempts++;
          if (attempts == 1) {
            throw const FirstRunSyncException('PULL_FAILED');
          }
        },
      );
      await expectLater(gate.runOnce(), throwsA(isA<FirstRunSyncException>()));
      expect(map.containsKey(FirstRunReminderResync.doneKey), isFalse);
      expect(await gate.runOnce(), isTrue);
      expect(attempts, 2);
    });

    test('performReminderResync schedules toggles, counters, reminders',
        () async {
      final futureMs = DateTime(2100, 1, 1).millisecondsSinceEpoch;
      final profile = <String, dynamic>{
        'habitReminderEnabled': true,
        'projectReminderEnabled': false,
        'eventReminderEnabled': true,
        'eventCounters': jsonEncode([
          {
            'id': 'c1',
            'name': 'Big Day',
            'targetDate': futureMs,
            'isArchived': false,
            'isUp': false,
          },
        ]),
        'reminders': jsonEncode([
          {
            'id': 5,
            'title': 'Take meds',
            'type': 'FIXED',
            'fixedHour': 8,
            'fixedMinute': 30,
            'isEnabled': true,
          },
        ]),
      };
      final backend = TabsBackend(
        client: MockClient((request) async {
          expect(request.url.path, '/api/sync/pull');
          return http.Response(
            jsonEncode({'profile': profile, 'entries': [], 'categories': []}),
            200,
          );
        }),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      // The imported check-in toggle: OFF in this fixture.
      final settingsMap = <String, String>{
        'settings_checkin_reminder_enabled': 'false',
      };
      final settings = SettingsStore.withStorage(
        read: (k) async => settingsMap[k],
        write: (k, v) async => settingsMap[k] = v,
        delete: (k) async => settingsMap.remove(k),
      );
      final notifs = FakeReminderNotificationService();
      await performReminderResync(
        backend: backend,
        settingsStore: settings,
        notifications: notifs,
      );
      // Habit daily armed (1003 @19:00); project off; check-in off
      // (the imported toggle wins — 770001 must NOT be scheduled).
      expect(notifs.daily[1003], '19:0');
      expect(notifs.daily.containsKey(1004), isFalse);
      expect(notifs.daily.containsKey(770001), isFalse);
      // The counter's one-shot 09:00 alarm is armed.
      expect(notifs.once.length, 1);
      expect(notifs.once.values.single.hour, 9);
      // The user reminder's daily slot: 100000 + 5*1500 + 0.
      expect(notifs.daily[107500], '8:30');
    });

    test('performReminderResync never reconciles on a failed profile',
        () async {
      final backend = TabsBackend(
        client: MockClient((request) async {
          // A pull with no profile object: fetchSyncPull succeeds,
          // fetchProfile is null.
          return http.Response(jsonEncode({'entries': []}), 200);
        }),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      final settingsMap = <String, String>{};
      final settings = SettingsStore.withStorage(
        read: (k) async => settingsMap[k],
        write: (k, v) async => settingsMap[k] = v,
        delete: (k) async => settingsMap.remove(k),
      );
      final notifs = FakeReminderNotificationService();
      await expectLater(
        performReminderResync(
          backend: backend,
          settingsStore: settings,
          notifications: notifs,
        ),
        throwsA(isA<FirstRunSyncException>()
            .having((e) => e.code, 'code', 'PROFILE_FAILED')),
      );
      // No user-reminder slot was scheduled OR cancelled on a guess:
      // reconcile (which cancels whole blocks) never ran.
      expect(notifs.cancelled.where((id) => id >= 100000 && id < 700000),
          isEmpty);
    });
  });
}
