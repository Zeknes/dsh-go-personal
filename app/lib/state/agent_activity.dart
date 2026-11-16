// What the Host last did inside a subagent's conversation, and when.
//
// `session/list` dates a child by its last prompt (dispatch or continuation),
// which never moves when the child works or finishes. The Host does publish its
// own event clock, though: the child's `subagentTiming` projection carries
// `active.through` — the time of the newest committed event folded into the open
// turn — and drops it when the turn closes. So the app reads that clock while a
// turn runs and remembers, per child session, when it last saw a turn end; that
// is the "last real update" a finished child is ordered by. A turn the app never
// saw close (closed while the app was away, or history from an older Host) keeps
// no end time, and the lineage falls back to the prompt time.
//
// Only committed Host events set these times: nothing here reads the local
// clock, so a rebuild, a scroll, a timer tick or opening a list never invents an
// update.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_state.dart';
import 'sessions_state.dart';

Map<String, Object?>? _asMap(Object? value) => value is Map ? value.cast<String, Object?>() : null;

int? _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number when number.isFinite => number.toInt(),
  _ => null,
};

DateTime? _asTime(Object? value) {
  final ms = _asInt(value);
  return ms == null || ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

/// The Host's clock for one child session, as far as this app has seen it.
class AgentActivity {
  const AgentActivity({
    this.seq = -1,
    this.running = false,
    this.turnStart,
    this.lastEventAt,
    this.lastEndedAt,
    this.lastTurnCompleted,
  });

  factory AgentActivity.fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return const AgentActivity();
    return AgentActivity(
      seq: _asInt(map['seq']) ?? -1,
      running: map['running'] == true,
      turnStart: _asTime(map['turnStart']),
      lastEventAt: _asTime(map['lastEventAt']),
      lastEndedAt: _asTime(map['lastEndedAt']),
      lastTurnCompleted: switch (map['completed']) {
        true => true,
        false => false,
        _ => null,
      },
    );
  }

  /// Projection cut the timing fields were read at.
  final int seq;

  /// The live status of the session (status events carry it, not the projection).
  final bool running;

  /// When the turn that is open (or was last open) started.
  final DateTime? turnStart;

  /// Host time of the newest committed event folded into that turn.
  final DateTime? lastEventAt;

  /// Host time of the last event of the last turn this app watched close: when
  /// that turn ended, as far as the app could see.
  final DateTime? lastEndedAt;

  /// Outcome of that turn: true completed, false ended otherwise, null unknown.
  final bool? lastTurnCompleted;

  /// The last moment the Host did something here, when the app has one.
  DateTime? get lastActivity => lastEndedAt ?? lastEventAt;

  /// What a panel would draw differently: a turn opening or closing, not each
  /// event inside it. [lastEventAt] moves with every streamed token, so it is
  /// kept without publishing a change.
  bool sameReading(AgentActivity other) =>
      running == other.running &&
      turnStart == other.turnStart &&
      lastEndedAt == other.lastEndedAt &&
      lastTurnCompleted == other.lastTurnCompleted;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'running': running,
    'turnStart': ?turnStart?.millisecondsSinceEpoch,
    'lastEventAt': ?lastEventAt?.millisecondsSinceEpoch,
    'lastEndedAt': ?lastEndedAt?.millisecondsSinceEpoch,
    'completed': ?lastTurnCompleted,
  };

  AgentActivity copyWith({
    int? seq,
    bool? running,
    DateTime? turnStart,
    DateTime? lastEventAt,
    DateTime? lastEndedAt,
    bool? lastTurnCompleted,
  }) => AgentActivity(
    seq: seq ?? this.seq,
    running: running ?? this.running,
    turnStart: turnStart ?? this.turnStart,
    lastEventAt: lastEventAt ?? this.lastEventAt,
    lastEndedAt: lastEndedAt ?? this.lastEndedAt,
    lastTurnCompleted: lastTurnCompleted ?? this.lastTurnCompleted,
  );

  @override
  bool operator ==(Object other) =>
      other is AgentActivity &&
      other.seq == seq &&
      other.running == running &&
      other.turnStart == turnStart &&
      other.lastEventAt == lastEventAt &&
      other.lastEndedAt == lastEndedAt &&
      other.lastTurnCompleted == lastTurnCompleted;

  @override
  int get hashCode => Object.hash(seq, running, turnStart, lastEventAt, lastEndedAt, lastTurnCompleted);
}

