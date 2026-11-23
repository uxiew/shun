part of 'settings_screen.dart';

class _ThemePicker extends StatefulWidget {
  const _ThemePicker({
    required this.brightness,
    required this.selectedId,
  });

  final Brightness brightness;
  final String selectedId;

  @override
  State<_ThemePicker> createState() => _ThemePickerState();
}

class _ThemePickerState extends State<_ThemePicker> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final themes = ShunTheme.presets(widget.brightness)
        .where(
          (theme) =>
              query.isEmpty ||
              theme.name.toLowerCase().contains(query.toLowerCase()) ||
              theme.id.contains(query.toLowerCase()),
        )
        .toList(growable: false);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(
                  widget.brightness == Brightness.dark ? '选择深色主题' : '选择浅色主题',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const FormGap(),
                TextField(
                  autofocus: false,
                  decoration: LInputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索 62 种主题',
                  ),
                  onChanged: (value) => setState(() => query = value.trim()),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 210,
                mainAxisExtent: 88,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: themes.length,
              itemBuilder: (context, index) {
                final theme = themes[index];
                final selected = theme.id == widget.selectedId;
                return Semantics(
                  button: true,
                  selected: selected,
                  child: Material(
                    // 选中那张叠一层主色：当前主题的卡片色和面板底色一样，不叠就看不出块。
                    color: selected
                        ? Color.alphaBlend(
                            theme.primary.withValues(alpha: 0.16), theme.card)
                        : theme.card,
                    shape: prism.AppShape.md,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.pop(context, theme.id),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              decoration: ShapeDecoration(
                                color: theme.primary,
                                shape: prism.AppShape.full,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: LText(
                                theme.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.foreground,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (selected)
                              Icon(Icons.check_circle, color: theme.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
