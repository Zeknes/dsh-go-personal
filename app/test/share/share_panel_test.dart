// The share panel (「分享」): goldens of its pages, the scope and privacy choices
// driving every way out (card, file, link, text), a link's life (make, copy, QR,
// share, stop, undo), the three file forms, large text and narrow phones, and
// the symmetry of every row.
//
//   flutter test --update-goldens test/share/share_panel_test.dart

import 'dart:io';
import 'dart:math';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/export/conversation_out.dart';
import 'package:dsh_app/ui/export/export_widgets.dart' show ShareToggle;
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/share/share_panel_pages.dart';
import 'package:dsh_app/ui/share/share_picker.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncData, ProviderScope;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/conversation_fixture.dart';
import '../support/english_preview.dart';
import 'support.dart';

// ── Fakes ───────────────────────────────────────────────────────────────────

class _Out extends ConversationOut {
  _Out(Directory dir) : super(files: const FilesChannel(), cacheRoot: () async => dir);

  final shared = <(File, ConversationFormat)>[];
  final saved = <(File, ConversationFormat)>[];
  final texts = <String>[];

  @override
  Future<void> shareFile(File file, ConversationFormat format) async => shared.add((file, format));

  @override
  Future<void> shareText(String text) async => texts.add(text);

  @override
  Future<String> save(String name, String content, ConversationFormat format) async {
    final file = await write(name, content);
    saved.add((file, format));
    return 'Download/DSH-Go/${file.uri.pathSegments.last}';
  }
}

/// A conversation with a durable log (todos, goals, times of notices).
class _Chat extends FakeChatController {
  _Chat(super.sessionId, super.initial, this.log);

  final List<SessionLogEvent> log;

  @override
  Iterable<SessionLogEvent> get events => log;
}

class _Panel {
  _Panel(this.out);

  final _Out out;
}

/// The two-turn conversation of the export tests, as the chat holds it.
ChatState _fixture() =>
    ChatState(items: fixtureItems, turns: fixtureTurns, commands: fixtureCommands, title: '修复登录重复提交', loading: false);

AssistantChatItem _reply(ChatState state, String id) =>
    state.items.whereType<AssistantChatItem>().firstWhere((r) => r.id == id);

/// Opens the panel on [state] (default: the share-card sample), from the
/// reply [reply] (`first`: its first reply; null: from the drawer).
Future<_Panel> _open(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  ChatState? state,
  String? reply = 'first',
  ShareScope? scope,
  double textScale = 1,
  Size? size,
}) async {
  await tester.runAsync(loadTestFonts);
  usePhoneView(tester);
  if (size != null) tester.view.physicalSize = size * 2;
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('share-panel')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final panel = _Panel(_Out(dir));
  final chat = state ?? shareChatState();
  final anchor = switch (reply) {
    null => null,
    'first' => firstReply(chat),
    final id => _reply(chat, id),
  };
  // A fresh app for every open (a test may open twice).
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            // No ink and no visible text: nothing shows through the glass sheet.
            child: GestureDetector(
              onTap: () => showAppSheet<void>(
                context,
                dismissal: SheetDismissal.drag,
                heightFactor: 0.92,
                builder: (_) => SharePanel(
                  subject: ConversationSubject(sessionId: 's1', reply: anchor),
                  scope: scope,
                  clock: () => DateTime.utc(2026, 10, 25, 3),
                  loadImage: (_) async => tinyPng,
                ),
              ),
              child: const Text('open', style: TextStyle(color: Colors.transparent)),
            ),
          ),
        ),
      ),
      brightness: brightness,
      overrides: [
        settingsProvider.overrideWith(() => TestSettings()),
        // No engine: pictures in replies give up at once.
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        localConnectionProvider.overrideWith(NoLocalEngine.new),
        localRuntimeProvider.overrideWith(StaticRuntime.new),
        conversationOutProvider.overrideWithValue(panel.out),
        chatProvider.overrideWith2((id) => _Chat(id, chat, state == null ? const [] : fixtureEvents)),
      ],
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return panel;
}

/// Lets real async work (pictures shrunk, files written, PNGs encoded) run,
/// pumping frames in between until nothing is busy.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
    if (i > 4 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _key(WidgetTester tester, String key) => _tap(tester, find.byKey(ValueKey(key)));

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回'));
  await tester.pumpAndSettle();
}

String _summary(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('share-summary'))).data!;

String _status(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('share-status'))).data!;

