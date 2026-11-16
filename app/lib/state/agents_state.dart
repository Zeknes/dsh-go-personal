// Subagents and agent teams of the active host, the native implementation of
// the subagent and Agent Teams panels.
// See packages/dsh_client/lib/src/agents_api.dart for the wire side.
//
// The lineage is built from the session list the app already keeps
// (`session/list` lists subagent children with their parent and carries the
// `subagentCatalog`, `subagentTiming` and `subagent` projection hints), so the
// chat header can show it without extra requests. The team panel reads the
// Lead's `agentTeam` projection live (`session/projections` +
// `session/control`) and the messages members received.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';
import 'plugins_state.dart';
import 'sessions_state.dart';

/// Every session of the active host by id, subagent children included.
final hostSessionsProvider = Provider<Map<String, SessionSummary>>((ref) {
  if (ref.watch(activeConnectionProvider).value == null) return const {};
  ref.watch(sessionsProvider);
  final all = ref.read(sessionsProvider.notifier).allSessions;
  return {for (final s in all) s.sessionId: s};
});

/// What a subagent is doing, as the chip says it.
enum AgentRunState {
  running,
  completed,
  failed,
  idle;

  String get label => switch (this) {
    running => appL10n.commonRunning,
    completed => appL10n.commonCompleted,
    failed => appL10n.stateAgentError,
    idle => appL10n.stateNotRunning,
  };
}

String subagentModeLabel(SubagentMode mode) => switch (mode) {
  SubagentMode.oneShot => appL10n.stateAgentOneShot,
  SubagentMode.continuable => appL10n.stateAgentContinuable,
  SubagentMode.external => appL10n.stateAgentExternal,
  SubagentMode.unknown => appL10n.stateSubagent,
};

/// One child in a lineage tree.
class SubagentNode {
  const SubagentNode({
    required this.id,
    required this.parentId,
    required this.label,
    required this.mode,
    required this.state,
    this.title,
    this.timing,
    this.createdAt,
    this.updatedAt,
    this.children = const [],
  });

  final String id;
  final String parentId;

  /// The creation label (the task the parent gave it), else its title.
  final String label;
  final SubagentMode mode;
  final AgentRunState state;

  /// The child's own session title, when it differs from [label].
  final String? title;
  final SubagentTiming? timing;

  /// When the parent's catalog recorded the dispatch; null for a child the
  /// catalog does not name.
  final DateTime? createdAt;

  /// The Host's `updatedAt` for the child: the later of its creation and its
  /// last prompt (dispatch or continuation), read from the session list.
  final DateTime? updatedAt;
  final List<SubagentNode> children;

  /// External tasks have no local conversation.
  bool get openable => mode != SubagentMode.external;
  bool get running => state == AgentRunState.running;

  SubagentAddress get address => SubagentAddress(parentSessionId: parentId, childSessionId: id, mode: mode);

  /// This node and every descendant, depth first.
  Iterable<SubagentNode> get flattened sync* {
    yield this;
    for (final child in children) {
      yield* child.flattened;
    }
  }
}

AgentRunState _stateOf(SessionSummary? summary) {
  if (summary == null) return AgentRunState.idle;
  if (summary.running) return AgentRunState.running;
  return switch (summary.projections.subagentTiming?.lastTurnCompleted) {
    true => AgentRunState.completed,
    false => AgentRunState.failed,
    null => AgentRunState.idle,
  };
}

// -----------------------------------------------------------------------------
// Display order

/// How a node ranks against its siblings: work in progress first, then the
/// ones that ended badly (few, and worth acting on), then the ones that
/// finished, then everything else. `idle` says nothing failed — it means no
/// turn has closed yet, the state is unknown, or the task is external.
int lineageStateRank(AgentRunState state) => switch (state) {
  AgentRunState.running => 0,
  AgentRunState.failed => 1,
  AgentRunState.completed => 2,
  AgentRunState.idle => 3,
};

DateTime? _moment(DateTime? time) => time == null || time.millisecondsSinceEpoch <= 0 ? null : time;

