import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'task_models.dart';
import 'connection_state.dart';
import 'hosts_state.dart';

class _HostRuns {
  _HostRuns(this.host, this.client, this.clock, this.onChange) {
    _sub = client.hostEvents.listen(_onEvent, onError: (_) {});
    if (client.mux.generation != null) unawaited(_list());
  }

  final HostRef host;
  final DshClient client;
  final DateTime Function() clock;
  final void Function() onChange;
  late final StreamSubscription<HostEvent> _sub;
  final Map<String, SessionSummary> _info = {};
  final Map<String, DateTime?> _running = {};
  bool _disposed = false;
  bool _listing = false;
  int _readyEpoch = 0;
  bool _listAgain = false;
  final _statusDuringList = <String>{};
  final _infoDuringList = <String>{};

  String _root(String id) {
    var current = id;
    for (var depth = 0; depth < 8; depth++) {
      final parent = _info[current]?.parentSessionId;
      if (!(_info[current]?.isSubagent ?? false) || parent == null || parent.isEmpty) return current;
      current = parent;
    }
    return current;
  }

  List<TaskRun> get runs => [
    for (final MapEntry(:key, :value) in _running.entries)
      TaskRun(
        host,
        key,
        subagent: _info[key]?.isSubagent ?? false,
        root: _root(key),
        since: value,
        title: _info[_root(key)]?.title,
      ),
  ];

  void _onEvent(HostEvent event) {
    if (_disposed) return;
    switch (event) {
      case HostReadyEvent():
        _readyEpoch++;
        if (_listing) {
          _listAgain = true;
        } else {
          unawaited(_list());
        }
      case SessionStatusEvent(:final sessionId, :final running):
        // Even an idempotent false edge is newer than an in-flight list.
        if (_listing) _statusDuringList.add(sessionId);
        if (running == _running.containsKey(sessionId)) return;
        if (running) {
          _running[sessionId] = clock();
        } else {
          _running.remove(sessionId);
        }
        if (!_info.containsKey(sessionId)) unawaited(_list());
        onChange();
      case SessionAddedEvent(:final summary):
        if (_listing) _infoDuringList.add(summary.sessionId);
        _info[summary.sessionId] = summary;
      case SessionRemovedEvent(:final sessionId):
        if (_listing) {
          _statusDuringList.add(sessionId);
          _infoDuringList.add(sessionId);
        }
        _info.remove(sessionId);
        if (_running.containsKey(sessionId)) {
          _running.remove(sessionId);
          onChange();
        }
      default:
        break;
    }
  }

  Future<void> _list() async {
    if (_disposed || _listing) return;
    _listing = true;
    final readyEpoch = _readyEpoch;
    _statusDuringList.clear();
    _infoDuringList.clear();
    try {
      final list = await client.listSessions();
      if (_disposed || readyEpoch != _readyEpoch) return;
      // Merge the snapshot only for fields untouched by newer stream edges.
      // Tombstones stay in the sets until this request finishes, so a removal
      // or an already-false status cannot be resurrected by its old response.
      final changedInfo = {
        for (final id in _infoDuringList)
          if (_info.containsKey(id)) id: _info[id]!,
      };
      final changedStatus = {
        for (final id in _statusDuringList)
          if (_running.containsKey(id)) id: _running[id],
      };
      _info
        ..clear()
        ..addEntries(list.where((s) => !_infoDuringList.contains(s.sessionId)).map((s) => MapEntry(s.sessionId, s)))
        ..addAll(changedInfo);
      final was = {..._running};
      _running
        ..clear()
        ..addEntries([
          for (final s in list)
            if (s.running && !_statusDuringList.contains(s.sessionId))
              MapEntry(s.sessionId, was[s.sessionId] ?? s.updatedAt),
        ])
        ..addAll(changedStatus);
      onChange();
    } catch (_) {
      // Unreachable for now: what we knew stays.
    } finally {
      _listing = false;
      _statusDuringList.clear();
      _infoDuringList.clear();
      if (_listAgain && !_disposed) {
        _listAgain = false;
        unawaited(_list());
      }
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
  }
}

/// Every running conversation and subagent on the on-device engine and the
/// active remote host.
class TaskRunsController extends Notifier<List<TaskRun>> {
  final Map<HostRef, _HostRuns> _hosts = {};
  bool _built = false;

  @override
  List<TaskRun> build() {
    _built = false;
    ref.onDispose(() {
      for (final h in _hosts.values) {
        h.dispose();
      }
      _hosts.clear();
    });
    ref.listen(localConnectionProvider, (_, next) => _attach(HostRef.local, next.value), fireImmediately: true);
    ref.listen(activeConnectionProvider, (_, next) {
      final conn = next.value;
      final host = conn == null || conn.isLocal ? null : ref.read(activeHostProvider);
      for (final other in [..._hosts.keys]) {
        if (!other.isLocal && other != host) _attach(other, null);
      }
      if (host != null && !host.isLocal) _attach(host, conn);
    }, fireImmediately: true);
    _built = true;
    return _collect();
  }

  void _attach(HostRef host, HostConnection? connection) {
    final current = _hosts[host];
    if (current != null && identical(current.client, connection?.client)) return;
    current?.dispose();
    _hosts.remove(host);
    if (connection != null) {
      _hosts[host] = _HostRuns(host, connection.client, DateTime.now, _changed);
    }
    _changed();
  }

  List<TaskRun> _collect() => [for (final h in _hosts.values) ...h.runs];

  void _changed() {
    if (!_built) return;
    final next = _collect();
    if (next.length != state.length || !next.toSet().containsAll(state)) state = next;
  }
}

final taskRunsProvider = NotifierProvider<TaskRunsController, List<TaskRun>>(TaskRunsController.new);
