// Every way into 「分享」 opens the same panel, and every way out is one tap
// from it: the key under a reply (beside 复制, the same size), a reply inside
// a replay (shared from the replay, not from the open chat). The long-press
// menu, the drawer and a delivered file are covered beside their own widgets
// (message_actions_test, wiring_test, artifact_card_test).

import 'dart:io';

import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/export/conversation_out.dart';
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/share/share_panel_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support.dart';

class _Out extends ConversationOut {
  _Out(Directory dir) : super(files: const FilesChannel(), cacheRoot: () async => dir);

  final shared = <(File, ConversationFormat)>[];
  final texts = <String>[];

  @override
  Future<void> shareFile(File file, ConversationFormat format) async => shared.add((file, format));

  @override
  Future<void> shareText(String text) async => texts.add(text);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
    if (i > 4 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(SharePanel), matching: find.byTooltip('返回')));
  await tester.pumpAndSettle();
}

/// From the panel's first page: every way out opens, and back.
Future<void> _everyWayOut(WidgetTester tester, _Out out) async {
  expect(find.byKey(const ValueKey('share-to-link')), findsNothing);
  expect(find.byKey(const ValueKey('share-to-image')), findsNothing);
  await _key(tester, 'share-to-file');
  expect(find.byType(ShareFilePage), findsOneWidget);
  await _key(tester, 'share-file-send');
  expect(out.shared, isNotEmpty);
  await _back(tester);
  await _key(tester, 'share-to-text');
  expect(out.texts, isNotEmpty);
  expect(find.byType(SharePanelHome), findsOneWidget);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('share-entries'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('the key under a reply: beside 复制, the same size; the panel at this reply', (tester) async {
    final out = _Out(dir);
    final state = shareChatState();
    final harness = ChatHarness(session: 's1', states: {'s1': state});
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(const ChatScreen(), overrides: [...harness.overrides, conversationOutProvider.overrideWithValue(out)]),
    );
    await pumpFrames(tester);

    final share = find.byKey(const ValueKey('reply-share')).last;
    final copy = find.byTooltip('复制').last;
    final shareBox = tester.getRect(share);
    final copyBox = tester.getRect(copy);
    expect(shareBox.size, copyBox.size, reason: 'the row\'s 36 keys');
    expect(shareBox.top, copyBox.top);
    expect(shareBox.left, moreOrLessEquals(copyBox.right), reason: 'keys sit box to box, as the row does');
    expect(tester.getSize(find.descendant(of: share, matching: find.byType(Icon))), const Size.square(20));
    expect(find.byTooltip('分享'), findsWidgets);
    expect(find.byTooltip('好的回答'), findsNothing);

    await tester.tap(share);
    await pumpFrames(tester);
    expect(find.byType(SharePanel), findsOneWidget);
    final scope = tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>));
    expect(scope.selected, ShareScope.reply);
    await _everyWayOut(tester, out);
  });
}
