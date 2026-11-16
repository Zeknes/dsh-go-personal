// The display order of a conversation's lineage: work in progress first, then
// the newest Host-recorded change, with the tree kept whole. Pure functions, no
// widgets: the sheet and the details tab both read this order.

import 'package:dsh_app/state/agent_activity.dart';
import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

int _ms(DateTime time) => time.millisecondsSinceEpoch;

/// A child row as `session/list` sends it.
SessionSummary _row(
  String id, {
  String? parent = parentId,
  bool running = false,
  DateTime? updatedAt,
  bool? lastTurnCompleted,
  Duration activeFor = Duration.zero,
  List<Map<String, Object?>>? catalog,
  String? title,
}) => SessionSummary(
  sessionId: id,
  updatedAt: updatedAt ?? agentsNow,
  running: running,
  blank: false,
  agentAvailable: running,
  parentSessionId: parent,
  origin: parent == null ? null : 'subagent',
  projections: SessionProjections(10, {
    'title': ?title,
    if (lastTurnCompleted != null || activeFor > Duration.zero)
      'subagentTiming': {
        'settledMs': lastTurnCompleted == true ? 60000 : 0,
        'lastTurnCompleted': ?lastTurnCompleted,
        if (activeFor > Duration.zero)
          'active': {
            'since': _ms(agentsNow.subtract(activeFor)),
            'through': _ms(agentsNow.subtract(activeFor).add(const Duration(seconds: 1))),
          },
      },
    'subagentCatalog': ?catalog,
  }),
);

Map<String, Object?> _entry(String id, {String? label, Duration createdAt = const Duration(minutes: 30)}) => {
  'id': id,
  'mode': 'continuable',
  'label': label ?? id,
  'createdAt': _ms(agentsNow.subtract(createdAt)),
};

/// A parent whose catalog lists [children] in the given order.
Map<String, SessionSummary> _tree(List<Map<String, Object?>> children, List<SessionSummary> rows) {
  final parent = _row(parentId, parent: null, catalog: children);
  return {parent.sessionId: parent, for (final row in rows) row.sessionId: row};
}

