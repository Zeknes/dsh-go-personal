import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/new_chat_options.dart';
import 'package:dsh_app/ui/settings/interface_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

void main() {
  for (final oldValue in [true, false]) {
    testWidgets('legacy suggestion preference $oldValue does not restore suggestions', (tester) async {
      SharedPreferences.setMockInitialValues({'chat_suggestions': oldValue});
      usePhoneView(tester);
      final harness = ChatHarness();
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await pumpFrames(tester, 8);
      expect(find.byType(NewChatOptions), findsOneWidget);
      expect(find.text('看看工作区'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      Navigator.of(tester.element(find.byType(ChatScreen)))
          .push(MaterialPageRoute<void>(builder: (_) => const InterfacePage()));
      await pumpFrames(tester, 8);
      expect(find.text('聊天建议'), findsNothing);
    });
  }
}
