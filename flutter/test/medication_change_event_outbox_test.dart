import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/medication_change_event_outbox.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// H1-07 — medication change-event OUTBOX (durable queue).
///
/// The old emit path was fire-and-forget: `TabsBackend.
/// postMedicationChangeEvents` returns false (never throws) on
/// transport failure / timeout / 500, and the old emit discarded
/// that bool. Because every later edit diffs against the
/// already-pushed medication list, a lost transition could never
/// be re-derived — a permanent silent gap in the Medication
/// Timeline, Clinician Report, and Patterns F5.
///
/// New contract (mirrors the DailyScoreSync queue):
/// (a) a failed first POST stages the ORIGINAL events (original
///     ids) durably on disk, owner-stamped — not lost;
/// (b) a later flush on a healthy backend posts the SAME event
///     ids exactly once and drains the queue (the server is
///     insert-only idempotent on the client-supplied id, so
///     replaying the original objects is safe);
/// (c) a duplicate flush after success posts nothing;
/// (d) a queue staged under account A is NEVER posted under
///     account B — it is dropped unsent on owner mismatch.

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

const _ownerA = 'a@tabs.app';
const _ownerB = 'b@tabs.app';

const _event = MedicationChangeEvent(
  id: 'evt-outbox-1',
  medId: 'iva',
  medName: 'Ivabradine',
  type: 'dose_change',
  oldSnapshot: MedicationFieldSnapshot(
    dose: '7.5 mg',
    frequency: 'Twice daily',
    startDate: 'Sep 1, 2026',
    endDate: 'Present',
    isPresent: true,
  ),
  newSnapshot: MedicationFieldSnapshot(
    dose: '5 mg',
    frequency: 'Twice daily',
    startDate: 'Sep 1, 2026',
    endDate: 'Present',
    isPresent: true,
  ),
  effectiveDate: null,
  recordedAt: 1790000000000,
  source: 'tools',
);

MedicationChangeEventOutbox _outbox(_FakeDisk disk) =>
    MedicationChangeEventOutbox.withDeps(
      read: disk.read,
      write: disk.write,
      delete: disk.delete,
    );

TabsBackend _backend({
  required String? email,
  required String token,
  required http.Client client,
}) => TabsBackend(
  client: client,
  sessionStore: FakeSessionStore()
    ..token = token
    ..email = email,
);