/// One observation folded into [prev]: a `session/list` row or a
/// `session/control` frame. [running] is the live status where the observer
/// knows it (a list row does; a projection frame only knows "a turn is open");
/// [timing] is the child's `subagentTiming` at [seq], and a cut older than what
/// is already known never rewrites the timing fields.
AgentActivity foldActivity(AgentActivity? prev, {int seq = -1, bool? running, SubagentTiming? timing}) {
  final known = prev ?? const AgentActivity();
  var next = AgentActivity(
    seq: known.seq,
    running: running ?? known.running,
    turnStart: known.turnStart,
    lastEventAt: known.lastEventAt,
    lastEndedAt: known.lastEndedAt,
    lastTurnCompleted: known.lastTurnCompleted,
  );
  if (seq < known.seq) return next;
  final since = timing?.activeSince;
  final through = timing?.activeThrough;
  if (since != null && since != known.turnStart) {
    // A new turn: its clock starts here, whatever the previous turn ended at.
    next = next.copyWith(turnStart: since, lastEventAt: through ?? since);
  } else if (through != null && (next.lastEventAt == null || through.isAfter(next.lastEventAt!))) {
    next = next.copyWith(lastEventAt: through);
  }
  final completed = timing?.lastTurnCompleted;
  if (completed != null && !next.running) {
    // The turn closed: its last event is the closest thing to an end time the
    // Host leaves behind (it drops `active` when the turn ends).
    next = next.copyWith(seq: seq, lastEndedAt: next.lastEventAt ?? known.lastEndedAt, lastTurnCompleted: completed);
  } else {
    next = next.copyWith(seq: seq);
  }
  return next;
}

/// Everything the app remembers, keyed by child session id.
typedef AgentActivityMap = Map<String, AgentActivity>;

/// How many sessions the store keeps: a conversation kept for a year collects
/// thousands of children, and the prompt-time fallback covers the rest.
const agentActivityKeep = 2000;

