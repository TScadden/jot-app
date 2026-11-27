import 'dart:convert';

/// Gem Store cosmetics (founder-approved, Nov 27, 2026).
///
/// Bandit is no longer one baked image: the chair, Bandit himself,
/// the book and the sunglasses are independent layers (see
/// `layered_bandit_view.dart`), each with purchasable colorways.
/// Ownership + the equipped selection are SERVER-held and arrive
/// in the profile sync payload; purchases and equips go through
/// CosmeticsService (POST /api/store/purchase, /api/store/equip).
///
/// Catalog + prices are FIXED by the package brief (Otto's
/// contract; the server's prices are authoritative — these are
/// the display values and must match Mason's catalog): 13
/// purchasables — bandit_rose 400, bandit_sky 400, bandit_mint
/// 500, bandit_sunset 600, chair_ocean 350, chair_crimson 350,
/// chair_midnight 500, book_teal 150, book_scarlet 200,
/// book_gold 300, shades_black 200, shades_rose 250,
/// shades_gold 350 (full set 4,550). Defaults (bandit_original /
/// chair_classic / book_purple, shades none) are owned by
/// everyone.
///
/// Copy: every user-facing store string lives in [StoreCopy],
/// byte-exact from Juno's FINAL ruling
/// (build-gem-store/JUNO-COPY.md, Nov 27, 2026; section numbers
/// in comments are the ruling's). Strings the ruling reuses from
/// GemCopy (freeze feedback, the About-gems footer, the balance
/// pill label) are referenced from GemCopy directly, never
/// re-typed here.
abstract final class StoreCopy {
  // ── §1 Structure ────────────────────────────────────────────
  static const String storeTitle = 'Gem Store'; // #1
  static const String heroTitle = 'Your Bandit'; // #2
  static const String heroLine =
      'Tap any item and he tries it on, reading animation and all.'; // #3
  static const String banditSection = 'Bandit Colors'; // #4
  static const String banditSectionSub =
      'A new coat for Bandit, everywhere he shows up.'; // #5
  static const String chairsSection = 'Chairs'; // #6
  static const String chairsSectionSub =
      "Bandit's reading chair on your home screen."; // #7
  static const String booksSection = 'Books'; // #8
  static const String booksSectionSub = 'The book Bandit is reading.'; // #9
  static const String shadesSection = 'Sunglasses'; // #10
  static const String shadesSectionSub =
      'Shades for Bandit. He wears them everywhere.'; // #11

  /// §1 hero chips: `Bandit {color}` · `Chair {chair}` ·
  /// `Book {book}` · `Shades {shades}` (`Shades None` when no
  /// sunglasses are equipped).
  static String chipBandit(String name) => 'Bandit $name';
  static String chipChair(String name) => 'Chair $name';
  static String chipBook(String name) => 'Book $name';
  static String chipShades(String name) => 'Shades $name';

  // ── §2 Your Chests row ──────────────────────────────────────
  static const String chestsRowTitle = 'Your Chests'; // #12
  static String chestsRowSubtitle(int unopened) {
    if (unopened >= 2) return '$unopened unopened, tap to open'; // #13
    if (unopened == 1) return '1 unopened, tap to open'; // #14
    return 'No chests yet'; // #15
  }

  // ── §3 Streak Freeze card ───────────────────────────────────
  // Title/sub/Buy reuse the ruling's strings; the price value is
  // GemCopy.freezePrice at the call site (never a second
  // literal), success/insufficient feedback is GemCopy verbatim,
  // and at cap the price + Buy simply do not render (no at-cap
  // string exists — §3).
  static const String freezeTitle = 'Streak Freeze'; // #16
  static const String freezeSubtitle = 'Covers one missed day.'; // #17
  static const String freezeBuyLabel = 'Buy'; // #19
  static String freezeOwnedLine(int n) => 'You have $n'; // #20

  // ── §4 Card / detail state formats ──────────────────────────
  static const String ownedLabel = 'Owned'; // #22
  static const String equippedChip = 'EQUIPPED'; // #23
  static const String equipChip = 'EQUIP'; // #24
  static const String buyAndEquipLabel = 'Buy & Equip'; // #25
  static String afterBuyingLine(int balanceAfter) => balanceAfter == 1
      ? 'After buying: 1 gem left'
      : 'After buying: $balanceAfter gems left'; // #26
  static const String equipLabel = 'Equip'; // #27
  static const String equippedLabel = 'Equipped'; // #28
  static const String takeOffLabel = 'Take off'; // #29
  static const String noneName = 'None'; // §5

