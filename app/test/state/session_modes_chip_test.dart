// The chip above the composer names the conversation's permission — every
// preset but 完全权限, which shows nothing.

import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the composer chip', () {
    test('完全权限 carries none', () {
      const modes = SessionModes(preset: 'danger-full-access');
      expect(modes.chipPreset, isNull);
    });

    for (final preset in ['read-only', 'workspace-write', 'custom']) {
      test('$preset is named', () {
        expect(SessionModes(preset: preset).chipPreset, preset);
      });
    }

    test('自动审查 is named too', () {
      expect(const SessionModes(preset: 'auto').chipPreset, 'auto');
    });

    test('nothing until the log says', () {
      expect(SessionModes.unknown.chipPreset, isNull);
    });
  });

  test('a logged preset change moves the chip', () {
    var modes = foldSessionModes(
      const SessionProjections(3, {
        'permissions': {'currentValue': 'workspace-write'},
      }),
      const [],
    );
    expect(modes.chipPreset, 'workspace-write');

    modes = foldSessionModes(
      const SessionProjections(3, {
        'permissions': {'currentValue': 'workspace-write'},
      }),
      [
        PermissionPresetChangedEvent(
          4,
          DateTime(2026, 11, 16),
          const {'preset': 'danger-full-access'},
          preset: 'danger-full-access',
        ),
      ],
    );
    expect(modes.chipPreset, isNull);
  });
}
