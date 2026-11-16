// What a conversation is set to right now: its permission preset and whether
// plan mode is on. Read from the open chat's own log (the snapshot's
// projections, then any `permission/preset` / `plan/mode` events after them),
// so the composer's permission pill and the ＋ panel need no extra request.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_state.dart';

/// A conversation's preset and plan mode, as its log has them.
class SessionModes {
  const SessionModes({this.preset, this.plan = false});

  static const unknown = SessionModes();

  /// `read-only`, `workspace-write`, `auto`, `danger-full-access`, `custom`;
  /// null until the log or the snapshot says.
  final String? preset;

  /// Plan mode is on (logged: a selection made mid-turn shows once the next
  /// step takes it).
  final bool plan;

  /// The preset the chip above the composer names: every one but
  /// `danger-full-access` — 完全权限 is this app's ordinary setting on the
  /// phone and carries no chip (设置 › 权限 still switches it). Null until the
  /// log or the snapshot says.
  String? get chipPreset => preset == 'danger-full-access' ? null : preset;

  /// `auto` is looser than 工作区内修改: its chip takes the warning tone.
  bool get warns => preset == 'auto';

  @override
  bool operator ==(Object other) => other is SessionModes && other.preset == preset && other.plan == plan;

  @override
  int get hashCode => Object.hash(preset, plan);
}

/// Folds [projections] and the [events] logged after them.
SessionModes foldSessionModes(SessionProjections projections, Iterable<SessionLogEvent> events) {
  var preset = projections.permissionPreset;
  final planValue = projections.values['plan'];
  var plan = planValue is Map && planValue['active'] == true;
  for (final event in events) {
    if (event.seq <= projections.asOfSeq) continue;
    switch (event) {
      case PermissionPresetChangedEvent(preset: final next) when next.isNotEmpty:
        preset = next;
      case UnknownEvent(type: 'plan/mode', :final data):
        plan = data['active'] == true;
      default:
        break;
    }
  }
  return SessionModes(preset: preset, plan: plan);
}

/// [SessionModes] of an open conversation; recomputed whenever its log
/// changes, and only notifies when the answer does. The turns are traced
/// afresh exactly when the log changes; the items also change with every
/// streamed delta.
final sessionModesProvider = Provider.autoDispose.family<SessionModes, String>((ref, sessionId) {
  ref.watch(chatProvider(sessionId).select((s) => s.turns));
  final chat = ref.read(chatProvider(sessionId).notifier);
  return foldSessionModes(chat.projections, chat.events);
});
