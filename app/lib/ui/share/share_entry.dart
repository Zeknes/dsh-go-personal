// The ways into 「分享」 (share_panel.dart): a reply (the key under it, the
// long-press menu, a reply in a replay), a whole conversation (the drawer), a
// delivered file; and the plugin card the plugin share sheet offers as 「图片」.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/artifacts.dart';
import '../../state/sessions_state.dart';
import 'share_panel.dart';

/// 「分享」 on a reply: the panel at 「这条回复」. A reply in a replayed
/// conversation shares from the replay, not from the chat that happens to be
/// open.
Future<void> shareReply(BuildContext context, AssistantChatItem reply) async {
  final sessionId = ProviderScope.containerOf(context, listen: false).read(currentSessionProvider);
  if (sessionId == null) return;
  return showSharePanel(context, ConversationSubject(sessionId: sessionId, reply: reply));
}

/// 「分享」 on a conversation (the drawer): the panel at 「整段对话」. Works for
/// a conversation that is not open yet: the panel waits for it.
Future<void> shareConversation(BuildContext context, String sessionId) =>
    showSharePanel(context, ConversationSubject(sessionId: sessionId), scope: ShareScope.whole);

Future<void> shareArtifact(BuildContext context, {required String sessionId, required Artifact artifact}) =>
    showSharePanel(context, ArtifactSubject(sessionId: sessionId, artifact: artifact));
