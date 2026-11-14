import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/live_activity.dart';
import '../pets/pet_mood.dart' show PetActivity, PetFocus, PetPending;
import '../pets/pet_state.dart';
import 'chat_state.dart';
import 'hosts_state.dart';
import 'notify_state.dart';
import 'sessions_state.dart';
import 'task_alerts.dart';
import 'task_runs.dart';

export '../notify/live_activity.dart';

PetFocus _focusOf(HostRef host, String sessionId, ChatState chat) {
  final approval = chat.openApproval;
  final question = approval == null ? chat.questions.firstOrNull : null;
  return PetFocus(
    host: host,
    sessionId: sessionId,
    title: chat.title,
    activity: chat.running ? PetActivity.thinking : PetActivity.none,
    waitingKey: approval?.eventId ?? question?.eventId,
    waitingQuestion: question != null,
  );
}

final _liveTitlesProvider = Provider<Map<PetTarget, String>>((ref) => <PetTarget, String>{});

final liveActivityProvider = Provider<LiveActivity?>((ref) {
  final runs = ref.watch(petRunsProvider);
  final alerts = ref.watch(taskAlertsProvider).values.toList();
  final session = ref.watch(currentSessionProvider);
  final host = ref.watch(activeHostProvider);
  final focus = session == null || !ref.exists(chatProvider(session))
      ? null
      : ref.watch(chatProvider(session).select((chat) => _focusOf(host, session, chat)));
  final titles = ref.watch(_liveTitlesProvider);
  learnLiveTitles(titles, runs, focus: focus);
  final pending = [
    for (final alert in alerts)
      if (alert.kind.attention)
        PetPending(
          host: alert.host,
          sessionId: alert.sessionId,
          key: alert.key,
          question: alert.kind == AlertKind.question,
        ),
  ];
  if (focus?.waitingKey case final key?) {
    if (!pending.any((item) => item.host == host && item.sessionId == session)) {
      pending.insert(0, PetPending(host: host, sessionId: session!, key: key, question: focus!.waitingQuestion));
    }
  }
  final terminal = alerts.where((a) => !a.kind.attention && a.kind != AlertKind.stopped).lastOrNull;
  final target =
      pending.firstOrNull?.target ??
      (terminal == null ? null : PetTarget(terminal.host, terminal.sessionId)) ??
      (runs.isEmpty ? null : PetTarget(runs.first.host, runs.first.root));
  final foreground = ref.watch(appForegroundProvider);
  if (terminal != null) titles[PetTarget(terminal.host, terminal.sessionId)] = terminal.title;
  final state = pending.isNotEmpty
      ? PetStateName.notification
      : terminal?.kind == AlertKind.done
      ? PetStateName.attention
      : terminal?.kind == AlertKind.failed
      ? PetStateName.error
      : PetStateName.thinking;
  final prefs = ref.watch(notifyPrefsProvider);
  return liveActivityOf(
    pet: PetState(state: state, target: target, foreground: foreground),
    runs: runs,
    pending: pending,
    focus: focus,
    titles: titles,
    showDone: prefs.done,
    showFailed: prefs.failed,
  );
});

final livePushProvider = Provider<LivePush>((ref) {
  final enabled = ref.watch(notifyPrefsProvider.select((p) => p.enabled && p.live));
  return LivePush(enabled: enabled, activity: enabled ? ref.watch(liveActivityProvider) : null);
});

final liveActivityBridgeProvider = Provider.autoDispose<void>((ref) {
  ref.listen<LivePush>(livePushProvider, (previous, next) {
    if (previous == next) return;
    unawaited(ref.read(notifyChannelProvider).live(next));
  }, fireImmediately: true);
});

final liveSystemStatusProvider = FutureProvider<LiveSystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).liveStatus(),
);
