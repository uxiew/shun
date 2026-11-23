import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/security_key.dart';
import '../../infrastructure/ssh/security_key_channel.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'credential_field.dart' show CredentialFields;
import 'secret_content.dart';

final securityKeyChannelProvider = Provider((ref) => SecurityKeyChannel());

/// 等用户把钥匙贴上来（或插上）最多等多久。超时后当作没等到，连接报错停下。
const securityKeyWait = Duration(seconds: 60);

/// 连接时让钥匙签名：弹框写明登录哪台机器，用户在钥匙上确认。
///
/// 没有页面可弹时（[context] 为 null）报 [SecurityKeyNeedsUser]，不会静默走别的路。
Future<SecurityKeyAssertion> signWithSecurityKey(
  BuildContext? context,
  SecurityKeyChannel channel,
  SecurityKeySignRequest request,
) async {
  if (context == null || !context.mounted) throw const SecurityKeyNeedsUser();
  final key = request.key;
  final hash = await Sha256().hash(request.data);
  final clientDataHash = Uint8List.fromList(hash.bytes);
  if (!context.mounted) throw const SecurityKeyNeedsUser();
  return showSecurityKeyPrompt<SecurityKeyAssertion>(
    context,
    channel,
    title: '安全密钥登录',
    detail: '${request.username}@${request.hostLabel}',
    pinFirst: key.userVerificationRequired,
    // resident 密钥可能设了「没 PIN 就当它不存在」，而从钥匙读出来时看不到这个设置。
    pinOnNoCredential: key.flags & skFlagResident != 0,
    abort: request.cancelled,
    run: (pin) => channel.sign(
      application: key.application,
      clientDataHash: clientDataHash,
      keyHandle: key.keyHandle,
      userPresence: key.userPresenceRequired,
      pin: pin,
    ),
  );
}

/// 一个等钥匙的对话框，执行 [run] 一次或几次（每次 PIN 都是用户自己填的）。
///
/// 失败或取消时抛 [SecurityKeyException]。PIN 错了留在框里让用户决定要不要再试：错到一定次数钥匙就锁了，
/// 所以这里绝不拿同一个 PIN 重试。PIN 只在这个框里用，不存、不带出去。
Future<T> showSecurityKeyPrompt<T extends Object>(
  BuildContext context,
  SecurityKeyChannel channel, {
  required String title,
  String? detail,
  required Future<T> Function(String? pin) run,
  bool pinFirst = false,
  bool pinOnNoCredential = false,
  Future<void>? abort,
  Duration wait = securityKeyWait,
}) async {
  final outcome = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (context) => SecurityKeyPrompt<T>(
      channel: channel,
      title: title,
      detail: detail,
      run: run,
      pinFirst: pinFirst,
      pinOnNoCredential: pinOnNoCredential,
      abort: abort,
      wait: wait,
    ),
  );
  return switch (outcome) {
    final T value => value,
    final SecurityKeyException error => throw error,
    // 对话框被别的东西关掉（比如页面没了）按取消算。
    _ => throw const SecurityKeyException(SecurityKeyFailure.cancelled),
  };
}

class SecurityKeyPrompt<T extends Object> extends StatefulWidget {
  const SecurityKeyPrompt({
    super.key,
    required this.channel,
    required this.title,
    this.detail,
    required this.run,
    this.pinFirst = false,
    this.pinOnNoCredential = false,
    this.abort,
    this.wait = securityKeyWait,
  });

  final SecurityKeyChannel channel;
  final String title;
  final String? detail;
  final Future<T> Function(String? pin) run;
  final bool pinFirst;
  final bool pinOnNoCredential;

  /// 完成时当作用户点了取消：连接已经没了，框不用再等人。
  final Future<void>? abort;
  final Duration wait;

  @override
  State<SecurityKeyPrompt<T>> createState() => _SecurityKeyPromptState<T>();
}

