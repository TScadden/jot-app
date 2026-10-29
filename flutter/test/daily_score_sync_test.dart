import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_refresh.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

import 'test_helpers.dart';

/// Daily Score server sync (founder direction, Oct 28, 2026) —
/// the APP half:
///
/// - Payload builder → the exact server contract JSON.
/// - Push: the engine's persistScore and the refresher's
///   replaceScore each enqueue (auto / manual_refresh); the
///   queue is durable, owner-stamped, deduped by the server's
///   own write rules, and flushed as ONE batched POST; failures
///   keep records for retry; another account's queue is dropped
///   UNSENT.
/// - Hydration: GET + merge under the exact conflict rule —
///   fill-missing; server manual_refresh newer wins; older
///   loses; auto vs auto → local stands; server manual vs legacy
///   local (no computedAt) → server wins; present local
///   biometrics are never overwritten.
/// - Round-trip through a fake backend implementing the server
///   contract's write rules into an EMPTY store renders
///   identically (score, subscores, inputs, source, computedAt,
///   algorithmVersion).
/// - Wipe discipline: the AccountActions funnel clears the
///   queue, and a hydration in flight during a wipe cannot
///   resurrect scores.

const _ownerA = 'a@example.com';
const _ownerB = 'b@example.com';

class _FakeDisk {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

HealthHistoryStore _storeOn(_FakeDisk disk) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: disk.read, write: disk.write, delete: disk.delete);
  return store;
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

List<String> _priorDates(String anchor, int count) {
  final a = DateTime.parse(anchor);
  return [
    for (var i = count; i >= 1; i--) _ds(a.subtract(Duration(days: i))),
  ];
}

DailyScoreSyncRecord _record(
  String date, {
  int score = 70,
  int? sleepScore = 80,
  int? hrvScore = 60,
  int? restingHrScore = 70,
  int? asleepMinutes = 420,
  int? sleepNeedMinutes = 480,
  double? hrvMs = 40,
  double? hrvBaselineMs = 50,
  int? restingHrBpm = 60,
  double? restingHrBaselineBpm = 62,
  String source = dailyScoreSourceAuto,
  int algorithmVersion = dailyScoreAlgorithmVersion,
  int computedAt = 1000,
}) =>
    DailyScoreSyncRecord(
      date: date,
      score: score,
      sleepScore: sleepScore,
      hrvScore: hrvScore,
      restingHrScore: restingHrScore,
      asleepMinutes: asleepMinutes,
      sleepNeedMinutes: sleepNeedMinutes,
      hrvMs: hrvMs,
      hrvBaselineMs: hrvBaselineMs,
      restingHrBpm: restingHrBpm,
      restingHrBaselineBpm: restingHrBaselineBpm,
      source: source,
      algorithmVersion: algorithmVersion,
      computedAt: computedAt,
    );

/// A fake implementing the SERVER contract's write rules: auto
/// inserts only when no row exists; manual_refresh replaces an
/// auto row or a manual_refresh row with an older computedAt.
/// GET returns rows date-ascending.
class _FakeScoreServer {
  final Map<String, DailyScoreSyncRecord> rows = {};
  final List<List<DailyScoreSyncRecord>> posts = [];
  bool failPosts = false;

  Future<bool> post(List<DailyScoreSyncRecord> batch) async {
    posts.add(batch);
    if (failPosts) return false;
    for (final record in batch) {
      final existing = rows[record.date];
      if (existing == null) {
        rows[record.date] = record;
      } else if (record.source == dailyScoreSourceManualRefresh &&
          (existing.source == dailyScoreSourceAuto ||
              record.computedAt > existing.computedAt)) {
        rows[record.date] = record;
      }
      // else ignored, per the contract.
    }
    return true;
  }

  Future<List<DailyScoreSyncRecord>> get() async {
    final out = rows.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return out;
  }
}

class _SyncRig {
  final _FakeDisk queueDisk = _FakeDisk();
  final _FakeDisk storeDisk = _FakeDisk();
  final _FakeScoreServer server = _FakeScoreServer();
  String? owner = _ownerA;
  late final HealthHistoryStore store = _storeOn(storeDisk);
  late final DailyScoreSync sync = _makeSync();

  DailyScoreSync _makeSync() => DailyScoreSync.withDeps(
        store: store,
        poster: server.post,
        fetcher: server.get,
        ownerProvider: () async => owner,
        read: queueDisk.read,
        write: queueDisk.write,
        delete: queueDisk.delete,
      );

  /// A fresh sync service over the SAME queue disk + store (a
  /// process restart, in miniature).
  DailyScoreSync restartedSync() => _makeSync();
}

