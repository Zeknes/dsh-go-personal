// The subtitle sheet over a long-lived conversation: a thousand children are
// built lazily, the history is one row away, search finds any of them, and a
// child changing state moves without losing its row.

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/agents/agent_widgets.dart';
import 'package:dsh_app/ui/agents/lineage_sheet.dart';
import 'package:dsh_app/ui/common/search_capsule.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support.dart';

/// The sessions on screen; a test swaps the map to let a child change state.
class _Sessions extends Notifier<Map<String, SessionSummary>> {
  _Sessions(this.initial);

  final Map<String, SessionSummary> initial;

  @override
  Map<String, SessionSummary> build() => initial;

  void update(Map<String, SessionSummary> value) => state = value;
}

final _sessionsProvider = NotifierProvider<_Sessions, Map<String, SessionSummary>>(
  () => throw UnimplementedError('overridden per test'),
);

SessionSummary _child(
  String id, {
  required DateTime updatedAt,
  bool running = false,
  bool? lastTurnCompleted,
  String? title,
}) => SessionSummary(
  sessionId: id,
  updatedAt: updatedAt,
  running: running,
  blank: false,
  agentAvailable: running,
  parentSessionId: parentId,
  origin: 'subagent',
  projections: SessionProjections(10, {
    'title': ?title,
    'subagentTiming': {
      'settledMs': lastTurnCompleted == true ? 30000 : 0,
      'lastTurnCompleted': ?lastTurnCompleted,
      if (running) 'active': {
        'since': updatedAt.millisecondsSinceEpoch,
        'through': updatedAt.millisecondsSinceEpoch + 500,
      },
    },
  }),
);

/// A parent with [count] children, newest dispatched first; [running] of them
/// are still working.
Map<String, SessionSummary> _wide(int count, {Set<String> running = const {}}) {
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
            'mode': i.isEven ? 'continuable' : 'one-shot',
            'label': '任务 $i',
            'createdAt': agentsNow.subtract(Duration(minutes: 60 + i)).millisecondsSinceEpoch,
          },
      ],
    }),
  );
  return {
    parent.sessionId: parent,
    for (var i = 0; i < count; i++)
      'c-$i': _child(
        'c-$i',
        updatedAt: agentsNow.subtract(Duration(seconds: i)),
        running: running.contains('c-$i'),
        lastTurnCompleted: running.contains('c-$i') ? null : true,
      ),
  };
}

List<Override> _overrides(Map<String, SessionSummary> sessions) => [
  _sessionsProvider.overrideWith(() => _Sessions(sessions)),
  hostSessionsProvider.overrideWith((ref) => ref.watch(_sessionsProvider)),
  activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
  teamProvider.overrideWith2((leadId) => FakeTeam(leadId, null)),
  teamMessagesProvider.overrideWith((ref, leadId) async => const TeamMessagesSnapshot()),
  installedPluginsProvider.overrideWith(() => FakeInstalled(const [])),
];

Future<ProviderContainer> _pump(WidgetTester tester, Map<String, SessionSummary> sessions) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(const Scaffold(body: LineageSheet(sessionId: parentId)), overrides: _overrides(sessions)),
  );
  await pumpFrames(tester, 6);
  return ProviderScope.containerOf(tester.element(find.byType(LineageSheet)));
}

/// The sheet's own list (the one that scrolls vertically).
final Finder _list = find.byType(ListView);

/// Scrolls until [finder] is on screen; the paced rows end below the fold.
Future<void> _scrollTo(WidgetTester tester, Finder finder, {double delta = 500, int maxScrolls = 400}) async {
  await tester.scrollUntilVisible(finder, delta, scrollable: find.byType(Scrollable).last, maxScrolls: maxScrolls);
  await pumpFrames(tester, 4);
}

List<String> _visibleIds(WidgetTester tester) => [
  for (final row in tester.widgetList<SubagentRow>(find.byType(SubagentRow))) row.node.id,
];

