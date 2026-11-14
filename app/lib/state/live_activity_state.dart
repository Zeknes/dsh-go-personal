import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/live_activity.dart';
import 'task_models.dart';
import 'chat_state.dart';
import 'hosts_state.dart';
import 'notify_state.dart';
import 'sessions_state.dart';
import 'task_alerts.dart';
import 'task_runs.dart';

export '../notify/live_activity.dart';

TaskFocus _focusOf(HostRef host, String sessionId, ChatState chat) {
  final approval = chat.openApproval;
  final question = approval == null ? chat.questions.firstOrNull : null;
  return TaskFocus(
    host: host,
    sessionId: sessionId,
    title: chat.title,
    activity: chat.running ? TaskActivity.thinking : TaskActivity.none,
    waitingKey: approval?.eventId ?? question?.eventId,
    waitingQuestion: question != null,
  );
}

final _liveTitlesProvider = Provider<Map<TaskTarget, String>>((ref) => <TaskTarget, String>{});

final liveActivityProvider = Provider<LiveActivity?>((ref) {
  final runs = ref.watch(taskRunsProvider);
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
        TaskPending(
          host: alert.host,
          sessionId: alert.sessionId,
          key: alert.key,
          question: alert.kind == AlertKind.question,
        ),
  ];
  if (focus?.waitingKey case final key?) {
    if (!pending.any((item) => item.host == host && item.sessionId == session)) {
      pending.insert(0, TaskPending(host: host, sessionId: session!, key: key, question: focus!.waitingQuestion));
    }
  }
  final terminal = alerts.where((a) => !a.kind.attention && a.kind != AlertKind.stopped).lastOrNull;
  final target =
      pending.firstOrNull?.target ??
      (terminal == null ? null : TaskTarget(terminal.host, terminal.sessionId)) ??
      (runs.isEmpty ? null : TaskTarget(runs.first.host, runs.first.root));
  final foreground = ref.watch(appForegroundProvider);
  if (terminal != null) titles[TaskTarget(terminal.host, terminal.sessionId)] = terminal.title;
  final state = pending.isNotEmpty
      ? TaskStateName.notification
      : terminal?.kind == AlertKind.done
      ? TaskStateName.attention
      : terminal?.kind == AlertKind.failed
      ? TaskStateName.error
      : TaskStateName.thinking;
  final prefs = ref.watch(notifyPrefsProvider);
  return liveActivityOf(
    task: TaskState(state: state, target: target, foreground: foreground),
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