class _SecurityKeyPromptState<T extends Object>
    extends State<SecurityKeyPrompt<T>> {
  final _pin = TextEditingController();
  StreamSubscription<SecurityKeyStage>? _stages;
  Timer? _deadline;
  SecurityKeyStage _stage = SecurityKeyStage.waitingForKey;
  SecurityKeyAvailability? _availability;

  /// 现在在等 PIN（没有正在进行的操作）。
  var _askingPin = false;
  String? _pinNote;
  var _triedPin = false;
  var _timedOut = false;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    _stages = widget.channel.stages.listen((stage) {
      if (mounted) setState(() => _stage = stage);
    });
    unawaited(_loadAvailability());
    unawaited(widget.abort?.then((_) => _cancel()));
    if (widget.pinFirst) {
      _askingPin = true;
    } else {
      unawaited(_start(null));
    }
  }

  Future<void> _loadAvailability() async {
    final value = await widget.channel.availability();
    if (mounted) setState(() => _availability = value);
  }

  @override
  void dispose() {
    _deadline?.cancel();
    unawaited(_stages?.cancel());
    _pin.dispose();
    super.dispose();
  }

  Future<void> _start(String? pin) async {
    _triedPin = pin != null;
    // 新的一轮要重新贴钥匙。
    _stage = SecurityKeyStage.waitingForKey;
    _deadline = Timer(widget.wait, () {
      _timedOut = true;
      unawaited(widget.channel.cancel());
    });
    try {
      final value = await widget.run(pin);
      _close(value);
    } on SecurityKeyException catch (error) {
      _onFailure(error);
    } finally {
      _deadline?.cancel();
    }
  }

  void _onFailure(SecurityKeyException error) {
    if (_timedOut && error.failure == SecurityKeyFailure.cancelled) {
      _close(const SecurityKeyException(SecurityKeyFailure.timeout));
      return;
    }
    final String? note = switch (error.failure) {
      SecurityKeyFailure.pinRequired => '这把钥匙要 PIN',
      SecurityKeyFailure.pinInvalid => '$error',
      SecurityKeyFailure.noCredential
          when widget.pinOnNoCredential && !_triedPin =>
        '这把钥匙可能要 PIN',
      _ => null,
    };
    if (note == null) {
      _close(error);
      return;
    }
    if (!mounted) return;
    setState(() {
      _askingPin = true;
      _pinNote = note;
      _pin.clear();
    });
  }

  void _close(Object outcome) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(outcome);
  }

  void _submitPin() {
    final pin = _pin.text;
    // CTAP2 规定 PIN 至少 4 位：短了一定是错的，别白白消耗一次机会。
    if (pin.length < 4) {
      setState(() => _pinNote = 'PIN 至少 4 位');
      return;
    }
    setState(() {
      _askingPin = false;
      _pinNote = null;
    });
    _pin.clear();
    unawaited(_start(pin));
  }

  void _cancel() {
    unawaited(widget.channel.cancel());
    _close(const SecurityKeyException(SecurityKeyFailure.cancelled));
  }

  String _status() {
    final available = _availability;
    return switch (_stage) {
      SecurityKeyStage.waitingForKey =>
        available != null && available.nfc && !available.nfcEnabled
            ? '插上钥匙。NFC 没打开，要用先到系统设置里开'
            : '把钥匙贴到手机背面，或插到 USB 口',
      SecurityKeyStage.communicating => '正在通信，别拿开',
      SecurityKeyStage.waitingForTouch => '碰一下钥匙',
    };
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: SecretContent(
        child: AlertDialog(
          title: LText(widget.title),
          scrollable: true,
          content: CredentialFields(
              inDialog: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.detail != null) ...[
                    Text(widget.detail!, style: small),
                    const SizedBox(height: 12),
                  ],
                  if (_askingPin) ...[
                    if (_pinNote != null) ...[
                      LText(
                        _pinNote!,
                        key: const ValueKey('security-key-pin-note'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      key: const ValueKey('security-key-pin'),
                      controller: _pin,
                      autofocus: true,
                      obscureText: true,
                      keyboardType: TextInputType.visiblePassword,
                      enableIMEPersonalizedLearning: false,
                      enableSuggestions: false,
                      autocorrect: false,
                      onSubmitted: (_) => _submitPin(),
                      decoration: LInputDecoration(labelText: '钥匙的 PIN'),
                    ),
                  ] else
                    ShunSectionItem(
                        child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: LText(
                            _status(),
                            key: const ValueKey('security-key-status'),
                          ),
                        ),
                      ],
                    )),
                ],
              )),
          actions: [
            ShunButton(
              key: const ValueKey('security-key-cancel'),
              kind: ShunButtonKind.text,
              onPressed: _cancel,
              label: '取消',
            ),
            if (_askingPin)
              ShunButton(
                key: const ValueKey('security-key-pin-submit'),
                onPressed: _submitPin,
                label: '继续',
              ),
          ],
        ),
      ),
    );
  }
}
