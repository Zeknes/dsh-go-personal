import 'dart:async';

import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final stored in [null, false, true]) {
    test('personal auto approval defaults and retains stored choice: $stored', () async {
      final preferences = <String, Object>{};
      if (stored != null) preferences['auto_approve_commands'] = stored;
      SharedPreferences.setMockInitialValues(preferences);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final loaded = Completer<void>();
      final subscription = container.listen(settingsProvider, (_, next) {
        if (next.loaded && !loaded.isCompleted) loaded.complete();
      }, fireImmediately: true);
      addTearDown(subscription.close);
      await loaded.future;
      expect(container.read(settingsProvider).autoApproveCommands, stored ?? true);
    });
  }
}