void main() {
  group('state rank', () {
    test('running, then failed, then completed, then the rest', () {
      final nodes = buildLineage(
        parentId,
        _tree(
          [
            _entry('c-idle', label: '待命'),
            _entry('c-done', label: '完成'),
            _entry('c-bad', label: '出错'),
            _entry('c-run', label: '运行'),
          ],
          [
            _row('c-idle', updatedAt: agentsNow),
            _row('c-done', lastTurnCompleted: true),
            _row('c-bad', lastTurnCompleted: false),
            _row('c-run', running: true, activeFor: const Duration(seconds: 20)),
          ],
        ),
      );
      expect(nodes.map((n) => n.id), ['c-run', 'c-bad', 'c-done', 'c-idle']);
      expect(nodes.last.state, AgentRunState.idle);
      // 「未运行」 is not a failure: no turn has closed, or the state is unknown.
      expect(nodes.last.state, isNot(AgentRunState.failed));
      expect(nodes.map((n) => lineageStateRank(n.state)), [0, 1, 2, 3]);
    });

    test('an external task stays idle even when its row is missing', () {
      final nodes = buildLineage(parentId, _tree(const [
        {'id': 'ext', 'mode': 'external', 'label': '外部任务'},
      ], const []));
      expect(nodes.single.state, AgentRunState.idle);
      expect(nodes.single.openable, isFalse);
    });
  });

  group('activity', () {
    test('the newest Host-recorded change comes first within a state', () {
      final nodes = buildLineage(
        parentId,
        _tree(
          [_entry('old'), _entry('new'), _entry('mid')],
          [
            _row('old', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(hours: 2))),
            _row('new', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 3))),
            _row('mid', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 40))),
          ],
        ),
      );
      expect(nodes.map((n) => n.id), ['new', 'mid', 'old']);
    });

    test('a continuation moves the same child up, and no row is duplicated', () {
      final before = buildLineage(
        parentId,
        _tree(
          [_entry('first'), _entry('second')],
          [
            _row('first', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(hours: 1))),
            _row('second', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 5))),
          ],
        ),
      );
      expect(before.map((n) => n.id), ['second', 'first']);

      final after = buildLineage(
        parentId,
        _tree(
          [_entry('first'), _entry('second')],
          [
            // Continuing a child prompts it again: same id, newer updatedAt.
            _row('first', lastTurnCompleted: true, updatedAt: agentsNow),
            _row('second', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 5))),
          ],
        ),
      );
      expect(after.map((n) => n.id), ['first', 'second']);
      expect(after, hasLength(2));
      expect(lineageSize(after), 2);
    });

    test('an open turn is dated by its newest committed event', () {
      final live = foldActivity(
        null,
        seq: 10,
        running: true,
        timing: SubagentTiming(
          activeSince: agentsNow.subtract(const Duration(minutes: 2)),
          activeThrough: agentsNow.subtract(const Duration(seconds: 20)),
        ),
      );
      final running = buildLineage(
        parentId,
        _tree(
          [_entry('r')],
          [
            _row(
              'r',
              running: true,
              activeFor: const Duration(minutes: 2),
              updatedAt: agentsNow.subtract(const Duration(hours: 1)),
            ),
          ],
        ),
        activity: {'r': live},
      ).single;
      expect(running.state, AgentRunState.running);
      // 最近更新: the Host's newest event, not the turn's start.
      final activity = lineageActivity(running);
      expect(activity.time, agentsNow.subtract(const Duration(seconds: 20)));
      expect(activity.exact, isTrue);
    });

    test('a running row with no watched turn falls back to dispatch, and says so', () {
      final node = buildLineage(
        parentId,
        _tree(
          [_entry('r')],
          [_row('r', running: true, updatedAt: agentsNow.subtract(const Duration(minutes: 5)))],
        ),
      ).single;
      expect(node.running, isTrue);
      final activity = lineageActivity(node);
      expect(activity.time, agentsNow.subtract(const Duration(minutes: 5)));
      expect(activity.exact, isFalse);
    });

    test('old rows without a prompt time fall back to the catalog creation', () {
      final missing = _row('legacy', updatedAt: DateTime.fromMillisecondsSinceEpoch(0));
      final nodes = buildLineage(
        parentId,
        _tree(
          [_entry('legacy', createdAt: const Duration(minutes: 7)), _entry('known')],
          [
            missing,
            _row('known', updatedAt: agentsNow),
          ],
        ),
      );
      expect(nodes.map((n) => n.id), ['known', 'legacy']);
      // No prompt time and no Host event time: the creation time stands in, and
      // says so.
      final activity = lineageActivity(nodes.last);
      expect(activity.time, agentsNow.subtract(const Duration(minutes: 7)));
      expect(activity.exact, isFalse);
    });

    test('nothing dated at all: the id keeps the order stable', () {
      final sessions = _tree(
        [_entry('b'), _entry('a')],
        [
          _row('a', updatedAt: DateTime.fromMillisecondsSinceEpoch(0)),
          _row('b', updatedAt: DateTime.fromMillisecondsSinceEpoch(0)),
        ],
      );
      // Neither row nor catalog carries a time: both fall back to nothing.
      sessions[parentId] = _row(
        parentId,
        parent: null,
        catalog: [
          {'id': 'b', 'mode': 'continuable', 'label': 'b'},
          {'id': 'a', 'mode': 'continuable', 'label': 'a'},
        ],
      );
      for (var round = 0; round < 3; round++) {
        expect(buildLineage(parentId, sessions).map((n) => n.id), ['a', 'b']);
      }
    });

    test('equal stamps and creation times keep the id order across builds', () {
      const same = Duration(minutes: 5);
      final sessions = _tree(
        [_entry('c-3', createdAt: same), _entry('c-1', createdAt: same), _entry('c-2', createdAt: same)],
        [_row('c-1'), _row('c-2'), _row('c-3')],
      );
      final first = buildLineage(parentId, sessions).map((n) => n.id).toList();
      expect(first, ['c-1', 'c-2', 'c-3']);
      for (var round = 0; round < 3; round++) {
        expect(buildLineage(parentId, sessions).map((n) => n.id), first);
      }
    });
  });

  group('host event clock', () {
    AgentActivity closed(String id, {required DateTime endedAt, required bool completed}) => foldActivity(
      foldActivity(
        null,
        seq: 10,
        running: true,
        timing: SubagentTiming(activeSince: endedAt.subtract(const Duration(minutes: 2)), activeThrough: endedAt),
      ),
      seq: 12,
      running: false,
      timing: SubagentTiming(settled: const Duration(minutes: 2), lastTurnCompleted: completed),
    );

    test('finished rows are ordered by when they finished, not by dispatch', () {
      final sessions = _tree(
        [_entry('dispatched-first'), _entry('dispatched-last')],
        [
          // Dispatched first, finished last.
          _row('dispatched-first', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(hours: 3))),
          // Dispatched last, finished first.
          _row('dispatched-last', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 5))),
        ],
      );
      final activity = {
        'dispatched-first': closed('dispatched-first', endedAt: agentsNow.subtract(const Duration(minutes: 1)), completed: true),
        'dispatched-last': closed('dispatched-last', endedAt: agentsNow.subtract(const Duration(minutes: 40)), completed: true),
      };
      final nodes = buildLineage(parentId, sessions, activity: activity);
      expect(nodes.map((n) => n.id), ['dispatched-first', 'dispatched-last']);
      final first = lineageActivity(nodes.first);
      expect(first.time, agentsNow.subtract(const Duration(minutes: 1)));
      expect(first.exact, isTrue);
    });

    test('a turn the app never watched close falls back to the dispatch time', () {
      final sessions = _tree(
        [_entry('dispatched-first'), _entry('dispatched-last')],
        [
          _row('dispatched-first', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(hours: 3))),
          _row('dispatched-last', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 5))),
        ],
      );
      final nodes = buildLineage(parentId, sessions);
      expect(nodes.map((n) => n.id), ['dispatched-last', 'dispatched-first']);
      final first = lineageActivity(nodes.first);
      expect(first.time, agentsNow.subtract(const Duration(minutes: 5)));
      expect(first.exact, isFalse);
    });

    test('a newer frame than the row settles the state before the next list read', () {
      final sessions = _tree(
        [_entry('ending')],
        // The row's projection predates the turn ending: no outcome yet.
        [_row('ending', updatedAt: agentsNow.subtract(const Duration(minutes: 9)))],
      );
      expect(buildLineage(parentId, sessions).single.state, AgentRunState.idle);

      final nodes = buildLineage(parentId, sessions, activity: {
        'ending': closed('ending', endedAt: agentsNow.subtract(const Duration(minutes: 1)), completed: true),
      });
      expect(nodes.single.state, AgentRunState.completed);
      expect(nodes.single.state, isNot(AgentRunState.idle));
    });

    test('an ending that failed is not reported as a finish', () {
      final sessions = _tree(
        [_entry('ending')],
        [_row('ending', updatedAt: agentsNow.subtract(const Duration(minutes: 9)))],
      );
      final nodes = buildLineage(parentId, sessions, activity: {
        'ending': closed('ending', endedAt: agentsNow.subtract(const Duration(minutes: 1)), completed: false),
      });
      expect(nodes.single.state, AgentRunState.failed);
    });

    test('two running children swap as the newer one acts, and only then', () {
      AgentActivity event(Duration ago) => foldActivity(
        null,
        seq: 10,
        running: true,
        timing: SubagentTiming(
          activeSince: agentsNow.subtract(const Duration(minutes: 30)),
          activeThrough: agentsNow.subtract(ago),
        ),
      );
      final sessions = _tree(
        [_entry('a'), _entry('b')],
        [
          _row('a', running: true, updatedAt: agentsNow.subtract(const Duration(minutes: 2))),
          _row('b', running: true, updatedAt: agentsNow.subtract(const Duration(minutes: 2))),
        ],
      );
      // b acted a minute ago, a two minutes ago: b leads.
      var nodes = buildLineage(parentId, sessions, activity: {
        'a': event(const Duration(minutes: 2)),
        'b': event(const Duration(minutes: 1)),
      });
      expect(nodes.map((n) => n.id), ['b', 'a']);
      // a's next real event puts it first — the newest update wins.
      final acted = {
        'a': event(const Duration(seconds: 10)),
        'b': event(const Duration(minutes: 1)),
      };
      nodes = buildLineage(parentId, sessions, activity: acted);
      expect(nodes.map((n) => n.id), ['a', 'b']);
      // No further event: rebuilding (a tick, a scroll) keeps that order.
      for (var round = 0; round < 3; round++) {
        expect(buildLineage(parentId, sessions, activity: acted).map((n) => n.id), ['a', 'b']);
      }
    });
  });

  group('tree shape', () {
    test('a running grandchild lifts its parent, and stays under it', () {
      final sessions = _tree(
        [_entry('done'), _entry('parent')],
        [
          _row('done', lastTurnCompleted: true, updatedAt: agentsNow),
          _row('parent', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(hours: 1)), catalog: [_entry('nested', createdAt: Duration.zero)]),
          _row('nested', parent: 'parent', running: true, activeFor: const Duration(minutes: 1)),
        ],
      );
      final nodes = buildLineage(parentId, sessions);
      expect(nodes.map((n) => n.id), ['parent', 'done']);
      expect(lineageRows(nodes).map((r) => (r.node.id, r.depth)), [('parent', 0), ('nested', 1), ('done', 0)]);
    });

    test('the catalog array order does not decide the display order', () {
      final sessions = _tree(
        [_entry('z-old', createdAt: const Duration(minutes: 1)), _entry('a-new', createdAt: const Duration(minutes: 9))],
        [
          _row('z-old', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(hours: 3))),
          _row('a-new', lastTurnCompleted: true, updatedAt: agentsNow.subtract(const Duration(minutes: 2))),
        ],
      );
      expect(buildLineage(parentId, sessions).map((n) => n.id), ['a-new', 'z-old']);
    });
  });

  group('what the list shows', () {
    Map<String, SessionSummary> many(int count, {int running = 0}) => _tree(
      [for (var i = 0; i < count; i++) _entry('c-$i', createdAt: Duration(minutes: 30 + i))],
      [
        for (var i = 0; i < count; i++)
          _row('c-$i', running: i < running, updatedAt: agentsNow.subtract(Duration(seconds: i))),
      ],
    );

    test('a long history opens on the recent rows', () {
      final nodes = buildLineage(parentId, many(1000));
      expect(lineageSize(nodes), 1000);
      final rows = visibleLineage(nodes);
      expect(rows, hasLength(recentLineageLimit));
      expect(rows.map((r) => r.node.id), [for (var i = 0; i < recentLineageLimit; i++) 'c-$i']);
      expect(visibleLineage(nodes, expanded: true), hasLength(1000));
      // Ordinals are intact once expanded: nothing was dropped on the way.
      final all = visibleLineage(nodes, expanded: true);
      expect(all[900].node.id, 'c-900');
      expect(all.last.node.id, 'c-999');
    });

    test('every running child stays visible, even past the cap', () {
      final nodes = buildLineage(parentId, many(40, running: 30));
      final rows = visibleLineage(nodes);
      expect(rows.where((r) => r.node.running), hasLength(30));
      expect(rows, hasLength(30));
      expect(visibleLineage(nodes, limit: 5).where((r) => r.node.running), hasLength(30));
    });

    test('a short lineage is never capped', () {
      final nodes = buildLineage(parentId, many(7));
      expect(visibleLineage(nodes), hasLength(7));
      expect(visibleLineage(nodes, limit: 5), hasLength(5));
    });

    test('search reaches the 900th child without expanding', () {
      final nodes = buildLineage(parentId, many(1000));
      final rows = visibleLineage(nodes, query: 'c-900');
      expect(rows.map((r) => r.node.id), ['c-900']);
      expect(rows.single.depth, 0);
      expect(visibleLineage(nodes, query: '  C-90 '), hasLength(11)); // c-90, c-900..c-909
      expect(visibleLineage(nodes, query: 'nothing'), isEmpty);
    });

    test('search spans the whole tree, nested children included', () {
      final sessions = _tree(
        [_entry('parent')],
        [
          _row('parent', lastTurnCompleted: true, catalog: [_entry('nested')], title: 'nested owner'),
          _row('nested', parent: 'parent', lastTurnCompleted: true, title: '对照官方文档'),
        ],
      );
      final nodes = buildLineage(parentId, sessions);
      final byTitle = visibleLineage(nodes, query: '官方文档');
      expect(byTitle.map((r) => r.node.id), ['nested']);
      final byId = visibleLineage(nodes, query: 'nested');
      // The parent's title carries the word too; the tree order decides.
      expect(byId.map((r) => r.node.id), ['parent', 'nested']);
    });
  });
}