ConversationShare _decode(String text) => decodeConversationFile(text).share;

void main() {
  _selectionTests();
  _wholeScopeAfterUpdateTests();
  // ── Goldens ───────────────────────────────────────────────────────────────

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets('golden: the first page ($mode)', (tester) async {
      await _open(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_panel_$mode.png'));
    });
  }

  testWidgets('golden: the first page (en)', (tester) async {
    useEnglish();
    await _open(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_share_panel_light.png'));
  });

  testWidgets('golden: 文件', (tester) async {
    await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);
    await _key(tester, 'share-to-file');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_file_light.png'));
  });

  // ── Scope and privacy ─────────────────────────────────────────────────────

  testWidgets('from the drawer: no 这条回复, the whole conversation first', (tester) async {
    await _open(tester, reply: null);
    final pill = tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>));
    expect([for (final s in pill.segments) s.label], ['选中消息', '整段对话']);
    expect(pill.selected, ShareScope.whole);
    expect(find.byKey(const ValueKey('share-to-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-to-link')), findsNothing);
    await _tap(tester, find.text('选中消息'));
    expect(find.text('完成（2）'), findsOneWidget, reason: 'the last exchange to start with');
  });

  testWidgets('privacy reaches the file, the link and the text alike', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);

    await _key(tester, 'share-to-file');
    await _key(tester, 'share-file-send');
    var file = decodeConversationFile(panel.out.shared.last.$1.readAsStringSync());
    expect(file.share.entries.whereType<ToolEntry>(), isNotEmpty);
    expect(file.share.entries.whereType<ReplyEntry>().any((r) => r.thinking != null), isTrue);
    expect(file.assets, hasLength(1));
    await _back(tester);

    for (final label in ['思考过程', '工具调用', '图片']) {
      await _tap(tester, find.byKey(ValueKey('share-toggle-$label')));
    }
    expect(_summary(tester), '5 条消息 · 密钥已隐藏');

    void quiet(ConversationShare share, {required String why}) {
      expect(share.entries.whereType<ToolEntry>(), isEmpty, reason: why);
      expect(share.entries.whereType<TodosEntry>(), isEmpty, reason: why);
      expect(share.entries.whereType<GoalEntry>(), isEmpty, reason: why);
      expect(share.entries.whereType<ReplyEntry>().every((r) => r.thinking == null), isTrue, reason: why);
      expect(share.images, isEmpty, reason: why);
      expect(share.toJson()['include'], {'thinking': false, 'tools': false}, reason: why);
    }

    await _key(tester, 'share-to-file');
    await _key(tester, 'share-file-send');
    file = decodeConversationFile(panel.out.shared.last.$1.readAsStringSync());
    quiet(file.share, why: 'file');
    expect(file.assets, isEmpty);
    await _back(tester);

    await _key(tester, 'share-to-text');
    final text = panel.out.texts.single;
    expect(text, startsWith('# 修复登录重复提交'));
    expect(text, isNot(contains('npm test')), reason: 'no tool lines');
    expect(text, isNot(contains(secret)));
    expect(text, isNot(contains('/home/user')));
  });

  testWidgets('文字 on a reply: its own words, redacted; pictures as alt text when left out', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6');
    await _key(tester, 'share-to-text');
    expect(panel.out.texts.last, startsWith('登录测试挂在重复提交上。看图：![截图](/root/workspace/shot.png)'));
    expect(panel.out.texts.last, isNot(contains('dsh-ui')), reason: 'a visual reply as its one line');
    await _tap(tester, find.byKey(const ValueKey('share-toggle-图片')));
    await _key(tester, 'share-to-text');
    expect(panel.out.texts.last, startsWith('登录测试挂在重复提交上。看图：〔截图〕'));
  });

  // ── 链接 ──────────────────────────────────────────────────────────────────

  testWidgets('文件: a DSH Go file, a web page, Markdown; 预览 opens the replay', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);
    await _key(tester, 'share-to-file');
    expect(find.text('修复登录重复提交.dshgo'), findsOneWidget);
    expect(find.text('在 DSH Go 里回放、接着聊'), findsOneWidget);
    await _key(tester, 'share-file-save');
    final (saved, format) = panel.out.saved.single;
    expect(format, ConversationFormat.file);
    expect(saved.uri.pathSegments.last, '修复登录重复提交.dshgo');
    expect(_decode(saved.readAsStringSync()).range, isNull, reason: 'the whole conversation');
    expect(find.text('已保存'), findsOneWidget);

    await _tap(tester, find.text('网页'));
    expect(find.text('任何浏览器都能打开，不用联网'), findsOneWidget);
    await _key(tester, 'share-file-send');
    final (page, pageFormat) = panel.out.shared.single;
    expect(pageFormat, ConversationFormat.page);
    expect(page.uri.pathSegments.last, '修复登录重复提交.html');
    final html = page.readAsStringSync();
    expect(html, contains('<title>修复登录重复提交 · DSH Go</title>'));
    expect(html, contains("connect-src 'none'"));

    await _tap(tester, find.text('Markdown'));
    expect(find.text('纯文本，随处可读'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-preview-replay')), findsNothing, reason: 'Markdown does not replay');
    await _key(tester, 'share-file-send');
    final (md, mdFormat) = panel.out.shared.last;
    expect(mdFormat, ConversationFormat.markdown);
    expect(md.uri.pathSegments.last, '修复登录重复提交.md');
    expect(md.readAsStringSync(), startsWith('# 修复登录重复提交'));

    expect(find.byKey(const ValueKey('share-preview-replay')), findsNothing);
  });

  testWidgets('over the limit: the file and the link say so and nothing goes out; Markdown still does', (tester) async {
    final random = Random(7);
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final noise = String.fromCharCodes(List.generate(5200000, (_) => alphabet.codeUnitAt(random.nextInt(64))));
    final state = ChatState(
      title: '很长',
      loading: false,
      items: [
        UserChatItem(seq: 1, time: t0, text: '把日志原样贴回来', images: const [], files: const []),
        AssistantChatItem(id: 'a2', seq: 2, time: t0, text: noise, reasoning: ''),
      ],
    );
    final panel = await _open(tester, state: state, reply: 'a2');
    await _key(tester, 'share-to-file');
    expect(_status(tester), '超过 4 MB，请缩小范围');
    await tester.tap(find.byKey(const ValueKey('share-file-send')));
    await _settle(tester);
    expect(panel.out.shared, isEmpty);
    await _tap(tester, find.text('Markdown'));
    expect(find.byKey(const ValueKey('share-status')), findsNothing);
  });

  // ── 图片 ──────────────────────────────────────────────────────────────────

  testWidgets('privacy capsules: 12 of air at both ends, one height, on one line', (tester) async {
    await _open(tester);
    final rects = <Rect>[];
    for (final label in ['思考过程', '工具调用', '图片']) {
      final capsule = tester.getRect(find.byKey(ValueKey('share-toggle-$label')));
      final check = tester.getRect(find.byKey(ValueKey('share-toggle-check-$label')));
      final text = tester.getRect(
        find.descendant(of: find.byKey(ValueKey('share-privacy')), matching: find.text(label)),
      );
      expect(capsule.height, ShareToggle.height);
      expect(check.left - capsule.left, moreOrLessEquals(ShareToggle.padding));
      expect(capsule.right - text.right, moreOrLessEquals(ShareToggle.padding));
      expect(check.center.dy, moreOrLessEquals(text.center.dy, epsilon: 0.5));
      expect(capsule.center.dy, moreOrLessEquals(text.center.dy, epsilon: 0.5));
      rects.add(capsule);
    }
    for (final r in rects) {
      expect(r.center.dy, moreOrLessEquals(rects.first.center.dy));
    }
    // Off: no check, the same air.
    await _tap(tester, find.byKey(const ValueKey('share-toggle-图片')));
    final capsule = tester.getRect(find.byKey(const ValueKey('share-toggle-图片')));
    final text = tester.getRect(
      find.descendant(of: find.byKey(const ValueKey('share-privacy')), matching: find.text('图片')),
    );
    expect(text.left - capsule.left, moreOrLessEquals(ShareToggle.padding));
    expect(capsule.right - text.right, moreOrLessEquals(ShareToggle.padding));
  });

  testWidgets('the summary line: its glyph centred on the text; 调整 does not move it', (tester) async {
    await _open(tester);
    final row = find.byKey(const ValueKey('share-summary'));
    final glyph = tester.getRect(find.byIcon(AppIcons.redacted));
    final before = tester.getRect(row);
    expect(glyph.center.dy, moreOrLessEquals(before.center.dy, epsilon: 0.5));
    expect(glyph.left, moreOrLessEquals(tester.getRect(find.byType(SharePanel)).left + 20));
    await _tap(tester, find.text('选中消息'));
    await _tap(tester, find.text('完成（2）'));
    final after = tester.getRect(row);
    expect(after.center.dy, moreOrLessEquals(before.center.dy, epsilon: 0.5));
    final adjust = tester.getRect(find.byKey(const ValueKey('share-adjust')));
    expect(adjust.center.dy, moreOrLessEquals(after.center.dy, epsilon: 0.5));
  });
}

