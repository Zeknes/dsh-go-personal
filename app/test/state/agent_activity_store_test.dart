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
    await store.flush();

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
}