/// The Host's own time for this node's last change a person caused: the prompt
/// that dispatched or continued it, or the start of a turn still open. The
/// Host records no end time, so a finished node's value is its last prompt —
/// not when it finished — and a node with neither falls back to its catalog
/// creation time.
DateTime? lineageActivity(SubagentNode node) {
  DateTime? newest;
  for (final mark in [_moment(node.updatedAt), if (node.running) _moment(node.timing?.activeSince)]) {
    if (mark == null) continue;
    if (newest == null || mark.isAfter(newest)) newest = mark;
  }
  return newest ?? _moment(node.createdAt);
}

/// The best rank in the subtree: a running grandchild lifts its ancestors so
/// the tree stays whole instead of exposing a child above a hidden parent.
int _subtreeRank(SubagentNode node) {
  var best = lineageStateRank(node.state);
  for (final child in node.children) {
    final rank = _subtreeRank(child);
    if (rank < best) best = rank;
  }
  return best;
}

DateTime? _subtreeActivity(SubagentNode node) {
  var newest = lineageActivity(node);
  for (final child in node.children) {
    final at = _subtreeActivity(child);
    if (at != null && (newest == null || at.isAfter(newest))) newest = at;
  }
  return newest;
}

/// Display order among siblings: state rank, then the newest activity, then
/// the newest dispatch, then the id — so equal rows never swap between builds.
int compareLineage(SubagentNode a, SubagentNode b) {
  final rank = _subtreeRank(a).compareTo(_subtreeRank(b));
  if (rank != 0) return rank;
  final at = _subtreeActivity(a);
  final bt = _subtreeActivity(b);
  if (at != null && bt != null) {
    final byActivity = bt.compareTo(at);
    if (byActivity != 0) return byActivity;
  } else if (at != null) {
    return -1;
  } else if (bt != null) {
    return 1;
  }
  final ac = _moment(a.createdAt);
  final bc = _moment(b.createdAt);
  if (ac != null && bc != null) {
    final byCreated = bc.compareTo(ac);
    if (byCreated != 0) return byCreated;
  } else if (ac != null) {
    return -1;
  } else if (bc != null) {
    return 1;
  }
  return a.id.compareTo(b.id);
}

/// [nodes] as siblings in display order; children keep their own order.
List<SubagentNode> orderLineage(List<SubagentNode> nodes) => [...nodes]..sort(compareLineage);

/// One visible row: a node and how deep it sits under the conversation.
class LineageRow {
  const LineageRow(this.node, {this.depth = 0});

  final SubagentNode node;
  final int depth;
}

/// Every row of the trees in [nodes], depth first.
List<LineageRow> lineageRows(List<SubagentNode> nodes) {
  final rows = <LineageRow>[];
  void add(SubagentNode node, int depth) {
    rows.add(LineageRow(node, depth: depth));
    for (final child in node.children) {
      add(child, depth + 1);
    }
  }

  for (final node in nodes) {
    add(node, 0);
  }
  return rows;
}

/// How many rows the whole lineage has, nested ones included.
int lineageSize(List<SubagentNode> nodes) {
  var count = 0;
  for (final node in nodes) {
    count += node.flattened.length;
  }
  return count;
}

/// Rows a conversation's lineage shows before it is expanded: the recent ones,
/// and always every running one (a long session keeps its history, but the
/// open sheet starts with what is happening).
const recentLineageLimit = 20;

/// The rows to show: all of them when [expanded] or when the lineage is short,
/// otherwise a leading slice that includes every running node; with [query],
/// every node matching it (label, title or id, case-insensitive), flattened.
List<LineageRow> visibleLineage(
  List<SubagentNode> nodes, {
  String query = '',
  bool expanded = false,
  int limit = recentLineageLimit,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isNotEmpty) {
    return [
      for (final node in nodes.expand((n) => n.flattened))
        if (node.label.toLowerCase().contains(needle) ||
            (node.title?.toLowerCase().contains(needle) ?? false) ||
            node.id.toLowerCase().contains(needle))
          LineageRow(node),
    ];
  }
  final rows = lineageRows(nodes);
  if (expanded || rows.length <= limit) return rows;
  var count = limit < 0 ? 0 : limit;
  for (var i = count; i < rows.length; i++) {
    if (rows[i].node.running) count = i + 1;
  }
  return rows.sublist(0, count.clamp(0, rows.length));
}

