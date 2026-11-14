import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/chat_alerts.dart';
import 'hosts_state.dart';
import 'task_runs.dart';

typedef TaskAlertKey = ({HostRef host, String sessionId, String key});

class TaskAlertsController extends Notifier<Map<TaskAlertKey, ChatAlert>> {
  final _timers = <TaskAlertKey, Timer>{};

  @override
  Map<TaskAlertKey, ChatAlert> build() {
    ref.listen(taskRunsProvider, (previous, next) {
      final before = {for (final run in previous ?? []) (host: run.host, sessionId: run.root)};
      for (final run in next) {
        if (!before.contains((host: run.host, sessionId: run.root))) {
          remove((host: run.host, sessionId: run.root, key: turnKey));
        }
      }
    });
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    return const {};
  }

  void record(ChatAlert alert) {
    final key = (host: alert.host, sessionId: alert.sessionId, key: alert.key);
    _timers.remove(key)?.cancel();
    state = {...state, key: alert};
    if (!alert.kind.attention) {
      _timers[key] = Timer(const Duration(seconds: 6), () => remove(key));
    }
  }

  void remove(TaskAlertKey key) {
    _timers.remove(key)?.cancel();
    if (!state.containsKey(key)) return;
    state = {...state}..remove(key);
  }

  void clearHost(HostRef host) {
    for (final key in state.keys.where((key) => key.host == host).toList()) {
      remove(key);
    }
  }

  void clearSession(HostRef host, String sessionId) {
    for (final key in state.keys.where((key) => key.host == host && key.sessionId == sessionId).toList()) {
      remove(key);
    }
  }
}

final taskAlertsProvider = NotifierProvider<TaskAlertsController, Map<TaskAlertKey, ChatAlert>>(
  TaskAlertsController.new,
);