  // ── §6 Detail view ──────────────────────────────────────────
  static String eyebrow(CosmeticSlot slot) => switch (slot) {
    CosmeticSlot.bandit => 'BANDIT COLOR',
    CosmeticSlot.chair => 'CHAIR',
    CosmeticSlot.book => 'BOOK',
    CosmeticSlot.shades => 'SUNGLASSES',
  }; // #31

  /// #34 combine note (generalized to "this" per the ruling).
  static const String combineNote =
      'Mix and match freely: this still works with any chair, any book, '
      'and any sunglasses you own. Swap pieces any time, nothing breaks.';

  // ── §7 Insufficient gems (cosmetics) ────────────────────────
  static String insufficientForItem(int needed) => needed == 1
      ? 'you need 1 more gem for this one — you earn 5 gems each time '
            'you finish your daily summary.'
      : 'you need $needed more gems for this one — you earn 5 gems '
            'each time you finish your daily summary.'; // #36/#37

  // ── §8 Purchase success (cosmetics) ─────────────────────────
  static const String purchaseSuccessTitle = "it's yours"; // #38
  static String purchaseSuccessBody(String name, int balance) =>
      balance == 1
      ? 'bandit is wearing $name now. you have 1 gem left.'
      : 'bandit is wearing $name now. you have $balance gems left.'; // #39–#41

  // ── §9 Failure copy ─────────────────────────────────────────
  static const String purchaseFailedLine =
      "couldn't complete that purchase."; // #42
  static const String tryAgainLabel = 'Try again'; // #43
  static const String laterLabel = 'Later'; // #44
  static const String equipFailedLine = "couldn't save that change."; // #45
  static const String loadFailedLine = "Couldn't load the store."; // #47

  // ── §10 Accessibility ───────────────────────────────────────
  /// #49 hero label (the EQUIPPED look; unchanged under reduced
  /// motion because the look is unchanged).
  static String heroLabel(BanditSelection s) {
    final base =
        'Bandit reading in his chair. Wearing: ${s.bandit.name} Bandit, '
        '${s.chair.name} chair, ${s.book.name} book';
    final shades = s.shades;
    return shades == null ? '$base.' : '$base, ${shades.name} sunglasses.';
  }

  /// #50–#52 item-card labels.
  static String cardLabel({
    required String name,
    required int price,
    required bool owned,
    required bool equipped,
  }) {
    if (equipped) return '$name, owned, equipped';
    if (owned) return '$name, owned';
    return '$name, $price gems';
  }

  /// #53 None-card label while shades are equipped.
  static const String noneCardLabelEquipped = 'None, take sunglasses off';

  /// #54 chests-row labels.
  static String chestsRowLabel(int unopened) {
    if (unopened >= 2) return '$unopened unopened chests';
    if (unopened == 1) return '1 unopened chest';
    return 'Your Chests, no unopened chests';
  }

  /// #55 freeze-card label (identical at cap — no at-cap wording).
  static String freezeLabel(int totalCover) =>
      'Streak Freeze, 300 gems. Covers one missed day. '
      'You have $totalCover.';
}

/// The four cosmetic slots. The wire names are the API's `slot`
/// values for POST /api/store/equip.
enum CosmeticSlot {
  bandit,
  chair,
  book,
  shades;

  String get wireName => name;
}

/// One catalog item. [assetSuffix] is the colorway segment of the
/// layered asset filenames (see LayeredBanditView's asset scheme).
/// [description] is the detail-view line (Juno §6 #35).
class CosmeticItem {
  final String id;
  final CosmeticSlot slot;
  final String name;
  final int price;
  final String assetSuffix;
  final String description;

  const CosmeticItem({
    required this.id,
    required this.slot,
    required this.name,
    required this.price,
    required this.assetSuffix,
    required this.description,
  });

  bool get isDefault => price == 0;
}

