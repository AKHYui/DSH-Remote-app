/// Model display and selection.
///
/// `session.selectModel` is a separate call from `session.prompt` (the prompt
/// has no model argument), and the session's current choice arrives with
/// `session.list` under `projections.modelSelection` — so nothing here needs an
/// extra round trip just to show what is selected.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme.dart';

/// The composer pill showing the session's model and opening the picker.
///
/// Two details exist to fit a real model name into a phone-width composer row:
///
///   * **No leading glyph.** The sparkle icon cost ~21dp of a row that also has to
///     hold `DeepSeek V4 Flash Vision (exp)` (190.7dp in a real font). The muted
///     pill and the chevron already read as a dropdown, so the glyph was the
///     cheapest thing to give up.
///   * **[FittedBox] around the label.** `scaleDown` means a name that is still too
///     long shrinks slightly instead of being cut mid-word: an ellipsis on a model
///     name (`DeepSeek V4 Flash Visi…`) says nothing, while 95% type is readable.
class ModelChip extends StatelessWidget {
  const ModelChip({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppColors.surfaceMuted,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (busy)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the catalog and returns the chosen selection, or null if dismissed.
Future<ModelSelection?> showModelPicker(
  BuildContext context, {
  required ModelCatalog catalog,
  ModelSelection? current,
}) {
  return showModalBottomSheet<ModelSelection>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ModelPickerSheet(catalog: catalog, current: current),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({required this.catalog, this.current});

  final ModelCatalog catalog;
  final ModelSelection? current;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _matches(ModelInfo info) {
    final needle = _filter.text.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return info.name.toLowerCase().contains(needle) ||
        info.id.toLowerCase().contains(needle);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = widget.catalog.groups
        .map((group) => ModelGroup(
              id: group.id,
              name: group.name,
              models: group.models.where(_matches).toList(growable: false),
            ))
        .where((group) => group.models.isNotEmpty)
        .toList(growable: false);

    return SizedBox(
      // Tall enough to be useful, short enough to keep the list obviously
      // scrollable behind the phone's own keyboard.
      height: MediaQuery.of(context).size.height * 0.78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceMutedStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppGap.page, 0, AppGap.page, 10),
            child: Row(
              children: [
                Text('选择模型', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (widget.current != null)
                  Text(
                    '当前 ${widget.current!.shortName}',
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppGap.page, 0, AppGap.page, 10),
            child: TextField(
              controller: _filter,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索模型…',
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
          ),
          Expanded(
            child: groups.isEmpty
                ? Center(child: Text('没有匹配的模型', style: theme.textTheme.bodySmall))
                : ListView(
                    padding: const EdgeInsets.only(bottom: AppGap.loose),
                    children: [
                      for (final group in groups) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppGap.page,
                            10,
                            AppGap.page,
                            4,
                          ),
                          child: Text(
                            group.name,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ),
                        for (final info in group.models)
                          _ModelRow(
                            info: info,
                            selected: widget.current != null &&
                                widget.current!.provider == group.id &&
                                widget.current!.model == info.id,
                            onTap: () => Navigator.of(context).pop(
                              ModelSelection(provider: group.id, model: info.id),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.info, required this.selected, required this.onTap});

  final ModelInfo info;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.timeline),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.timeline),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: selected ? AppColors.accentText : AppColors.textPrimary,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (info.name != info.id)
                        Text(
                          info.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall,
                        ),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_rounded, size: 18, color: AppColors.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
