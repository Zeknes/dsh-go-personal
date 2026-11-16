// The app's record of the Host's own clock per child session: a running turn's
// newest event, and the end of the turn the app watched close. Nothing here
// reads the local clock, so a rebuild never invents an update.

import 'package:dsh_app/state/agent_activity.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 11, 16, 10, 0);

DateTime _at(int minutes, [int seconds = 0]) => _start.add(Duration(minutes: minutes, seconds: seconds));

SubagentTiming _open(int startMinute, int throughMinute, [int throughSecond = 0]) =>
    SubagentTiming(activeSince: _at(startMinute), activeThrough: _at(throughMinute, throughSecond), settled: const Duration(minutes: 3));

SubagentTiming _closed({required bool completed}) => SubagentTiming(
  settled: const Duration(minutes: 7),
  lastTurnCompleted: completed,
);

void main() {
  group('fold', () {
    test('an open turn keeps its start and the newest event it streamed', () {
      var rec = foldActivity(null, seq: 10, running: true, timing: _open(0, 1));
      expect(rec.turnStart, _at(0));
      expect(rec.lastEventAt, _at(1));
      expect(rec.lastEndedAt, isNull);

      rec = foldActivity(rec, seq: 11, timing: _open(0, 2, 30));
      expect(rec.turnStart, _at(0));
      expect(rec.lastEventAt, _at(2, 30));

      // A projection cut never moves the clock backwards.
      rec = foldActivity(rec, seq: 12, timing: _open(0, 1));
      expect(rec.lastEventAt, _at(2, 30));
    });

    test('a closed turn ends at its last event, with its outcome', () {
      var rec = foldActivity(null, seq: 10, running: true, timing: _open(0, 4));
      rec = foldActivity(rec, seq: 12, running: false, timing: _closed(completed: true));
      expect(rec.lastEndedAt, _at(4));
      expect(rec.lastTurnCompleted, isTrue);
      expect(rec.lastActivity, _at(4));
    });

    test('a turn that ended badly keeps that outcome and its end', () {
      var rec = foldActivity(null, seq: 10, running: true, timing: _open(0, 2));
      rec = foldActivity(rec, seq: 14, running: false, timing: _closed(completed: false));
      expect(rec.lastEndedAt, _at(2));
      expect(rec.lastTurnCompleted, isFalse);
    });

    test('a continuation starts a fresh clock; the old end is not reused', () {
      var rec = foldActivity(null, seq: 10, running: true, timing: _open(0, 4));
      rec = foldActivity(rec, seq: 12, running: false, timing: _closed(completed: true));
      expect(rec.lastEndedAt, _at(4));

      rec = foldActivity(rec, seq: 20, running: true, timing: _open(30, 31));
      expect(rec.turnStart, _at(30));
      // The new turn's clock replaced the old one; a later close uses it.
      rec = foldActivity(rec, seq: 22, running: false, timing: _closed(completed: true));
      expect(rec.lastEndedAt, _at(31));
    });

    test('an older cut never rewrites what a newer one said', () {
      var rec = foldActivity(null, seq: 20, running: true, timing: _open(0, 9));
      rec = foldActivity(rec, seq: 5, running: true, timing: _open(0, 1));
      expect(rec.lastEventAt, _at(9));
      expect(rec.seq, 20);
    });

    test('live status is not a projection cut: a status change still lands', () {
      final rec = foldActivity(
        const AgentActivity(seq: 9, running: true, lastEventAt: null),
        // No timing in this observation: the cut is the stale row's.
        seq: 9,
        running: false,
      );
      expect(rec.running, isFalse);
      expect(rec.seq, 9);
    });

    test('a streamed event is not a reading change; a closing turn is', () {
      final open = foldActivity(null, seq: 10, running: true, timing: _open(0, 1));
      final more = foldActivity(open, seq: 11, timing: _open(0, 2));
      expect(more.lastEventAt, isNot(open.lastEventAt));
      // Panels draw nothing new for another event of the same turn.
      expect(more.sameReading(open), isTrue);

      final closed = foldActivity(more, seq: 12, running: false, timing: _closed(completed: true));
      expect(closed.sameReading(more), isFalse);
    });

    test('a turn closed while the app was away leaves no end time', () {
      // A list row of a finished child: its projection has the outcome but the
      // Host dropped `active`, so there is no clock to read.
      final rec = foldActivity(null, seq: 30, running: false, timing: _closed(completed: true));
      expect(rec.lastEndedAt, isNull);
      expect(rec.lastTurnCompleted, isTrue);
      expect(rec.lastActivity, isNull);
    });
  });

  group('storage', () {
    test('round-trips through JSON', () {
      final records = {
        'a': foldActivity(null, seq: 10, running: true, timing: _open(0, 2)),
        'b': foldActivity(
          foldActivity(null, seq: 10, running: true, timing: _open(0, 5)),
          seq: 12,
          running: false,
          timing: _closed(completed: false),
        ),
      };
      final back = decodeActivity(encodeActivity(records));
      expect(back, records);
      expect(back['b']!.lastEndedAt, _at(5));
      expect(back['b']!.lastTurnCompleted, isFalse);
    });

    test('unreadable text decodes to nothing instead of throwing', () {
      expect(decodeActivity(null), isEmpty);
      expect(decodeActivity(''), isEmpty);
      expect(decodeActivity('{oops'), isEmpty);
      expect(decodeActivity('[]'), isEmpty);
    });

    test('keeps the newest sessions and drops the oldest', () {
      final records = {
        for (var i = 0; i < agentActivityKeep + 10; i++)
          's-$i': foldActivity(
            foldActivity(null, seq: 10, running: true, timing: _open(i, i + 1)),
            seq: 12,
            running: false,
            timing: _closed(completed: true),
          ),
      };
      final kept = pruneActivity(records);
      expect(kept, hasLength(agentActivityKeep));
      expect(kept.containsKey('s-${agentActivityKeep + 9}'), isTrue);
      expect(kept.containsKey('s-0'), isFalse);
    });
  });
}
