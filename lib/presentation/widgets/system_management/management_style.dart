import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../localization/localized_widgets.dart';
import '../empty_state.dart';

Color managementFill(BuildContext context) => prism.SurfaceContext(context)
    .raisedSurfaceLevel
    .colorOf(prism.Theme.of(context).colorScheme);

class ManagementFieldDecoration extends LInputDecoration {
  static const _idle =
      ShapedInputBorder(shape: prism.AppShape.md, borderSide: BorderSide.none);

  ManagementFieldDecoration(
    BuildContext context, {
    bool inDialog = false,
    super.hintText,
    super.labelText,
    super.prefixIcon,
    super.suffixIcon,
    super.isDense,
    super.helperText,
    super.helperMaxLines,
    super.errorText,
  }) : super(
          filled: true,
          fillColor:
              inDialog ? _dialogFieldFill(context) : managementFill(context),
          border: _idle,
          enabledBorder: _idle,
          disabledBorder: _idle,
          focusedBorder: _idle.copyWith(
            borderSide: BorderSide(
                color: Theme.of(context).colorScheme.primary, width: 2),
          ),
        );

  static Color _dialogFieldFill(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return prism.SurfaceLevel.floatingOf(colors).next.colorOf(colors);
  }
}

class ManagementTabStyle extends StatelessWidget {
  const ManagementTabStyle({super.key, required this.child});
  final TabBar child;

  @override
  Widget build(BuildContext context) => TabBarTheme(
        data: TabBarTheme.of(context).copyWith(
          dividerHeight: 0,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: ShapeDecoration(
            shape: prism.AppShape.full,
            color: managementFill(context),
          ),
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: child,
      );
}

class ManagementEmptyState extends StatelessWidget {
  const ManagementEmptyState(
      {super.key, required this.icon, required this.title, this.action});
  final IconData icon;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          child: EmptyState(icon: icon, title: title, action: action),
        ),
      );
}
