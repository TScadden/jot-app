import 'dart:math';

/// A fresh random UUID v4 (RFC 4122), hand-rolled over
/// [Random.secure] — the codebase carries no uuid package
/// dependency. The version (4) and variant (10xx) bits are set
/// explicitly per RFC 4122 §4.4, and every other bit is
/// cryptographic randomness: the value carries NO time,
/// device, or sequence information.
///
/// That property is a hard requirement, not a nicety (Juno's
/// GAP-18 condition, Nov 27, 2026): log-entry and category IDs
/// appear in sync traffic alongside health entries, so an ID
/// must leak nothing about when or on what device the entry
/// was created. No v1/time-based or device-derived IDs.
String generateUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int i) => bytes[i].toRadixString(16).padLeft(2, '0');
  return '${hex(0)}${hex(1)}${hex(2)}${hex(3)}-'
      '${hex(4)}${hex(5)}-${hex(6)}${hex(7)}-'
      '${hex(8)}${hex(9)}-${hex(10)}${hex(11)}'
      '${hex(12)}${hex(13)}${hex(14)}${hex(15)}';
}

/// The canonical RFC 4122 v4 shape (version nibble `4`, variant
/// `8`/`9`/`a`/`b`). Used by tests and by any code that needs to
/// tell a client-generated UUID id apart from a legacy numeric
/// server id.
final RegExp uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

bool isUuidV4(String value) => uuidV4Pattern.hasMatch(value);
