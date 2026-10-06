/// The main screen: the conversation, or the composer when starting something
/// new. Everything else lives in the drawer.
///
/// Two deliberate borrowings from the reference app: the user's own message is a
/// **left-aligned** grey bubble rather than a right-aligned one, and assistant
/// prose carries no bubble at all. Together they make the agent's output the
/// visual subject and the human's turn a quiet marker.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../api/relay_events.dart';
import '../chat/attachments.dart';
import '../chat/metrics.dart';
import '../chat/transcript.dart';
import '../state/app_controller.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'app_drawer.dart';
import 'app_logo.dart';
import 'attachment_picker.dart';
import 'composer.dart';
import 'markdown_text.dart';
import 'model_picker.dart';
import 'process_timeline.dart';
import 'workspace_sheet.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The task list is loaded on connect and after actions, not on a timer, so a
    // conversation archived (or started) on the desktop while the phone was in the
    // background stayed visible here. Coming back to the foreground is exactly when
    // the list has to be right.
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(appControllerProvider.notifier).loadSessions());
    }
  }

  /// Refreshes the task list and opens the drawer.
  ///
  /// Opening the drawer is the moment the list matters, and it is also the moment a
  /// stale list is most obvious: a session archived on the desktop meanwhile was
  /// still listed here until something else happened to reload it — which read as
  /// "archived conversations still show up".
  void _openDrawer() {
    unawaited(ref.read(appControllerProvider.notifier).loadSessions());
    _scaffoldKey.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final sessionId = state.activeSessionId;

    return Scaffold(
      key: _scaffoldKey,
      drawer: const AppDrawer(),
      appBar: AppBar(
        leadingWidth: 62,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: CircleIconButton(
            icon: Icons.menu_rounded,
            tooltip: '菜单',
            onTap: _openDrawer,
          ),
        ),
        title: Text(
          state.activeDevice?.name.isNotEmpty == true
              ? state.activeDevice!.name
              : 'DSH Remote',
        ),
        actions: [
          if (state.approvals.isNotEmpty) _PendingBadge(count: state.approvals.length),
          if (sessionId != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: CircleIconButton(
                icon: Icons.add_comment_outlined,
                tooltip: '新建任务',
                onTap: () => ref.read(appControllerProvider.notifier).composeNew(),
              ),
            ),
        ],
      ),
      // Approvals and questions sit above whatever the user is looking at.
      // Rendering them only inside the matching session meant a question asked
      // while the phone was on the home screen — or in another task — was
      // invisible even though it had arrived.
      body: Column(
        children: [
          if (state.approvals.isNotEmpty)
            _PendingAsksPanel(asks: state.approvals),
          Expanded(
            child: sessionId == null
                ? const WelcomeView()
                : SessionView(key: ValueKey(sessionId), sessionId: sessionId),
          ),
        ],
      ),
    );
  }
}

/// Attachment plumbing shared by both compose surfaces.
///
/// The two surfaces are the same target — the welcome view simply has no session
/// yet — so they must not drift: a rule that only one of them enforced is how a
/// disabled send button shipped once already.
mixin _AttachmentPicker<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Future<void> _pickAttachment() async {
    final controller = ref.read(appControllerProvider.notifier);
    final result = await pickAttachment(context);
    if (result == null || !mounted) return;

    String? error = result.error;
    for (final attachment in result.attachments) {
      // The controller re-checks the rule, so an oversized pick is refused even
      // if the picker's own check is bypassed.
      error ??= controller.addAttachment(attachment);
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(error),
        ));
    }
  }

  void _removeAttachment(PendingAttachment attachment) {
    ref.read(appControllerProvider.notifier).removeAttachment(attachment.id);
  }
}