/// The direct children of [parentId] (and theirs, recursively), in display
/// order: the parent's catalog plus listed children the catalog does not name
/// yet, siblings ordered by [orderLineage].
List<SubagentNode> buildLineage(
  String parentId,
  Map<String, SessionSummary> sessions, {
  int depth = 0,
  Set<String>? seen,
}) {
  if (depth > 8) return const [];
  // Build once per snapshot traversal; even a leaf used to scan every host
  // session again. Keep this local so deletion/reparenting needs no cache invalidation.
  final childrenByParent = <String, List<SessionSummary>>{};
  for (final session in sessions.values) {
    final parent = session.parentSessionId;
    if (session.isSubagent && parent != null) {
      (childrenByParent[parent] ??= []).add(session);
    }
  }
  return _buildLineage(parentId, sessions, childrenByParent, depth, seen ?? <String>{parentId});
}

List<SubagentNode> _buildLineage(
  String parentId,
  Map<String, SessionSummary> sessions,
  Map<String, List<SessionSummary>> childrenByParent,
  int depth,
  Set<String> visited,
) {
  if (depth > 8) return const [];
  final parent = sessions[parentId];
  final entries = <SubagentCatalogEntry>[...?parent?.projections.subagentCatalog];
  final named = {for (final e in entries) e.id};
  final extra = [
    for (final s in childrenByParent[parentId] ?? const <SessionSummary>[])
      if (!named.contains(s.sessionId)) s,
  ];
  for (final s in extra) {
    final identity = s.projections.subagentIdentity;
    entries.add(
      SubagentCatalogEntry(id: s.sessionId, mode: identity?.mode ?? SubagentMode.unknown, label: identity?.label),
    );
  }
  final nodes = <SubagentNode>[];
  for (final entry in entries) {
    if (!visited.add(entry.id)) continue;
    final summary = sessions[entry.id];
    final identity = summary?.projections.subagentIdentity;
    final title = summary?.title?.trim();
    final label = entry.label ?? identity?.label ?? title;
    final mode = entry.mode == SubagentMode.unknown && identity != null ? identity.mode : entry.mode;
    nodes.add(
      SubagentNode(
        id: entry.id,
        parentId: parentId,
        label: label == null || label.isEmpty ? appL10n.stateSubagent : label,
        mode: mode,
        state: mode == SubagentMode.external ? AgentRunState.idle : _stateOf(summary),
        title: title == null || title.isEmpty || title == label ? null : title,
        timing: summary?.projections.subagentTiming,
        createdAt: entry.createdAt,
        updatedAt: summary?.updatedAt,
        children: _buildLineage(entry.id, sessions, childrenByParent, depth + 1, visited),
      ),
    );
  }
  return orderLineage(nodes);
}

/// The lineage under one conversation.
final subagentLineageProvider = Provider.autoDispose.family<List<SubagentNode>, String>((ref, parentId) {
  final sessions = ref.watch(hostSessionsProvider);
  return buildLineage(parentId, sessions);
});

/// A child conversation's place under its parent.
class SubagentParent {
  const SubagentParent({required this.address, required this.label, required this.parentTitle});

  final SubagentAddress address;

  /// The child's creation label (header title).
  final String label;
  final String parentTitle;
}

