import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';

const sampleTitle = '修复登录按钮重复提交';
const sampleQuestion = '登录按钮连点会提交两次，帮我看看 login_controller.dart 怎么改？';

const sampleAnswer = r'''问题在 `submit()` 没有防重入：第一次请求还没回来，第二次点击又进来了。

加一个 `_submitting` 标记，请求期间直接返回，按钮同时置灰：

```dart
Future<void> submit() async {
  if (_submitting) return;
  _submitting = true;
  try {
    await api.login(username.text, password.text, rememberMe: remember.value);
  } finally {
    _submitting = false;
  }
}
```

| 方案 | 优点 | 缺点 |
|---|---|---|
| 标记位 | 简单直接 | 要记得复位 |
| 防抖 | 通用 | 有 300ms 延迟 |

两次点击间隔 $\Delta t < 0.3$ 秒时只算一次。''';

// ── A finished conversation ─────────────────────────────────────────────────

final _t0 = DateTime(2026, 10, 24, 15, 30);

TraceSpan _tool(String name, int step, int seq) =>
    TraceSpan(kind: TraceKind.tool, step: step, seq: seq, start: _t0, end: _t0, toolName: name);

/// Two exchanges; the first turn took 53 s over 8 model steps, reading four
/// files, editing two and running one command.
ChatState shareChatState() {
  final items = <ChatItem>[
    UserChatItem(seq: 1, time: _t0, text: sampleQuestion, images: const [], files: const []),
    AssistantChatItem(id: 'a10', seq: 10, text: sampleAnswer, reasoning: '', model: 'deepseek-v4-pro'),
    UserChatItem(
      seq: 11,
      time: _t0,
      text: '顺便把按钮置灰也加上，token 是 sk-test1234567890abcdef',
      images: const [],
      files: const [],
    ),
    const AssistantChatItem(id: 'a14', seq: 14, text: '加好了：请求期间 `onPressed` 为 null，按钮自动置灰。', reasoning: ''),
  ];
  return ChatState(
    items: items,
    title: sampleTitle,
    loading: false,
    turns: [
      TurnTrace(
        turn: 1,
        startSeq: 1,
        start: _t0,
        end: _t0.add(const Duration(seconds: 53)),
        endSeq: 10,
        spans: [
          for (var i = 0; i < 8; i++)
            TraceSpan(kind: TraceKind.model, step: i + 1, seq: 2 + i, start: _t0, end: _t0, model: 'deepseek-v4-pro'),
          _tool('read', 1, 2),
          _tool('grep', 1, 3),
          _tool('read', 2, 4),
          _tool('todo_write', 2, 4),
          _tool('read', 3, 5),
          _tool('edit', 4, 6),
          _tool('edit', 5, 7),
          _tool('bash', 6, 8),
        ],
      ),
    ],
  );
}

AssistantChatItem firstReply(ChatState state) => state.items.whereType<AssistantChatItem>().first;