/// Count of requests waiting, visible even when the panel is scrolled past.
class _PendingBadge extends StatelessWidget {
  const _PendingBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.notifications_active_outlined, size: 14, color: AppColors.danger),
          const SizedBox(width: 5),
          Text(
            '$count 待处理',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.danger,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pending approvals and questions, rendered wherever the user happens to be.
class _PendingAsksPanel extends ConsumerWidget {
  const _PendingAsksPanel({required this.asks});

  final List<ApprovalAsk> asks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(appControllerProvider);

    // Only the newest request is shown. Several can be outstanding at once (a
    // burst of questions), and stacking them buries the conversation while the
    // older ones are usually stale by the time they are read. The relay gives
    // every ask a TTL, so the one with the most time left is the most recent.
    final newest = asks.reduce(
      (a, b) => (b.expiresInSeconds ?? 0) >= (a.expiresInSeconds ?? 0) ? b : a,
    );

    return ConstrainedBox(
      // Bounded, so a burst of requests can never squeeze the conversation away.
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppGap.page, 8, AppGap.page, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.notifications_active_outlined,
                  size: 15,
                  color: AppColors.danger,
                ),
                const SizedBox(width: 6),
                Text(
                  asks.length > 1
                      ? '最新 1 个请求（另有 ${asks.length - 1} 个较早的）'
                      : '${asks.length} 个请求等待你处理',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final ask in [newest]) ...[
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 4),
                child: Text(
                  [
                    if (ask.deviceId.isNotEmpty) ask.deviceId,
                    state.labelForSession(ask.sessionId),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
              ApprovalCard(
                ask: ask,
                onDecide: (decision, answers) => ref
                    .read(appControllerProvider.notifier)
                    .decide(ask, decision, answers: answers),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

/// A white circular icon button — the reference app's main chrome element.
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 40,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.5, color: AppColors.textPrimary),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

// --------------------------------------------------------------------------- //
// starting something new
// --------------------------------------------------------------------------- //

class WelcomeView extends ConsumerStatefulWidget {
  const WelcomeView({super.key});

  @override
  ConsumerState<WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends ConsumerState<WelcomeView> with _AttachmentPicker<WelcomeView> {
  final _input = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final attachments = ref.read(appControllerProvider).attachments;
    if ((text.isEmpty && attachments.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final error = await ref
          .read(appControllerProvider.notifier)
          .sendPrompt(text, attachments: attachments);
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      } else {
        _input.clear();
      }
    } finally {
      // The busy flag is cleared on every path. A send that throws used to leave
      // the button spinning forever, which reads as a frozen app.
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickWorkspace() => showWorkspaceSheet(context, ref);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(appControllerProvider);
    // Three fit on one row at phone width; a fourth wraps to a clipped second
    // row on a short viewport. Archived tasks are excluded: the welcome screen
    // offers "continue recent work", and something the user put away is not that.
    final recent = visibleSessions(state.sessions).take(3).toList();

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppGap.page),
            child: Column(
              children: [
                const _Hero(),
                const SizedBox(height: 14),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: '让电脑替你'),
                      TextSpan(
                        text: '干活',
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '通过你自己的中继，远程驱动桌面上的 DeepSeek Harness。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (recent.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('继续最近的任务', style: theme.textTheme.labelSmall),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final session in recent)
                        _RecentChip(
                          label: session.label,
                          running: session.running,
                          onTap: () => ref
                              .read(appControllerProvider.notifier)
                              .openSession(session.sessionId),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppGap.page, 8, AppGap.page, AppGap.page),
          child: Composer(
            controller: _input,
            busy: _sending,
            hintText: '交给电脑做点什么…',
            onSend: _send,
            attachments: state.attachments,
            uploading: state.uploadingAttachments,
            onAttach: _pickAttachment,
            onRemoveAttachment: _removeAttachment,
            leading: WorkspaceChip(
              label: state.workspace.isEmpty ? '默认工作区' : _lastSegment(state.workspace),
              onTap: _pickWorkspace,
            ),
          ),
        ),
      ],
    );
  }

  static String _lastSegment(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}

/// The welcome mark. Our own, but in the reference's spirit: a single large
/// object on a soft radial glow.
///
/// Sized to leave room for the subtitle and the recent-task chips on a short
/// viewport (a landscape tablet or an emulator window), where a 190pt hero
/// pushed them both below the fold.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      height: 112,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [AppColors.accentSoft, AppColors.page],
                stops: [0.1, 1.0],
              ),
            ),
          ),
          // The app icon, not a stand-in glyph: the same artwork the launcher
          // shows, so the screen the user opens and the icon they tapped match.
          const AppLogo(size: 72, radius: 18),
        ],
      ),
    );
  }
}

class _RecentChip extends StatelessWidget {
  const _RecentChip({required this.label, required this.onTap, this.running = false});