double _topOf(WidgetTester tester, String title) => tester.getTopLeft(find.text(title).first).dy;

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a thousand children: the sheet builds a screenful, not a thousand rows', (tester) async {
    await _pump(tester, _wide(1000));
    final built = _visibleIds(tester);
    expect(built, isNotEmpty);
    expect(built.length, lessThan(60));
    // The end of an old history is not rendered at all until asked for.
    expect(find.text('任务 999'), findsNothing);
    expect(find.text('1000 个子代理'), findsOneWidget);
    await _scrollTo(tester, find.byType(LineageCountRow));
    expect(find.text('显示全部 1000 个'), findsOneWidget);
    // A screenful at a time, wherever the list is.
    expect(tester.widgetList(find.byType(SubagentRow)).length, lessThan(60));
  });

  testWidgets('expanding reaches the 900th child, still a screenful at a time', (tester) async {
    await _pump(tester, _wide(1000));
    await _scrollTo(tester, find.byType(LineageCountRow));
    await tester.tap(find.byType(LineageCountRow));
    await pumpFrames(tester, 4);
    expect(tester.widgetList(find.byType(SubagentRow)).length, lessThan(60));
    await _scrollTo(tester, find.text('任务 900'));
    expect(find.text('任务 900'), findsOneWidget);
    expect(tester.widgetList(find.byType(SubagentRow)).length, lessThan(60));
  });

  testWidgets('a folded list opens and folds back', (tester) async {
    await _pump(tester, _wide(30));
    await _scrollTo(tester, find.byType(LineageCountRow));
    expect(find.text('显示全部 30 个'), findsOneWidget);
    await tester.tap(find.byType(LineageCountRow));
    await pumpFrames(tester, 4);
    await _scrollTo(tester, find.text('任务 29'));
    expect(find.text('任务 29'), findsOneWidget);
    await _scrollTo(tester, find.text('收起'));
    await tester.tap(find.text('收起'));
    await pumpFrames(tester, 4);
    expect(find.byType(LineageCountRow), findsOneWidget);
    expect(find.text('显示全部 30 个'), findsOneWidget);
  });

  testWidgets('search reaches a child far below the fold without expanding', (tester) async {
    await _pump(tester, _wide(1000));
    expect(find.byType(SearchCapsule), findsOneWidget);
    expect(find.text('任务 900'), findsNothing);

    await tester.enterText(find.byType(TextField), '任务 900');
    await pumpFrames(tester, 4);
    expect(find.widgetWithText(SubagentRow, '任务 900'), findsOneWidget);
    expect(_visibleIds(tester), ['c-900']);
    // Searching replaces the paced view: no fold row under it.
    expect(find.byType(LineageCountRow), findsNothing);

    await tester.enterText(find.byType(TextField), '没有这个');
    await pumpFrames(tester, 4);
    expect(find.text('没有匹配的子代理'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await pumpFrames(tester, 4);
    expect(_visibleIds(tester).first, 'c-0');
    expect(_visibleIds(tester).length, lessThan(60));
  });

  testWidgets('a short lineage has no search and no fold', (tester) async {
    await _pump(tester, _wide(3));
    expect(find.byType(SearchCapsule), findsNothing);
    expect(find.text('显示全部 3 个'), findsNothing);
    expect(_visibleIds(tester), ['c-0', 'c-1', 'c-2']);
  });

  testWidgets('a running child leads, and a finished one moves down when its time does', (tester) async {
    final sessions = {
      ..._wide(0),
      'c-old': _child('c-old', updatedAt: agentsNow.subtract(const Duration(minutes: 30)), lastTurnCompleted: true),
      'c-mid': _child('c-mid', updatedAt: agentsNow.subtract(const Duration(minutes: 10)), lastTurnCompleted: true),
      'c-run': _child('c-run', updatedAt: agentsNow.subtract(const Duration(minutes: 40)), running: true),
    };
    sessions[parentId] = SessionSummary(
      sessionId: parentId,
      updatedAt: agentsNow,
      running: false,
      blank: false,
      agentAvailable: false,
      projections: SessionProjections(10, {
        'subagentCatalog': [
          for (final id in ['c-old', 'c-mid', 'c-run'])
            {
              'id': id,
              'mode': 'continuable',
              'label': id,
              'createdAt': agentsNow.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
            },
        ],
      }),
    );
    final container = await _pump(tester, sessions);
    // Running first, then the newest finished one.
    expect(_visibleIds(tester), ['c-run', 'c-mid', 'c-old']);
    expect(_topOf(tester, 'c-run'), lessThan(_topOf(tester, 'c-mid')));

    // The turn ends (the Host says it completed; its last prompt stays old).
    final ended = {
      ...sessions,
      'c-run': _child('c-run', updatedAt: agentsNow.subtract(const Duration(minutes: 40)), lastTurnCompleted: true),
    };
    container.read(_sessionsProvider.notifier).update(ended);
    await pumpFrames(tester, 4);
    expect(_visibleIds(tester), ['c-mid', 'c-old', 'c-run']);
    // Same three rows: nothing was duplicated or left behind by the move.
    expect(tester.widgetList(find.byType(SubagentRow)), hasLength(3));
  });

  testWidgets('scrolling keeps its place when a row down the list changes', (tester) async {
    final sessions = _wide(1000);
    final container = await _pump(tester, sessions);
    await tester.drag(_list, const Offset(0, -400));
    await pumpFrames(tester, 4);
    final offset = tester.state<ScrollableState>(find.byType(Scrollable).last).position.pixels;
    expect(offset, greaterThan(200));

    // A child in the middle starts working: it moves to the top, the sheet
    // does not jump to it.
    final updated = {...sessions, 'c-500': _child('c-500', updatedAt: agentsNow, running: true)};
    container.read(_sessionsProvider.notifier).update(updated);
    await pumpFrames(tester, 6);
    expect(tester.takeException(), isNull);
    expect(tester.state<ScrollableState>(find.byType(Scrollable).last).position.pixels, offset);
    final ids = _visibleIds(tester);
    expect(ids.toSet().length, ids.length);
    expect(tester.widgetList(find.byType(SubagentRow)).length, lessThan(60));
  });
}
