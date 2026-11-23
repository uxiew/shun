import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shun/presentation/localization/localized_widgets.dart';

import 'management_style.dart';

class ManagementFilterChip extends StatelessWidget {
  const ManagementFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
        label: LText(label),
        selected: selected,
        shape: prism.AppShape.full,
        side: BorderSide.none,
        backgroundColor: managementFill(context),
        selectedColor: Theme.of(context).colorScheme.primaryContainer,
        labelStyle: TextStyle(
            color: selected
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : Theme.of(context).colorScheme.onSurfaceVariant),
        showCheckmark: false,
        onSelected: (_) => onSelected(),
      );
}