/// Where [sessionId] sits when it is a subagent child; null for a root
/// conversation (or one the session list doesn't know yet).
final subagentParentProvider = Provider.autoDispose.family<SubagentParent?, String>((ref, sessionId) {
  final sessions = ref.watch(hostSessionsProvider);
  final self = sessions[sessionId];
  final parentId = self?.parentSessionId;
  if (self == null || !self.isSubagent || parentId == null) return null;
  final parent = sessions[parentId];
  SubagentCatalogEntry? entry;
  for (final e in parent?.projections.subagentCatalog ?? const []) {
    if (e.id == sessionId) entry = e;
  }
  final identity = self.projections.subagentIdentity;
  final label = entry?.label ?? identity?.label ?? self.title?.trim();
  final parentTitle = parent?.title?.trim();
  return SubagentParent(
    address: SubagentAddress(
      parentSessionId: parentId,
      childSessionId: sessionId,
      mode: entry?.mode ?? identity?.mode ?? SubagentMode.unknown,
    ),
    label: label == null || label.isEmpty ? appL10n.stateSubagent : label,
    parentTitle: parentTitle == null || parentTitle.isEmpty ? appL10n.stateParentChat : parentTitle,
  );
});

/// What the chat header shows for the current conversation.
class HeaderAgents {
  const HeaderAgents({this.parent, this.children = 0, this.running = 0, this.team, this.leadId});

  /// Set in a subagent conversation: the breadcrumb back.
  final SubagentParent? parent;

  /// Direct children and how many of them run.
  final int children;
  final int running;

  /// The Lead's team when the Agent Teams bundle is on.
  final TeamSnapshot? team;
  final String? leadId;

  bool get isChild => parent != null;
  bool get hasTeam => team != null && leadId != null;
  bool get isEmpty => !isChild && children == 0 && !hasTeam;

  @override
  bool operator ==(Object other) =>
      other is HeaderAgents &&
      other.parent?.address == parent?.address &&
      other.parent?.label == parent?.label &&
      other.parent?.parentTitle == parent?.parentTitle &&
      other.children == children &&
      other.running == running &&
      other.leadId == leadId &&
      other.team?.teammates.length == team?.teammates.length &&
      (other.team == null) == (team == null);

  @override
  int get hashCode => Object.hash(
    parent?.address,
    parent?.label,
    parent?.parentTitle,
    children,
    running,
    leadId,
    team?.teammates.length,
    team == null,
  );
}

final headerAgentsProvider = Provider.autoDispose.family<HeaderAgents, String>((ref, sessionId) {
  final sessions = ref.watch(hostSessionsProvider);
  if (sessions.isEmpty) return const HeaderAgents();
  final parent = ref.watch(subagentParentProvider(sessionId));
  final children = ref.watch(subagentLineageProvider(sessionId));
  // Teammates are the Lead's direct children: a teammate's panel is the
  // Lead's.
  final leadId = parent?.address.parentSessionId ?? sessionId;
  final team = sessions[leadId]?.projections.agentTeam;
  return HeaderAgents(
    parent: parent,
    children: children.length,
    running: children.where((c) => c.running).length,
    team: team,
    leadId: team == null ? null : leadId,
  );
});

// -----------------------------------------------------------------------------
// Agent team

/// The Agent Teams bundle (Team service, tools and the official panel).
const agentTeamBundle = '@deepseek-ai/dsh-experimental-agent-team-profile';

/// The bundle row on the active host; null while unknown or not offered.
final agentTeamBundleProvider = Provider<AsyncValue<PluginBundle?>>((ref) {
  return ref
      .watch(installedPluginsProvider)
      .whenData((bundles) => bundles?.where((b) => b.name == agentTeamBundle).firstOrNull);
});

/// Live `agentTeam` of one Lead: the list hint at once, then
/// `session/projections`, then `session/control` frames. Null data means the
/// Team projection is absent (bundle off).
class TeamController extends Notifier<AsyncValue<TeamSnapshot?>> {
  TeamController(this.leadId);

  final String leadId;

  /// Seq of the team shown (-1: none yet): an older seed or frame never
  /// replaces a newer one.
  int _seq = -1;

  int _seedTicket = 0;
  bool _hasControlCut = false;

