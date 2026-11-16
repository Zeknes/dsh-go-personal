// The activity store across launches: what one launch saw a turn end at is
// still there in the next, so a finished child keeps its real end time even if
// the app was closed while it ran.

import 'package:dsh_app/state/agent_activity.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _endedAt = DateTime(2026, 11, 16, 10, 30);

AgentActivity _closedRecord({required bool completed}) => foldActivity(
  foldActivity(
    null,
    seq: 90,
    running: true,
    timing: SubagentTiming(
      activeSince: _endedAt.subtract(const Duration(minutes: 4)),
      activeThrough: _endedAt,
    ),
  ),
  seq: 92,
  running: false,
  timing: SubagentTiming(settled: const Duration(minutes: 4), lastTurnCompleted: completed),
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
      hostSessionsProvider.overrideWithValue(const {}),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The store loads its records in a microtask.
Future<void> _settled() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new launch reads back the end time the last one saw', () async {
    final record = _closedRecord(completed: true);
    SharedPreferences.setMockInitialValues({
      AgentActivityController.prefsKey: encodeActivity({'child-1': record}),
    });
    final container = _container();
    container.read(agentActivityProvider);
    await _settled();

    final loaded = container.read(agentActivityProvider)['child-1'];
    expect(loaded, isNotNull);
    expect(loaded!.lastEndedAt, _endedAt);
    expect(loaded.lastTurnCompleted, isTrue);
  });

  test('an ending the app watched is on disk before the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final container = _container();
    container.read(agentActivityProvider);
    await _settled();

    final store = container.read(agentActivityProvider.notifier);
    store.applyObservation(
      'child-2',
      seq: 90,
      running: true,
      timing: SubagentTiming(
        activeSince: _endedAt.subtract(const Duration(minutes: 4)),
        activeThrough: _endedAt,
      ),
    );
    store.applyObservation(
      'child-2',
      seq: 92,
      running: false,
      timing: const SubagentTiming(settled: Duration(minutes: 4), lastTurnCompleted: false),
    );
    // The store batches writes; wait out its debounce.
    await Future<void>.delayed(const Duration(milliseconds: 2200));

    final prefs = await SharedPreferences.getInstance();
    final saved = decodeActivity(prefs.getString(AgentActivityController.prefsKey));
    expect(saved['child-2']!.lastEndedAt, _endedAt);
    expect(saved['child-2']!.lastTurnCompleted, isFalse);

    // And the other direction: a fresh container shows it without any frame.
    final next = _container();
    next.read(agentActivityProvider);
    await _settled();
    expect(next.read(agentActivityProvider)['child-2']!.lastEndedAt, _endedAt);
  });

  test('a list row of this launch does not drop the remembered end', () async {
    SharedPreferences.setMockInitialValues({
      AgentActivityController.prefsKey: encodeActivity({'child-4': _closedRecord(completed: true)}),
    });
    // The row the Host sends now has the outcome but no clock: it dropped the
    // open turn when the turn ended.
    final row = SessionSummary(
      sessionId: 'child-4',
      updatedAt: _endedAt.subtract(const Duration(minutes: 30)),
      running: false,
      blank: false,
      agentAvailable: false,
      parentSessionId: 'parent',
      origin: 'subagent',
      projections: const SessionProjections(92, {
        'subagentTiming': {'settledMs': 240000, 'lastTurnCompleted': true},
      }),
    );
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        hostSessionsProvider.overrideWithValue({'child-4': row}),
      ],
    );
    addTearDown(container.dispose);
    container.read(agentActivityProvider);
    await _settled();

    final record = container.read(agentActivityProvider)['child-4']!;
    expect(record.lastEndedAt, _endedAt);
    expect(record.lastTurnCompleted, isTrue);
  });

  test('what a later frame says wins over the remembered record', () async {
    final remembered = _closedRecord(completed: true);
    SharedPreferences.setMockInitialValues({
      AgentActivityController.prefsKey: encodeActivity({'child-3': remembered}),
    });
    final container = _container();
    container.read(agentActivityProvider);
    await _settled();

    // A continuation opened a new turn after the remembered end.
    final later = _endedAt.add(const Duration(minutes: 10));
    container.read(agentActivityProvider.notifier).applyObservation(
      'child-3',
      seq: 120,
      running: true,
      timing: SubagentTiming(activeSince: later, activeThrough: later.add(const Duration(seconds: 5))),
    );
    final now = container.read(agentActivityProvider)['child-3']!;
    expect(now.turnStart, later);
    expect(now.running, isTrue);
    // The old end is still a fact about the previous turn; a running child is
    // ordered by the turn it is in.
    expect(now.lastEndedAt, _endedAt);
  });

  test('events inside a running turn reach listeners once per publish window', () async {
    SharedPreferences.setMockInitialValues({});
    final container = _container();
    final seen = <AgentActivityMap>[];
    container.listen(agentActivityProvider, (_, next) => seen.add(next), fireImmediately: true);
    await _settled();
    final store = container.read(agentActivityProvider.notifier);
    final start = _endedAt.subtract(const Duration(minutes: 5));
    SubagentTiming open(int seconds) =>
        SubagentTiming(activeSince: start, activeThrough: start.add(Duration(seconds: seconds)));

    // The turn opening is a status change: published at once.
    store.applyObservation('child-5', seq: 10, running: true, timing: open(0));
    expect(container.read(agentActivityProvider)['child-5']!.running, isTrue);
    seen.clear();

    // Many token slices in a row: no rebuild per slice, and the time carried is
    // the Host's newest event.
    for (final seconds in [1, 2, 3, 4, 5]) {
      store.applyObservation('child-5', seq: 10 + seconds, timing: open(seconds));
    }
    expect(seen, isEmpty);
    await Future<void>.delayed(AgentActivityController.publishWindow + const Duration(milliseconds: 120));
    expect(seen, hasLength(1));
    expect(
      container.read(agentActivityProvider)['child-5']!.lastEventAt,
      start.add(const Duration(seconds: 5)),
    );

    // Nothing new: waiting another window publishes nothing (no tick-made update).
    seen.clear();
    await Future<void>.delayed(AgentActivityController.publishWindow + const Duration(milliseconds: 120));
    expect(seen, isEmpty);
  });
}