void main() {
  group('algorithm version constant', () {
    test('v2 is the squared sleep curve (VC 100110 combine C2); '
        'v1 was the linear curve and no v1-stamped squared score '
        'was ever pushed', () {
      expect(dailyScoreAlgorithmVersion, 2);
      // The squared map itself: 50% of need → 25 (the v1 linear
      // map gave 50).
      expect(scoreSleepComponent(0.5), 25);
      expect(scoreSleepComponent(1.5), 100);
    });
  });

  group('payload builder', () {
    test('full computation → exact contract JSON, all keys', () {
      const computation = DailyScoreComputation(
        date: '2026-10-16',
        sleepScore: 87.5,
        hrvScore: 35.2,
        restingHrScore: 100,
        dailyExact: 71.6,
        asleepMinutes: 420,
        sleepNeedMinutes: 480,
        hrvMs: 32,
        hrvBaselineMs: 40,
        restingHrBpm: 54,
        restingHrBaselineBpm: 60,
      );
      final record = buildDailyScoreRecord(
        computation,
        source: dailyScoreSourceAuto,
        computedAt: 1790000000000,
      );
      expect(record.score, 72);
      expect(record.toJson(), {
        'date': '2026-10-16',
        'score': 72,
        'sleepScore': 88,
        'hrvScore': 35,
        'restingHrScore': 100,
        'asleepMinutes': 420,
        'sleepNeedMinutes': 480,
        'hrvMs': 32.0,
        'hrvBaselineMs': 40.0,
        'restingHrBpm': 54,
        'restingHrBaselineBpm': 60.0,
        'source': 'auto',
        'algorithmVersion': dailyScoreAlgorithmVersion,
        'computedAt': 1790000000000,
      });
      expect(record.toJson().keys.toSet(), {
        'date',
        'score',
        'sleepScore',
        'hrvScore',
        'restingHrScore',
        'asleepMinutes',
        'sleepNeedMinutes',
        'hrvMs',
        'hrvBaselineMs',
        'restingHrBpm',
        'restingHrBaselineBpm',
        'source',
        'algorithmVersion',
        'computedAt',
      });
    });

    test('partial computation → nulls carried explicitly', () {
      const computation = DailyScoreComputation(
        date: '2026-10-16',
        sleepScore: 87.5,
        hrvScore: null,
        restingHrScore: null,
        dailyExact: 87.5,
        asleepMinutes: 420,
        sleepNeedMinutes: 480,
      );
      final json = buildDailyScoreRecord(
        computation,
        source: dailyScoreSourceManualRefresh,
        computedAt: 42,
      ).toJson();
      expect(json['score'], 88);
      expect(json['sleepScore'], 88);
      expect(json['hrvScore'], isNull);
      expect(json['restingHrScore'], isNull);
      expect(json['hrvMs'], isNull);
      expect(json['hrvBaselineMs'], isNull);
      expect(json['restingHrBpm'], isNull);
      expect(json['restingHrBaselineBpm'], isNull);
      expect(json['source'], 'manual_refresh');
      expect(json['computedAt'], 42);
    });

    test('record JSON round-trips through fromJson; malformed '
        'records are refused', () {
      final record = _record('2026-10-16', computedAt: 777);
      expect(DailyScoreSyncRecord.fromJson(record.toJson()), record);
      expect(DailyScoreSyncRecord.fromJson({'date': '2026-10-16'}),
          isNull);
      expect(
          DailyScoreSyncRecord.fromJson({
            ...record.toJson(),
            'source': 'carrier_pigeon',
          }),
          isNull);
      expect(DailyScoreSyncRecord.fromJson('nope'), isNull);
    });
  });

  group('TabsBackend contract wiring', () {
    TabsBackend backend(
      MockClientHandler handler, {
      required String token,
    }) =>
        TabsBackend(
          client: MockClient(handler),
          sessionStore: FakeSessionStore()..token = token,
        );

    test('postDailyScores posts {scores:[...]} and verifies the '
        'count triple', () async {
      http.Request? captured;
      final b = backend((request) async {
        captured = request;
        return http.Response(
            '{"success":true,"inserted":1,"replaced":0,"ignored":0}',
            200);
      }, token: 'tok-scoresync-1');
      final record = _record('2026-10-16');
      expect(await b.postDailyScores([record]), isTrue);
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/api/sync/daily-scores');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'scores'});
      expect((body['scores'] as List).single, record.toJson());
    });

    test('postDailyScores fails closed on a partial count, a '
        'success:false body, and a non-200', () async {
      final partial = backend((request) async {
        return http.Response(
            '{"success":true,"inserted":0,"replaced":0,"ignored":0}',
            200);
      }, token: 'tok-scoresync-2');
      expect(await partial.postDailyScores([_record('2026-10-16')]),
          isFalse);

      final refused = backend((request) async {
        return http.Response('{"success":false}', 200);
      }, token: 'tok-scoresync-3');
      expect(await refused.postDailyScores([_record('2026-10-16')]),
          isFalse);

      final httpFail = backend((request) async {
        return http.Response('nope', 500);
      }, token: 'tok-scoresync-4');
      expect(await httpFail.postDailyScores([_record('2026-10-16')]),
          isFalse);
    });

    test('fetchDailyScores parses the GET shape and skips '
        'malformed rows; failure → empty', () async {
      final record = _record('2026-10-16');
      final b = backend((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/sync/daily-scores');
        return http.Response(
            jsonEncode({
              'success': true,
              'scores': [record.toJson(), {'bogus': true}],
            }),
            200);
      }, token: 'tok-scoresync-5');
      expect(await b.fetchDailyScores(), [record]);

      final failing = backend((request) async {
        return http.Response('nope', 503);
      }, token: 'tok-scoresync-6');
      expect(await failing.fetchDailyScores(), isEmpty);
    });
  });

  group('push after persist', () {
    Future<({_SyncRig rig, HealthHistoryStore store})> seededRig() async {
      final rig = _SyncRig();
      await rig.store.mergeRefresh([
        for (final d in _priorDates('2026-10-16', 28))
          DailyBiometrics(date: d, restingHrBpm: 60, hrvRmssdMs: 40),
        const DailyBiometrics(
            date: '2026-10-16', restingHrBpm: 54, hrvRmssdMs: 32),
      ]);
      return (rig: rig, store: rig.store);
    }

    test('engine scoring a new day enqueues an auto record and '
        'flushes it batched', () async {
      final (:rig, :store) = await seededRig();
      final fixedNow = DateTime(2026, 10, 17, 8);
      final written = await DailyScoreEngine(
        store: store,
        scoreSync: rig.sync,
        now: () => fixedNow,
      ).computeMissingScores();
      expect(written, greaterThan(0));
      await rig.sync.drain();

      // Every scored day went up in ONE batched POST per flush
      // run — the server now holds the target day as auto, with
      // the engine's computedAt + the constant's version.
      expect(rig.server.posts, isNotEmpty);
      final target = rig.server.rows['2026-10-16']!;
      expect(target.source, dailyScoreSourceAuto);
      expect(target.score, 62);
      expect(target.hrvScore, 35);
      expect(target.restingHrScore, 100);
      expect(target.computedAt, fixedNow.millisecondsSinceEpoch);
      expect(target.algorithmVersion, dailyScoreAlgorithmVersion);
      // The queue is empty after a successful flush, and the
      // store's metadata carries the same stamp as the payload.
      expect(await rig.sync.pendingRecords(), isEmpty);
      final meta = store.scoreMetaFor('2026-10-16')!;
      expect(meta.source, dailyScoreSourceAuto);
      expect(meta.computedAt, fixedNow.millisecondsSinceEpoch);
      expect(meta.algorithmVersion, dailyScoreAlgorithmVersion);
    });

    test('refresher replacing a score enqueues a manual_refresh '
        'record', () async {
      final (:rig, :store) = await seededRig();
      final engineNow = DateTime(2026, 10, 17, 8);
      await DailyScoreEngine(
        store: store,
        scoreSync: rig.sync,
        now: () => engineNow,
      ).computeMissingScores();
      await rig.sync.drain();
      expect(rig.server.rows['2026-10-16']!.source,
          dailyScoreSourceAuto);

      // Late HRV lands; the founder refreshes the day.
      final refreshNow = DateTime(2026, 10, 17, 20);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        scoreSync: rig.sync,
        now: () => refreshNow,
        capture: ({bool force = false}) async {
          await store.mergeRefresh([
            const DailyBiometrics(date: '2026-10-16', hrvRmssdMs: 50),
          ]);
          return true;
        },
      );
      final outcome = await refresher.refresh('2026-10-16');
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      await rig.sync.drain();

      final target = rig.server.rows['2026-10-16']!;
      expect(target.source, dailyScoreSourceManualRefresh);
      expect(target.score, 100);
      expect(target.computedAt, refreshNow.millisecondsSinceEpoch);
      // The local metadata moved to the manual record too.
      final meta = store.scoreMetaFor('2026-10-16')!;
      expect(meta.source, dailyScoreSourceManualRefresh);
      expect(meta.computedAt, refreshNow.millisecondsSinceEpoch);
    });

    test(
        'F1: unchanged-score manual refresh restamps store meta '
        'to the queued payload stamp; older server records do '
        'not displace the refreshed local record', () async {
      final (:rig, :store) = await seededRig();
      final engineNow = DateTime(2026, 10, 17, 8);
      await DailyScoreEngine(
        store: store,
        scoreSync: rig.sync,
        now: () => engineNow,
      ).computeMissingScores();
      await rig.sync.drain();
      expect(rig.server.rows['2026-10-16']!.source,
          dailyScoreSourceAuto);
      expect(store.scoreMetaFor('2026-10-16')!.source,
          dailyScoreSourceAuto);
      expect(store.scoreMetaFor('2026-10-16')!.computedAt,
          engineNow.millisecondsSinceEpoch);
      final scoreBefore =
          (await store.readAll())['2026-10-16']!.dailyScore;
      expect(scoreBefore, 62);

      // POST-fails window: the refresh's queued payload cannot
      // land, so it stays pending for inspection / retry.
      rig.server.failPosts = true;
      // A manual refresh whose capture lands NO new data: the
      // recomputation is numerically identical (still 62).
      final refreshNow = DateTime(2026, 10, 17, 20);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        scoreSync: rig.sync,
        now: () => refreshNow,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh('2026-10-16');
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, scoreBefore);
      await rig.sync.drain();

      // THE F1 INVARIANT: store metadata stamp == queued
      // payload stamp (source + computedAt), even though the
      // four score values never changed.
      final meta = store.scoreMetaFor('2026-10-16')!;
      expect(meta.source, dailyScoreSourceManualRefresh);
      expect(meta.computedAt, refreshNow.millisecondsSinceEpoch);
      final pending = (await rig.sync.pendingRecords())
          .where((r) => r.date == '2026-10-16')
          .toList();
      expect(pending, hasLength(1));
      expect(pending.single.source, meta.source);
      expect(pending.single.computedAt, meta.computedAt);
      expect(pending.single.score, scoreBefore);

      // Downstream hydration consequence, part 1 (per Vera's
      // prescription): a server AUTO record for that day does
      // NOT displace the refreshed local record, however new
      // its stamp. Null raw inputs isolate the score decision
      // (no biometric fill can count as a change).
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 91,
          asleepMinutes: null,
          hrvMs: null,
          restingHrBpm: null,
          source: dailyScoreSourceAuto,
          computedAt: 9999999999999);
      expect(await rig.sync.hydrate(), 0);
      expect((await store.readAll())['2026-10-16']!.dailyScore,
          scoreBefore);
      expect(store.scoreMetaFor('2026-10-16')!.computedAt,
          refreshNow.millisecondsSinceEpoch);

      // Downstream consequence, part 2 (the discriminating
      // F1 case): a server manual_refresh stamped BETWEEN the
      // original auto stamp (T1) and this refresh (T2) must
      // also lose — local computedAt is now T2, so T_mid > T2
      // is false. Before the fix the local stamp stayed at T1
      // and this record was over-adopted.
      final midNow = DateTime(2026, 10, 17, 14);
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 91,
          asleepMinutes: null,
          hrvMs: null,
          restingHrBpm: null,
          source: dailyScoreSourceManualRefresh,
          computedAt: midNow.millisecondsSinceEpoch);
      expect(await rig.sync.hydrate(), 0);
      expect((await store.readAll())['2026-10-16']!.dailyScore,
          scoreBefore);
      final metaAfter = store.scoreMetaFor('2026-10-16')!;
      expect(metaAfter.source, dailyScoreSourceManualRefresh);
      expect(metaAfter.computedAt,
          refreshNow.millisecondsSinceEpoch);
    });

    test('an engine with NO sync wired scores exactly as before '
        '(no queue, but metadata is still stamped)', () async {
      final (:rig, :store) = await seededRig();
      await DailyScoreEngine(store: store).computeMissingScores();
      expect(rig.server.posts, isEmpty);
      expect((await store.readAll())['2026-10-16']!.dailyScore, 62);
      expect(store.scoreMetaFor('2026-10-16')!.source,
          dailyScoreSourceAuto);
    });
  });

  group('queue durability + dedup', () {
    test('pending records survive a service restart; flush '
        'success clears; the blob is owner-stamped', () async {
      final rig = _SyncRig();
      rig.server.failPosts = true; // enqueue's flush cannot land
      await rig.sync.enqueueRecord(_record('2026-10-16'));
      await rig.sync.drain();
      expect(await rig.sync.pendingRecords(), hasLength(1));
      final blob = jsonDecode(rig.queueDisk
          .values[DailyScoreSync.storageKey]!) as Map<String, dynamic>;
      expect(blob['ownerEmail'], _ownerA);
      expect((blob['records'] as List), hasLength(1));

      // Restart: a fresh service over the same disk sees the
      // pending record and flushes it once posts succeed again.
      final restarted = rig.restartedSync();
      expect(await restarted.pendingRecords(), hasLength(1));
      rig.server.failPosts = false;
      expect(await restarted.flush(), isTrue);
      expect(await restarted.pendingRecords(), isEmpty);
      expect(rig.server.rows['2026-10-16']!.score, 70);
      final after = jsonDecode(rig.queueDisk
          .values[DailyScoreSync.storageKey]!) as Map<String, dynamic>;
      expect((after['records'] as List), isEmpty);
    });

    test('flush failure retains the records for retry', () async {
      final rig = _SyncRig();
      rig.server.failPosts = true;
      await rig.sync.enqueueRecord(_record('2026-10-16'));
      expect(await rig.sync.flush(), isFalse);
      expect(await rig.sync.pendingRecords(), hasLength(1));
      rig.server.failPosts = false;
      expect(await rig.sync.flush(), isTrue);
      expect(await rig.sync.pendingRecords(), isEmpty);
    });

    test('dedup mirrors the server rules: stale auto never '
        'displaces a manual; older manual never displaces newer',
        () async {
      final rig = _SyncRig();
      rig.server.failPosts = true; // keep everything queued
      // Manual first (newer), then a stale auto: refused.
      expect(
          await rig.sync.enqueueRecord(_record('2026-10-16',
              source: dailyScoreSourceManualRefresh, computedAt: 2000)),
          isTrue);
      expect(
          await rig.sync.enqueueRecord(
              _record('2026-10-16', computedAt: 3000)),
          isFalse);
      var pending = await rig.sync.pendingRecords();
      expect(pending.single.source, dailyScoreSourceManualRefresh);
      expect(pending.single.computedAt, 2000);
      // An older manual: refused. A newer manual: replaces. An
      // auto over a manual: refused even when newer.
      expect(
          await rig.sync.enqueueRecord(_record('2026-10-16',
              source: dailyScoreSourceManualRefresh, computedAt: 1500)),
          isFalse);
      expect(
          await rig.sync.enqueueRecord(_record('2026-10-16',
              source: dailyScoreSourceManualRefresh, computedAt: 2500)),
          isTrue);
      expect(
          await rig.sync.enqueueRecord(
              _record('2026-10-16', computedAt: 9999)),
          isFalse);
      pending = await rig.sync.pendingRecords();
      expect(pending.single.computedAt, 2500);
      // Manual over a queued auto replaces regardless of stamp.
      expect(await rig.sync.enqueueRecord(_record('2026-10-17')),
          isTrue);
      expect(
          await rig.sync.enqueueRecord(_record('2026-10-17',
              source: dailyScoreSourceManualRefresh, computedAt: 10)),
          isTrue);
      final day17 = (await rig.sync.pendingRecords())
          .firstWhere((r) => r.date == '2026-10-17');
      expect(day17.source, dailyScoreSourceManualRefresh);
    });
  });

  group('owner safety', () {
    test("account A's queue is dropped UNSENT when the session "
        'owner is B (flush path)', () async {
      final rig = _SyncRig();
      rig.server.failPosts = true;
      await rig.sync.enqueueRecord(_record('2026-10-16'));
      await rig.sync.drain();
      expect(await rig.sync.pendingRecords(), hasLength(1));
      final postsBefore = rig.server.posts.length;

      // The session changes to B before any retry can land.
      rig.owner = _ownerB;
      rig.server.failPosts = false;
      expect(await rig.sync.flush(), isTrue); // empty after drop
      expect(rig.server.posts.length, postsBefore); // never sent
      expect(rig.server.rows, isEmpty);
      expect(await rig.sync.pendingRecords(), isEmpty);
      expect(rig.queueDisk.values.containsKey(DailyScoreSync.storageKey),
          isFalse);
      expect(rig.sync.boundOwner, _ownerB);
    });

    test("account A's queue is dropped UNSENT at B's login "
        'owner-mismatch hook; same-owner login keeps it', () async {
      final rig = _SyncRig();
      rig.server.failPosts = true;
      await rig.sync.enqueueRecord(_record('2026-10-16'));
      await rig.sync.drain();

      expect(await rig.sync.clearIfOwnerMismatch(_ownerA), isFalse);
      expect(await rig.sync.pendingRecords(), hasLength(1));

      final postsBefore = rig.server.posts.length;
      expect(await rig.sync.clearIfOwnerMismatch(_ownerB), isTrue);
      expect(await rig.sync.pendingRecords(), isEmpty);
      // No NEW post after the mismatch: the queue died unsent.
      expect(rig.server.posts.length, postsBefore);
      expect(rig.server.rows, isEmpty);
    });

    test('an unstamped queue carrying records is dropped unsent '
        'when a known owner arrives', () async {
      final rig = _SyncRig();
      rig.queueDisk.values[DailyScoreSync.storageKey] = jsonEncode({
        'ownerEmail': null,
        'records': [_record('2026-10-16').toJson()],
      });
      // Owner A is the session owner from the start here: the
      // unstamped records are unprovable, so load drops them.
      expect(await rig.sync.pendingRecords(), isEmpty);
      expect(rig.server.rows, isEmpty);
    });
  });

  group('hydration matrix', () {
    Future<_SyncRig> rigWithLocal({
      required String date,
      int? dailyScore,
      int? sleepMinutes,
      double? hrvRmssdMs,
      int? restingHrBpm,
      DailyScoreMeta? meta,
    }) async {
      final rig = _SyncRig();
      await rig.store.mergeRefresh([
        DailyBiometrics(
          date: date,
          sleepMinutes: sleepMinutes,
          hrvRmssdMs: hrvRmssdMs,
          // A day with NO biometric at all is skipped by the
          // merge (hasAnyValue), so the row always carries one.
          restingHrBpm: restingHrBpm ?? 60,
        ),
      ]);
      if (dailyScore != null) {
        await rig.store.persistScore(
          date,
          dailyScore: dailyScore,
          scoreSleep: 70,
          scoreHrv: 60,
          scoreRestingHr: 80,
          scoreSource: meta?.source,
          scoreComputedAt: meta?.computedAt,
          scoreAlgorithmVersion: meta?.algorithmVersion,
        );
      }
      return rig;
    }

    test('fill-missing: an empty local day takes the server '
        'record whole (score, subscores, inputs, metadata)',
        () async {
      final rig = _SyncRig();
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 83,
          sleepScore: 90,
          hrvScore: 75,
          restingHrScore: 85,
          asleepMinutes: 432,
          hrvMs: 47.5,
          restingHrBpm: 57,
          computedAt: 5000);
      expect(await rig.sync.hydrate(), 1);
      final row = (await rig.store.readAll())['2026-10-16']!;
      expect(row.dailyScore, 83);
      expect(row.scoreSleep, 90);
      expect(row.scoreHrv, 75);
      expect(row.scoreRestingHr, 85);
      expect(row.sleepMinutes, 432);
      expect(row.hrvRmssdMs, 47.5);
      expect(row.restingHrBpm, 57);
      final meta = rig.store.scoreMetaFor('2026-10-16')!;
      expect(meta.source, dailyScoreSourceAuto);
      expect(meta.computedAt, 5000);
      expect(meta.algorithmVersion, dailyScoreAlgorithmVersion);
    });

    test('server manual_refresh NEWER than local wins', () async {
      final rig = await rigWithLocal(
        date: '2026-10-16',
        dailyScore: 62,
        meta: const DailyScoreMeta(
            source: dailyScoreSourceAuto,
            computedAt: 1000,
            algorithmVersion: 1),
      );
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 91,
          source: dailyScoreSourceManualRefresh,
          computedAt: 2000);
      expect(await rig.sync.hydrate(), 1);
      final row = (await rig.store.readAll())['2026-10-16']!;
      expect(row.dailyScore, 91);
      expect(rig.store.scoreMetaFor('2026-10-16')!.source,
          dailyScoreSourceManualRefresh);
      expect(rig.store.scoreMetaFor('2026-10-16')!.computedAt, 2000);
    });

    test('server manual_refresh OLDER than local loses', () async {
      // Local carries every biometric the server record carries,
      // so the ONLY possible change is the score decision itself.
      final rig = await rigWithLocal(
        date: '2026-10-16',
        dailyScore: 62,
        sleepMinutes: 420,
        hrvRmssdMs: 40,
        meta: const DailyScoreMeta(
            source: dailyScoreSourceManualRefresh,
            computedAt: 3000,
            algorithmVersion: 1),
      );
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 91,
          source: dailyScoreSourceManualRefresh,
          computedAt: 2000);
      expect(await rig.sync.hydrate(), 0);
      final row = (await rig.store.readAll())['2026-10-16']!;
      expect(row.dailyScore, 62);
      expect(rig.store.scoreMetaFor('2026-10-16')!.computedAt, 3000);
    });

    test('server auto vs local auto → the local record stands '
        'even when the server stamp is newer', () async {
      // Local carries every biometric the server record carries,
      // so the ONLY possible change is the score decision itself.
      final rig = await rigWithLocal(
        date: '2026-10-16',
        dailyScore: 62,
        sleepMinutes: 420,
        hrvRmssdMs: 40,
        meta: const DailyScoreMeta(
            source: dailyScoreSourceAuto,
            computedAt: 1000,
            algorithmVersion: 1),
      );
      rig.server.rows['2026-10-16'] =
          _record('2026-10-16', score: 91, computedAt: 9999);
      expect(await rig.sync.hydrate(), 0);
      expect((await rig.store.readAll())['2026-10-16']!.dailyScore,
          62);
    });

    test('local record stands on score, but a locally ABSENT '
        'biometric still fills from the server record', () async {
      final rig = await rigWithLocal(
        date: '2026-10-16',
        dailyScore: 62,
        sleepMinutes: 420,
        // hrv absent locally
        meta: const DailyScoreMeta(
            source: dailyScoreSourceAuto,
            computedAt: 1000,
            algorithmVersion: 1),
      );
      rig.server.rows['2026-10-16'] =
          _record('2026-10-16', score: 91, computedAt: 9999);
      // 1 change: the hrv fill only — score + metadata untouched.
      expect(await rig.sync.hydrate(), 1);
      final row = (await rig.store.readAll())['2026-10-16']!;
      expect(row.dailyScore, 62);
      expect(row.hrvRmssdMs, 40);
      expect(row.sleepMinutes, 420);
      expect(rig.store.scoreMetaFor('2026-10-16')!.computedAt, 1000);
    });

    test('server manual_refresh vs LEGACY local (no metadata → '
        'computedAt 0) → the server record wins', () async {
      final rig = _SyncRig();
      // A pre-sync blob shape: the day + score, no metadata.
      await rig.store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      await rig.store.persistScore('2026-10-16', dailyScore: 55);
      expect(rig.store.scoreMetaFor('2026-10-16'), isNull);
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 77,
          source: dailyScoreSourceManualRefresh,
          computedAt: 5);
      expect(await rig.sync.hydrate(), 1);
      expect((await rig.store.readAll())['2026-10-16']!.dailyScore,
          77);
      expect(rig.store.scoreMetaFor('2026-10-16')!.computedAt, 5);
    });

    test('hydration NEVER overwrites a locally present biometric, '
        'but fills the absent ones', () async {
      final rig = await rigWithLocal(
        date: '2026-10-16',
        dailyScore: null,
        sleepMinutes: 400, // present locally — HC truth
        restingHrBpm: 61, // present locally
        // hrv absent locally
      );
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 83,
          asleepMinutes: 432, // must NOT replace the local 400
          hrvMs: 47.5, // absent locally → fills
          restingHrBpm: 57, // must NOT replace the local 61
          computedAt: 5000);
      expect(await rig.sync.hydrate(), 1);
      final row = (await rig.store.readAll())['2026-10-16']!;
      expect(row.dailyScore, 83); // score filled (was missing)
      expect(row.sleepMinutes, 400);
      expect(row.restingHrBpm, 61);
      expect(row.hrvRmssdMs, 47.5);
    });

    test('hydration does nothing on a store/session owner '
        'mismatch', () async {
      final rig = _SyncRig();
      await rig.store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      rig.store.bindToAccount(_ownerA);
      rig.owner = _ownerB; // session is B; the store is A's
      rig.server.rows['2026-10-16'] = _record('2026-10-16');
      expect(await rig.sync.hydrate(), 0);
      expect((await rig.store.readAll())['2026-10-16']!.dailyScore,
          isNull);
    });

    test('metadata survives a store restart (sidecar in the '
        'blob) and legacy blobs load with no metadata', () async {
      final rig = _SyncRig();
      rig.server.rows['2026-10-16'] =
          _record('2026-10-16', computedAt: 4242);
      await rig.sync.hydrate();
      final cold = _storeOn(rig.storeDisk);
      expect((await cold.readAll())['2026-10-16']!.dailyScore, 70);
      expect(cold.scoreMetaFor('2026-10-16')!.computedAt, 4242);

      // Legacy blob: days only, no scoreMeta key at all.
      final legacyDisk = _FakeDisk();
      legacyDisk.values[HealthHistoryStore.storageKey] = jsonEncode({
        'ownerEmail': _ownerA,
        'days': {
          '2026-10-16': {'date': '2026-10-16', 'dailyScore': 66},
        },
      });
      final legacy = _storeOn(legacyDisk);
      expect((await legacy.readAll())['2026-10-16']!.dailyScore, 66);
      expect(legacy.scoreMetaFor('2026-10-16'), isNull);
    });
  });

  group('round-trip', () {
    test('payload → fake server → GET shape → hydrate into an '
        'EMPTY store renders identically', () async {
      // Device A: compute, persist, push.
      final a = _SyncRig();
      await a.store.mergeRefresh([
        for (final d in _priorDates('2026-10-16', 28))
          DailyBiometrics(
              date: d,
              sleepMinutes: 480,
              restingHrBpm: 60,
              hrvRmssdMs: 40),
        const DailyBiometrics(
            date: '2026-10-16',
            sleepMinutes: 420,
            restingHrBpm: 54,
            hrvRmssdMs: 32),
      ]);
      final fixedNow = DateTime(2026, 10, 17, 9);
      await DailyScoreEngine(
        store: a.store,
        scoreSync: a.sync,
        now: () => fixedNow,
      ).computeMissingScores();
      await a.sync.drain();
      final aRow = (await a.store.readAll())['2026-10-16']!;
      final aMeta = a.store.scoreMetaFor('2026-10-16')!;
      expect(aRow.dailyScore, isNotNull);

      // Device B: a different store + sync over the SAME server.
      final bDisk = _FakeDisk();
      final bStore = _storeOn(bDisk);
      final bSync = DailyScoreSync.withDeps(
        store: bStore,
        poster: a.server.post,
        fetcher: a.server.get,
        ownerProvider: () async => _ownerA,
        read: _FakeDisk().read,
        write: _FakeDisk().write,
        delete: _FakeDisk().delete,
      );
      final changed = await bSync.hydrate();
      expect(changed, greaterThan(0));

      final bRow = (await bStore.readAll())['2026-10-16']!;
      expect(bRow.dailyScore, aRow.dailyScore);
      expect(bRow.scoreSleep, aRow.scoreSleep);
      expect(bRow.scoreHrv, aRow.scoreHrv);
      expect(bRow.scoreRestingHr, aRow.scoreRestingHr);
      expect(bRow.sleepMinutes, aRow.sleepMinutes);
      expect(bRow.hrvRmssdMs, aRow.hrvRmssdMs);
      expect(bRow.restingHrBpm, aRow.restingHrBpm);
      final bMeta = bStore.scoreMetaFor('2026-10-16')!;
      expect(bMeta.source, aMeta.source);
      expect(bMeta.computedAt, aMeta.computedAt);
      expect(bMeta.algorithmVersion, aMeta.algorithmVersion);
      // And the server's record for the day IS the payload the
      // builder produced from A's computation.
      final serverRecord = a.server.rows['2026-10-16']!;
      expect(serverRecord.score, aRow.dailyScore);
      expect(serverRecord.asleepMinutes, 420);
      expect(serverRecord.sleepNeedMinutes, isNotNull);
      expect(serverRecord.hrvMs, 32);
      expect(serverRecord.hrvBaselineMs, 40);
      expect(serverRecord.restingHrBpm, 54);
      expect(serverRecord.restingHrBaselineBpm, 60);
    });
  });

  group('wipe discipline', () {
    test('the AccountActions funnel clears the singleton queue',
        () async {
      final sync = DailyScoreSync.instance;
      final queueDisk = _FakeDisk();
      sync.debugReset();
      sync.debugSetStore(
          read: queueDisk.read,
          write: queueDisk.write,
          delete: queueDisk.delete);
      // Seed a queued record directly in the blob (owner A, the
      // singleton's owner resolution may be null in tests — the
      // funnel clear must not depend on it).
      queueDisk.values[DailyScoreSync.storageKey] = jsonEncode({
        'ownerEmail': _ownerA,
        'records': [_record('2026-10-16').toJson()],
      });
      await AccountActions.clearDefaultCaches();
      expect(queueDisk.values.containsKey(DailyScoreSync.storageKey),
          isFalse);
      expect(await sync.pendingRecords(), isEmpty);
      sync.debugReset();
    });

    test('a hydration in flight during a wipe does NOT resurrect '
        'scores', () async {
      final rig = _SyncRig();
      await rig.store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      await rig.store.persistScore('2026-10-16', dailyScore: 66);
      // A slow fetcher: the GET is on the wire when the wipe
      // lands (logout / expiry → clear() on the SAME service —
      // in production both are the singleton).
      late final DailyScoreSync slowSync;
      slowSync = DailyScoreSync.withDeps(
        store: rig.store,
        poster: rig.server.post,
        fetcher: () async {
          await slowSync.clear();
          return [_record('2026-10-16', score: 99)];
        },
        ownerProvider: () async => _ownerA,
        read: rig.queueDisk.read,
        write: rig.queueDisk.write,
        delete: rig.queueDisk.delete,
      );
      expect(await slowSync.hydrate(), 0);
      // The store was NOT wiped in this miniature (only the
      // queue was) — the point is the merge never landed: the
      // local 66 stands and no 99 appears.
      expect((await rig.store.readAll())['2026-10-16']!.dailyScore,
          66);
    });
  });

  group('score history screen trigger', () {
    testWidgets('opening the history with gaps hydrates silently '
        'and repaints; stored days paint first', (tester) async {
      final rig = _SyncRig();
      // The local store is EMPTY (fresh device); the server
      // holds the day.
      rig.server.rows['2026-10-16'] = _record('2026-10-16',
          score: 83, sleepScore: 90, computedAt: 5000);
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: rig.store,
          scoreSync: rig.sync,
          snapshotCapture: ({bool force = false}) async => true,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // The hydrated day renders in the history.
      expect(find.text('Fri, Oct 16'), findsOneWidget);
      expect(find.text('83'), findsWidgets);
      expect((await rig.store.readAll())['2026-10-16']!.dailyScore,
          83);
    });

    testWidgets('opening the history flushes the pending queue',
        (tester) async {
      final rig = _SyncRig();
      rig.server.failPosts = true;
      await rig.sync.enqueueRecord(_record('2026-10-15'));
      await rig.sync.drain();
      expect(rig.server.rows, isEmpty);
      rig.server.failPosts = false;
      await rig.store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-15', restingHrBpm: 60),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: rig.store,
          scoreSync: rig.sync,
          snapshotCapture: ({bool force = false}) async => true,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(rig.server.rows['2026-10-15']!.score, 70);
      expect(await rig.sync.pendingRecords(), isEmpty);
    });
  });
}
