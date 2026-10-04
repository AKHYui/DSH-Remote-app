/// Turns a session's event stream into a renderable conversation.
///
/// This is intentionally pure Dart with no Flutter imports: it is the part most
/// likely to be wrong, so it is the part that gets unit tested. See
/// `test/transcript_test.dart`.
library;

import 'dart:convert';

import '../api/models.dart';

/// One row in the conversation view.
sealed class ChatItem {
  const ChatItem({required this.seq});

  /// Durable sequence number of the event this came from.
  final int seq;

  /// Reasoning and tool activity are "process": the UI collapses them into a
  /// timeline rather than showing them as conversation. Without this a long
  /// agent run buries the actual dialogue under dozens of cards.
  bool get isProcess => switch (this) {
        ReasoningNote() => true,
        ToolCall() => true,
        UserBubble() => false,
        PendingUserBubble() => false,
        AssistantBubble() => false,
        ContextNotice() => false,
        DeliverablesCard() => false,
        SystemNote() => false,
        // A question is addressed to the human, so it must never be folded away
        // with the machinery.
        QuestionCard() => false,
      };
}

/// The tool the harness exposes for asking the human a question.
const String kAskUserQuestionTool = 'ask_user_question';

/// Extracts a question call's questions from its raw arguments.
///
/// Returns null when this is not a well-formed question call, so the caller can
/// fall back to showing it as an ordinary tool call rather than a broken card.
List<Map<String, dynamic>>? parseToolQuestions(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  final rawQuestions = asMap(decoded)['questions'];
  if (rawQuestions is! List) return null;
  final questions = rawQuestions
      .whereType<Map<dynamic, dynamic>>()
      .map((item) => item.cast<String, dynamic>())
      .where((question) => asString(question['id']).isNotEmpty)
      .toList(growable: false);
  return questions.isEmpty ? null : questions;
}

/// Reads the answers the harness recorded into a question's tool result.
///
/// The result carries JSON text of the form
/// `{"answers":[{"id":"...","selected":[...],"custom":"..."}]}`.
List<Map<String, dynamic>>? parseAnswersFromResult(Map<String, dynamic> data) {
  final text = contentText(asMap(data['message'])['content']).trim();
  if (text.isEmpty) return null;
  try {
    final raw = asMap(jsonDecode(text))['answers'];
    if (raw is! List) return null;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  } on FormatException {
    return null;
  }
}

/// An `ask_user_question` call, shown as an interactive card.
///
/// The questions arrive as the tool call's arguments — part of the durable
/// session log, which the phone already receives — so discovering them needs no
/// push channel at all. Only the answer has to travel back.
final class QuestionCard extends ChatItem {
  const QuestionCard({
    required super.seq,
    required this.callId,
    required this.questions,
    this.answers,
  });

  final String callId;
  final List<Map<String, dynamic>> questions;

  /// What the harness recorded, once the call has a result.
  final List<Map<String, dynamic>>? answers;

  bool get answered => answers != null;

  QuestionCard withAnswers(List<Map<String, dynamic>> answers) => QuestionCard(
        seq: seq,
        callId: callId,
        questions: questions,
        answers: answers,
      );
}

/// A message the user sent.
final class UserBubble extends ChatItem {
  const UserBubble({required super.seq, required this.text, this.rpcId = ''});
  final String text;

  /// The request id the phone sent with this prompt, when the harness echoed it.
  ///
  /// DSH records the caller's `requestId` in `source.rpcId`, which is what lets a
  /// locally echoed bubble be matched to its durable event **exactly** rather than
  /// by guessing from the text.
  final String rpcId;
}

/// A user message shown locally at the moment the relay accepted it, before the
/// durable `user/message` has been observed.
///
/// Without this the sender's own turn is invisible until the follow stream
/// delivers the event — and if that stream has gone stale (a phone that was
/// backgrounded, a relay restart) it stays invisible until the App is restarted,
/// which is exactly the bug this fixes. It is removed the moment the durable
/// event arrives, matched by `rpcId` and falling back to the text.
final class PendingUserBubble extends ChatItem {
  const PendingUserBubble({
    required super.seq,
    required this.text,
    this.requestId = '',
  });

