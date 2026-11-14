// The glue between the app's state and the pet's mood reducer (pet_mood.dart):
// what runs on every connected host, what waits on the person, the conversation
// on screen, turn-end and request alerts, the last touch — reduced into
// [PetState]s for the chat page's pet layer and the out-of-app overlay. Nothing
// here calls a model or the network beyond the host events the app already
// holds.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/chat_alerts.dart';
import '../performance/performance_state.dart';
import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show FlagController, appForegroundProvider, chatOnScreenProvider;
import '../state/run_pulse.dart';
import '../state/task_runs.dart';
export '../state/task_runs.dart' show petRunsProvider, TaskRunsController;
import '../state/session_attention_state.dart';
import '../ui/chat/run_info.dart';
import 'pet_mood.dart';
import 'pet_overlay_actions.dart';
import 'pet_prefs.dart';
import 'pet_state.dart';

/// The pet's clock (tests drive it by hand).
final petClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class PetEventBus {
  final _events = StreamController<PetEvent>.broadcast(sync: true);
  final _companionSignals = StreamController<CompanionAlertDelivery>.broadcast(sync: true);

  /// Independent metadata lane; it never calls old PetEvent text handlers.
  Stream<CompanionAlertDelivery> get companionSignals => _companionSignals.stream;
  void companionSignal(CompanionAlertDelivery delivery) {
    if (!_companionSignals.isClosed && delivery.current) _companionSignals.add(delivery);
  }

  Stream<PetEvent> get events => _events.stream;

  /// One alert. [bubble]: it may raise a bubble (it went to the pet or to the
  /// system, not to the conversation on screen, not switched off). [asked]:
  /// the turn answered 问一句, its bubble shows the reply.
  void alert(ChatAlert alert, DateTime now, {bool bubble = false, bool asked = false}) {
    final kind = switch (alert.kind) {
      AlertKind.done => PetEventKind.done,
      // An engine restart is not the turn's failure: no error.
      AlertKind.failed
          when alert.key == turnKey &&
              (alert.turnEndKind == 'interrupted' ||
                  // l10n:keep legacy alert text prefix when no wire reason is available
                  (alert.turnEndKind == null && alert.text.startsWith('已中断'))) =>
        PetEventKind.stopped,
      AlertKind.failed => PetEventKind.failed,
      AlertKind.stopped => PetEventKind.stopped,
      AlertKind.approval => PetEventKind.approval,
      AlertKind.question => PetEventKind.question,
    };
    // A request shows what it asks; answered on the bubble only when all of it shows.
    final ask = switch (alert) {
      ChatAlert(kind: AlertKind.approval || AlertKind.question, :final eventId?) => PetAsk(
        eventId: eventId,
        token: alert.petToken,
        text: alert.petText ?? alert.text,
        approvable: alert.kind == AlertKind.approval && alert.petText != null,
        choices: alert.choices ?? const [],
      ),
      _ => null,
    };
    add(
      PetEvent(
        kind: kind,
        host: alert.host,
        sessionId: alert.sessionId,
        key: alert.key,
        title: alert.title == untitledSession ? null : alert.title,
        at: now,
        bubble: bubble,
        ask: ask,
        preview: asked && kind == PetEventKind.done ? alert.reply : null,
      ),
    );
  }

  void add(PetEvent event) => _events.add(event);

  void dispose() {
    unawaited(_events.close());
    unawaited(_companionSignals.close());
  }
}

