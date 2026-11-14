import 'package:flutter/material.dart';
import 'package:shun/presentation/ui/components.dart';
import 'package:shun/presentation/ui/non_modal_panel.dart';
import 'package:shun/presentation/widgets/choice_segments.dart';
import 'package:shun/presentation/widgets/empty_state.dart';
import 'package:shun/presentation/widgets/form_gap.dart';
import 'package:shun/presentation/widgets/hint.dart';

/// R84 公共控件的一页图库：正常、禁用、处理中、校验失败、帮助各一份，
/// 外加打开非模态面板和普通模态确认的按钮。test/ui_components_test.dart 在它上面走行为，
/// test/ui_gallery_test.dart 用它出图。所有可操作的东西都有 key。
class ComponentGallery extends StatefulWidget {
  const ComponentGallery({super.key});

  @override
  State<ComponentGallery> createState() => ComponentGalleryState();
}

class ComponentGalleryState extends State<ComponentGallery> {
  final secret = TextEditingController(text: 'hunter2');
  final empty = TextEditingController();
  final disabled = TextEditingController(text: 'locked');

  /// 每个按钮、行被真点到的次数：断言用，不在界面上显示。
  final taps = <String, int>{};
  var busy = false;
  var address = 'ipv4';
  var notify = true;
  var highlight = false;
  Object? panelResult = 'unset';
  bool? confirmed;

  void count(String id) => setState(() => taps[id] = (taps[id] ?? 0) + 1);

  void setBusy(bool value) => setState(() => busy = value);

  @override
  void dispose() {
    secret.dispose();
    empty.dispose();
    disabled.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('公共控件')),
        body: ListView(
          key: const ValueKey('gallery-list'),
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ShunButton(
                  key: const ValueKey('gallery-save'),
                  label: '保存',
                  busy: busy,
                  onPressed: () => count('save'),
                ),
                ShunButton(
                  key: const ValueKey('gallery-busy'),
                  label: '测试连接',
                  kind: ShunButtonKind.tonal,
                  icon: Icons.network_check,
                  busy: true,
                  onPressed: () => count('busy'),
                ),
                const ShunButton(
                  key: ValueKey('gallery-disabled'),
                  label: '恢复',
                  kind: ShunButtonKind.outlined,
                  onPressed: null,
                ),
                ShunButton(
                  key: const ValueKey('gallery-text'),
                  label: '取消',
                  kind: ShunButtonKind.text,
                  onPressed: () => count('text'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ShunSecretField(
              key: const ValueKey('gallery-secret'),
              controller: secret,
              label: '密码',
              helperText: '已加密保存',
            ),
            const FormGap(),
            ShunSecretField(
              key: const ValueKey('gallery-secret-error'),
              controller: empty,
              label: 'API key',
              errorText: '必填',
            ),
            const FormGap(),
            ShunSecretField(
              key: const ValueKey('gallery-secret-disabled'),
              controller: disabled,
              label: '口令（可选）',
              enabled: false,
            ),
            const SizedBox(height: 24),
            ChoiceSegments<String>(
              segments: const [
                ChoiceSegment('ipv4', 'IPv4',
                    key: ValueKey('gallery-seg-ipv4')),
                ChoiceSegment('ipv6', 'IPv6',
                    key: ValueKey('gallery-seg-ipv6')),
                ChoiceSegment('fqdn', 'MagicDNS 名称',
                    key: ValueKey('gallery-seg-fqdn')),
              ],
              selected: address,
              onTap: (value) {
                count('seg-$value');
                setState(() => address = value);
              },
            ),
            const SizedBox(height: 16),
            Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  ShunListRow(
                    key: const ValueKey('gallery-row'),
                    title: '状态同步',
                    subtitle: '每 5 分钟',
                    leading: const Icon(Icons.sync),
                    onTap: () => count('row'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const HintButton(
                          title: '状态同步',
                          message: '后台定时读一次设备在线状态。',
                        ),
                        Switch(
                          key: const ValueKey('gallery-row-switch'),
                          value: notify,
                          onChanged: (value) => setState(() => notify = value),
                        ),
                      ],
                    ),
                  ),
                  ShunListRow(
                    key: const ValueKey('gallery-row-disabled'),
                    title: '云端同步',
                    subtitle: '未配置',
                    leading: const Icon(Icons.cloud_off),
                    enabled: false,
                    onTap: () => count('row-disabled'),
                  ),
                  HintSwitchTile(
                    title: '敏感页面允许截屏',
                    hint: '关着时截屏是黑的。',
                    value: notify,
                    onChanged: (value) => setState(() => notify = value),
                  ),
                ],
              ),
            ),
            ShunSection(
              key: const ValueKey('gallery-section'),
              title: '分组',
              hint: '设置页那种分组：首尾圆角，行间细线。',
              children: [
                ShunListRow(
                  key: const ValueKey('gallery-section-open'),
                  title: '代理管理',
                  leading: const Icon(Icons.public),
                  chevron: true,
                  onTap: () => count('section-open'),
                ),
                ShunSwitchRow(
                  key: const ValueKey('gallery-section-switch'),
                  title: '代码高亮',
                  hint: '打开文件时按语法上色。',
                  value: highlight,
                  onChanged: (value) => setState(() => highlight = value),
                ),
                ShunSwitchRow(
                  key: const ValueKey('gallery-section-switch-off'),
                  title: '系统安全键盘',
                  subtitle: '保存中',
                  value: false,
                  onChanged: null,
                ),
                const ShunSectionItem(
                  key: ValueKey('gallery-section-item'),
                  child: Text('自由内容'),
                ),
              ],
            ),
            // 列表里高度不受限：EmptyState 的 Center 按内容收缩，大字号也不溢出。
            const EmptyState(
              icon: Icons.dns_outlined,
              title: '还没有主机',
              action: ShunButton(
                key: ValueKey('gallery-empty-action'),
                label: '新建主机',
                onPressed: null,
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                Builder(
                  builder: (context) => ShunButton(
                    key: const ValueKey('gallery-open-panel'),
                    label: '打开面板',
                    kind: ShunButtonKind.tonal,
                    onPressed: () async {
                      final result = await showNonModalPanel<String>(
                        Scaffold.of(context),
                        builder: (_, close) => _Panel(onDone: close),
                      );
                      if (mounted) setState(() => panelResult = result);
                    },
                  ),
                ),
                ShunButton(
                  key: const ValueKey('gallery-background'),
                  label: '背后的按钮',
                  kind: ShunButtonKind.text,
                  onPressed: () => count('background'),
                ),
                ShunButton(
                  key: const ValueKey('gallery-confirm'),
                  label: '删除',
                  kind: ShunButtonKind.outlined,
                  onPressed: () async {
                    final value = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: const Text('删了不能撤销。'),
                        actions: [
                          TextButton(
                            key: const ValueKey('gallery-confirm-no'),
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                        ],
                      ),
                    );
                    if (mounted) setState(() => confirmed = value);
                  },
                ),
              ],
            ),
            // 面板开着时底部被它盖住：留出空，让背后的按钮仍在面板上方。
            const SizedBox(height: 360),
          ],
        ),
      );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.onDone});

  final ValueChanged<String?> onDone;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('面板', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              ShunButton(
                key: const ValueKey('gallery-panel-done'),
                label: '保存',
                onPressed: () => onDone('saved'),
              ),
            ],
          ),
        ),
      );
}