  @override
  AsyncValue<TeamSnapshot?> build() {
    _seq = -1;
    _hasControlCut = false;
    final conn = ref.watch(activeConnectionProvider).value;
    // Re-read after the bundle switches (late enabling registers the
    // projection on the open Lead).
    ref.watch(agentTeamBundleProvider.select((b) => b.value?.enabled ?? false));
    if (conn == null) return const AsyncData(null);
    final hint = ref.read(hostSessionsProvider)[leadId]?.projections.agentTeam;
    final sub = conn.client.watchSessionControl().listen(
      (update) => _onControl(update, conn.client),
      onError: (Object _) {},
    );
    ref.onDispose(() => unawaited(sub.cancel()));
    unawaited(_seed(conn.client, retainOnError: hint != null));
    return hint == null ? const AsyncLoading() : AsyncData(hint);
  }

  Future<void> _seed(DshClient client, {required bool retainOnError}) async {
    // Notifier.ref changes when dependencies rebuild; this read belongs to this build.
    final r = ref;
    final ticket = ++_seedTicket;
    final readyGeneration = client.mux.lastReadyGenerationNumber;
    try {
      final projections = await client.projections(leadId);
      if (!r.mounted || ticket != _seedTicket || client.mux.lastReadyGenerationNumber != readyGeneration) {
        return;
      }
      if (_seq >= 0 && (projections == null || projections.asOfSeq <= _seq)) return;
      if (projections != null) _seq = projections.asOfSeq;
      state = AsyncData(projections?.agentTeam);
    } catch (error, stack) {
      if (!r.mounted || ticket != _seedTicket || client.mux.lastReadyGenerationNumber != readyGeneration) {
        return;
      }
      if (!retainOnError && _seq < 0) state = AsyncError(error, stack);
    }
  }

  void _onControl(SessionControlUpdate update, DshClient client) {
    if (!ref.mounted) return;
    switch (update) {
      case SessionControlBaseline(:final projections):
        if (_hasControlCut) ++_seedTicket;
        _hasControlCut = true;
        final mine = projections[leadId];
        if (mine != null && mine.has('agentTeam')) {
          _seq = mine.asOfSeq;
          state = AsyncData(mine.agentTeam);
        } else if (mine == null) {
          // Cold sessions are absent from the resident baseline. Their
          // current query can replace the cache, but a failed query cannot.
          _seq = -1;
          unawaited(_seed(client, retainOnError: state.hasValue));
        }
      case SessionControlProjection(:final sessionId, :final key, :final value, :final seq)
          when sessionId == leadId && key == 'agentTeam':
        if (seq <= _seq) return;
        _seq = seq;
        state = AsyncData(TeamSnapshot.fromJson(value));
      default:
        break;
    }
  }

  /// Re-reads the projection (pull to refresh, after enabling the bundle).
  Future<void> refresh() async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client != null) await _seed(client, retainOnError: state.hasValue);
  }
}

final teamProvider = NotifierProvider.autoDispose.family<TeamController, AsyncValue<TeamSnapshot?>, String>(
  TeamController.new,
);

/// A roster row with its live activity.
class TeamMemberView {
  const TeamMemberView({required this.member, required this.running, this.model, this.mode = SubagentMode.continuable});

  final TeamMember member;
  final bool running;

  /// Model the member's next request uses (from its session hints).
  final ModelSelection? model;
  final SubagentMode mode;

  /// `provisioning`/`failed` win over activity.
  AgentRunState get state => switch (member.phase) {
    'failed' => AgentRunState.failed,
    _ when running || member.phase == 'provisioning' => AgentRunState.running,
    _ => AgentRunState.idle,
  };

  String get stateLabel => switch (member.phase) {
    'provisioning' => appL10n.statePreparing,
    'failed' => appL10n.commonFailed,
    _ => running ? appL10n.commonRunning : appL10n.stateNotRunning,
  };
}