  final String label;
  final VoidCallback onTap;
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: AppColors.online,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// an existing session
// --------------------------------------------------------------------------- //

class SessionView extends ConsumerStatefulWidget {
  const SessionView({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends ConsumerState<SessionView>
    with _AttachmentPicker<SessionView>, WidgetsBindingObserver {
  final _transcript = Transcript();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<FollowFrame>? _subscription;
  Timer? _retry;
  int _generation = 0;
  bool _live = false;
  bool _sending = false;
  bool _loadingOlder = false;
  String? _olderError;
  String? _error;

  /// Metrics from the newest follow snapshot, if one carried a projection block.
  SessionMetrics? _snapshotMetrics;

  /// Whether the follow stream has been silent long enough that a nudge from the
  /// other channel counts as evidence it is stale.
  ///
  /// Set by a timer rather than by comparing `DateTime.now()`, because widget tests
  /// advance timers and not the wall clock — a rule that cannot be tested is a rule
  /// that will regress.
  bool _streamLooksStale = false;
  Timer? _staleTimer;
  Timer? _gapTimer;
  Timer? _watchdog;

  /// How long the follow stream may stay silent before a nudge means "stale".
  ///
  /// A quiet conversation is normal, so silence alone proves nothing; it only
  /// becomes evidence when the *other* channel says the desktop moved, because a
  /// healthy stream delivers an append within milliseconds of it happening.
  static const Duration _staleAfter = Duration(seconds: 10);

  /// Rate limit for recoveries, doubling up to [_maxRecoveryGap] while they keep
  /// producing no traffic, and reset by any delivered frame.
  Duration _recoveryGap = const Duration(seconds: 5);
  static const Duration _maxRecoveryGap = Duration(seconds: 60);
  bool _recoveryBlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscribe();
      // Cheap and only useful while something of ours is waiting for the desktop:
      // the staleness flags themselves are timers, see [_noteFrame].
      _watchdog = Timer.periodic(const Duration(seconds: 5), (_) => _checkUnconfirmed());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _retry?.cancel();
    _watchdog?.cancel();
    _staleTimer?.cancel();
    _gapTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _subscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Loads the previous page when the user reaches the older end of the list.
  ///
  /// The list is reversed, so "scrolling back through history" means approaching
  /// `maxScrollExtent`. The snapshot that opens a follow is bounded by bytes — one
  /// long turn can fill it — so without this the conversation simply stopped.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 320) unawaited(_loadOlder());
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_transcript.hasOlder) return;
    final client = ref.read(appControllerProvider.notifier).client;
    final before = _transcript.oldestSeq;
    if (client == null || before <= 0) return;
    final generation = _generation;
    setState(() => _loadingOlder = true);
    try {
      final page = await client.page(
        ref.read(appControllerProvider).activeDeviceId,
        widget.sessionId,
        // `throughSeq` is the inclusive end of the window, so the record before the
        // oldest one we hold is where the previous page starts.
        throughSeq: before - 1,
        beforeSeq: before,
        maxMessages: 60,
      );
      if (!mounted || generation != _generation) return;
      final records = sessionEventsFromRecords(
        page['records'],
        sessionId: widget.sessionId,
      );
      setState(() {
        _transcript.prependOlder(records, hasMore: page['hasMore'] == true);
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      // A failed page is not fatal: the loaded history stays on screen and the
      // user can pull again.
      setState(() => _olderError = '$error');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android suspends the socket while the app is backgrounded, and a half-open
    // connection does not necessarily report an error: the page then shows
    // whatever it had until the App is restarted. Resubscribing on resume is the
    // cheap, deterministic recovery — `session.follow` always reopens with an
    // authoritative snapshot.
    if (state == AppLifecycleState.resumed) _subscribe();
  }

  /// The follow stream delivered something: restart the silence clock.
  ///
  /// Traffic is also proof the stream works, so it clears the recovery backoff.
  void _noteFrame() {
    _streamLooksStale = false;
    _recoveryGap = const Duration(seconds: 5);
    _staleTimer?.cancel();
    _staleTimer = Timer(_staleAfter, () {
      if (mounted) _streamLooksStale = true;
    });
  }

  /// The event socket says this session moved.
  ///
  /// A healthy follow stream delivers an append within milliseconds of the desktop
  /// making it, so "the socket reported activity, the follow stream has been silent
  /// for seconds" means the follow stream is stale — the exact state that used to
  /// require restarting the app or switching sessions, because a half-open HTTP
  /// response never errors and never ends.
  void _onSessionSignal(SessionSignal signal) {
    if (!mounted || signal.sessionId != widget.sessionId) return;
    if (!_streamLooksStale) return;
    _recoverStream('the event socket reported activity');
  }

  /// Re-opens the stream when a message we sent is still unconfirmed.
  ///
  /// Belt and braces for the case where *both* channels died (a network change, a
  /// suspended app): the desktop may have answered while the phone was away, and
  /// the sender's own message must not sit behind a dead socket until a restart.
  void _checkUnconfirmed() {
    if (!mounted || !_streamLooksStale) return;
    if (!_transcript.items.any((item) => item is PendingUserBubble)) return;
    _recoverStream('a sent message is still unconfirmed');
  }

  /// Re-opens the follow stream, rate limited.
  ///
  /// Recovery is not free — it re-fetches the snapshot — so a stream that keeps
  /// going quiet backs off up to a minute, and any delivered frame resets the
  /// backoff because it proves the stream works.
  void _recoverStream(String reason) {
    if (_recoveryBlocked) return;
    _recoveryBlocked = true;
    _recoveryGap = Duration(
      seconds: (_recoveryGap.inSeconds * 2).clamp(5, _maxRecoveryGap.inSeconds),
    );
    _gapTimer?.cancel();
    _gapTimer = Timer(_recoveryGap, () {
      if (mounted) _recoveryBlocked = false;
    });
    debugPrint('[dsh-remote] re-opening the follow stream: $reason');
    _subscribe();
    // The stream carries the conversation; the *list* carries the per-session
    // running flag. A turn that ended while the stream was dead would otherwise
    // leave the composer spinning with its cancel button showing.
    unawaited(ref.read(appControllerProvider.notifier).loadSessions());
  }

  /// (Re)opens the follow stream.
  ///
  /// Deliberately synchronous: cancelling the previous subscription is
  /// fire-and-forget. Awaiting that cancel used to leave a window in which the view
  /// had no subscription at all — during which a recovery could be requested again
  /// and its own `follow` call would land after the fact. The generation counter
  /// already neuters any frame still in flight from the old stream, so the cancel
  /// does not need to gate the re-open.
  void _subscribe() {
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    unawaited(previous?.cancel());

    if (!mounted) return;

    final client = ref.read(appControllerProvider.notifier).client;
    if (client == null) {
      setState(() => _error = '尚未连接中继。');
      return;
    }
    setState(() => _error = null);

    // A fresh subscription restarts the silence clock, otherwise the first nudge
    // from the event socket would immediately declare it stale again.
    _noteFrame();

    final deviceId = ref.read(appControllerProvider).activeDeviceId;
    _subscription = client.follow(deviceId, widget.sessionId, maxMessages: 60).listen(
      (frame) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _live = true;
          _noteFrame();
          if (frame.kind == 'snapshot') {
            _transcript.applySnapshot(frame.snapshotEvents, hasMore: frame.hasMore);
            // The snapshot is where the footer numbers arrive; later frames carry
            // events only.
            _snapshotMetrics = frame.metrics ?? _snapshotMetrics;
          } else if (frame.kind == 'event') {
            final event = frame.event;
            if (event != null) _transcript.applyEvent(event);
            // The footer numbers live in the projections, which arrive with a list
            // read rather than with the stream. Ask for one when a step settles, so
            // the line keeps up with the turn instead of waiting for the next poll.
            if (event?.type == 'step/end' || event?.type == 'turn/end') {
              ref.read(appControllerProvider.notifier).scheduleSessionRefresh();
            }
          } else if (frame.kind == 'assistant-stream') {
            _transcript.applyStreamDelta(frame.streamingText);
          }
        });
      },
      onError: (Object error) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _live = false;
          _error = '$error';
        });
        _scheduleRetry();
      },
      onDone: () {
        if (!mounted || generation != _generation) return;
        setState(() => _live = false);
        _scheduleRetry();
      },
      cancelOnError: true,
    );
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      if (mounted) _subscribe();
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final attachments = ref.read(appControllerProvider).attachments;
    if ((text.isEmpty && attachments.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final error = await ref.read(appControllerProvider.notifier).sendPrompt(
            text,
            attachments: attachments,
            // The sender's own turn is shown at once, marked unconfirmed; the
            // durable event replaces it when it arrives. Waiting for the follow
            // stream instead is why a message sent from the phone could stay
            // invisible until the App was restarted.
            onAccepted: (requestId, echoText) {
              if (!mounted) return;
              setState(() {
                _transcript.applyLocalUserMessage(
                  echoText,
                  requestId: requestId,
                );
              });
            },
          );
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      } else {
        _input.clear();
        // A stream that died while the phone was in the background never notices,
        // and the only recovery used to be restarting the App. Reopening it costs
        // one snapshot and guarantees the view is actually live.
        _subscribe();
      }
    } finally {
      // Same rule as the welcome view: the composer must never be left busy.
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancel() async {
    final error = await ref.read(appControllerProvider.notifier).cancelActiveTurn();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// The numbers spelled out, on tap.
  void _showMetrics(SessionMetrics metrics) {
    final session = ref.read(appControllerProvider).activeSession;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // The breakdown is taller than the default sheet height on a phone, and it
      // grows with the rows a session has; let it size itself and scroll.
      isScrollControlled: true,
      builder: (_) => _MetricsSheet(
        title: session?.label ?? '',
        metrics: metrics,
        preset: session?.agentPreset ?? '',
        permission: session?.permission ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(appControllerProvider);
    final session = state.activeSession;

    // Two independent liveness clues for a stream that cannot report its own death:
    // the event socket saying this session moved (see [_onSessionSignal]), and the
    // event socket coming back at all — a network blip that killed it almost
    // certainly killed the follow stream too.
    ref.listen<AppState>(appControllerProvider, (previous, next) {
      final signal = next.lastSignal;
      if (signal != null && !identical(signal, previous?.lastSignal)) {
        _onSessionSignal(signal);
      }
      final reconnected = next.eventsState == RelayEventsState.connected &&
          previous?.eventsState != RelayEventsState.connected;
      if (reconnected && !_live) _recoverStream('the event socket reconnected');
    });

    // Two sources for the same numbers: the follow snapshot (freshest at open and
    // after every reconnect) and the task list (refreshed while a turn runs, so the
    // line moves instead of freezing until the next resubscribe). Newer seq wins.
    final metrics = SessionMetrics.freshest(_snapshotMetrics, session?.metrics);

    return Column(
      children: [
        if (_error != null) _ErrorBar(message: _error!, onRetry: _subscribe),
        Expanded(child: _buildTranscript(theme)),
        if (metrics != null && !metrics.isEmpty)
          _StatusLine(metrics: metrics, onTap: () => _showMetrics(metrics)),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppGap.page, 4, AppGap.page, AppGap.page),
          child: Composer(
            controller: _input,
            busy: _sending,
            running: session?.running ?? false,
            onCancel: _cancel,
            onSend: _send,
            attachments: state.attachments,
            uploading: state.uploadingAttachments,
            onAttach: _pickAttachment,
            onRemoveAttachment: _removeAttachment,
            leading: _SessionModelChip(session: session),
          ),
        ),
      ],
    );
  }

  Widget _buildTranscript(ThemeData theme) {
    final rows = buildRows(_transcript.items);
    final streaming = _transcript.streamingText;

    if (rows.isEmpty && streaming.isEmpty) {
      return Center(
        child: Text(
          _live ? '这个任务还是空的，发一条消息试试。' : '正在打开任务…',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    // One extra row past the oldest message: the "older end" of a reversed list.
    // It is where the user finds out whether scrolling back did anything.
    final footer = _HistoryFooter(
      loading: _loadingOlder,
      exhausted: !_transcript.hasOlder,
      error: _olderError,
      onRetry: _loadOlder,
    );
    final itemCount = rows.length + (streaming.isEmpty ? 0 : 1) + 1;

    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(AppGap.page, 4, AppGap.page, 8),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index == itemCount - 1) return footer;
        if (streaming.isNotEmpty) {
          if (index == 0) return _StreamingBubble(text: streaming);
          return _buildRow(theme, rows[reverseIndexOf(rows.length, index - 1)]);
        }
        return _buildRow(theme, rows[reverseIndexOf(rows.length, index)]);
      },
    );
  }

  Widget _buildRow(ThemeData theme, ConversationRow row) {
    switch (row) {
      case ProcessTimeline():
        return ProcessTimelineView(
          timeline: row,
          // The newest run is the interesting one, so open it when it is the
          // only thing on screen; otherwise stay collapsed.
          initiallyExpanded: row.runningCount > 0,
        );
      case MessageRow():
        final item = row.item;
        return switch (item) {
          UserBubble() => _UserBubble(text: item.text),
          PendingUserBubble() => _UserBubble(text: item.text, pending: true),
          ContextNotice() => _ContextNoticeRow(notice: item),
          DeliverablesCard() => _DeliverablesCardView(card: item),
          AssistantBubble() => Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarkdownOrPlain(text: item.text),
                  if (item.interrupted)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('（被中断）', style: theme.textTheme.labelSmall),
                    ),
                ],
              ),
            ),
          SystemNote() => Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(item.text, style: theme.textTheme.labelSmall),
              ),
            ),
          QuestionCard() => _QuestionCardView(
              card: item,
              deviceId: ref.read(appControllerProvider).activeDeviceId,
              onAnswer: (answers) async {
                final controller = ref.read(appControllerProvider.notifier);
                final questionIds =
                    item.questions.map((question) => asString(question['id'])).toList();
                // While the question is still blocking, the ask is the only path
                // that accepts an answer; the op would answer `false` and the
                // answer would be dropped.
                final live = controller.liveQuestionFor(widget.sessionId, questionIds);
                if (live != null) {
                  await controller.decide(live, 'approved', answers: answers);
                  return null;
                }
                return controller.answerQuestion(
                  sessionId: widget.sessionId,
                  callId: item.callId,
                  answers: answers,
                );
              },
            ),
          // Reasoning and tools are handled by ProcessTimeline above.
          _ => const SizedBox.shrink(),
        };
    }
  }
}