void main() {
  group('MedicationChangeEventOutbox (H1-07)', () {
    test('(a) POST 500 on first emit → events staged on disk, '
        'owner-stamped, not lost', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      var calls = 0;
      final failing = _backend(
        email: _ownerA,
        token: 'tok-a-1',
        client: MockClient((request) async {
          calls++;
          return http.Response('nope', 500);
        }),
      );

      // Must complete normally even though the POST fails.
      await emitMedicationChangeEvents(failing, [_event], outbox: outbox);
      expect(calls, 1);

      // Still pending in memory…
      final pending = await outbox.pendingEvents();
      expect(pending, hasLength(1));
      expect(pending.single.id, 'evt-outbox-1');

      // …and DURABLY on disk (a process death here loses
      // nothing), stamped to the staging account.
      final raw = disk.values[MedicationChangeEventOutbox.storageKey];
      expect(raw, isNotNull);
      final blob = jsonDecode(raw!) as Map<String, dynamic>;
      expect(blob['ownerEmail'], _ownerA);
      final staged = (blob['events'] as List).cast<Map<String, dynamic>>();
      expect(staged, hasLength(1));
      expect(staged.single['id'], 'evt-outbox-1');
      expect(staged.single, _event.toJson());
    });

    test('(b) later flush on a healthy backend posts the SAME '
        'event ids exactly once and drains the queue', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final failing = _backend(
        email: _ownerA,
        token: 'tok-a-2',
        client: MockClient((request) async {
          return http.Response('nope', 500);
        }),
      );
      await emitMedicationChangeEvents(failing, [_event], outbox: outbox);
      expect(await outbox.pendingEvents(), hasLength(1));

      // A brand-new outbox over the SAME disk (process restart):
      // the staged event must survive and flush from disk alone.
      final restarted = _outbox(disk);
      final bodies = <Map<String, dynamic>>[];
      final healthy = _backend(
        email: _ownerA,
        token: 'tok-a-2',
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
      );
      expect(
        await flushMedicationChangeEvents(healthy, outbox: restarted),
        isTrue,
      );
      expect(bodies, hasLength(1));
      final events = (bodies.single['events'] as List)
          .cast<Map<String, dynamic>>();
      expect(events, hasLength(1));
      // The ORIGINAL event object with its ORIGINAL id — never a
      // re-diff (a re-diff against the pushed list would derive
      // nothing, and a new id would defeat server idempotency).
      expect(events.single, _event.toJson());
      expect(await restarted.pendingEvents(), isEmpty);
    });

    test('(c) duplicate flush after success posts nothing', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      var calls = 0;
      final healthy = _backend(
        email: _ownerA,
        token: 'tok-a-3',
        client: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await emitMedicationChangeEvents(healthy, [_event], outbox: outbox);
      expect(calls, 1);
      expect(await outbox.pendingEvents(), isEmpty);

      expect(
        await flushMedicationChangeEvents(healthy, outbox: outbox),
        isTrue,
      );
      expect(
        await flushMedicationChangeEvents(healthy, outbox: outbox),
        isTrue,
      );
      expect(calls, 1);
    });

    test('(d) owner mismatch: a queue staged under account A is '
        'never posted under account B', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final failingA = _backend(
        email: _ownerA,
        token: 'tok-a-4',
        client: MockClient((request) async {
          return http.Response('nope', 500);
        }),
      );
      await emitMedicationChangeEvents(failingA, [_event], outbox: outbox);
      expect(await outbox.pendingEvents(), hasLength(1));

      // Account B signs in and a flush trigger fires: B's backend
      // must NEVER receive A's events. The queue is dropped
      // unsent (the DailyScoreSync owner rule).
      var bCalls = 0;
      final healthyB = _backend(
        email: _ownerB,
        token: 'tok-b-4',
        client: MockClient((request) async {
          bCalls++;
          return http.Response('{}', 200);
        }),
      );
      await flushMedicationChangeEvents(healthyB, outbox: outbox);
      expect(bCalls, 0);
      expect(await outbox.pendingEvents(), isEmpty);
      expect(
        disk.values.containsKey(MedicationChangeEventOutbox.storageKey),
        isFalse,
      );

      // And the login-funnel enforcement agrees: staging under A
      // again, then clearIfOwnerMismatch(B) drops it unsent.
      await emitMedicationChangeEvents(failingA, [_event], outbox: outbox);
      expect(await outbox.pendingEvents(), hasLength(1));
      expect(await outbox.clearIfOwnerMismatch(_ownerB), isTrue);
      expect(await outbox.pendingEvents(), isEmpty);
    });

    test('staging the same event id twice queues it once', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final failing = _backend(
        email: _ownerA,
        token: 'tok-a-5',
        client: MockClient((request) async {
          return http.Response('nope', 500);
        }),
      );
      await emitMedicationChangeEvents(failing, [_event], outbox: outbox);
      await emitMedicationChangeEvents(failing, [_event], outbox: outbox);
      final pending = await outbox.pendingEvents();
      expect(pending, hasLength(1));
      expect(pending.single.id, 'evt-outbox-1');
    });

    test('emit never throws even when the poster throws', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final throwing = _backend(
        email: _ownerA,
        token: 'tok-a-6',
        client: MockClient((request) async {
          throw StateError('transport exploded');
        }),
      );
      await emitMedicationChangeEvents(throwing, [_event], outbox: outbox);
      expect(await outbox.pendingEvents(), hasLength(1));
    });
  });
}
