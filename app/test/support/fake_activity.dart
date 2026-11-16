// A child-activity store tests can state directly: no control stream, records
// (and therefore ordering by real end times) driven by the test.

import 'package:dsh_app/state/agent_activity.dart';
import 'package:dsh_client/dsh_client.dart';

/// Child activity the test states instead of watching the Host's control
/// stream; [record] stands in for a frame.
class FakeActivity extends AgentActivityController {
  FakeActivity([this.initial = const {}]);

  final AgentActivityMap initial;

  @override
  AgentActivityMap build() => initial;

  void record(String sessionId, {required int seq, bool? running, SubagentTiming? timing}) =>
      applyObservation(sessionId, seq: seq, running: running, timing: timing);
}
