import 'package:flutter/material.dart';

/// Profile-picture catalog (founder direction, Nov 23, 2026): the
/// 15 approved avatar icons, ids `avatar_01`..`avatar_15` in sheet
/// order. The art files are byte-identical copies of the approved
/// sheet icons (avatar_option_v2_*_20261123) — never re-render or
/// recolor them.
///
/// Contract (shared with the server): the profile field is the JSON
/// key `avatarId` (POST /api/sync/profile partial push; sync pull
/// profile map; friends list rows). A null / absent / unknown id
/// means NO picture — surfaces render their existing initial-letter
/// fallback, exactly as before this feature existed.
class AvatarOption {
  final String id;
  final String name;
  final String asset;

  const AvatarOption({
    required this.id,
    required this.name,
    required this.asset,
  });
}

/// All 15 selectable profile pictures, in sheet order.
const List<AvatarOption> kAvatarCatalog = [
  AvatarOption(
    id: 'avatar_01',
    name: 'Classic Bandit',
    asset: 'assets/images/avatar_01.png',
  ),
  AvatarOption(
    id: 'avatar_02',
    name: 'Teal Bandit',
    asset: 'assets/images/avatar_02.png',
  ),
  AvatarOption(
    id: 'avatar_03',
    name: 'Gold Bandit',
    asset: 'assets/images/avatar_03.png',
  ),
  AvatarOption(
    id: 'avatar_04',
    // Juno copy ruling (Nov 23, 2026): the art is pink/magenta,
    // not red — display name is Rose Bandit; the stored id is
    // unchanged (display name only).
    name: 'Rose Bandit',
    asset: 'assets/images/avatar_04.png',
  ),
  AvatarOption(
    id: 'avatar_05',
    name: 'Emerald Bandit',
    asset: 'assets/images/avatar_05.png',
  ),
  AvatarOption(
    id: 'avatar_06',
    name: 'Pink Bandit',
    asset: 'assets/images/avatar_06.png',
  ),
  AvatarOption(
    id: 'avatar_07',
    name: 'Flame',
    asset: 'assets/images/avatar_07.png',
  ),
  AvatarOption(
    id: 'avatar_08',
    name: 'Gem',
    asset: 'assets/images/avatar_08.png',
  ),
  AvatarOption(
    id: 'avatar_09',
    name: 'Moon',
    asset: 'assets/images/avatar_09.png',
  ),
  AvatarOption(
    id: 'avatar_10',
    name: 'Orb',
    asset: 'assets/images/avatar_10.png',
  ),
  AvatarOption(
    id: 'avatar_11',
    name: 'Prism',
    asset: 'assets/images/avatar_11.png',
  ),
  AvatarOption(
    id: 'avatar_12',
    name: 'Waves',
    asset: 'assets/images/avatar_12.png',
  ),
  AvatarOption(
    id: 'avatar_13',
    name: 'Sunset',
    asset: 'assets/images/avatar_13.png',
  ),
  AvatarOption(
    id: 'avatar_14',
    name: 'Heart',
    asset: 'assets/images/avatar_14.png',
  ),
  AvatarOption(
    id: 'avatar_15',
    name: 'Snowflake',
    asset: 'assets/images/avatar_15.png',
  ),
];

final Map<String, AvatarOption> _kAvatarById = {
  for (final option in kAvatarCatalog) option.id: option,
};

/// The catalog entry for [id], or null when the id is null, empty,
/// or not one of the 15 known ids (the NO-picture contract case).
AvatarOption? avatarOptionForId(String? id) {
  if (id == null || id.isEmpty) return null;
  return _kAvatarById[id];
}

/// Whether [id] names one of the 15 catalog pictures.
bool isKnownAvatarId(String? id) => avatarOptionForId(id) != null;

/// Perf-lag fix (Nov 23, 2026) — the decode bound for avatar art:
/// the catalog PNGs are 480×480, but they display at 40–72 dp, so
/// decoding at full size wastes ~16–21× the pixels. The bound is
/// a deterministic DPR cap of 3× the display extent:
/// `ceil(extent * 3)`, clamped to at least 1 and to at most 480
/// (the source size — decoding beyond it buys nothing, and a
/// very wide picker cell on a tablet-class layout must not
/// request it). (Deterministic — deliberately NOT the ambient
/// devicePixelRatio, so the bound is the same in tests and on
/// every device class; 3× covers the highest-density phones in
/// the fleet.) Shared by [UserAvatar] and the Settings picker
/// grid so both size their decodes the same way.
int avatarDecodeExtent(double displayExtent) {
  final extent = (displayExtent * 3).ceil();
  if (extent < 1) return 1;
  if (extent > 480) return 480;
  return extent;
}

/// The shared profile-picture renderer. A valid [avatarId] renders
/// the catalog art as a circular cover image at [size]; a null,
/// empty, or unknown id renders [fallback] completely untouched —
/// each surface passes its own pre-feature rendering as the
/// fallback, so the no-picture appearance never changes.
class UserAvatar extends StatelessWidget {
  final String? avatarId;
  final double size;
  final Widget fallback;

  const UserAvatar({
    super.key,
    required this.avatarId,
    required this.size,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final option = avatarOptionForId(avatarId);
    if (option == null) return fallback;
    final decode = avatarDecodeExtent(size);
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Image.asset(
          option.asset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: decode,
          cacheHeight: decode,
        ),
      ),
    );
  }
}
