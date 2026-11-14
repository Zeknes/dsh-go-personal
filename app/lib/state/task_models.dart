import 'package:flutter/foundation.dart';

import 'hosts_state.dart';

enum TaskActivity { none, thinking, working, waiting, stopping }

enum TaskStateName {
  idle,
  thinking,
  working,
  juggling,
  sweeping,
  notification,
  attention,
  error,
  carrying,
  sleeping,
  waking,
}

/// A conversation on a host.
@immutable
class TaskTarget {
  const TaskTarget(this.host, this.sessionId);

  final HostRef host;
  final String sessionId;

  Map<String, Object?> toMap() => {'host': host.encode(), 'sessionId': sessionId};

  @override
  bool operator ==(Object other) => other is TaskTarget && other.host == host && other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(host, sessionId);

  @override
  String toString() => 'TaskTarget(${host.kind.name}:${host.id}/$sessionId)';
}

/// A running conversation (or subagent) on some host.
@immutable
class TaskRun {
  const TaskRun(this.host, this.sessionId, {this.subagent = false, String? root, this.since, this.title})
    : root = root ?? sessionId;

  final HostRef host;
  final String sessionId;
  final bool subagent;

  /// The top-level conversation (itself unless a subagent).
  final String root;

  /// When it was last seen starting (the most recently active one wins).
  final DateTime? since;

  /// The top-level conversation's title, unmasked; null until the host listed it.
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is TaskRun &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.subagent == subagent &&
      other.root == root &&
      other.since == since &&
      other.title == title;

  @override
  int get hashCode => Object.hash(host, sessionId, subagent, root, since, title);
}

/// Something waiting on the person: an approval or a question.
@immutable
class TaskPending {
  const TaskPending({required this.host, required this.sessionId, required this.key, this.question = false});

  final HostRef host;

  /// The top-level conversation.
  final String sessionId;

  /// The request's identity (its eventId).
  final String key;
  final bool question;

  String get id => '${host.kind.name}:${host.id}|$sessionId|$key';

  TaskTarget get target => TaskTarget(host, sessionId);

  @override
  bool operator ==(Object other) =>
      other is TaskPending &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.key == key &&
      other.question == question;

  @override
  int get hashCode => Object.hash(host, sessionId, key, question);
}

/// The conversation the chat page shows.
@immutable
class TaskFocus {
  const TaskFocus({
    required this.host,
    required this.sessionId,
    this.title,
    this.activity = TaskActivity.none,
    this.compacting = false,
    this.waitingKey,
    this.waitingQuestion = false,
  });

  final HostRef host;
  final String sessionId;

  /// The current chat state's title, before notification masking.
  final String? title;
  final TaskActivity activity;
  final bool compacting;

  /// The open approval (or question) card's eventId, if one waits.
  final String? waitingKey;
  final bool waitingQuestion;

  bool get running => activity != TaskActivity.none;

  TaskTarget get target => TaskTarget(host, sessionId);

  bool isOf(HostRef h, String id) => h == host && id == sessionId;

  @override
  bool operator ==(Object other) =>
      other is TaskFocus &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.activity == activity &&
      other.compacting == compacting &&
      other.waitingKey == waitingKey &&
      other.waitingQuestion == waitingQuestion;

  @override
  int get hashCode => Object.hash(host, sessionId, title, activity, compacting, waitingKey, waitingQuestion);
}

@immutable
class TaskState {
  const TaskState({this.state = TaskStateName.idle, this.target, this.foreground = true});
  final TaskStateName state;
  final TaskTarget? target;
  final bool foreground;
}