  final String text;
  final String requestId;
}

/// Context the harness injected into the session, which arrives as a
/// `user/message` like any other.
///
/// DSH's `MessageSourceMap` has exactly one kind for the human's own words
/// (`user`, plus `user-rpc` which is the same kind with an `rpcId`) and
/// everything else is machine-written: `agent-message` (another agent's
/// `Agent <id> sent a message: …`), `subagent-settled`, `model-selection`,
/// `runtime-context`, `skill-catalog`, `compact-checkpoint`, … Those turned up in
/// the phone's transcript as ordinary grey user bubbles — indistinguishable from
/// the human's own turn and often enormous. They are kept, because they explain
/// what the harness is doing, but collapsed to one line.
final class ContextNotice extends ChatItem {
  const ContextNotice({
    required super.seq,
    required this.text,
    this.sourceKind = '',
    this.summary = '',
    this.senderId = '',
  });

  /// The full injected text, shown only when the row is expanded.
  final String text;

  /// The `source.kind` that produced it, used for the collapsed label.
  final String sourceKind;

  /// `source.summary`, when the harness supplied a one-line description.
  final String summary;

  /// `source.senderSessionId` for an `agent-message`: which agent wrote it.
  final String senderId;
}

/// The prefix DSH puts on an adjacent-agent message.
///
/// `createAgentMessage` frames every one of them as
/// `Agent <sender-uuid> sent a message: ` + the real content. That framing is
/// exactly the noise the user asked to stop seeing, so the collapsed preview
/// drops it and keeps the words the agent actually wrote.
final RegExp _agentFraming = RegExp(r'^Agent\s+\S+\s+sent a message:\s*');