/// [team]'s roster with each member's activity from the session list.
List<TeamMemberView> teamMembers(TeamSnapshot team, Map<String, SessionSummary> sessions) => [
  for (final m in team.members)
    TeamMemberView(
      member: m,
      running: sessions[m.id]?.running ?? false,
      model: sessions[m.id]?.projections.nextModel,
      mode: sessions[m.id]?.projections.subagentIdentity?.mode ?? SubagentMode.continuable,
    ),
];

/// One-shot read of a member's recent log (a follow snapshot, then closed).
Future<List<SessionLogEvent>> _recentEvents(DshClient client, String sessionId) async {
  final done = Completer<List<SessionLogEvent>>();
  final sub = client
      .watch(
        sessionId,
        options: const WatchOptions(
          assistantStream: false,
          turnWindow: null,
          maxMessages: 200,
          includeHostEvents: false,
          includeConnectionEvents: false,
        ),
      )
      .listen(
        (event) {
          if (event is SessionSnapshotEvent && !done.isCompleted) {
            done.complete(event.events);
          }
        },
        onError: (Object error) {
          if (!done.isCompleted) done.completeError(error);
        },
        onDone: () {
          if (!done.isCompleted) done.completeError(StateError('Team log closed before its snapshot'));
        },
      );
  try {
    return await done.future.timeout(const Duration(seconds: 20));
  } finally {
    unawaited(sub.cancel());
  }
}

/// Recent messages plus the members whose logs could not be read. A successful
/// empty snapshot is different from a failed or prematurely closed follow.
class TeamMessagesSnapshot {
  const TeamMessagesSnapshot({this.messages = const [], this.unreadableMembers = const <String>{}});

  final List<TeamMessage> messages;
  final Set<String> unreadableMembers;
}

/// The team's messages, newest first: what every member received in its
/// inbox (every message has exactly one recipient, so the union is the whole
/// conversation between members). Re-read when activity changes.
final teamMessagesProvider = FutureProvider.autoDispose.family<TeamMessagesSnapshot, String>((ref, leadId) async {
  final conn = ref.watch(activeConnectionProvider).value;
  final team = ref.watch(teamProvider(leadId)).value;
  // A new turn anywhere in the team may have carried a message.
  ref.watch(
    hostSessionsProvider.select(
      (s) =>
          [for (final m in team?.members ?? const <TeamMember>[]) '${m.id}:${s[m.id]?.running}:${s[m.id]?.updatedAt}']
              .join('|'),
    ),
  );
  if (conn == null || team == null) return const TeamMessagesSnapshot();
  final client = conn.client;
  final out = <TeamMessage>[];
  final unreadable = <String>{};
  await Future.wait([
    for (final m in team.members)
      () async {
        if (!m.lead) {
          client.routeSubagent(SubagentAddress(parentSessionId: leadId, childSessionId: m.id));
        }
        try {
          for (final e in await _recentEvents(client, m.id)) {
            final message = TeamMessage.fromEvent(m.id, e);
            if (message != null) out.add(message);
          }
        } catch (_) {
          // Preserve the readable members, without presenting a partial result
          // (or all failed reads) as a complete, successfully empty inbox.
          unreadable.add(m.id);
        }
      }(),
  ]);
  out.sort((a, b) => b.time.compareTo(a.time));
  return TeamMessagesSnapshot(
    messages: List.unmodifiable(out),
    unreadableMembers: Set.unmodifiable(unreadable),
  );
});

// -----------------------------------------------------------------------------
// Navigation

/// Opens [address]'s child conversation in the chat: routes it through its
/// parent, then makes it current.
void selectSubagent(WidgetRef ref, SubagentAddress address) {
  ref.read(activeConnectionProvider).value?.client.routeSubagent(address);
  ref.read(currentSessionProvider.notifier).select(address.childSessionId);
}

/// Opens [sessionId] (a root conversation, or a child the session list
/// knows) in the chat.
void selectConversation(WidgetRef ref, String sessionId) {
  final parent = ref.read(subagentParentProvider(sessionId));
  if (parent != null) {
    selectSubagent(ref, parent.address);
  } else {
    ref.read(currentSessionProvider.notifier).select(sessionId);
  }
}
