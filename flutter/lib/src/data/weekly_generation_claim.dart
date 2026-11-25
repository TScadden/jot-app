import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Weekly Report Background Generation — the cross-process claim
/// (Vera design ruling 2026-11-24, §3–§4, BINDING).
///
/// A per-week claim file serializes automatic generation across
/// the two engines that can race for a due week (the WorkManager
/// background isolate and the first-open foreground check). The
/// claim is coordination state only — never data: no record
/// content is ever derived from it, and losing every claim file
/// loses nothing the archive holds.
///
/// Production backing: one file per week in app-private storage,
/// `<appSupport>/weekly_report_claims/claim_<weekStartKey>.json`,
/// content `{token, weekStartKey, claimedAtMs}`; the token is a
/// fresh [Random.secure] value per acquisition attempt.
///
/// Staleness is judged on the file's filesystem `lastModified`
/// ONLY (never on the content), so a corrupt claim is handled by
/// the same rule as a parseable one: fresh mtime ⇒ a live holder;
/// mtime at least [staleAfter] old ⇒ stealable. Stealing is
/// rename-to-trash → delete trash → exclusive-create; the
/// exclusive create is the sole proof of holding the claim.
abstract class WeeklyGenerationClaim {
  /// Attempts to hold the claim for [weekStartKey] as of [now].
  ///
  /// Returns a handle when this attempt holds the claim, and null
  /// when a fresh claim held by another run already exists (the
  /// caller treats that as `notDue` and releases nothing).
  /// Throws on claim-infrastructure failure — the caller must
  /// FAIL CLOSED (never generate unclaimed).
  Future<WeeklyClaimHandle?> tryAcquire(String weekStartKey, DateTime now);

  /// The permissive test default (Vera §6 obligation 12): every
  /// acquisition succeeds, verification always passes, release is
  /// a no-op. Pre-existing weekly suites construct coordinators
  /// without a claim and must observe no behavior change.
  factory WeeklyGenerationClaim.permissive() = _PermissiveClaim;

  /// A claim backed by a real directory (production passes the
  /// `weekly_report_claims` directory under application support;
  /// tests pass a real temp directory on workspace disk so
  /// exclusive-create atomicity is exercised against a real
  /// filesystem).
  factory WeeklyGenerationClaim.inDirectory(Directory directory) = _FileClaim;

  /// The production claim: the claims directory under the app's
  /// support directory, resolved through path_provider.
  static Future<WeeklyGenerationClaim> production() async {
    final support = await getApplicationSupportDirectory();
    return WeeklyGenerationClaim.inDirectory(
      Directory('${support.path}/weekly_report_claims'),
    );
  }

  /// A lazily-resolved production claim, for constructors that
  /// cannot await (the Progress Reports page builds its
  /// coordinator synchronously in initState): the directory is
  /// resolved on first acquisition and cached. A resolution
  /// failure throws from [tryAcquire] — the coordinator's
  /// fail-closed path, exactly like any other claim
  /// infrastructure failure.
  factory WeeklyGenerationClaim.lazyProduction() = _LazyProductionClaim;

  /// A claim older than this (by file mtime) is stale and
  /// stealable (Vera ruling §4: 10 minutes — the WorkManager
  /// execution ceiling, ≈19× the heaviest observed generation).
  static const Duration staleAfter = Duration(minutes: 10);
}

/// A held claim. [verifyStillMine] is Vera step 9 (claim-token
/// re-verification after upsert, immediately before the send);
/// [release] is token-checked — it re-reads the file and deletes
/// it ONLY when its token still equals this handle's token, so a
/// run never deletes another run's claim.
class WeeklyClaimHandle {
  final String token;
  final String weekStartKey;
  final Future<bool> Function() _verify;
  final Future<void> Function() _release;

  WeeklyClaimHandle({
    required this.token,
    required this.weekStartKey,
    required this._verify,
    required this._release,
  });

  Future<bool> verifyStillMine() => _verify();
  Future<void> release() => _release();
}

String _newToken() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _LazyProductionClaim implements WeeklyGenerationClaim {
  WeeklyGenerationClaim? _resolved;

  @override
  Future<WeeklyClaimHandle?> tryAcquire(
    String weekStartKey,
    DateTime now,
  ) async {
    final claim = _resolved ??= await WeeklyGenerationClaim.production();
    return claim.tryAcquire(weekStartKey, now);
  }
}

class _PermissiveClaim implements WeeklyGenerationClaim {
  @override
  Future<WeeklyClaimHandle?> tryAcquire(
    String weekStartKey,
    DateTime now,
  ) async {
    final token = _newToken();
    return WeeklyClaimHandle(
      token: token,
      weekStartKey: weekStartKey,
      verify: () async => true,
      release: () async {},
    );
  }
}