final petEventBusProvider = Provider<PetEventBus>((ref) {
  final bus = PetEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// Hands [alert] to the pet (called by `ChatAlertsController._onAlert`).
void petHearAlert(Ref ref, ChatAlert alert, {bool bubble = false}) {
  final asked =
      alert.key == turnKey && ref.read(petAskedProvider.notifier).take(PetTarget(alert.host, alert.sessionId));
  ref.read(petEventBusProvider).alert(alert, ref.read(petClockProvider)(), bubble: bubble, asked: asked);
}

/// Conversations 问一句 sent to whose turn hasn't ended yet: that turn's end
/// bubble shows the reply's first lines (pet_overlay_actions.dart).
class PetAskedController extends Notifier<Set<PetTarget>> {
  @override
  Set<PetTarget> build() => const {};

  void add(PetTarget target) => state = {...state, target};

  /// Whether [target] was asked; it no longer is.
  bool take(PetTarget target) {
    if (!state.contains(target)) return false;
    state = {...state}..remove(target);
    return true;
  }
}

final petAskedProvider = NotifierProvider<PetAskedController, Set<PetTarget>>(PetAskedController.new);

// ── On screen ────────────────────────────────────────────────────────────────

/// The chat page's pet is drawn and visible (set by its layer).
final petLayerShownProvider = NotifierProvider<FlagController, bool>(() => FlagController(false));

/// The pet speaks for the app in front: its layer shows on the chat page,
/// the chat is the current route, and quiet mode is off. Alerts for other
/// conversations then go to its bubble instead of the glass banner.
final petOnScreenProvider = Provider<bool>(
  (ref) =>
      ref.watch(petLayerShownProvider) &&
      ref.watch(chatOnScreenProvider) &&
      ref.watch(appForegroundProvider) &&
      !ref.watch(petPrefsProvider.select((p) => p.quiet)),
);

/// How far the pet reaches above its perch (logical px), for the chat list's
/// bottom padding: the last line scrolls clear of it. 0 without a pet.
final petHeadroomProvider = NotifierProvider<PetHeadroomController, double>(PetHeadroomController.new);

class PetHeadroomController extends Notifier<double> {
  @override
  double build() => 0;

  void set(double value) {
    if ((value - state).abs() >= 0.5) state = value;
  }
}

// ── The last touch ───────────────────────────────────────────────────────────

class PetInteractionController extends Notifier<DateTime> {
  @override
  DateTime build() => ref.read(petClockProvider)();

  /// Something on the chat page (or the pet) was touched.
  void touch() {
    final now = ref.read(petClockProvider)();
    // Pointer storms: one update a second is plenty for a 60 s timer.
    if (now.difference(state) >= const Duration(seconds: 1)) state = now;
  }
}

final petInteractionProvider = NotifierProvider<PetInteractionController, DateTime>(PetInteractionController.new);

// ── What runs where ──────────────────────────────────────────────────────────

/// Running conversations and subagents of one host, from its `$events`
/// (status edges) and `session/list` (lineage).
// ── The conversation on screen ───────────────────────────────────────────────

/// [ActivityKind] → what the pet makes of it.
PetActivity petActivityOf(ActivityKind? kind) => switch (kind) {
  null => PetActivity.none,
  ActivityKind.tool || ActivityKind.writing => PetActivity.working,
  ActivityKind.approval || ActivityKind.question => PetActivity.waiting,
  ActivityKind.stopping => PetActivity.stopping,
  ActivityKind.waiting ||
  ActivityKind.thinking ||
  ActivityKind.retry ||
  ActivityKind.compaction => PetActivity.thinking,
};

/// Whether a conversation is compacting its context (its run pulse says).
class PetCompactingController extends Notifier<bool> {
  PetCompactingController(this.sessionId);

  final String sessionId;

  @override
  bool build() {
    final pulse = ref.watch(runPulseProvider(sessionId));
    void listener() {
      final compacting = pulse.compactingSince != null;
      if (compacting != state) state = compacting;
    }

    pulse.addListener(listener);
    ref.onDispose(() => pulse.removeListener(listener));
    return pulse.compactingSince != null;
  }
}

final petCompactingProvider = NotifierProvider.autoDispose.family<PetCompactingController, bool, String>(
  PetCompactingController.new,
);

/// The conversation the native chat page shows, and what it is doing. The
/// chat page's pet stage reports it ([PetFocusController.report]); null when
/// no chat page is up (网页模式, before the first frame). Read from the page,
/// not from `chatProvider`, so nothing here opens a conversation's stream.
class PetFocusController extends Notifier<PetFocus?> {
  @override
  PetFocus? build() => null;

  void report(PetFocus? focus) {
    if (!ref.mounted) return;
    if (focus != state) state = focus;
  }
}

final petFocusProvider = NotifierProvider<PetFocusController, PetFocus?>(PetFocusController.new);

/// What the conversation [s] is doing, for the pet.
PetFocus petFocusOf(HostRef host, String sessionId, ChatState s, {bool compacting = false}) {
  final approval = s.openApproval;
  final question = approval == null ? s.questions.firstOrNull : null;
  return PetFocus(
    host: host,
    sessionId: sessionId,
    title: s.title,
    activity: petActivityOf(runActivityOf(s)?.kind),
    compacting: compacting,
    waitingKey: approval?.eventId ?? question?.eventId,
    waitingQuestion: question != null,
  );
}

/// What waits on the person: the active host's pending requests (by their
/// top-level conversation) and the open card of the conversation on screen.
final petPendingProvider = Provider<List<PetPending>>((ref) {
  final host = ref.watch(activeHostProvider);
  final pending = ref.watch(pendingInteractionsProvider);
  final focus = ref.watch(petFocusProvider);
  final own = focus?.waitingKey;
  return [
    if (focus != null && own != null)
      PetPending(host: focus.host, sessionId: focus.sessionId, key: own, question: focus.waitingQuestion),
    for (final MapEntry(:key, :value) in pending.entries)
      if (own == null || focus == null || key != focus.sessionId || host != focus.host)
        PetPending(host: host, sessionId: key, key: value.name, question: value != PendingKind.approval),
  ];
});

/// A pet pack is being unpacked: the pet carries it in (docs/design/pets.md §4.2).
final petCarryingProvider = NotifierProvider<FlagController, bool>(() => FlagController(false));

/// All level signals.
final petSignalsProvider = Provider<PetSignals>((ref) {
  final focus = ref.watch(petFocusProvider);
  return PetSignals(
    focus: focus,
    viewed: focus != null && ref.watch(appForegroundProvider) && ref.watch(chatOnScreenProvider),
    runs: [
      for (final run in ref.watch(petRunsProvider))
        PetRun(run.host, run.sessionId, subagent: run.subagent, root: run.root, since: run.since, title: run.title),
    ],
    pending: ref.watch(petPendingProvider),
    lastInteraction: ref.watch(petInteractionProvider),
    carrying: ref.watch(petCarryingProvider),
    quiet: ref.watch(petPrefsProvider.select((p) => p.quiet)),
  );
});

final petTimingsProvider = Provider<PetTimings>((ref) => const PetTimings());

// ── The mood ─────────────────────────────────────────────────────────────────

/// Runs [reducePetMood] for one [PetScope] on every signal, event and timer.
class PetMoodController extends Notifier<PetMood> {
  PetMoodController(this.scope);

  final PetScope scope;
  Timer? _timer;
  final List<PetEvent> _events = [];
  bool _running = false;

  DateTime get _now => ref.read(petClockProvider)();

  @override
  PetMood build() {
    final sub = ref.watch(petEventBusProvider).events.listen((e) {
      _events.add(e);
      _reduce();
    });
    ref.listen(
      petSignalsProvider,
      (_, _) => scheduleMicrotask(() {
        if (ref.mounted) _reduce();
      }),
    );
    ref.listen(
      petTimingsProvider,
      (_, _) => scheduleMicrotask(() {
        if (ref.mounted) _reduce();
      }),
    );
    ref.onDispose(() {
      _timer?.cancel();
      unawaited(sub.cancel());
    });
    final now = _now;
    final first = reducePetMood(
      PetMood.initial(now),
      ref.read(petSignalsProvider),
      now,
      timings: ref.read(petTimingsProvider),
      scope: scope,
    );
    _arm(first.next);
    return first;
  }

  void _reduce() {
    if (_running) return;
    _running = true;
    try {
      final events = [..._events];
      _events.clear();
      final next = reducePetMood(
        state,
        ref.read(petSignalsProvider),
        _now,
        events: events,
        timings: ref.read(petTimingsProvider),
        scope: scope,
      );
      state = next;
      _arm(next.next);
    } finally {
      _running = false;
    }
  }

  void _arm(DateTime? at) {
    _timer?.cancel();
    _timer = null;
    if (at == null) return;
    var wait = at.difference(_now);
    if (wait.isNegative) wait = Duration.zero;
    _timer = Timer(wait + const Duration(milliseconds: 1), _reduce);
  }

  /// Re-reads the signals now (tests move the clock by hand).
  void refresh() => _reduce();

  /// The bubble was tapped or swiped away: it goes now.
  void dismissBubble(String id) {
    if (state.bubble?.id == id) state = state.copyWith(clearBubble: true);
  }
}

final petMoodProvider = NotifierProvider.family<PetMoodController, PetMood, PetScope>(PetMoodController.new);

/// What the pet shows in [scope]; bubbles and the target are global.
final petScopedStateProvider = Provider.family<PetState, PetScope>((ref, scope) {
  final global = ref.watch(petMoodProvider(PetScope.global));
  final mood = scope == PetScope.global ? global : ref.watch(petMoodProvider(scope));
  final signals = ref.watch(petSignalsProvider);
  final prefs = ref.watch(petPrefsProvider);
  final activeHost = ref.watch(activeHostProvider);
  return PetState(
    state: mood.shown,
    tier: mood.tier,
    bubble: prefs.quiet ? null : global.bubble,
    target: petTarget(global, signals),
    active: petActive(global, signals),
    foreground: ref.watch(appForegroundProvider),
    packId: prefs.packId,
    size: prefs.size,
    quiet: prefs.quiet,
    reduceMotion: ref.watch(performanceDefaultsProvider.select((p) => p.reduceMotion)),
    canStop: signals.runs.any((r) => PetTarget(r.host, r.root) == petTarget(global, signals) && r.host == activeHost),
    hosts: ref.watch(petHostChoicesProvider),
  );
});

/// The global state: the overlay's.
final petStateProvider = Provider<PetState>((ref) => ref.watch(petScopedStateProvider(PetScope.global)));

/// The pet is drawn on the chat page: the empty state's still whale tail
/// steps aside — one mascot a screen. Hidden, 不显示 or 网页模式: the whale
/// is back.
final petTakesWhaleProvider = Provider<bool>((ref) => ref.watch(petLayerShownProvider));
