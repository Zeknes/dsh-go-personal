import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/ui/chat/widgets/plus_panel.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';
import '../shell/golden_harness.dart' show FakeRuntime, runningStatus;

void main() {
  for (final surface in ['settings', 'session']) {
    for (final remote in [true, false]) {
      testWidgets('permission default: $surface on ${remote ? 'a remote host' : 'this phone'}, at once and no dialog', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({'auto_approve_commands': false});
        usePhoneView(tester);
        final remoteCarrier = FakePluginCarrier();
        final localCarrier = FakePluginCarrier();
        final remoteClient = DshClient.withCarrier(remoteCarrier);
        final localClient = DshClient.withCarrier(localCarrier);
        addTearDown(remoteClient.close);
        addTearDown(localClient.close);
        for (final carrier in [remoteCarrier, localCarrier]) {
          carrier.handlers['settings/describe'] = (_) => {
            'writable': true,
            'namespaces': [
              {'ns': 'permission', 'value': <String, Object?>{}, 'revision': 4},
            ],
          };
          carrier.handlers['permissionPresets/catalog'] = (_) => {
            'options': [
              {'value': 'workspace-write', 'name': 'workspace-write'},
              {'value': 'read-only', 'name': 'read-only'},
              {'value': 'danger-full-access', 'name': 'danger-full-access'},
            ],
            'defaultPreset': 'danger-full-access',
          };
          carrier.handlers['session/projections'] = (_) => {
            'kind': 'sequenced',
            'asOfSeq': 1,
            'values': {
              'permissions': {'currentValue': 'read-only'},
            },
          };
          carrier.handlers['settings/mutate'] = (_) => {
            'ns': 'permission',
            'value': {'defaultPreset': 'read-only'},
            'revision': 5,
          };
        }
        await tester.pumpWidget(
          testApp(
            surface == 'settings'
                ? const PermissionPage()
                : const Scaffold(body: SessionPermissionPage(sessionId: 's1')),
            overrides: [
              sessionModesProvider.overrideWith((ref, id) => const SessionModes(preset: 'read-only')),
              activeConnectionProvider.overrideWith((ref) {
                final host = ref.watch(activeHostProvider);
                return AsyncData(
                  host.kind == HostKind.local
                      ? HostConnection(client: localClient, isLocal: true)
                      : HostConnection(client: remoteClient, isLocal: false, kind: HostKind.ssh, hostId: 'pc'),
                );
              }),
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(LocalRuntimeState(loaded: true, status: runningStatus)),
              ),
            ],
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(surface == 'settings' ? PermissionPage : SessionPermissionPage)),
        );
        container.read(activeHostProvider.notifier).select(remote ? const HostRef.ssh('pc') : HostRef.local);
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).autoApproveCommands, isFalse);

        await tester.tap(find.text(surface == 'settings' ? '仅可查看' : '设为新对话默认').last);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

        final prefs = await SharedPreferences.getInstance();
        expect(
          [container.read(settingsProvider).autoApproveCommands, prefs.getBool('auto_approve_commands') ?? false],
          [false, false],
        );
        expect(remoteCarrier.argsOf('settings/mutate').length, remote ? 1 : 0);
        expect(localCarrier.argsOf('settings/mutate').length, remote ? 0 : 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