class _FileClaim implements WeeklyGenerationClaim {
  _FileClaim(this._directory);

  final Directory _directory;

  File _claimFile(String weekStartKey) =>
      File('${_directory.path}/claim_$weekStartKey.json');

  String _content(String token, String weekStartKey, DateTime now) =>
      jsonEncode({
        'token': token,
        'weekStartKey': weekStartKey,
        'claimedAtMs': now.millisecondsSinceEpoch,
      });

  /// Exclusive-create the claim file with [token]. Returns false
  /// when the file already exists; any other failure throws
  /// (claim-infrastructure failure — fail closed).
  Future<bool> _createExclusive(
    File file,
    String token,
    String weekStartKey,
    DateTime now,
  ) async {
    try {
      final created = await file.create(exclusive: true);
      await created.writeAsString(
        _content(token, weekStartKey, now),
        flush: true,
      );
      return true;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 17 || // EEXIST (POSIX)
          e.toString().contains('already exists') ||
          e.toString().contains('File exists')) {
        return false;
      }
      // A create that failed after landing leaves a partial file
      // whose fresh mtime reads as a live claim — the honest
      // outcome is still the throw (fail closed); the partial
      // file ages out through the normal staleness rule.
      rethrow;
    }
  }

  @override
  Future<WeeklyClaimHandle?> tryAcquire(
    String weekStartKey,
    DateTime now,
  ) async {
    // Directory creation is part of the claim infrastructure:
    // a failure here throws and the caller fails closed.
    await _directory.create(recursive: true);
    final file = _claimFile(weekStartKey);
    final token = _newToken();

    if (await _createExclusive(file, token, weekStartKey, now)) {
      return _handle(file, token, weekStartKey);
    }

    // The claim exists. Fresh ⇒ another run owns this week.
    // Stale ⇒ stealable. Age is mtime ONLY (Vera §4).
    DateTime mtime;
    try {
      mtime = await file.lastModified();
    } on FileSystemException {
      // The holder released between our create attempt and the
      // stat: retry the exclusive create once.
      if (await _createExclusive(file, token, weekStartKey, now)) {
        return _handle(file, token, weekStartKey);
      }
      return null;
    }
    if (now.difference(mtime) < WeeklyGenerationClaim.staleAfter) {
      return null;
    }

    // Steal (Vera §4, required shape): atomic rename to a unique
    // trash path → delete the trash → exclusive-create. The
    // create is the sole proof of holding; delete-then-create is
    // expressly forbidden.
    final trash = File(
      '${file.path}.trash-$token-${now.millisecondsSinceEpoch}',
    );
    var moved = false;
    try {
      await file.rename(trash.path);
      moved = true;
    } on FileSystemException {
      // Another stealer moved the stale file first (or the
      // holder released it): fall through to the create, which
      // arbitrates.
    }
    if (moved) {
      // Stat→rename window (Vera C1): if the file we actually
      // moved is NOT the stale file we statted (a fresh claim
      // landed at the path in between — its mtime differs from
      // the stale mtime), displacement is permanent: delete the
      // trash and stand down WITHOUT resurrecting the moved
      // claim and WITHOUT an exclusive-create in this branch.
      // The displaced holder then fails its step-9 token check,
      // exactly as ruled (§3).
      DateTime? trashMtime;
      try {
        trashMtime = await trash.lastModified();
      } catch (_) {}
      final mismatched =
          trashMtime != null && trashMtime != mtime;
      try {
        await trash.delete();
      } catch (_) {
        // The trash file is inert either way; the create below
        // is the proof, not the cleanup.
      }
      if (mismatched) {
        return null;
      }
    }
    if (await _createExclusive(file, token, weekStartKey, now)) {
      return _handle(file, token, weekStartKey);
    }
    return null;
  }

  WeeklyClaimHandle _handle(File file, String token, String weekStartKey) {
    Future<String?> readToken() async {
      try {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['weekStartKey'] == weekStartKey) {
          final t = decoded['token'];
          if (t is String) return t;
        }
      } catch (_) {}
      return null;
    }

    return WeeklyClaimHandle(
      token: token,
      weekStartKey: weekStartKey,
      verify: () async => (await readToken()) == token,
      release: () async {
        // Token-checked release: re-read + compare; never delete
        // another run's claim. Release never throws — it runs in
        // a finally on every exit path.
        try {
          if ((await readToken()) == token) {
            await file.delete();
          }
        } catch (_) {}
      },
    );
  }
}