/// The fixed catalog (§5), in display order per slot: defaults
/// first, then ascending price (the sunglasses grid is price
/// order per §12 — Classic Black, Rose Tint, Gold Frame — with
/// the None card rendered by the screen ahead of them).
abstract final class CosmeticCatalog {
  static const CosmeticItem banditOriginal = CosmeticItem(
    id: 'bandit_original',
    slot: CosmeticSlot.bandit,
    name: 'Original',
    price: 0,
    assetSuffix: 'original',
    description:
        "Bandit's original coat. Shows on your home screen, your "
        'profile, and anywhere else Bandit appears.',
  );
  static const CosmeticItem banditRose = CosmeticItem(
    id: 'bandit_rose',
    slot: CosmeticSlot.bandit,
    name: 'Rose',
    price: 400,
    assetSuffix: 'rose',
    description:
        'A pink coat for Bandit. Shows on your home screen, your '
        'profile, and anywhere else Bandit appears.',
  );
  static const CosmeticItem banditSky = CosmeticItem(
    id: 'bandit_sky',
    slot: CosmeticSlot.bandit,
    name: 'Sky',
    price: 400,
    assetSuffix: 'sky',
    description:
        'A blue coat for Bandit. Shows on your home screen, your '
        'profile, and anywhere else Bandit appears.',
  );
  static const CosmeticItem banditMint = CosmeticItem(
    id: 'bandit_mint',
    slot: CosmeticSlot.bandit,
    name: 'Mint',
    price: 500,
    assetSuffix: 'mint',
    description:
        'A green coat for Bandit. Shows on your home screen, your '
        'profile, and anywhere else Bandit appears.',
  );
  static const CosmeticItem banditSunset = CosmeticItem(
    id: 'bandit_sunset',
    slot: CosmeticSlot.bandit,
    name: 'Sunset',
    price: 600,
    assetSuffix: 'sunset',
    description:
        'An orange coat for Bandit. Shows on your home screen, your '
        'profile, and anywhere else Bandit appears.',
  );

  static const CosmeticItem chairClassic = CosmeticItem(
    id: 'chair_classic',
    slot: CosmeticSlot.chair,
    name: 'Classic',
    price: 0,
    assetSuffix: 'classic',
    description:
        "Bandit's original reading chair. It is the chair on your "
        'home screen.',
  );
  static const CosmeticItem chairOcean = CosmeticItem(
    id: 'chair_ocean',
    slot: CosmeticSlot.chair,
    name: 'Ocean',
    price: 350,
    assetSuffix: 'ocean',
    description:
        "Bandit's reading chair, in ocean blue. It is the chair on "
        'your home screen.',
  );
  static const CosmeticItem chairCrimson = CosmeticItem(
    id: 'chair_crimson',
    slot: CosmeticSlot.chair,
    name: 'Crimson',
    price: 350,
    assetSuffix: 'crimson',
    description:
        "Bandit's reading chair, in deep red. It is the chair on "
        'your home screen.',
  );
  static const CosmeticItem chairMidnight = CosmeticItem(
    id: 'chair_midnight',
    slot: CosmeticSlot.chair,
    name: 'Midnight',
    price: 500,
    assetSuffix: 'midnight',
    description:
        "Bandit's reading chair, in dark navy. It is the chair on "
        'your home screen.',
  );

  static const CosmeticItem bookPurple = CosmeticItem(
    id: 'book_purple',
    slot: CosmeticSlot.book,
    name: 'Purple',
    price: 0,
    assetSuffix: 'purple',
    description: 'The book Bandit reads, with a purple cover.',
  );
  static const CosmeticItem bookTeal = CosmeticItem(
    id: 'book_teal',
    slot: CosmeticSlot.book,
    name: 'Teal',
    price: 150,
    assetSuffix: 'teal',
    description: 'The book Bandit reads, with a teal cover.',
  );
  static const CosmeticItem bookScarlet = CosmeticItem(
    id: 'book_scarlet',
    slot: CosmeticSlot.book,
    name: 'Scarlet',
    price: 200,
    assetSuffix: 'scarlet',
    description: 'The book Bandit reads, with a scarlet cover.',
  );
  static const CosmeticItem bookGold = CosmeticItem(
    id: 'book_gold',
    slot: CosmeticSlot.book,
    name: 'Gold Leaf',
    price: 300,
    assetSuffix: 'gold',
    description: 'The book Bandit reads, with a gold cover.',
  );

  static const CosmeticItem shadesBlack = CosmeticItem(
    id: 'shades_black',
    slot: CosmeticSlot.shades,
    name: 'Classic Black',
    price: 200,
    assetSuffix: 'black',
    description: 'Classic Black sunglasses for Bandit. He wears them everywhere.',
  );
  static const CosmeticItem shadesRose = CosmeticItem(
    id: 'shades_rose',
    slot: CosmeticSlot.shades,
    name: 'Rose Tint',
    price: 250,
    assetSuffix: 'rose',
    description: 'Rose Tint sunglasses for Bandit. He wears them everywhere.',
  );
  static const CosmeticItem shadesGold = CosmeticItem(
    id: 'shades_gold',
    slot: CosmeticSlot.shades,
    name: 'Gold Frame',
    price: 350,
    assetSuffix: 'gold',
    description: 'Gold Frame sunglasses for Bandit. He wears them everywhere.',
  );

  /// §6 #35 — the None (no-shades) detail description.
  static const String noneShadesDescription =
      "No sunglasses. Bandit's eyes, as they are.";