/// [records] with the newest [agentActivityKeep] kept (oldest activity out).
AgentActivityMap pruneActivity(AgentActivityMap records) {
  if (records.length <= agentActivityKeep) return records;
  final kept = records.entries.toList()
    ..sort((a, b) {
      final at = a.value.lastActivity ?? a.value.turnStart;
      final bt = b.value.lastActivity ?? b.value.turnStart;
      if (at == null && bt == null) return a.key.compareTo(b.key);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
  return {for (final entry in kept.take(agentActivityKeep)) entry.key: entry.value};
}

/// The store as JSON, for `SharedPreferences`.
String encodeActivity(AgentActivityMap records) =>
    jsonEncode({for (final entry in records.entries) entry.key: entry.value.toJson()});

AgentActivityMap decodeActivity(String? text) {
  if (text == null || text.isEmpty) return const {};
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return const {};
  }
  final map = _asMap(json);
  if (map == null) return const {};
  return {
    for (final entry in map.entries)
      if (entry.value is Map) entry.key: AgentActivity.fromJson(entry.value),
  };
}

/// Child session activity of the active Host, kept current by `session/list`
/// rows and `session/control` frames and remembered across launches.
///
/// [state] is what the app knows now; records loaded from the last launch are
/// underneath it, so a child that finished while the app was away still shows
/// the end time the app saw before it went.
class AgentActivityController extends Notifier<AgentActivityMap> {
  static const prefsKey = 'agent_activity_v1';

  final AgentActivityMap _records = {};
  AgentActivityMap _remembered = const {};
  Future<void>? _loaded;
  Timer? _save;

  @override
  AgentActivityMap build() {
    final conn = ref.watch(activeConnectionProvider).value;
    final sessions = ref.watch(hostSessionsProvider);
    _loaded ??= _readStore();
    _foldSessions(sessions.values);
    ref.onDispose(() {
      // A launch that ends inside the debounce still keeps the last turn it saw.
      final pending = _save;
      _save?.cancel();
      _save = null;
      if (pending != null) unawaited(_writeStore(pruneActivity(_merged())));
    });
    if (conn != null) {
      try {
        final sub = conn.client.watchSessionControl().listen(_onControl, onError: (Object _) {});
        ref.onDispose(() => unawaited(sub.cancel()));
      } catch (_) {
        // The carrier cannot open a stream (closed socket, or a test client):
        // list rows still carry the clock, just later.
      }
    }
    return _merged();
  }

  AgentActivityMap _merged() => {
    ..._remembered,
    ..._records,
  };

  /// Folds one `session/list` snapshot: a child row's status, and its timing
  /// when the row carries `subagentTiming`.
  void _foldSessions(Iterable<SessionSummary> rows) {
    var touched = false;
    for (final row in rows) {
      if (!row.isSubagent) continue;
      final timing = row.projections.subagentTiming;
      if (timing == null && !row.running) continue;
      final next = foldActivity(
        _records[row.sessionId] ?? _remembered[row.sessionId],
        seq: row.projections.asOfSeq,
        running: row.running,
        timing: timing,
      );
      final before = _records[row.sessionId];
      if (next == before) continue;
      _records[row.sessionId] = next;
      if (before == null || !next.sameReading(before)) touched = true;
    }
    if (touched) _persist();
  }

  void _onControl(SessionControlUpdate update) {
    if (!ref.mounted) return;
    switch (update) {
      case SessionControlBaseline(:final projections):
        for (final entry in projections.entries) {
          final timing = entry.value.subagentTiming;
          if (timing == null) continue;
          _apply(entry.key, seq: entry.value.asOfSeq, running: timing.activeSince == null ? null : true, timing: timing);
        }
      case SessionControlProjection(:final sessionId, :final key, :final value, :final seq)
          when key == 'subagentTiming':
        final timing = SubagentTiming.fromJson(value);
        if (timing == null) return;
        _apply(sessionId, seq: seq, running: timing.activeSince == null ? null : true, timing: timing);
      default:
        break;
    }
  }

  /// Records one observation (a `session/control` frame, or a caller that
  /// knows better). Exposed for the panels' tests, which drive frames directly.
  void applyObservation(String sessionId, {required int seq, bool? running, SubagentTiming? timing}) =>
      _apply(sessionId, seq: seq, running: running, timing: timing);

  void _apply(String sessionId, {required int seq, bool? running, SubagentTiming? timing}) {
    final before = _records[sessionId] ?? _remembered[sessionId];
    final next = foldActivity(before, seq: seq, running: running, timing: timing);
    if (next == before) return;
    _records[sessionId] = next;
    // A streamed event is not a redraw: only a turn opening or closing is.
    if (!next.sameReading(before ?? const AgentActivity())) {
      state = _merged();
      _persist();
    }
  }

  void _persist() {
    if (_save != null) return;
    _save = Timer(const Duration(seconds: 2), () {
      _save = null;
      unawaited(_writeStore(pruneActivity(_merged())));
    });
  }

  Future<void> _readStore() async {
    final loaded = await _loadStore();
    if (!ref.mounted) return;
    _remembered = loaded;
    state = _merged();
  }

  static Future<AgentActivityMap> _loadStore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return decodeActivity(prefs.getString(prefsKey));
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _writeStore(AgentActivityMap records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, encodeActivity(records));
    } catch (_) {
      // Storage unavailable (tests, platform denied): the live state is enough.
    }
  }
}

/// The activity of every child session the app has watched.
final agentActivityProvider = NotifierProvider<AgentActivityController, AgentActivityMap>(AgentActivityController.new);
