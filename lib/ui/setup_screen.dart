/// Onboarding: point the app at a relay and obtain a device token.
///
/// Two paths, because the relay deliberately has no self-service signup:
///
///   * pairing — the app asks for a code, the operator approves it on the server
///     with `python -m app.cli pair-approve <code>`, then the app claims it;
///   * paste a token — for a token minted straight from the CLI.
///
/// Layout rule learned the hard way: **the outcome of a tap must land on screen
/// without scrolling.** The first version put its result box at the bottom of a
/// scrolling list, so a failed request looked like a dead button — and because
/// `_makeClient()` was called outside the `try`, a throw there left the button
/// permanently disabled, which looked exactly the same. Both are fixed by
/// [FeedbackCard] sitting directly under the buttons and by running every action
/// through [_run].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/relay_client.dart';
import '../api/tls.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../theme.dart';
import 'error_text.dart';

enum _Tone { info, good, bad }

/// The result of the last action, shown where it cannot be missed.
class _Feedback {
  const _Feedback(this.tone, this.message, {this.code, this.deviceName});

  final _Tone tone;
  final String message;

  /// A pairing code to display prominently, when there is one.
  final String? code;

  /// The device name the code was requested with, so the approval command uses
  /// the name the user actually typed instead of a hard-coded one.
  final String? deviceName;
}

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _urlController = TextEditingController(text: 'https://39.100.70.90:58443');
  final _nameController = TextEditingController(text: 'my phone');
  final _codeController = TextEditingController();
  final _tokenController = TextEditingController();

  _Feedback? _feedback;
  bool _busy = false;
  bool _showToken = false;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _codeController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  String get _baseUrl => RelaySettings.normaliseBaseUrl(_urlController.text);

  void _say(_Feedback feedback, {bool announce = true}) {
    if (!mounted) return;
    setState(() => _feedback = feedback);
    if (announce) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(feedback.message.split('\n').first)));
    }
  }

  /// Runs one action with the client, guaranteeing that the button is usable
  /// again and that whatever went wrong is on screen.
  ///
  /// The client is created *inside* the guarded region on purpose: building it
  /// loads the bundled CA, which can throw, and the earlier version let that
  /// exception escape while `_busy` stayed true.
  Future<void> _run(
    Future<void> Function(RelayClient client) body, {
    String token = '',
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    RelayClient? client;
    try {
      client = await _makeClient(token: token);
      await body(client);
    } on Object catch (error) {
      _say(_Feedback(_Tone.bad, _explain(error)));
    } finally {
      client?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<RelayClient> _makeClient({String token = ''}) async {
    final http = await buildRelayHttpClient();
    return RelayClient(baseUrl: _baseUrl, token: token, httpClient: http);
  }

  Future<void> _probe() => _run((client) async {
        _say(_Feedback(_Tone.info, '正在连接 $_baseUrl …'), announce: false);
        try {
          final health = await client.health();
          _say(_Feedback(
            _Tone.good,
            '中继可达：v${health.version}，协议 v${health.protocol}，'
                '${health.devicesOnline} 台桌面在线',
          ));
        } on Object catch (error) {
          _say(_Feedback(_Tone.bad, _explain(error)));
        }
      });

  Future<void> _requestCode() => _run((client) async {
        final name = _nameController.text.trim().isEmpty
            ? 'my phone'
            : _nameController.text.trim();
        _say(const _Feedback(_Tone.info, '正在向中继索取配对码…'), announce: false);
        try {
          final value = await client.pairStart(name);
          final code = (value['code'] ?? '').toString();
          if (code.isEmpty) {
            _say(const _Feedback(_Tone.bad, '中继没有返回配对码。'));
            return;
          }
          final ttl = value['ttlSeconds'] ?? 300;
          _codeController.text = code;
          _say(
            _Feedback(
              _Tone.good,
              '配对码有效期 $ttl 秒。请在中继服务器上执行下面这条命令批准它，'
                  '然后再点「兑换令牌」。',
              code: code,
              deviceName: name,
            ),
          );
        } on Object catch (error) {
          _say(_Feedback(_Tone.bad, _explain(error)));
        }
      });

  Future<void> _claim() => _run((client) async {
        final code = _codeController.text.trim();
        if (code.isEmpty) {
          _say(const _Feedback(_Tone.bad, '请先获取配对码。'));
          return;
        }
        _say(const _Feedback(_Tone.info, '正在兑换令牌…'), announce: false);
        try {
          final value = await client.pairClaim(code);
          final token = (value['deviceToken'] ?? '').toString();
          if (token.isEmpty) {
            _say(const _Feedback(_Tone.bad, '中继没有返回令牌。'));
            return;
          }
          await _finish(token);
        } on Object catch (error) {
          _say(_Feedback(
            _Tone.bad,
            '${_explain(error)}\n'
                '（配对码必须先由管理员在服务器上批准，之后才能兑换。）',
          ));
        }
      });

  Future<void> _usePastedToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      _say(const _Feedback(_Tone.bad, '请粘贴一个设备令牌。'));
      return;
    }
    // A client carrying the pasted token, so the request itself proves it works
    // before anything is stored.
    await _run((client) async {
      try {
        await client.devices();
        await _finish(token);
      } on Object catch (error) {
        _say(_Feedback(_Tone.bad, _explain(error)));
      }
    }, token: token);
  }

  Future<void> _finish(String token) async {
    final controller = ref.read(settingsProvider.notifier);
    await controller.setRelay(baseUrl: _baseUrl, deviceName: _nameController.text);
    await controller.setToken(token);
    _say(const _Feedback(_Tone.good, '完成，正在进入…'));
  }

  /// Delegates to the shared mapper so the wording is unit tested; see
  /// `ui/error_text.dart`.
  String _explain(Object error) => explainRelayError(error, baseUrl: _baseUrl);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('连接到中继')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppGap.page, 8, AppGap.page, AppGap.loose),
        children: [
          Text('这台手机上还没有凭据。', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '本 App 直接连你自己部署的中继，令牌只存在手机的 Keystore 里。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppGap.loose),

          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '中继地址',
              helperText: '例如 39.100.70.90:58443 —— 会规范化为 https://',
            ),
          ),
          const SizedBox(height: AppGap.base),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '设备名称',
              helperText: '会显示在中继的设备列表里',
            ),
          ),
          const SizedBox(height: AppGap.base),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _probe,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _requestCode,
                  icon: const Icon(Icons.qr_code_2, size: 18),
                  label: const Text('获取配对码'),
                ),
              ),
            ],
          ),

          // Directly under the buttons, so the outcome of a tap can never be
          // below the fold.
          const SizedBox(height: AppGap.base),
          if (_busy) const _WorkingBar(),
          if (_feedback != null) ...[
            if (_busy) const SizedBox(height: AppGap.base),
            _FeedbackCard(feedback: _feedback!),
          ],
          const SizedBox(height: AppGap.loose),
          const Divider(),
          const SizedBox(height: AppGap.base),

          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: '6 位配对码',
              counterText: '',
            ),
          ),
          const SizedBox(height: AppGap.base),
          OutlinedButton.icon(
            onPressed: _busy ? null : _claim,
            icon: const Icon(Icons.link, size: 18),
            label: const Text('兑换令牌'),
          ),

          const SizedBox(height: AppGap.loose),
          TextButton.icon(
            onPressed: () => setState(() => _showToken = !_showToken),
            icon: Icon(_showToken ? Icons.expand_less : Icons.expand_more, size: 18),
            label: const Text('我已经有令牌，直接粘贴'),
          ),
          if (_showToken) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _tokenController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '设备令牌'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _usePastedToken,
              icon: const Icon(Icons.login, size: 18),
              label: const Text('验证并保存'),
            ),
          ],
        ],
      ),
    );
  }
}

