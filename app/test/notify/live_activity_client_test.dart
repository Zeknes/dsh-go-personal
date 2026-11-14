import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support.dart';

class _Local extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

class _Channel extends FakeNotifyChannel {
  final pushes = <LivePush>[];
  @override
  Future<void> live(LivePush push) async => pushes.add(push);
}

Future<void> _until(bool Function() test) async {
  for (var i = 0; i < 200; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for host event');
}

void main() {
  test('real client host events feed live activity across runs, requests and reconnect', () async {
    SharedPreferences.setMockInitialValues({});
    final host = await FakeDsh.start();
    var running = false;
    var reason = 'completed';
    var seq = 1;
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {
        'items': [
          {
            'sessionId': 's1',
            'running': running,
            'agentAvailable': true,
            'updatedAt': 1,
            'projections': {
              'asOfSeq': seq,
              'values': {'title': 'Task'},
            },
          },
        ],
      },
    };
    host.handlers['session/projections'] = (_) => {
      'ok': true,
      'value': {
        'kind': 'sequenced',
        'asOfSeq': seq,
        'values': {'title': 'Task'},
      },
    };
    host.handlers['session/page'] = (_) => {
      'ok': true,
      'value': {
        'records': [
          {
            'type': 'event',
            'event': {
              'type': 'turn/end',
              'seq': seq,
              'time': 1,
              'data': {
                'turn': seq,
                'reason': {
                  'kind': reason,
                  if (reason == 'aborted') 'reason': {'kind': 'user'},
                },
              },
            },
          },
        ],
        'hasMore': false,
      },
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    final channel = _Channel();
    final container = ProviderContainer(
      overrides: [
        localConnectionProvider.overrideWith(_Local.new),
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: client, label: 'Lab', isLocal: false, kind: HostKind.ssh, hostId: 'lab')),
        ),
        activeHostProvider.overrideWith(() => _Host()),
        notifyChannelProvider.overrideWithValue(channel),
        alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
      ],
    );
    final alerts = container.listen(chatAlertsProvider, (_, _) {});
    final bridge = container.listen(liveActivityBridgeProvider, (_, _) {});
    addTearDown(() async {
      alerts.close();
      bridge.close();
      container.dispose();
      await channel.actionController.close();
      await channel.tapController.close();
      await client.close();
      await host.close();
    });
    await _until(() => host.rpcCalls.any((c) => c['method'] == 'session/list'));
    container.read(appForegroundProvider.notifier).set(false);
    void status(bool value) {
      running = value;
      host.sockets.last.event({
        'type': 'emit',
        'event': 'api-session/status',
        'args': ['s1', value],
      });
    }

    status(true);
    await _until(() => container.read(liveActivityProvider)?.kind == LiveKind.running);
    status(false);
    await _until(() => container.read(liveActivityProvider)?.kind == LiveKind.done);
    await _until(() => channel.pushes.lastOrNull?.activity?.kind == LiveKind.done);
    expect(channel.shown.last.kind, 'done');
    seq++;
    status(true);
    await _until(() => container.read(liveActivityProvider)?.kind == LiveKind.running);
    reason = 'error';
    status(false);
    await _until(() => container.read(liveActivityProvider)?.kind == LiveKind.failed);
    seq++;
    status(true);
    await _until(() => container.read(liveActivityProvider)?.kind == LiveKind.running);
    reason = 'aborted';
    status(false);
    await _until(() => channel.shown.any((post) => post.kind == 'stopped'));
    expect(container.read(liveActivityProvider), isNull);
    host.sockets.last.event({
      'type': 'waterfall',
      'eventId': 'e1',
      'event': 'approval/request',
      'agentId': 's1',
      'request': {'toolName': 'bash'},
    });
    await _until(() => container.read(liveActivityProvider)?.kind == LiveKind.waiting);
    expect(container.read(liveActivityProvider)?.eventId, 'e1');
    container.read(appForegroundProvider.notifier).set(true);
    expect(container.read(liveActivityProvider)?.kind, LiveKind.waiting);
    host.pendingWaterfalls.add({
      'type': 'waterfall',
      'eventId': 'e1',
      'event': 'approval/request',
      'agentId': 's1',
      'request': {'toolName': 'bash'},
    });
    client.mux.reconnect();
    await client.mux.ready();
    await _until(() => host.sockets.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(liveActivityProvider)?.kind, LiveKind.waiting);
    host.sockets.last.event({'type': 'cancel', 'eventId': 'e1'});
    await _until(() => container.read(liveActivityProvider) == null);
  });
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => const HostRef.ssh('lab');
}