/// An `ask_user_question` call, rendered as something the user can answer.
///
/// The questions come from the tool call's arguments — part of the durable
/// session log the phone already receives — so the card appears with no push
/// channel involved. The existing [ApprovalCard] renders the options, multi
/// select and custom text and produces the `{id, selected, custom?}` shape the
/// harness expects, so it is reused rather than duplicated.
class _QuestionCardView extends StatelessWidget {
  const _QuestionCardView({
    required this.card,
    required this.deviceId,
    required this.onAnswer,
  });

  final QuestionCard card;
  final String deviceId;
  final Future<String?> Function(List<Map<String, dynamic>> answers) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (card.answered) {
      final chosen = (card.answers ?? const [])
          .map((answer) {
            final selected = (answer['selected'] as List?)?.whereType<String>().join('、') ?? '';
            final custom = (answer['custom'] as String?) ?? '';
            return [selected, custom].where((part) => part.isNotEmpty).join('；');
          })
          .where((text) => text.isNotEmpty)
          .join(' / ');

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(AppGap.page),
        decoration: cardDecoration(color: AppColors.surfaceMuted),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.check_circle_outline, size: 18, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('已回答', style: theme.textTheme.titleSmall),
                  if (chosen.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(chosen, style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Reuse the approval card by presenting the questions in the shape it
    // already understands.
    final ask = ApprovalAsk(
      askId: card.callId,
      topic: 'question.ask',
      sessionId: deviceId,
      payload: {'questions': card.questions},
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ApprovalCard(
        ask: ask,
        onDecide: (decision, answers) async {
          if (decision != 'approved' || answers == null) return;
          final error = await onAnswer(answers);
          if (!context.mounted) return;
          // Say something on BOTH paths. The card already greys its buttons on
          // submit, so without a visible message a success is indistinguishable
          // from a failure — which is exactly how a working answer was reported
          // as "you never received it".
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 6),
                content: Text(error == null ? '已把回答发回电脑，等待它确认…' : '发送失败：$error'),
              ),
            );
        },
      ),
    );
  }
}

