import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/ui/modes/mode_switch.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Widget _app(Widget home) => ProviderScope(
  child: MaterialApp(
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

void main() {
  testWidgets('removed tavern startup falls back to work', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'tavern'});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();
    expect(find.text('工作首页'), findsOneWidget);
  });

  testWidgets('work remains the default startup', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();
    expect(find.text('工作首页'), findsOneWidget);
  });
}
