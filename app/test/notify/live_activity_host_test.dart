import 'package:dsh_app/state/task_models.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/task_runs.dart';
import 'package:dsh_app/ui/notify/chat_alert_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingNotify extends NotifyChannel {
  final pushes = <LivePush>[];
  @override
  Future<NotifySystemStatus> status() async => const NotifySystemStatus();
  @override
  Future<void> live(LivePush push) async => pushes.add(push);
}

void main() {
  testWidgets('home host mounts live updates once, follows data, and disposes', (tester) async {
    final channel = RecordingNotify();
    final runs = ValueNotifier<List<TaskRun>>([]);
    final container = ProviderContainer(
      overrides: [
        notifyChannelProvider.overrideWithValue(channel),
        notifySystemStatusProvider.overrideWith((ref) async => const NotifySystemStatus()),
        taskRunsProvider.overrideWith(() => _Runs(runs)),
      ],
    );
    addTearDown(() {
      container.dispose();
      runs.dispose();
    });
    Widget home() => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ChatAlertHost())),
    );
    await tester.pumpWidget(home());
    await tester.pump();
    await tester.pump();
    expect(channel.pushes.length, 1);
    expect(channel.pushes.last.activity, isNull);
    runs.value = [const TaskRun(HostRef.local, 's1')];
    await tester.pump();
    expect(channel.pushes.last.activity?.kind, LiveKind.running);
    final before = channel.pushes.length;
    await tester.pumpWidget(home());
    await tester.pump();
    expect(channel.pushes.length, before);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    runs.value = [];
    await tester.pump();
    expect(channel.pushes.length, before);
    await tester.pumpWidget(home());
    await tester.pump();
    expect(channel.pushes.length, before + 1);
  });
}

class _Runs extends TaskRunsController {
  _Runs(this.runs);
  final ValueNotifier<List<TaskRun>> runs;
  @override
  List<TaskRun> build() {
    void changed() => state = runs.value;
    runs.addListener(changed);
    ref.onDispose(() => runs.removeListener(changed));
    return runs.value;
  }
}
