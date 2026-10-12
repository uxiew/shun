import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/proxy_profiles.dart';
import '../localization/localized_widgets.dart';

/// Edits one saved profile. Inline conversion creates a new profile and returns
/// its ID; only the calling, unsaved host draft switches to that reference.
class ProxyProfileEditor extends ConsumerStatefulWidget {
  const ProxyProfileEditor({super.key, this.profile, this.inlineConfig});
  final ProxyProfile? profile;
  final Map<String, dynamic>? inlineConfig;

  @override
  ConsumerState<ProxyProfileEditor> createState() => _ProxyProfileEditorState();
}

class _ProxyProfileEditorState extends ConsumerState<ProxyProfileEditor> {
  final _form = GlobalKey<FormState>();
  late final String _id;
  late final TextEditingController _label, _host, _port, _user, _password;
  late ProxyType? _type;
  bool _saving = false, _obscure = true;
  String? _error;

  Map<String, dynamic> get _originalConfig {
    final value = widget.profile?.data['config'] ?? widget.inlineConfig;
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  @override
  void initState() {
    super.initState();
    _id = widget.profile?.id ?? const Uuid().v4();
    final config = ProxyConfig.fromJson(_originalConfig);
    _type = widget.profile == null && widget.inlineConfig == null
        ? ProxyType.socks5
        : config.type;
    _label = TextEditingController(text: widget.profile?.label);
    _host = TextEditingController(text: config.host);
    _port =
        TextEditingController(text: config.port == 0 ? '' : '${config.port}');
    _user = TextEditingController(text: config.username);
    _password = TextEditingController(text: config.password);
  }

  @override
  void dispose() {
    for (final c in [_label, _host, _port, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final config = {
        ..._originalConfig,
        ...ProxyConfig(
                type: _type,
                host: _host.text.trim(),
                port: int.tryParse(_port.text.trim()) ?? 0,
                username: _user.text.trim(),
                password: _password.text)
            .toJson()
      };
      if (_user.text.trim().isEmpty) config.remove('username');
      if (_password.text.isEmpty) config.remove('password');
      final profile = ProxyProfile({
        ...?widget.profile?.data,
        'id': _id,
        'label': _label.text.trim(),
        'config': config,
      });
      await ref
          .read(vaultControllerProvider.notifier)
          .saveProxyProfile(profile, expected: widget.profile);
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.pop(context, profile.id);
    } on RouteConfigException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ProxyProfileChanged catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (_) {
      if (mounted) setState(() => _error = '代理保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
            title: LText(widget.profile == null ? '新建代理' : '编辑代理'),
            actions: [
              TextButton(
                  key: const ValueKey('proxy-save'),
                  onPressed: _saving ? null : _save,
                  child: const LText('保存'))
            ]),
        body: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const LText('修改后，引用此代理的主机下次连接使用新配置；已连接的会话不变。'),
              TextFormField(
                  key: const ValueKey('proxy-label'),
                  controller: _label,
                  enabled: !_saving,
                  decoration: LInputDecoration(labelText: '代理名称'),
                  validator: (v) =>
                      v?.trim().isNotEmpty == true ? null : localized('必填')),
              const SizedBox(height: 12),
              DropdownButtonFormField<ProxyType>(
                  initialValue: _type,
                  decoration: LInputDecoration(labelText: '代理类型'),
                  items: const [
                    DropdownMenuItem(
                        value: ProxyType.socks5, child: Text('SOCKS5')),
                    DropdownMenuItem(
                        value: ProxyType.http, child: Text('HTTP')),
                  ],
                  onChanged: _saving ? null : (v) => setState(() => _type = v)),
              TextFormField(
                  key: const ValueKey('proxy-host'),
                  controller: _host,
                  enabled: !_saving,
                  autocorrect: false,
                  decoration: LInputDecoration(labelText: '代理地址')),
              TextFormField(
                  key: const ValueKey('proxy-port'),
                  controller: _port,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  decoration: LInputDecoration(labelText: '代理端口')),
              TextFormField(
                  controller: _user,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: LInputDecoration(labelText: '代理用户名（可选）')),
              TextFormField(
                  controller: _password,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: _obscure,
                  decoration: LInputDecoration(
                      labelText: '代理密码（可选）',
                      suffixIcon: IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          tooltip: localized('显示或隐藏密码'),
                          icon: Icon(_obscure
                              ? Icons.visibility
                              : Icons.visibility_off)))),
              const SizedBox(height: 12),
              const LText('代理的用户名和密码是明文发给代理的：SSH 只加密之后的终端会话，保护不了这段口令。'),
              if (_error != null)
                LText(_error!,
                    key: const ValueKey('proxy-error'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ])),
      ));
}
