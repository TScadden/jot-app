import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/connections/connect_ai_screen.dart';

import 'test_helpers.dart';

/// Friend data sharing — visual capture harness (modeled on
/// heart_sleep_capture_test.dart). Frames @ DPR 3.0 at 360dp and
/// 390dp, populated states:
/// - share_my_data_{w}: Share my data with an accepted share
///   (last-read line) + a pending share.
/// - share_picker_{w}: the category step open for a friend.
/// - shared_with_you_{w}: the incoming offer card (exact
///   categories + honesty lines + Accept/Decline).
///
/// Output dir: $MCP_SHARING_CAPTURE_OUT, default
/// ~/workspace/build-mcp-sharing/captures.

class _CaptureBackend extends TabsBackend {
  _CaptureBackend()
      : super(
          client: MockClient((_) async => http.Response('{}', 200)),
          sessionStore: FakeSessionStore(),
        );

  @override
  Future<List<AiConnectionDto>?> fetchAiConnections() async => [
        AiConnectionDto(
          id: '7',
          name: 'Claude',
          connectedAt: DateTime(2026, 11, 20),
          lastUsedAt: DateTime(2026, 11, 22),
        ),
      ];

  @override
  Future<({bool isUnlimited, bool isAdmin})?> fetchMembershipOrNull() async =>
      const (isUnlimited: true, isAdmin: false);

  @override
  Future<List<FriendDto>> fetchFriendsList() async => const [
        FriendDto(
            id: 'f3',
            nickname: 'Maya',
            tag: '31415',
            status: 'Online',
            level: 3),
      ];

  @override
  Future<List<DataShareDto>?> fetchOutgoingShares() async => [
        DataShareDto(
          id: 's1',
          otherId: 'f1',
          otherNickname: 'Dad',
          otherTag: '12345',
          categories: const ['medications', 'sleep'],
          status: 'accepted',
          createdAt: DateTime(2026, 11, 18),
          respondedAt: DateTime(2026, 11, 20),
        ),
        DataShareDto(
          id: 's2',
          otherId: 'f2',
          otherNickname: 'Boston',
          otherTag: '22222',
          categories: const ['streak'],
          status: 'pending',
          createdAt: DateTime(2026, 11, 22),
        ),
      ];

  @override
  Future<List<DataShareDto>?> fetchIncomingShares() async => [
        DataShareDto(
          id: 's9',
          otherId: 'u9',
          otherNickname: 'Mom',
          otherTag: '99999',
          categories: const ['medications', 'sleep'],
          status: 'pending',
          createdAt: DateTime(2026, 11, 21),
        ),
        DataShareDto(
          id: 's10',
          otherId: 'u10',
          otherNickname: 'Dad',
          otherTag: '12345',
          categories: const ['daily_scores'],
          status: 'accepted',
          createdAt: DateTime(2026, 11, 15),
          respondedAt: DateTime(2026, 11, 20),
        ),
      ];

  @override
  Future<List<ShareLastReadDto>?> fetchShareLastReads() async => [
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '12345',
          category: 'medications',
          readAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ];
}

void main() {
  late Directory outDir;
  final rootKey = GlobalKey();

  setUpAll(() async {
    outDir = Directory(
      Platform.environment['MCP_SHARING_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}'
              '/workspace/build-mcp-sharing/captures',
    );
    await outDir.create(recursive: true);
  });

  Future<void> loadFonts(WidgetTester tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/tools/flutter/bin/cache/'
        'artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await iconsFile.exists()) {
        final icons = await iconsFile.readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
        );
        await iconLoader.load();
      }
    });
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${outDir.path}/$name.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
    });
  }

  Future<void> reveal(WidgetTester tester, Finder finder,
      {bool up = false}) async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.drag(
          find.byType(ListView), Offset(0, up ? 300 : -300));
      await tester.pumpAndSettle();
    }
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder.first);
      await tester.pumpAndSettle();
    }
  }

  for (final width in [390.0, 360.0]) {
    final tag = width.toInt();
    testWidgets('capture sharing sections at $tag', (tester) async {
      await loadFonts(tester);
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: ConnectAiScreen(backend: _CaptureBackend()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Frame 1: Share my data (accepted + last-read + pending).
      await reveal(tester, find.text('Share my data'));
      await capture(tester, 'share_my_data_$tag');

      // Frame 2: category step open for Maya.
      await reveal(
          tester, find.byKey(const ValueKey('pick_friend_f3')));
      await tester.tap(find.byKey(const ValueKey('pick_friend_f3')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Choose what to share'));
      await capture(tester, 'share_picker_$tag');

      // Frame 3: Shared with you — the incoming offer.
      await reveal(
          tester,
          find.text('Mom wants to share their Tabs data with you'));
      await capture(tester, 'shared_with_you_$tag');
    });
  }
}
