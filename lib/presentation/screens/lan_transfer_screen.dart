import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr/qr.dart';

import '../../application/vault_controller.dart';
import '../../application/vault_import.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/qr_scanner.dart';
import '../../infrastructure/storage/encrypted_vault_file.dart';
import '../../infrastructure/sync/lan_transfer.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../widgets/hint.dart';
import '../widgets/secret_content.dart';
import '../widgets/vault_import_dialog.dart';

/// 发送方：出二维码，等对方扫。
///
/// 服务只在这页真显示着的时候监听：离开页面、App 退到后台、到期都关端口。二维码里有密钥，整页防截屏（R44）。
class LanSendScreen extends ConsumerStatefulWidget {
  const LanSendScreen({
    super.key,
    this.addresses = lanAddresses,
    this.validFor = lanTransferValidFor,
  });

  final Future<List<String>> Function() addresses;
  final Duration validFor;

  @override
  ConsumerState<LanSendScreen> createState() => _LanSendScreenState();
}

enum _SendPhase { preparing, waiting, delivered, stopped, noNetwork, failed }

class _LanSendScreenState extends ConsumerState<LanSendScreen>
    with WidgetsBindingObserver {
  var _phase = _SendPhase.preparing;
  LanTransferSender? _sender;
  Timer? _ticker;
  Object? _error;
  var _missing = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    unawaited(_sender?.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_sender?.close());
  }

  Future<void> _start() async {
    setState(() => _phase = _SendPhase.preparing);
    try {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      final addresses = await widget.addresses();
      if (!mounted) return;
      if (addresses.isEmpty) {
        setState(() => _phase = _SendPhase.noNetwork);
        return;
      }
      final sender = await LanTransferSender.start(
        EncryptedVaultFile.plainForTransfer(vault),
        addresses: addresses,
        validFor: widget.validFor,
      );
      if (!mounted) {
        await sender.close();
        return;
      }
      _missing = controller.repository.unreadableSecrets.length;
      _sender = sender;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() => _phase = _SendPhase.waiting);
      final outcome = await sender.outcome;
      _ticker?.cancel();
      if (!mounted) return;
      setState(() {
        _sender = null;
        _phase = outcome == LanSendOutcome.delivered
            ? _SendPhase.delivered
            : _SendPhase.stopped;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _phase = _SendPhase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SecretContent(
        child: Scaffold(
          appBar: AppBar(
            title: const HintTitle(
              '发到另一台手机',
              hint: '另一台在「从另一台手机接收」里扫这个码。内容含密码和私钥，扫到码就能解开，别给别人看。离开这页就作废。',
            ),
          ),
          body: SafeArea(child: Center(child: _body(context))),
        ),
      );

  Widget _body(BuildContext context) {
    final sender = _sender;
    switch (_phase) {
      case _SendPhase.preparing:
        return const CircularProgressIndicator();
      case _SendPhase.waiting:
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: LanQrCode(sender!.pairing.encode()),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _waitingText(sender.pairing.expiresAt),
                key: const ValueKey('lan-send-status'),
              ),
            ),
            if (_missing > 0) ...[
              const SizedBox(height: 8),
              Center(child: _missingNote()),
            ],
          ],
        );
      case _SendPhase.delivered:
        return _Outcome(
          icon: Icons.check_circle_outline,
          message: '已传完',
          extra: _missing > 0 ? _missingNote() : null,
        );
      case _SendPhase.stopped:
        return _Outcome(
          icon: Icons.timer_off_outlined,
          message: '二维码已失效',
          action: '重新生成',
          onAction: _start,
        );
      case _SendPhase.noNetwork:
        return _Outcome(
          icon: Icons.wifi_off_outlined,
          message: '没连局域网。连上 Wi-Fi 或打开手机热点再试。',
          action: '重试',
          onAction: _start,
        );
      case _SendPhase.failed:
        return _Outcome(
          icon: Icons.error_outline,
          message: _errorText(_error),
          action: '重试',
          onAction: _start,
        );
    }
  }

  String _waitingText(DateTime expiresAt) {
    final left = expiresAt.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : left.inSeconds;
    final time =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return localized('等对方扫码 · $time');
  }

  Widget _missingNote() {
    final missing = _missing;
    return LText('$missing 条凭据解不开，没有带上');
  }

  String _errorText(Object? error) {
    final message = error is SocketException ? error.message : '$error';
    return localized('没开成：$message');
  }
}