/// A thin indeterminate bar shown while an action runs, next to the buttons.
class _WorkingBar extends StatelessWidget {
  const _WorkingBar();

  @override
  Widget build(BuildContext context) {
    return const ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(2)),
      child: LinearProgressIndicator(minHeight: 3),
    );
  }
}

/// The result of the last action: colour-coded, and impossible to mistake for
/// the previous state.
class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.feedback});

  final _Feedback feedback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color background, Color accent, IconData icon) = switch (feedback.tone) {
      _Tone.good => (AppColors.accentSoft, AppColors.accentText, Icons.check_circle_outline),
      _Tone.bad => (AppColors.dangerSoft, AppColors.danger, Icons.error_outline),
      _Tone.info => (AppColors.surfaceMuted, AppColors.textSecondary, Icons.hourglass_empty),
    };

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      padding: const EdgeInsets.all(AppGap.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  feedback.message,
                  style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          if (feedback.code != null) ...[
            const SizedBox(height: AppGap.base),
            Center(
              child: SelectableText(
                feedback.code!,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontSize: 34,
                  letterSpacing: 6,
                  color: accent,
                ),
              ),
            ),
            const SizedBox(height: AppGap.base),
            _CommandRow(code: feedback.code!, deviceName: feedback.deviceName ?? 'my phone'),
          ],
        ],
      ),
    );
  }
}

/// The exact command the operator has to run, with a copy button — this string
/// is the whole point of the pairing flow, and retyping it is error-prone.
class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.code, required this.deviceName});

  final String code;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final command =
        'cd /opt/dsh-backend && .venv/bin/python -m app.cli pair-approve $code --name "$deviceName"';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.timeline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.45),
            ),
          ),
          IconButton(
            tooltip: '复制命令',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.copy_rounded, color: AppColors.textSecondary),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(content: Text('命令已复制')));
            },
          ),
        ],
      ),
    );
  }
}
