import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/proxy_profiles.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'credential_field.dart';
import 'form_gap.dart';
import 'secret_content.dart';

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
  bool _saving = false;
  String? _error;

  /// 代理的账号密码：直接填，或者用「凭据」里的一个（F31）。选凭据时只记它的 ID，连接时展开。
  late LoginChoice _login;
  String? _credentialId;

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
    _credentialId = widget.profile?.data[proxyIdentityKey]?.toString();
    _login =
        _credentialId == null ? LoginChoice.simple : LoginChoice.credential;
  }

  @override
  void dispose() {
    for (final c in [_label, _host, _port, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _usesCredential => _login == LoginChoice.credential;

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _saving) return;
    if (_usesCredential && _credentialId == null) {
      setState(() => _error = '选一个凭据，或者改成用户名 / 密码。');
      return;
    }
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
      if (_usesCredential || _user.text.trim().isEmpty) {
        config.remove('username');
      }
      if (_usesCredential || _password.text.isEmpty) config.remove('password');
      final profile = ProxyProfile({
        ...?widget.profile?.data,
        'id': _id,
        'label': _label.text.trim(),
        'config': config,
      });
      if (_usesCredential) {
        profile.data[proxyIdentityKey] = _credentialId;
      } else {
        profile.data.remove(proxyIdentityKey);
      }
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

  // 整页防截屏（R44）：有代理口令。
  @override
  Widget build(BuildContext context) => SecretContent(child: _page(context));

  Widget _page(BuildContext context) => PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: ShunAppBar(
            title: LText(widget.profile == null ? '新建代理' : '编辑代理'),
            actions: [
              IconButton(
                  key: const ValueKey('proxy-save'),
                  tooltip: localized('保存'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, semanticsLabel: localized('处理中')))
                      : const Icon(Icons.check))
            ]),
        body: Form(
            key: _form,
            child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  ShunSectionItem(
                      padding: const EdgeInsets.all(8),
                      child: CredentialFields(
                          child: Column(children: [
                        TextFormField(
                            key: const ValueKey('proxy-label'),
                            controller: _label,
                            enabled: !_saving,
                            decoration: LInputDecoration(labelText: '代理名称'),
                            validator: (v) => v?.trim().isNotEmpty == true
                                ? null
                                : localized('必填')),
                        const FormGap(),
                        DropdownButtonFormField<ProxyType>(
                            initialValue: _type,
                            decoration: LInputDecoration(labelText: '代理类型'),
                            items: const [
                              DropdownMenuItem(
                                  value: ProxyType.socks5,
                                  child: Text('SOCKS5')),
                              DropdownMenuItem(
                                  value: ProxyType.http, child: Text('HTTP')),
                            ],
                            onChanged: _saving
                                ? null
                                : (v) => setState(() => _type = v)),
                        const FormGap(),
                        TextFormField(
                            key: const ValueKey('proxy-host'),
                            controller: _host,
                            enabled: !_saving,
                            autocorrect: false,
                            decoration: LInputDecoration(labelText: '代理地址')),
                        const FormGap(),
                        TextFormField(
                            key: const ValueKey('proxy-port'),
                            controller: _port,
                            enabled: !_saving,
                            keyboardType: TextInputType.number,
                            decoration: LInputDecoration(labelText: '代理端口')),
                      ]))),
                  const SizedBox(height: 8),
                  ShunSectionItem(
                      padding: const EdgeInsets.all(8),
                      child: CredentialFields(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            LoginChoiceField(
                                key: const ValueKey('proxy-login-choice'),
                                value: _login,
                                onChanged: (value) =>
                                    setState(() => _login = value)),
                            const FormGap(),
                            if (_usesCredential) ...[
                              CredentialField(
                                  key: const ValueKey('proxy-credential'),
                                  value: _credentialId,
                                  passwordOnly: true,
                                  onChanged: (id) => setState(() {
                                        _credentialId = id;
                                        _error = null;
                                      })),
                              const SizedBox(height: 6),
                              LText('明文发给代理',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ] else ...[
                              TextFormField(
                                  key: const ValueKey('proxy-username'),
                                  controller: _user,
                                  enabled: !_saving,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration:
                                      LInputDecoration(labelText: '代理用户名（可选）')),
                              const FormGap(),
                              // 切成明文时三个输入法开关也一直关着（ShunSecretField 保证，R44）。
                              ShunSecretField(
                                  key: const ValueKey('proxy-password'),
                                  controller: _password,
                                  enabled: !_saving,
                                  label: '代理密码（可选）',
                                  helperText: '明文发给代理'),
                            ],
                            if (_error != null)
                              LText(_error!,
                                  key: const ValueKey('proxy-error'),
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                          ]))),
                ])),
      ));
}
