import 'package:dsh_client/dsh_client.dart';

import '../chat/dsh_ui/dsh_ui.dart' show dshUiReplyChip;

TurnTrace? turnOf(List<TurnTrace> turns, int? seq) {
  if (seq == null) return null;
  for (final trace in turns.reversed) {
    if (trace.startSeq <= seq && (trace.endSeq == null || seq <= trace.endSeq!)) return trace;
  }
  return null;
}

/// A prompt worth putting on a card: text or pictures, not the tap that
/// answered a visual reply.
bool _isPrompt(ChatItem item) =>
    item is UserChatItem &&
    (item.text.trim().isNotEmpty || item.images.isNotEmpty) &&
    dshUiReplyChip(item.text) == null;

/// The prompt a reply answers: the nearest person-typed message above it
/// (answers to visual replies are skipped, they are a tap, not a question).
UserChatItem? questionFor(List<ChatItem> items, ChatItem reply) {
  final index = items.indexWhere((i) => i.key == reply.key);
  for (var i = (index < 0 ? items.length : index) - 1; i >= 0; i--) {
    final item = items[i];
    if (_isPrompt(item)) return item as UserChatItem;
  }
  return null;
}

List<ChatItem> shareableItems(List<ChatItem> items) => [
  for (final item in items)
    if (_isPrompt(item))
      item
    else if (item is AssistantChatItem && !item.streaming && item.text.trim().isNotEmpty)
      item,
];

Set<String> initialSelection(List<ChatItem> items, AssistantChatItem reply) => {
  ?questionFor(items, reply)?.key,
  reply.key,
};