ChatState _selectionFixture() {
  final source = _fixture();
  return ChatState(
    items: [
      for (final item in source.items)
        if (item is UserChatItem)
          UserChatItem(seq: item.seq, time: item.time, text: item.text, images: const [], files: item.files)
        else
          item,
    ],
    turns: source.turns,
    commands: source.commands,
    title: source.title,
    loading: false,
  );
}

Future<void> _selectionTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _selectionTests() {
  for (final append in [false, true]) {
    testWidgets(
      '[share-new-selection] explicitly selected reply is exported after initial preparation: append=$append',
      (tester) async {
        final initial = _selectionFixture();
        await _open(tester, state: initial, reply: null);
        try {
          final home = tester.element(find.byType(SharePanelHome));
          final container = ProviderScope.containerOf(home, listen: false);
          final controller = container.read(chatProvider('s1').notifier) as _Chat;
          final model = SharePanelScope.of(home);
          expect(model.scope, ShareScope.whole);
          await _selectionTap(tester, find.byKey(const ValueKey('share-to-file')));
          final first = await model.prepare();
          expect(first.share.entries.whereType<ReplyEntry>().map((e) => e.text), contains(_reply(initial, 'a15').text));
          await _selectionTap(tester, find.byTooltip('返回'));

          final addedPrompt = UserChatItem(
            seq: 19,
            time: at(150100),
            text: '请补充本轮验收结论',
            images: const [],
            files: const [],
          );
          final addedReply = AssistantChatItem(
            id: 'a20',
            seq: 20,
            time: at(151000),
            text: '新增验收结论：第三轮已完整核对。',
            reasoning: '',
            model: 'deepseek-v4-pro',
          );
          if (append) {
            controller.emit(
              ChatState(
                items: [...initial.items, addedPrompt, addedReply],
                turns: [
                  ...initial.turns,
                  TurnTrace(
                    turn: 3,
                    startSeq: 18,
                    start: at(150000),
                    endSeq: 21,
                    end: at(151100),
                    endReason: const TurnEndReason('completed'),
                    spans: [_selectionModelSpan()],
                  ),
                ],
                commands: initial.commands,
                title: initial.title,
                loading: false,
              ),
            );
            await tester.pump();
            expect(model.shareable.map((i) => i.key), contains(addedReply.key));
            expect(first.share.entries.whereType<ReplyEntry>().map((e) => e.text), isNot(contains(addedReply.text)));
          }
          final target = append ? addedReply : _reply(initial, 'a15');
          final prompt = append ? addedPrompt : initial.items.whereType<UserChatItem>().last;
          await _selectionTap(tester, find.text('选中消息'));
          final picker = tester.widget<MessagePicker>(find.byType(MessagePicker));
          expect(picker.items.map((i) => i.key), contains(target.key));
          expect(picker.selected, {prompt.key, target.key});
          final promptRow = find.byWidgetPredicate((w) => w is MessagePickRow && w.item.key == prompt.key);
          await _selectionTap(tester, promptRow);
          final targetRow = tester.widget<MessagePickRow>(
            find.byWidgetPredicate((w) => w is MessagePickRow && w.item.key == target.key),
          );
          expect(targetRow.picked, isTrue);
          await _selectionTap(tester, find.text('完成（1）'));
          expect(model.keys, {target.key});
          expect(model.scope, ShareScope.picked);
          await _selectionTap(tester, find.byKey(const ValueKey('share-to-file')));
          final selected = await model.prepare();
          final decoded = decodeConversationFile(selected.file.text);
          expect(selected.share.entries.whereType<ReplyEntry>().map((e) => e.text), [target.text]);
          expect(decoded.share.entries.whereType<ReplyEntry>().map((e) => e.text), [target.text]);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );
  }
}

TraceSpan _selectionModelSpan() => TraceSpan(
  kind: TraceKind.model,
  step: 1,
  seq: 20,
  start: at(150200),
  firstToken: at(150300),
  lastToken: at(151000),
  end: at(151000),
);

Future<void> _wholeScopeTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _wholeScopeAfterUpdateTests() {
  for (final append in [false, true]) {
    testWidgets('[share-whole-update] whole export uses current messages: append=$append', (tester) async {
      final source = _fixture();
      final initial = ChatState(
        items: [
          for (final item in source.items)
            if (item is UserChatItem)
              UserChatItem(seq: item.seq, time: item.time, text: item.text, images: const [], files: item.files)
            else
              item,
        ],
        turns: [...source.turns],
        commands: [...source.commands],
        title: source.title,
        loading: false,
      );
      try {
        final panel = await _open(tester, state: initial, reply: 'a15');
        final panelState = tester.state(find.byType(SharePanel));
        final home = tester.element(find.byType(SharePanelHome));
        final container = ProviderScope.containerOf(home, listen: false);
        final controller = container.read(chatProvider('s1').notifier) as _Chat;
        final model = SharePanelScope.of(home);
        expect(model.scope, ShareScope.reply);
        expect(model.anchor?.id, 'a15');
        await _wholeScopeTap(tester, find.byKey(const ValueKey('share-to-file')));
        final first = await model.prepare();
        expect(
          first.share.entries.whereType<ReplyEntry>().where((entry) => entry.text == _reply(initial, 'a15').text),
          hasLength(1),
        );
        await _wholeScopeTap(tester, find.byTooltip('返回'));
        expect(tester.state(find.byType(SharePanel)), same(panelState));
        expect(SharePanelScope.of(tester.element(find.byType(SharePanelHome))), same(model));

        final addedPrompt = UserChatItem(
          seq: 19,
          time: at(150100),
          text: '请补充本轮验收结论',
          images: const [],
          files: const [],
        );
        final addedReply = AssistantChatItem(
          id: 'a20',
          seq: 20,
          time: at(151000),
          text: '新增验收结论：第三轮已完整核对。',
          reasoning: '',
          model: 'deepseek-v4-pro',
        );
        if (append) {
          final updated = ChatState(
            items: [...initial.items, addedPrompt, addedReply],
            turns: [
              ...initial.turns,
              TurnTrace(
                turn: 3,
                startSeq: 18,
                start: at(150000),
                endSeq: 21,
                end: at(151100),
                endReason: const TurnEndReason('completed'),
                spans: [
                  TraceSpan(
                    kind: TraceKind.model,
                    step: 1,
                    seq: 20,
                    start: at(150200),
                    firstToken: at(150300),
                    lastToken: at(151000),
                    end: at(151000),
                  ),
                ],
              ),
            ],
            commands: [...initial.commands],
            title: initial.title,
            loading: false,
          );
          controller.emit(updated);
          await tester.pump();
          expect(container.read(chatProvider('s1')), same(updated));
          expect(model.shareable.map((item) => item.key), contains(addedReply.key));
          expect(initial.items.map((item) => item.key), isNot(contains(addedReply.key)));
        }
        expect(first.share.entries.whereType<ReplyEntry>().map((e) => e.text), isNot(contains(addedReply.text)));
        await _wholeScopeTap(tester, find.text('整段对话'));
        expect(
          tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>)).selected,
          ShareScope.whole,
        );
        expect(model.scope, ShareScope.whole);
        expect(find.byType(MessagePicker), findsNothing);
        expect(tester.state(find.byType(SharePanel)), same(panelState));
        expect(SharePanelScope.of(tester.element(find.byType(SharePanelHome))), same(model));
        expect(model.keys, {for (final item in model.shareable) item.key});
        await _wholeScopeTap(tester, find.byKey(const ValueKey('share-to-file')));
        final whole = await model.prepare();
        await tester.runAsync(() => model.saveFile());
        expect(model.fileSaved, isTrue);
        expect(panel.out.saved, hasLength(1));
        final (saved, format) = panel.out.saved.single;
        expect(format, ConversationFormat.file);
        final text = (await tester.runAsync(saved.readAsString))!;
        final decoded = _decode(text);
        for (final share in [decoded, whole.share]) {
          expect(share.range, isNull, reason: 'the whole conversation');
          final replies = share.entries.whereType<ReplyEntry>();
          expect(replies.where((entry) => entry.text == _reply(initial, 'a15').text), hasLength(1));
          expect(replies.where((entry) => entry.text == addedReply.text), hasLength(append ? 1 : 0));
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  }
}
