import 'package:flutter/material.dart';

import '../../../../core/database/collections/text_block.dart';
import '../../domain/models/tools.dart';
import '../canvas/text_layer_controller.dart';

/// XNota-style text block editor: a bottom sheet with the content field,
/// font-size presets, ink swatches, a sticky-note toggle (with its palette)
/// and (for existing blocks) delete.
///
///  • NEW blocks: [editing] null, [createAt] required — Save inserts with
///    the text tool's current defaults ([defaultSize], [defaultColor]);
///    [stickyDefault]/[stickyColorDefault] pre-armed the sticky toggle when
///    the text tool's "sticky mode" chip is active.
///  • EXISTING blocks: [editing] required — Save updates, Delete removes.
///
/// Text edits persist immediately (their own lifecycle — text blocks are
/// intentionally not part of the ink undo stack this iteration).
Future<void> showTextBlockEditorSheet(
  BuildContext context, {
  required TextLayerController controller,
  TextBlock? editing,
  Offset? createAt,
  double defaultSize = 16,
  Color defaultColor = const Color(0xFF111827),
  bool stickyDefault = false,
  Color stickyColorDefault = const Color(0xFFFFF3A3),
}) {
  assert(editing != null || createAt != null,
      'Either an existing block or a creation anchor is required.');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final isEditing = editing != null;
      final contentController =
          TextEditingController(text: editing?.content ?? '');
      var fontSize = editing?.fontSize ?? defaultSize;
      var color = editing != null
          ? Color(editing.colorValue)
          : defaultColor;
      var sticky = editing != null
          ? editing.stickyColorValue != 0
          : stickyDefault;
      var stickyColor = editing != null && editing.stickyColorValue != 0
          ? Color(editing.stickyColorValue)
          : stickyColorDefault;

      return Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: 16 +
              MediaQuery.of(sheetContext)
                  .viewInsets
                  .bottom, // rises above the keyboard
        ),
        child: StatefulBuilder(
          builder: (sheetContext2, setSheetState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEditing
                      ? (sticky ? 'Edit sticky note' : 'Edit text')
                      : (sticky ? 'New sticky note' : 'New text'),
                  style: Theme.of(sheetContext2).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Type here…',
                  ),
                  style: TextStyle(color: color, fontSize: 18),
                ),
                const SizedBox(height: 16),
                Text('Size', style: Theme.of(sheetContext2).textTheme.labelLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final preset in const [12.0, 16.0, 22.0, 30.0])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _SizeChip(
                          label: preset.round().toString(),
                          selected: (fontSize - preset).abs() < 0.1,
                          onTap: () => setSheetState(() => fontSize = preset),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Color',
                    style: Theme.of(sheetContext2).textTheme.labelLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final swatch in kTextInkSwatches)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: _SheetSwatch(
                          color: swatch,
                          selected: swatch == color,
                          onTap: () => setSheetState(() => color = swatch),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  secondary: const Icon(Icons.sticky_note_2_outlined),
                  title: const Text('Sticky note'),
                  subtitle:
                      const Text('A colored swatch behind the text'),
                  value: sticky,
                  onChanged: (v) => setSheetState(() => sticky = v),
                ),
                if (sticky) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (final swatch in kStickySwatches)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _SheetSwatch(
                            color: swatch,
                            selected: swatch == stickyColor,
                            onTap: () =>
                                setSheetState(() => stickyColor = swatch),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext2).pop(),
                      child: const Text('Cancel'),
                    ),
                    if (isEditing) ...[
                      TextButton(
                        onPressed: () {
                          Navigator.of(sheetContext2).pop();
                          controller.removeBlock(editing!);
                        },
                        child: const Text('Delete'),
                      ),
                    ],
                    FilledButton(
                      onPressed: () {
                        final content = contentController.text.trim();
                        Navigator.of(sheetContext2).pop();
                        if (content.isEmpty) {
                          if (editing != null) controller.removeBlock(editing);
                          return; // never keep empty text boxes
                        }
                        final existing = editing;
                        if (existing != null) {
                          existing
                            ..content = content
                            ..fontSize = fontSize
                            ..colorValue = color.value
                            ..stickyColorValue = sticky ? stickyColor.value : 0;
                          controller.persistBlock(existing);
                        } else {
                          controller.createBlock(
                            createAt!,
                            content: content,
                            fontSize: fontSize,
                            colorValue: color.value,
                            stickyColorValue: sticky ? stickyColor.value : 0,
                          );
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      );
    },
  );
}

/// Text-tool swatches (XNota's text palette: near-black + basics).
const kTextInkSwatches = [
  Color(0xFF111827), // ink black
  Color(0xFF155EEF), // brand blue
  Color(0xFFDC2626), // red
  Color(0xFFD97706), // amber
  Color(0xFF16A34A), // green
];

class _SizeChip extends StatelessWidget {
  const _SizeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? scheme.primary : scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _SheetSwatch extends StatelessWidget {
  const _SheetSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 3 : 1.5,
          ),
        ),
      ),
    );
  }
}
