// What the Host last did inside a subagent's conversation, and when.
//
// `session/list` dates a child by its last prompt (dispatch or continuation),
// which never moves when the child works or finishes. The Host does publish its
// own event clock, though: the child's `subagentTiming` projection carries
// `active.through` — the time of the newest committed event folded into the open
// turn — and drops it when the turn closes. So the app reads that clock while a
// turn runs and remembers, per child session, when it last saw a turn end; that
// is the "last real update" a finished child is ordered by, while a running one
// is ordered by its newest event. A turn the app never saw close (closed while
// the app was away, or history from an older Host) keeps no end time, and the
// lineage falls back to the prompt time.
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

  /// Host time of the last event the app saw in the last turn it watched close.
  /// The Host drops `active` at `turn/end`, so this is the closest the app gets
  /// to an end time — not the turn's exact end.
  final DateTime? lastEndedAt;

  /// Outcome of that turn: true completed, false ended otherwise, null unknown.
  final bool? lastTurnCompleted;

  /// The last moment the Host did something here, when the app has one.
  DateTime? get lastActivity => lastEndedAt ?? lastEventAt;

  /// What a panel draws differently at once: a turn opening or closing. An
  /// event inside an open turn still moves the order, and is published through
  /// the controller's publish window rather than immediately.
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

/// What this launch saw ([live]) with the facts a previous launch remembered
/// underneath: a list row that carries no end time does not erase an end the
/// app watched before it went away.
AgentActivity mergeActivity(AgentActivity live, AgentActivity remembered) {
  final liveEnded = live.lastEndedAt;
  final rememberedEnded = remembered.lastEndedAt;
  final useRememberedEnd =
      liveEnded == null || (rememberedEnded != null && rememberedEnded.isAfter(liveEnded));
  return AgentActivity(
    seq: live.seq >= remembered.seq ? live.seq : remembered.seq,
    running: live.running,
    turnStart: live.turnStart ?? remembered.turnStart,
    // The event clock belongs to whichever turn this launch knows about.
    lastEventAt: live.turnStart != null ? live.lastEventAt : remembered.lastEventAt,
    lastEndedAt: useRememberedEnd ? rememberedEnded : liveEnded,
    lastTurnCompleted: useRememberedEnd ? remembered.lastTurnCompleted : live.lastTurnCompleted,
  );
}

/// Everything the app remembers, keyed by child session id.
typedef AgentActivityMap = Map<String, AgentActivity>;

/// How many sessions the store keeps: a conversation kept for a year collects
/// thousands of children, and the prompt-time fallback covers the rest.
const agentActivityKeep = 2000;

/// [records] with the newest [agentActivityKeep] kept (oldest activity out).
/// This caps only the time cache: tasks and their sessions are never removed
/// here, and a child without a record still appears in the lineage, dated by
/// its dispatch time.
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
/// Records loaded from the last launch are merged under what this connection
/// sees, so a child that finished while the app was away still shows the end
/// time the app saw before it went.
class AgentActivityController extends Notifier<AgentActivityMap> {
  static const prefsKey = 'agent_activity_v1';

  final AgentActivityMap _records = {};
  Future<void>? _loaded;
  Timer? _save;
  Timer? _publish;

  /// How often an event inside an open turn may reach the list: a stream of
  /// tokens moves the order at most this often, while the time published is
  /// always the Host's newest committed event, never a local clock read.
  static const publishWindow = Duration(milliseconds: 500);

  @override
  AgentActivityMap build() {
    final conn = ref.watch(activeConnectionProvider).value;
    _loaded ??= _readStore();
    _foldSessions(ref.read(hostSessionsProvider).values);
    // A new session list folds in without rebuilding this notifier: rebuilding
    // would re-subscribe the control stream on every refresh.
    ref.listen(hostSessionsProvider, (_, next) {
      if (_foldSessions(next.values)) _publishNow();
    });
    ref.onDispose(() {
      // A launch that ends inside the debounce still keeps the last turn it saw.
      final pending = _save;
      _save?.cancel();
      _save = null;
      _publish?.cancel();
      _publish = null;
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

  AgentActivityMap _merged() => Map.unmodifiable(_records);

  /// Folds one `session/list` snapshot: a child row's status, and its timing
  /// when the row carries `subagentTiming`. Returns whether anything changed.
  bool _foldSessions(Iterable<SessionSummary> rows) {
    var changed = false;
    var boundary = false;
    for (final row in rows) {
      if (!row.isSubagent) continue;
      final timing = row.projections.subagentTiming;
      if (timing == null && !row.running) continue;
      final next = foldActivity(
        _records[row.sessionId],
        seq: row.projections.asOfSeq,
        running: row.running,
        timing: timing,
      );
      final before = _records[row.sessionId];
      if (next == before) continue;
      _records[row.sessionId] = next;
      changed = true;
      if (before == null || !next.sameReading(before)) boundary = true;
    }
    if (boundary) _persist();
    return changed;
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
    final before = _records[sessionId];
    final next = foldActivity(before, seq: seq, running: running, timing: timing);
    if (next == before) return;
    _records[sessionId] = next;
    // A turn opening or closing redraws at once; an event inside one only moves
    // the order, so it is merged into at most one redraw per publish window.
    if (!next.sameReading(before ?? const AgentActivity())) {
      _publishNow();
      _persist();
    } else if (next.lastEventAt != before?.lastEventAt) {
      _publishSoon();
    }
  }

  void _publishNow() {
    _publish?.cancel();
    _publish = null;
    if (ref.mounted) state = _merged();
  }

  void _publishSoon() {
    if (_publish != null) return;
    _publish = Timer(publishWindow, () {
      _publish = null;
      if (ref.mounted) state = _merged();
    });
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
    if (!ref.mounted || loaded.isEmpty) return;
    for (final entry in loaded.entries) {
      final live = _records[entry.key];
      _records[entry.key] = live == null ? entry.value : mergeActivity(live, entry.value);
    }
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