/// 二维码。不管主题都是白底黑块、带留白：深色主题下反色或没留白，很多摄像头识别不了。
class LanQrCode extends StatelessWidget {
  const LanQrCode(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    return Semantics(
      label: localized('互传二维码'),
      image: true,
      child: ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: AspectRatio(
            aspectRatio: 1,
            child: CustomPaint(painter: _QrPainter(image)),
          ),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    final cell = size.width / count;
    // 关掉抗锯齿：相邻的黑块之间不出现灰缝。
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var column = 0; column < count; column++) {
        if (image.isDark(row, column)) {
          canvas.drawRect(
            Rect.fromLTWH(column * cell, row * cell, cell, cell),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.icon,
    required this.message,
    this.extra,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final Widget? extra;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            LText(message, textAlign: TextAlign.center),
            if (extra != null) ...[const SizedBox(height: 8), extra!],
            if (action != null) ...[
              const SizedBox(height: 16),
              ShunButton(
                key: const ValueKey('lan-outcome-action'),
                label: action!,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      );
}

Future<List<int>> _receive(LanPairing pairing) => receiveLanTransfer(pairing);

/// 接收方：打开就扫码，拿到内容走和从文件恢复一样的确认框。
class LanReceiveScreen extends ConsumerStatefulWidget {
  const LanReceiveScreen({
    super.key,
    this.vpnUp = vpnInterfaceUp,
    this.receive = _receive,
  });

  final Future<bool> Function() vpnUp;
  final Future<List<int>> Function(LanPairing pairing) receive;

  @override
  ConsumerState<LanReceiveScreen> createState() => _LanReceiveScreenState();
}

class _LanReceiveScreenState extends ConsumerState<LanReceiveScreen> {
  String? _failure;
  String? _done;
  var _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _finish({String? failure, String? done}) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failure = failure;
      _done = done;
    });
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _failure = null;
      _done = null;
    });
    final String? text;
    try {
      text = await ref
          .read(qrScannerProvider)
          .scan(prompt: localized('扫对方手机上的二维码'));
    } on QrScanDenied {
      _finish(failure: '没有相机权限。到系统设置里给 shun 打开相机再试。');
      return;
    } on Exception {
      _finish(failure: '打不开扫码页，再试一次。');
      return;
    }
    if (!mounted) return;
    if (text == null) {
      Navigator.of(context).pop();
      return;
    }
    final pairing = LanPairing.tryParse(text);
    if (pairing == null) {
      _finish(failure: '不是 shun 的互传二维码');
      return;
    }
    try {
      final vault = _decode(await widget.receive(pairing));
      await _import(vault);
    } on LanTransferUnreachable {
      _finish(failure: await _unreachableText(pairing));
    } on LanTransferWrongPeer {
      _finish(failure: '对方不是出这个二维码的手机，让对方重新生成再扫。');
    } on LanTransferDamaged {
      _finish(failure: '收到的内容校验没过，重新扫码再试。');
    } on Exception catch (error) {
      _finish(failure: '$error');
    }
  }

  /// 内容已经过了 GCM 校验，这里还解不出来，只能是对方版本写的格式不对。
  VaultData _decode(List<int> plain) {
    try {
      return VaultData.fromJson(
        jsonDecode(utf8.decode(plain)) as Map<String, dynamic>,
      );
    } on FormatException {
      throw const LanTransferDamaged();
    } on TypeError {
      throw const LanTransferDamaged();
    }
  }

  Future<void> _import(VaultData vault) async {
    final controller = ref.read(vaultControllerProvider.notifier);
    final shown = planVaultImport(vault, await controller.ready());
    if (!mounted) return;
    final mode = await confirmVaultImport(context, shown);
    if (!mounted) return;
    if (mode == null) {
      Navigator.of(context).pop();
      return;
    }
    final plan = await controller.importVault(shown, mode);
    _finish(done: vaultImportSummary(plan, mode));
  }

  /// 最常见的原因排前面：过期最确定；VPN 在就先怀疑 VPN（所有者的手机就是这样，见 docs/21 F23c）。
  Future<String> _unreachableText(LanPairing pairing) async {
    if (DateTime.now().isAfter(pairing.expiresAt)) {
      return '二维码已过期，让对方重新生成。';
    }
    if (await widget.vpnUp()) {
      return '连不上对方。这台手机开着 VPN，局域网连接可能被导进了 VPN，先关掉再试。';
    }
    return '连不上对方。两台手机要连同一个 Wi-Fi，路由器开了 AP 隔离就改用手机热点。';
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final done = _done;
    return Scaffold(
      appBar: AppBar(title: const LText('从另一台手机接收')),
      body: SafeArea(
        child: Center(
          child: _busy
              ? const CircularProgressIndicator()
              : failure != null
                  ? _Outcome(
                      icon: Icons.error_outline,
                      message: failure,
                      action: '重新扫码',
                      onAction: _run,
                    )
                  : _Outcome(
                      icon: Icons.check_circle_outline,
                      message: done ?? '',
                    ),
        ),
      ),
    );
  }
}
