// 对话详情 › 子代理 over a conversation that dispatched thousands of children:
// the tab shows a page of them and adds a page per tap, so the page never
// builds the whole history.

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_app/ui/agents/agent_widgets.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support.dart';

Map<String, SessionSummary> _wide(int count) {
  final parent = SessionSummary(
    sessionId: parentId,
    updatedAt: agentsNow,
    running: false,
    blank: false,
    agentAvailable: false,
    projections: SessionProjections(10, {
      'title': '一条用了一年的对话',
      'subagentCatalog': [
        for (var i = 0; i < count; i++)
          {
            'id': 'c-$i',
            'mode': 'continuable',
            'label': '任务 $i',
            'createdAt': agentsNow.subtract(Duration(minutes: 60 + i)).millisecondsSinceEpoch,
          },
      ],
    }),
  );
  return {
    parent.sessionId: parent,
    for (var i = 0; i < count; i++)
      'c-$i': SessionSummary(
        sessionId: 'c-$i',
        updatedAt: agentsNow.subtract(Duration(seconds: i)),
        running: false,
        blank: false,
        agentAvailable: false,
        parentSessionId: parentId,
        origin: 'subagent',
        projections: const SessionProjections(10, {
          'subagentTiming': {'settledMs': 4000, 'lastTurnCompleted': true},
        }),
      ),
  };
}

Future<void> _pumpTab(WidgetTester tester, Map<String, SessionSummary> sessions) async {
  usePhoneView(tester);
  final harness = ChatHarness(session: parentId, states: {parentId: const ChatState(loading: false)});
  await tester.pumpWidget(
    testApp(
      const SessionDetailPage(sessionId: parentId, initialTab: SessionTab.subagents),
      overrides: [
        ...harness.overrides,
        hostSessionsProvider.overrideWithValue(sessions),
        workspaceSourceProvider.overrideWith((ref, id) => null),
        workspaceRootProvider.overrideWith((ref, id) => null),
      ],
    ),
  );
  await pumpFrames(tester, 8);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('five thousand children: a page at a time, never all of them', (tester) async {
    await _pumpTab(tester, _wide(5000));
    final first = tester.widgetList<SubagentRow>(find.byType(SubagentRow)).length;
    expect(first, lessThanOrEqualTo(recentLineageLimit));
    expect(first, greaterThan(0));
    expect(tester.takeException(), isNull);

    final fold = find.text('再显示 50 个');
    await tester.scrollUntilVisible(fold, 300, scrollable: find.byType(Scrollable).last, maxScrolls: 60);
    await tester.ensureVisible(fold);
    await pumpFrames(tester, 2);
    await tester.tap(fold);
    await pumpFrames(tester, 4);

    final grown = tester.widgetList<SubagentRow>(find.byType(SubagentRow)).length;
    expect(grown, greaterThan(first));
    expect(grown, lessThanOrEqualTo(recentLineageLimit + lineagePage + 1));
    expect(grown, lessThan(5000));
    expect(find.text('5000 个子代理'), findsOneWidget);
  });

  testWidgets('a short history has no paging row', (tester) async {
    await _pumpTab(tester, _wide(4));
    expect(tester.widgetList<SubagentRow>(find.byType(SubagentRow)).length, 4);
    expect(find.textContaining('再显示'), findsNothing);
  });
}