/// The user's own turn: a left-aligned grey bubble with a green rail.
///
/// The rail is the whole point: the harness injects its own `user/message`
/// events (agent messages, model switches, runtime context), and without a mark
/// on the human's turns the two are indistinguishable — the user reported exactly
/// this ("which of these did I send?"). Green is the app's accent, and nothing
/// else in the transcript is allowed to use it.
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, this.pending = false});

  final String text;

  /// Accepted by the relay but not yet seen in the durable log.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.84,
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            border: const Border(left: BorderSide(color: AppColors.accent, width: 4)),
            borderRadius: BorderRadius.circular(AppRadius.bubble),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SelectableText(text, style: theme.textTheme.bodyMedium),
                  ),
                  if (pending) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ],
                ],
              ),
              if (pending)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    '已发出，等电脑确认…',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The files an agent declared as deliverables, as a list — never their contents.
///
/// Why a phone needs this at all: driving the desktop from the outside, the one
/// thing you cannot see is the filesystem. `present` is how an agent says "this is
/// what I made", and the durable `deliverables/presented` event carries the list,
/// so the app can show **which** artifacts exist and what each one is for without
/// having to fetch a single byte. Tapping a row does nothing on purpose: the app
/// has no way to open a file on the desktop, and a row that looks tappable but is
/// not is worse than a plain list.
class _DeliverablesCardView extends StatefulWidget {
  const _DeliverablesCardView({required this.card});