  static const List<CosmeticItem> bandits = [
    banditOriginal,
    banditRose,
    banditSky,
    banditMint,
    banditSunset,
  ];
  static const List<CosmeticItem> chairs = [
    chairClassic,
    chairOcean,
    chairCrimson,
    chairMidnight,
  ];
  static const List<CosmeticItem> books = [
    bookPurple,
    bookTeal,
    bookScarlet,
    bookGold,
  ];
  static const List<CosmeticItem> shades = [shadesBlack, shadesRose, shadesGold];

  static const List<CosmeticItem> all = [
    ...bandits,
    ...chairs,
    ...books,
    ...shades,
  ];

  /// The 13 purchasables (§5).
  static final List<CosmeticItem> purchasables = [
    for (final item in all)
      if (!item.isDefault) item,
  ];

  static final Map<String, CosmeticItem> byId = {
    for (final item in all) item.id: item,
  };

  static List<CosmeticItem> itemsFor(CosmeticSlot slot) => switch (slot) {
    CosmeticSlot.bandit => bandits,
    CosmeticSlot.chair => chairs,
    CosmeticSlot.book => books,
    CosmeticSlot.shades => shades,
  };

  /// The default (always-owned) item for a slot; null for shades,
  /// whose default is "none".
  static CosmeticItem? defaultFor(CosmeticSlot slot) => switch (slot) {
    CosmeticSlot.bandit => banditOriginal,
    CosmeticSlot.chair => chairClassic,
    CosmeticSlot.book => bookPurple,
    CosmeticSlot.shades => null,
  };
}

/// A full Bandit look: one equipped item per slot (shades may be
/// null = none). Used for the EQUIPPED look (Home, store hero
/// start) and for PREVIEW looks (store hero / item cards) — the
/// same value type drives LayeredBanditView for any mix.
class BanditSelection {
  final CosmeticItem bandit;
  final CosmeticItem chair;
  final CosmeticItem book;
  final CosmeticItem? shades;

  const BanditSelection({
    required this.bandit,
    required this.chair,
    required this.book,
    required this.shades,
  });

  static const BanditSelection defaults = BanditSelection(
    bandit: CosmeticCatalog.banditOriginal,
    chair: CosmeticCatalog.chairClassic,
    book: CosmeticCatalog.bookPurple,
    shades: null,
  );

  bool get isDefault =>
      bandit.id == CosmeticCatalog.banditOriginal.id &&
      chair.id == CosmeticCatalog.chairClassic.id &&
      book.id == CosmeticCatalog.bookPurple.id &&
      shades == null;

  CosmeticItem? itemFor(CosmeticSlot slot) => switch (slot) {
    CosmeticSlot.bandit => bandit,
    CosmeticSlot.chair => chair,
    CosmeticSlot.book => book,
    CosmeticSlot.shades => shades,
  };

