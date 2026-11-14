import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
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
    final target = PetTarget(HostRef.local, 's1');
    final signals = ValueNotifier(PetSignals(lastInteraction: DateTime(2026)));
    final state = ValueNotifier(const PetState());
    final container = ProviderContainer(
      overrides: [
        notifyChannelProvider.overrideWithValue(channel),
        notifySystemStatusProvider.overrideWith((ref) async => const NotifySystemStatus()),
        petSignalsProvider.overrideWith((ref) {
          void changed() => ref.invalidateSelf();
          signals.addListener(changed);
          ref.onDispose(() => signals.removeListener(changed));
          return signals.value;
        }),
        petStateProvider.overrideWith((ref) {
          void changed() => ref.invalidateSelf();
          state.addListener(changed);
          ref.onDispose(() => state.removeListener(changed));
          return state.value;
        }),
      ],
    );
    addTearDown(() {
      container.dispose();
      signals.dispose();
      state.dispose();
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
    signals.value = PetSignals(lastInteraction: DateTime(2026), runs: [PetRun(HostRef.local, 's1')]);
    state.value = PetState(state: PetStateName.working, target: target, active: true);
    await tester.pump();
    expect(channel.pushes.last.activity?.kind, LiveKind.running);
    final before = channel.pushes.length;
    await tester.pumpWidget(home());
    await tester.pump();
    expect(channel.pushes.length, before);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    signals.value = PetSignals(lastInteraction: DateTime(2026));
    state.value = const PetState();
    await tester.pump();
    expect(channel.pushes.length, before);
    await tester.pumpWidget(home());
    await tester.pump();
    expect(channel.pushes.length, before + 1);
    state.value = PetState(state: PetStateName.working, target: target, active: true);
    signals.value = PetSignals(lastInteraction: DateTime(2026), runs: [PetRun(HostRef.local, 's1')]);
    await tester.pump();
    expect(channel.pushes.length, before + 2);
  });
}