  final DeliverablesCard card;

  @override
  State<_DeliverablesCardView> createState() => _DeliverablesCardViewState();
}

class _DeliverablesCardViewState extends State<_DeliverablesCardView> {
  /// How many rows a collapsed card shows. Enough to see the shape of the
  /// delivery on one screen; the rest is one tap away.
  static const int _collapsedRows = 4;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = widget.card.files;
    final hidden = files.length - _collapsedRows;
    final shown = _expanded || hidden <= 0 ? files : files.take(_collapsedRows).toList();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hidden > 0 ? () => setState(() => _expanded = !_expanded) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppGap.page, 12, 10, 10),
              child: Row(
                children: [
                  const Icon(
                    Icons.inventory_2_outlined,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '产物 · ${files.length} 个文件',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (hidden > 0)
                    Text(
                      _expanded ? '收起' : '展开全部',
                      style: theme.textTheme.labelSmall?.copyWith(color: AppColors.accentText),
                    ),
                  if (hidden > 0)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: AppColors.accentText,
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          for (final file in shown) _DeliverableRow(file: file),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _DeliverableRow extends StatelessWidget {
  const _DeliverableRow({required this.file});

  final DeliverableFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppGap.page, 9, AppGap.page, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(_iconFor(file.name), size: 16, color: AppColors.textSecondary),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (file.directory.isNotEmpty)
                  Text(
                    // The full path matters here: two builds in different folders
                    // are otherwise indistinguishable by file name alone.
                    file.directory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                if (file.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(file.description, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'png' || 'jpg' || 'jpeg' || 'webp' || 'gif' => Icons.image_outlined,
      'apk' => Icons.android_outlined,
      'zip' || 'gz' || '7z' => Icons.folder_zip_outlined,
      'md' || 'txt' => Icons.description_outlined,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.data_object_outlined,
      'dart' || 'js' || 'mjs' || 'py' || 'ts' || 'sh' || 'ps1' => Icons.code_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}


/// One line of harness-injected context, expandable to its full text.
///
/// These arrive as ordinary `user/message` events, so before this they rendered
/// as full grey bubbles: an `Agent <uuid> sent a message: …` or a whole tool
/// catalog looked like something the user had typed, and a couple of them buried
/// the actual conversation. Collapsed to a single row with its own label; tapping
/// opens the text.
class _ContextNoticeRow extends StatefulWidget {
  const _ContextNoticeRow({required this.notice});

  final ContextNotice notice;

  @override
  State<_ContextNoticeRow> createState() => _ContextNoticeRowState();
}

class _ContextNoticeRowState extends State<_ContextNoticeRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = widget.notice;
    // Name the sender when the harness told us who it was: "子代理消息 · b7e08bc2"
    // says which agent this came from without opening anything.
    final sender = notice.senderId.length > 8
        ? notice.senderId.substring(0, 8)
        : notice.senderId;
    final label = sender.isEmpty
        ? contextNoticeLabel(notice.sourceKind)
        : '${contextNoticeLabel(notice.sourceKind)} · $sender';
    final preview = contextNoticePreview(notice);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        // White, not `surfaceMuted`: the human's bubble is the grey one, and a
        // notice that shares its fill reads as another message from them.
        color: AppColors.surface,
        border: const Border(left: BorderSide(color: AppColors.rail, width: 3)),
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.field),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.forum_outlined, size: 15, color: AppColors.textTertiary),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textTertiary,
                  ),
                ],
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 4),
                  child: MarkdownOrPlain(text: notice.text),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The model control in the session composer.
///
/// The selection shown comes from the harness's own projection (it arrives with
/// `session.list`), and changing it is a separate call from sending a prompt —
/// `session.prompt` has no model argument, which is exactly why the first
/// version of this composer wrongly had no model control at all.
class _SessionModelChip extends ConsumerStatefulWidget {
  const _SessionModelChip({required this.session});

  final SessionSummary? session;

  @override
  ConsumerState<_SessionModelChip> createState() => _SessionModelChipState();
}

class _SessionModelChipState extends ConsumerState<_SessionModelChip> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(appControllerProvider.notifier).loadModelCatalog();
    });
  }

  Future<void> _pick() async {
    final controller = ref.read(appControllerProvider.notifier);
    final catalog = controller.catalog ?? await controller.loadModelCatalog();
    if (!mounted) return;
    if (catalog == null || catalog.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('读不到模型列表，检查设备是否在线。')),
      );
      return;
    }

    final chosen = await showModelPicker(
      context,
      catalog: catalog,
      current: widget.session?.model ?? catalog.defaultSelection,
    );
    if (chosen == null || !mounted) return;

    setState(() => _busy = true);
    final error = await controller.selectModel(chosen);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(error ?? '已切换到 ${chosen.shortName}')));
  }

  @override
  Widget build(BuildContext context) {
    // Watch the state so the chip refreshes once the catalog lands.
    ref.watch(appControllerProvider);
    final catalog = ref.read(appControllerProvider.notifier).catalog;
    final selection = widget.session?.model ?? catalog?.defaultSelection;
    final label = selection == null
        ? '选择模型'
        : (catalog?.nameFor(selection) ?? selection.shortName);

    return ModelChip(label: label, busy: _busy, onTap: _pick);
  }
}