  /// This selection with [slot] replaced by [item] (a null [item]
  /// clears the slot — the shades "None" option; clearing a
  /// non-shades slot falls back to its default).
  BanditSelection withItem(CosmeticItem? item, CosmeticSlot slot) {
    return switch (slot) {
      CosmeticSlot.bandit => BanditSelection(
        bandit: item ?? CosmeticCatalog.banditOriginal,
        chair: chair,
        book: book,
        shades: shades,
      ),
      CosmeticSlot.chair => BanditSelection(
        bandit: bandit,
        chair: item ?? CosmeticCatalog.chairClassic,
        book: book,
        shades: shades,
      ),
      CosmeticSlot.book => BanditSelection(
        bandit: bandit,
        chair: chair,
        book: item ?? CosmeticCatalog.bookPurple,
        shades: shades,
      ),
      CosmeticSlot.shades => BanditSelection(
        bandit: bandit,
        chair: chair,
        book: book,
        shades: item,
      ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is BanditSelection &&
      other.bandit.id == bandit.id &&
      other.chair.id == chair.id &&
      other.book.id == book.id &&
      other.shades?.id == shades?.id;

  @override
  int get hashCode => Object.hash(bandit.id, chair.id, book.id, shades?.id);

  @override
  String toString() =>
      'BanditSelection(${bandit.id}, ${chair.id}, ${book.id}, '
      '${shades?.id ?? 'none'})';
}

/// The server-held cosmetics state: what's owned + what's
/// equipped. Parsed defensively from the profile payload's
/// `cosmetics` value (a Map, or a JSON string encoding one):
///
///     {
///       "owned": ["bandit_original", "chair_ocean", ...],
///       "equipped": {"bandit": "bandit_rose", "chair": "chair_classic",
///                    "book": "book_purple", "shades": null}
///     }
///
/// Defaults are ALWAYS owned (the server grants them to every
/// account; the client also unions them in so a payload that
/// omits them can never un-own the defaults). Unknown ids are
/// ignored, never fabricated into items. An equipped id that is
/// not in the catalog falls back to the slot default.
class CosmeticsState {
  final Set<String> ownedIds;
  final BanditSelection equipped;

  const CosmeticsState({required this.ownedIds, required this.equipped});

  static const CosmeticsState defaults = CosmeticsState(
    ownedIds: {'bandit_original', 'chair_classic', 'book_purple'},
    equipped: BanditSelection.defaults,
  );

  bool owns(String itemId) => ownedIds.contains(itemId);
  bool ownsItem(CosmeticItem item) => owns(item.id);

  bool isEquipped(CosmeticItem item) =>
      equipped.itemFor(item.slot)?.id == item.id;

  static CosmeticsState fromPayload(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      if (raw.trim().isEmpty) return defaults;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return defaults;
      }
    }
    if (decoded is! Map) return defaults;
    final owned = <String>{...defaults.ownedIds};
    final rawOwned = decoded['owned'] ?? decoded['ownedIds'];
    if (rawOwned is List) {
      for (final id in rawOwned) {
        if (id is String && CosmeticCatalog.byId.containsKey(id)) {
          owned.add(id);
        }
      }
    }
    final rawEquipped = decoded['equipped'];
    var selection = BanditSelection.defaults;
    if (rawEquipped is Map) {
      CosmeticItem? pick(CosmeticSlot slot, CosmeticItem? fallback) {
        final v = rawEquipped[slot.wireName];
        if (v == null) return fallback;
        if (v is String) return CosmeticCatalog.byId[v] ?? fallback;
        return fallback;
      }

      selection = BanditSelection(
        bandit: pick(CosmeticSlot.bandit, CosmeticCatalog.banditOriginal)!,
        chair: pick(CosmeticSlot.chair, CosmeticCatalog.chairClassic)!,
        book: pick(CosmeticSlot.book, CosmeticCatalog.bookPurple)!,
        shades: pick(CosmeticSlot.shades, null),
      );
    }
    return CosmeticsState(ownedIds: owned, equipped: selection);
  }

  /// Serialize back to the payload shape (the service's
  /// optimistic equip + tests).
  Map<String, dynamic> toPayload() => {
    'owned': ownedIds.toList()..sort(),
    'equipped': {
      'bandit': equipped.bandit.id,
      'chair': equipped.chair.id,
      'book': equipped.book.id,
      'shades': equipped.shades?.id,
    },
  };

  CosmeticsState copyWith({Set<String>? ownedIds, BanditSelection? equipped}) {
    return CosmeticsState(
      ownedIds: ownedIds ?? this.ownedIds,
      equipped: equipped ?? this.equipped,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CosmeticsState &&
      other.equipped == equipped &&
      other.ownedIds.length == ownedIds.length &&
      other.ownedIds.containsAll(ownedIds);

  @override
  int get hashCode => Object.hash(equipped, Object.hashAllUnordered(ownedIds));
}

/// §6 #33 detail caption for previewing [previewed] against the
/// EQUIPPED look [equipped]: names the two highest-order pieces
/// that are NOT being previewed (order Bandit, chair, book,
/// shades, skipping the previewed piece), in the mock's sentence
/// shape. The Bandit-color instance is the mock's verbatim:
/// "Shown on the Classic chair with the Purple book. Your chair
/// and book keep whatever colors you have equipped."
String detailCaption({
  required CosmeticSlot previewed,
  required BanditSelection equipped,
}) {
  String phrase(CosmeticSlot slot) {
    final item = equipped.itemFor(slot);
    return switch (slot) {
      CosmeticSlot.bandit => '${item!.name} Bandit',
      CosmeticSlot.chair => '${item!.name} chair',
      CosmeticSlot.book => '${item!.name} book',
      CosmeticSlot.shades =>
        item == null ? 'no sunglasses' : '${item.name} sunglasses',
    };
  }

  String noun(CosmeticSlot slot) => switch (slot) {
    CosmeticSlot.bandit => 'Bandit',
    CosmeticSlot.chair => 'chair',
    CosmeticSlot.book => 'book',
    CosmeticSlot.shades => 'sunglasses',
  };

  final others = [
    for (final slot in CosmeticSlot.values)
      if (slot != previewed) slot,
  ];
  final first = others[0];
  final second = others[1];
  return 'Shown on the ${phrase(first)} with the ${phrase(second)}. '
      'Your ${noun(first)} and ${noun(second)} keep whatever colors '
      'you have equipped.';
}