/// One line worth showing while a notice is collapsed.
String contextNoticePreview(ContextNotice notice) {
  final source = notice.summary.isNotEmpty ? notice.summary : notice.text;
  return source.replaceFirst(_agentFraming, '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Whether a `user/message`'s `source.kind` means "the human wrote this".
///
/// Authoritative list: `MessageSourceMap` in DSH's session controller. An empty
/// kind is treated as human — an unknown/older shape is more likely a real
/// message than injected context, and hiding someone's own words is worse than
/// leaving one notice uncollapsed.
bool isHumanUserSourceKind(String kind) =>
    kind.isEmpty || kind == 'user' || kind == 'user-question-reply';

/// A short label for one injected-context kind.
String contextNoticeLabel(String kind) => switch (kind) {
      'agent-message' => '子代理消息',
      'subagent-settled' => '子代理已结束',
      'subagent-report' => '子代理汇报',
      'model-selection' => '模型已切换',
      'runtime-context' => '运行环境上下文',
      'skill-catalog' => '技能目录',
      'skill-invocation' => '已加载技能',
      'tool-registry' => '工具目录',
      'compact-checkpoint' => '上下文压缩点',
      'session-reference' => '关联会话',
      'user-approval' => '审批策略变化',
      'ptc-mode' => '模式变化',
      'schedule' => '定时任务',
      'goal' => '目标',
      'cordis-host-runner' => '宿主任务',
      '' => '系统消息',
      _ => kind.startsWith('agent-') || kind.startsWith('subagent-')
          ? '子代理消息'
          : '系统消息',
    };

/// One-line stand-in for a turn whose only content is attachments.
///
/// A `user/message` carrying an image or a file and no text flattens to nothing,
/// so without this the phone's own photo turn would leave no trace in the
/// transcript — and the local echo of it would look like it vanished when the
/// durable event superseded it. Images and files are counted the same way in both
/// places, so the echo and the durable bubble read identically.
String attachmentPlaceholder({int images = 0, int files = 0}) => [
      if (images > 0) images == 1 ? '[图片]' : '[$images 张图片]',
      if (files > 0) files == 1 ? '[文件]' : '[$files 个文件]',
    ].join(' ');

/// Counts the image/file blocks in a `user/message`'s content.
({int images, int files}) countAttachments(Object? content) {
  var images = 0;
  var files = 0;
  if (content is List) {
    for (final block in content) {
      switch (asString(asMap(block)['type'])) {
        case 'image':
          images += 1;
        case 'file':
          files += 1;
      }
    }
  }
  return (images: images, files: files);
}

/// One file an agent declared as a deliverable.
final class DeliverableFile {
  const DeliverableFile({required this.path, this.description = ''});

  /// Host path, exactly as the agent wrote it (absolute or repo-relative).
  final String path;

  /// The agent's own note about what this file is, when it wrote one.
  final String description;

  /// Last path segment, for the headline of a row.
  String get name => fileNameOf(path);

  /// Everything before the last segment: the muted second line.
  String get directory {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index <= 0 ? '' : path.substring(0, index);
  }
}

/// The last path segment of [path], tolerating both separators.
String fileNameOf(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// A turn's declared deliverables — the files the agent called `present` on.
///
/// The durable event is `deliverables/presented` with
/// `{turn, callId, files:[{path, description?}]}`, which is the same list the
/// desktop shows as its delivery card. The phone shows **which** files came out
/// and what they are for, never their contents: a remote reader cannot open them
/// anyway, and pretending otherwise would be worse than a list.
final class DeliverablesCard extends ChatItem {
  const DeliverablesCard({required super.seq, required this.turn, required this.files});

  /// The turn that produced them (1-based), 0 when the harness did not say.
  final int turn;
  final List<DeliverableFile> files;
}

/// Reads a `deliverables/presented` payload. Returns an empty list for anything
/// malformed, so a bad event renders nothing instead of an empty card.
List<DeliverableFile> parseDeliverables(Object? data) {
  final raw = asMap(data)['files'];
  if (raw is! List) return const [];
  final files = <DeliverableFile>[];
  for (final entry in raw) {
    final map = asMap(entry);
    final path = asString(map['path']).trim();
    if (path.isEmpty) continue;
    files.add(DeliverableFile(path: path, description: asString(map['description']).trim()));
  }
  return files;
}
/// A message from the model.
final class AssistantBubble extends ChatItem {
  const AssistantBubble({required super.seq, required this.text, this.interrupted = false});
  final String text;
  final bool interrupted;
}

/// The model's reasoning, shown collapsed by default.
final class ReasoningNote extends ChatItem {
  const ReasoningNote({required super.seq, required this.text});
  final String text;
}

/// A tool invocation, optionally carrying its result once it arrives.
final class ToolCall extends ChatItem {
  const ToolCall({
    required super.seq,
    required this.callId,
    required this.name,
    required this.arguments,
    this.result,
    this.isError = false,
  });

  final String callId;
  final String name;
  final String arguments;
  final String? result;
  final bool isError;

  bool get hasResult => result != null;

  ToolCall withResult({required String text, required bool isError}) => ToolCall(
        seq: seq,
        callId: callId,
        name: name,
        arguments: arguments,
        result: text,
        isError: isError,
      );
}

/// Maps a layout index in a reversed (newest-first) list back to a position in
/// [items], which are stored oldest-first.
///
/// The chat view uses `ListView(reverse: true)` so that opening a session lands
/// on the newest message: in a reversed list offset 0 is the bottom. That means
/// index 0 has to resolve to the *last* item. Getting this off by one silently
/// shows the wrong message, so the arithmetic lives here and is tested.
int reverseIndexOf(int length, int index) => length - 1 - index;

/// One visual row of the conversation.
///
/// Consecutive process items collapse into a single [ProcessTimeline]; everything
/// else stands alone.
sealed class ConversationRow {
  const ConversationRow();
}

/// A single message: a user bubble, assistant text, or a system note.
final class MessageRow extends ConversationRow {
  const MessageRow(this.item);

  final ChatItem item;
}

/// A run of consecutive reasoning steps and tool calls, rendered as one
/// collapsible timeline.
final class ProcessTimeline extends ConversationRow {
  ProcessTimeline(this.items) : assert(items.isNotEmpty, 'an empty timeline is not a row');

  final List<ChatItem> items;

  int get count => items.length;

  /// Distinct tool names in first-seen order, for a one-line summary.
  List<String> get toolNames {
    final seen = <String>{};
    for (final item in items) {
      if (item is ToolCall && item.name.isNotEmpty) seen.add(item.name);
    }
    return seen.toList(growable: false);
  }

  /// Calls that have not produced a result yet, so a collapsed run can still show
  /// that something is in flight.
  int get runningCount =>
      items.whereType<ToolCall>().where((call) => !call.hasResult).length;

  /// Failed calls. A collapsed run must not read as unqualified success.
  int get failureCount => items.whereType<ToolCall>().where((call) => call.isError).length;
}

/// Splits [items] into rows, collapsing each run of process items.
List<ConversationRow> buildRows(List<ChatItem> items) {
  final rows = <ConversationRow>[];
  var pending = <ChatItem>[];

  void flush() {
    if (pending.isEmpty) return;
    rows.add(ProcessTimeline(List<ChatItem>.unmodifiable(pending)));
    pending = <ChatItem>[];
  }

  for (final item in items) {
    if (item.isProcess) {
      pending.add(item);
    } else {
      flush();
      rows.add(MessageRow(item));
    }
  }
  flush();
  return rows;
}

/// A short system-style note (turn aborted, model error, ...).
final class SystemNote extends ChatItem {
  const SystemNote({required super.seq, required this.text});
  final String text;
}

/// Builds and maintains the transcript for one session.
///
/// Frames come from two places and are handled differently:
///
///   * a `snapshot` is authoritative — it replaces everything, which is what
///     makes reconnects trivial: just resubscribe and rebuild.
///   * a live `event` is appended, but only if its sequence number is new, so a
///     duplicate delivery cannot double-render a message.
class Transcript {
  final List<ChatItem> items = [];

  /// Text the model is streaming before the message is committed.
  String streamingText = '';

  int get lastSeq => _maxSeq;
  int _maxSeq = 0;
  int _localSeq = -1;
  final Map<String, int> _toolCallIndex = {};

  bool get isEmpty => items.isEmpty && streamingText.isEmpty;

  /// Show a prompt immediately after the relay accepted it.
  ///
  /// The follow stream is authoritative, but it can deliver the committed user
  /// event late — or never, if the stream went stale while the phone was
  /// backgrounded — which used to make the sender's own message appear only after
  /// restarting the App. So the sender's own turn is echoed at once, marked as
  /// unconfirmed, and reconciled against the durable event when it arrives.
  ///
  /// [requestId] is the `requestId` sent with `session.prompt`; DSH echoes it as
  /// `source.rpcId`, so reconciliation can be exact. Matching by text is the
  /// fallback for an event that does not carry one.
  ///
  /// [attachmentLabel] stands in when the turn carries only attachments, so a
  /// photo still leaves something behind.
  void applyLocalUserMessage(
    String text, {
    String requestId = '',
    String attachmentLabel = '',
  }) {
    final visible = text.trim().isNotEmpty ? text.trim() : attachmentLabel;
    if (visible.isEmpty) return;
    // Already confirmed by the durable log (or already echoed once) — a second
    // local copy would show the same turn twice.
    if (_hasUserBubble(text: visible, rpcId: requestId)) return;
    items.add(
      PendingUserBubble(seq: _localSeq--, text: visible, requestId: requestId),
    );
  }

  void clear() {
    items.clear();
    _toolCallIndex.clear();
    streamingText = '';
    _maxSeq = 0;
  }

  /// Rebuilds from a follow snapshot (authoritative).
  ///
  /// Everything is replaced — that is what makes reconnects trivial — **except**
  /// local echoes the snapshot does not cover yet. Dropping those was a real
  /// hole: a reconnect landing between "prompt accepted" and "durable event
  /// appended" made the message the user just sent vanish.
  void applySnapshot(Iterable<SessionEvent> events) {
    final pending = items.whereType<PendingUserBubble>().toList(growable: false);
    clear();
    for (final event in events) {
      _append(event);
    }
    for (final item in pending) {
      if (!_hasUserBubble(text: item.text, rpcId: item.requestId)) {
        items.add(item);
      }
    }
  }

  /// Appends one live event, ignoring replays.
  void applyEvent(SessionEvent event) {
    if (event.seq > 0 && event.seq <= _maxSeq) return;
    _append(event);
  }

  /// Accumulates a streamed assistant text delta.
  void applyStreamDelta(String? delta) {
    if (delta == null || delta.isEmpty) return;
    streamingText += delta;
  }

  /// Called when the committed message supersedes the streamed text.
  void clearStreaming() => streamingText = '';

  /// Removes the local echo a durable `user/message` has superseded.
  ///
  /// By `rpcId` when the event carries one — exact, and two turns that happen to
  /// contain the same words stay separate. Text is the fallback only for an event
  /// that has no id at all (an older harness), matched FIFO so two identical
  /// messages still reconcile one echo each.
  void _removePendingUser(String text, String rpcId) {
    var index = -1;
    if (rpcId.isNotEmpty) {
      index = items.indexWhere(
        (item) => item is PendingUserBubble && item.requestId == rpcId,
      );
    } else if (text.isNotEmpty) {
      index = items.indexWhere(
        (item) => item is PendingUserBubble && item.text == text,
      );
    }
    if (index >= 0) items.removeAt(index);
  }

  /// Whether the durable log already accounts for this text/request.
  bool _hasUserBubble({required String text, String rpcId = ''}) {
    for (final item in items) {
      if (item is! UserBubble) continue;
      if (rpcId.isNotEmpty && item.rpcId == rpcId) return true;
      if (item.text == text) return true;
    }
    return false;
  }

  void _append(SessionEvent event) {
    if (event.seq > _maxSeq) _maxSeq = event.seq;

    switch (event.type) {
      case 'user/message':
        final source = asMap(event.data['source']);
        final kind = asString(source['kind']);
        final summary = asString(source['summary']);
        final rpcId = asString(source['rpcId']);
        final text = contentText(event.data['content']).trim();
        // A notice may carry only a summary, so fall back to it before giving up.
        var body = text.isNotEmpty ? text : summary;

        if (!isHumanUserSourceKind(kind)) {
          if (body.isEmpty) return;
          // Injected context, not the human's turn. It never reconciles a local
          // echo: an `agent-message` can arrive between the prompt and its own
          // durable event.
          items.add(
            ContextNotice(
              seq: event.seq,
              text: body,
              sourceKind: kind,
              summary: summary,
              senderId: asString(source['senderSessionId']),
            ),
          );
          return;
        }

        // A turn carrying only an image or a file flattens to no text at all.
        if (body.isEmpty) {
          final counts = countAttachments(event.data['content']);
          body = attachmentPlaceholder(images: counts.images, files: counts.files);
        }
        // Reconcile first, even when nothing will be rendered: an attachment-only
        // turn still supersedes the echo that announced it.
        _removePendingUser(text, rpcId);
        if (body.isEmpty) return;
        items.add(UserBubble(seq: event.seq, text: body, rpcId: rpcId));
      case 'assistant/message':
        clearStreaming();
        final message = asMap(event.data['message']);
        _appendAssistantBlocks(event.seq, message['content'], event.data['interrupted'] == true);
      case 'developer/message':
      case 'system/message':
        final text = contentText(event.data['content']);
        if (text.trim().isNotEmpty) {
          items.add(SystemNote(seq: event.seq, text: text.trim()));
        }
      case 'tool/call':
        final callId = asString(event.data['callId']);
        final name = asString(event.data['name']);
        final questions = name == kAskUserQuestionTool
            ? parseToolQuestions(event.data['arguments'])
            : null;
        if (callId.isNotEmpty) _toolCallIndex[callId] = items.length;
        if (questions != null) {
          items.add(QuestionCard(seq: event.seq, callId: callId, questions: questions));
        } else {
          items.add(
            ToolCall(
              seq: event.seq,
              callId: callId,
              name: name,
              arguments: _prettyArguments(event.data['arguments']),
            ),
          );
        }
      case 'tool/result':
        _appendToolResult(event);
      case 'deliverables/presented':
        final files = parseDeliverables(event.data);
        if (files.isEmpty) return;
        items.add(
          DeliverablesCard(
            seq: event.seq,
            turn: asInt(event.data['turn']),
            files: files,
          ),
        );
      case 'turn/end':
        _appendTurnEnd(event);
      default:
        return;
    }
  }

  void _appendAssistantBlocks(int seq, Object? content, bool interrupted) {
    if (content is! List) {
      final text = contentText(content);
      if (text.trim().isNotEmpty) {
        items.add(AssistantBubble(seq: seq, text: text.trim(), interrupted: interrupted));
      }
      return;
    }

    // Group consecutive blocks of the same kind so a message that interleaves
    // reasoning and text renders as alternating sections rather than confetti.
    final buffer = StringBuffer();
    String? currentKind;

    void flush() {
      final text = buffer.toString().trim();
      buffer.clear();
      if (text.isEmpty) return;
      if (currentKind == 'reasoning') {
        items.add(ReasoningNote(seq: seq, text: text));
      } else {
        items.add(AssistantBubble(seq: seq, text: text, interrupted: interrupted));
      }
    }

    for (final block in content) {
      final map = asMap(block);
      final type = asString(map['type']);
      if (type != 'text' && type != 'reasoning') continue;
      final text = map['text'];
      if (text is! String || text.isEmpty) continue;
      if (currentKind != null && currentKind != type) flush();
      currentKind = type;
      buffer.write(text);
    }
    flush();
  }

  void _appendToolResult(SessionEvent event) {
    final message = asMap(event.data['message']);
    final callId = _resultCallId(event.data, message);
    final text = contentText(message['content']).trim();
    final isError = event.data['error'] != null;

    final index = callId.isEmpty ? null : _toolCallIndex[callId];
    if (index != null && index < items.length) {
      final existing = items[index];
      // A question card keeps its questions and gains the recorded answers, so
      // it can show what was chosen after the fact.
      if (existing is QuestionCard) {
        final answers = parseAnswersFromResult(event.data);
        if (answers != null) items[index] = existing.withAnswers(answers);
        return;
      }
      if (existing is ToolCall) {
        items[index] = existing.withResult(text: text, isError: isError);
        return;
      }
    }

    // A result whose call we never saw (the snapshot window started after it).
    items.add(
      ToolCall(seq: event.seq, callId: callId, name: '', arguments: '', result: text, isError: isError),
    );
  }

  void _appendTurnEnd(SessionEvent event) {
    final reason = asMap(event.data['reason']);
    final kind = asString(reason['kind'], 'completed');
    clearStreaming();
    if (kind == 'completed' || kind.isEmpty) return;

    final label = switch (kind) {
      'aborted' => '已中止',
      'error' => '出错：${_errorText(reason)}',
      'blocked' => '被拦截',
      'max-tokens' => '达到输出上限',
      'interrupted' => '被打断',
      'forked' => '已分叉',
      _ => kind,
    };
    items.add(SystemNote(seq: event.seq, text: label));
  }

  static String _errorText(Map<String, dynamic> reason) {
    final error = asMap(reason['error']);
    return asString(error['message'], asString(error['code'], '未知错误'));
  }

  static String _resultCallId(Map<String, dynamic> data, Map<String, dynamic> message) {
    for (final candidate in [
      data['callId'],
      message['callId'],
      message['toolCallId'],
      asMap(message['meta'])['callId'],
    ]) {
      if (candidate is String && candidate.isNotEmpty) return candidate;
    }
    return '';
  }

  /// Tool arguments arrive as a JSON string; pretty-print when possible.
  static String _prettyArguments(Object? raw) {
    if (raw is! String || raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } on FormatException {
      return raw;
    }
  }
}