/// Text being streamed before the message is committed.
///
/// Deliberately not run through the Markdown renderer: partial markers arrive
/// mid-token, so formatting it live makes the text flicker between plain and
/// styled on every delta.
class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: SizedBox(
              width: 7,
              height: 7,
              child: DecoratedBox(
                decoration: BoxDecoration(color: AppColors.online, shape: BoxShape.circle),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "older end" row of the conversation.
///
/// A followed session opens with a byte-bounded window (a long turn can fill it by
/// itself), so the top of the list is not necessarily the beginning of the task.
/// This row is how the user learns which of the three it is: more to fetch, busy
/// fetching, or genuinely the start.
class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter({
    required this.loading,
    required this.exhausted,
    required this.error,
    required this.onRetry,
  });

  final bool loading;
  final bool exhausted;
  final String? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget child;
    if (loading) {
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('正在加载更早的消息…', style: theme.textTheme.labelSmall),
        ],
      );
    } else if (error != null) {
      child = TextButton(
        onPressed: () => unawaited(onRetry()),
        child: Text('更早的消息没取到，点这里重试', style: theme.textTheme.labelSmall),
      );
    } else if (exhausted) {
      child = Text('已经到开头了', style: theme.textTheme.labelSmall);
    } else {
      child = Text('往上滑看更早的消息', style: theme.textTheme.labelSmall);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(child: child),
    );
  }
}

/// The session's numbers, in the desktop's own wording.
///
/// DSH puts this line in its composer dock; the phone puts it in the same place —
/// directly above the input, under the conversation — so the two read alike.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.metrics, required this.onTap});

  final SessionMetrics metrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = metricsSegments(metrics);
    if (segments.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppGap.page, vertical: 6),
        // One line at any font scale: these are reference numbers, and a wrapped
        // row here would shove the composer around as they change.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            segments.join(' · '),
            style: theme.textTheme.labelSmall?.copyWith(color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// The same numbers, spelled out, after tapping the status line.
class _MetricsSheet extends StatelessWidget {
  const _MetricsSheet({
    required this.title,
    required this.metrics,
    this.preset = '',
    this.permission = '',
  });

  final String title;
  final SessionMetrics metrics;
  final String preset;
  final String permission;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppGap.page, AppGap.base, AppGap.page, AppGap.base),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('任务用量', style: theme.textTheme.titleSmall),
              if (title.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
              ],
              const SizedBox(height: 6),
              for (final row in metricsDetail(metrics, preset: preset, permission: permission))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 96, child: Text(row.$1, style: theme.textTheme.labelSmall)),
                      Expanded(
                        child: Text(
                          row.$2,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AppGap.base),
              // The desktop reads these from a live projection stream; the phone
              // re-reads them on every (re)subscribe and while a turn runs.
              Text(
                '数据来自 DSH 的会话投影：模式与权限、回合与步数、累计 token、缓存命中与上下文占用。',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(AppGap.page, 0, AppGap.page, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.timeline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.danger),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// Approval / question card, restyled for the light surface.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({super.key, required this.ask, required this.onDecide});

  final ApprovalAsk ask;
  final void Function(String decision, List<Map<String, dynamic>>? answers) onDecide;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  final Map<String, Set<String>> _selected = {};
  final Map<String, TextEditingController> _custom = {};
  bool _submitted = false;

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit(String decision) {
    if (_submitted) return;
    setState(() => _submitted = true);
    final answers = <Map<String, dynamic>>[];
    for (final question in widget.ask.questions) {
      final id = (question['id'] ?? '').toString();
      final selected = _selected[id]?.toList() ?? const <String>[];
      final custom = _custom[id]?.text.trim() ?? '';
      answers.add({
        'id': id,
        'selected': selected,
        if (custom.isNotEmpty) 'custom': custom,
      });
    }
    widget.onDecide(decision, answers.isEmpty ? null : answers);
  }

  /// Whether every question has an answer worth sending.
  ///
  /// A question with options needs a selection; one without options needs typed
  /// text. Without this the submit button happily sends an empty batch — and it
  /// did: a real test run produced `提问 · 0/1 已回答` and handed the model an answer
  /// with `selected: []`, which costs the agent a turn and says nothing.
  bool get _answerComplete {
    for (final question in widget.ask.questions) {
      final id = (question['id'] ?? '').toString();
      final options = question['options'];
      if (options is List && options.isNotEmpty) {
        if ((_selected[id] ?? const <String>{}).isEmpty) return false;
      } else if ((_custom[id]?.text.trim() ?? '').isEmpty) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ask = widget.ask;

    return Container(
      decoration: cardDecoration(),
      padding: const EdgeInsets.all(AppGap.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.gpp_maybe_outlined, size: 19, color: AppColors.textPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ask.isQuestion
                      ? '电脑在等你回答'
                      : '电脑请求执行：${ask.toolName.isEmpty ? '工具' : ask.toolName}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (ask.displayReason != null || ask.reason != null) ...[
            const SizedBox(height: 6),
            Text(ask.displayReason ?? ask.reason!, style: theme.textTheme.bodySmall),
          ],
          if (ask.isQuestion)
            for (final question in ask.questions) _buildQuestion(theme, question),
          const SizedBox(height: AppGap.base),
          Row(
            children: [
              if (!ask.isQuestion) ...[
                Expanded(
                  child: FilledButton(
                    onPressed: _submitted ? null : () => _submit('approved'),
                    child: const Text('允许一次'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitted ? null : () => _submit('denied'),
                    child: const Text('拒绝'),
                  ),
                ),
              ] else
                Expanded(
                  child: FilledButton(
                    // Disabled until the answer is complete, so an empty batch
                    // cannot be sent by a stray tap.
                    onPressed: (_submitted || !_answerComplete) ? null : () => _submit('approved'),
                    child: const Text('提交回答'),
                  ),
                ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '交回电脑处理',
                onPressed: _submitted ? null : () => _submit('cancelled'),
                icon: const Icon(Icons.keyboard_return_rounded, size: 20),
                color: AppColors.textSecondary,
              ),
            ],
          ),
          Text(
            ask.isQuestion && !_answerComplete && !_submitted
                ? '先选一个选项（没有选项就填一段回答）再提交。'
                : '不回答也可以：超时后电脑上会照常弹出这个审批。',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Widget _buildQuestion(ThemeData theme, Map<String, dynamic> question) {
    final id = (question['id'] ?? '').toString();
    final options =
        (question['options'] as List?)?.whereType<Map<dynamic, dynamic>>().toList() ?? const [];
    final multi = question['multiSelect'] == true;
    _selected.putIfAbsent(id, () => <String>{});
    _custom.putIfAbsent(id, () {
      // The submit button's enabled state depends on this text, so typing has to
      // rebuild the card. Without the listener the button would stay disabled
      // until something else happened to trigger a rebuild.
      final controller = TextEditingController();
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      return controller;
    });

    return Padding(
      padding: const EdgeInsets.only(top: AppGap.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((question['question'] ?? '').toString(), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          if (options.isEmpty)
            TextField(controller: _custom[id], decoration: const InputDecoration(hintText: '回答'))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  FilterChip(
                    label: Text((option['label'] ?? '').toString()),
                    selected: _selected[id]!.contains((option['label'] ?? '').toString()),
                    // The default chip is a whisper of grey on a white card: on a
                    // phone screenshot the unselected options read as plain text,
                    // so nothing looked tappable. Give every option a real pill.
                    backgroundColor: AppColors.surfaceMuted,
                    selectedColor: AppColors.accentSoft,
                    side: const BorderSide(color: AppColors.divider),
                    showCheckmark: true,
                    onSelected: (isSelected) {
                      setState(() {
                        final label = (option['label'] ?? '').toString();
                        if (multi) {
                          if (isSelected) {
                            _selected[id]!.add(label);
                          } else {
                            _selected[id]!.remove(label);
                          }
                        } else {
                          _selected[id]!
                            ..clear()
                            ..add(label);
                        }
                      });
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
