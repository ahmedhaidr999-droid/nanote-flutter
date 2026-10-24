import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/input_settings.dart';
import '../../domain/models/tools.dart';
import '../canvas/selection_controller.dart';
import 'editor_page_view.dart';

/// Pen swatches (brand blue kept — it IS the Nanote ink identity).
const kPenSwatches = [
  Color(0xFF111827), // ink black
  Color(0xFF155EEF), // brand blue
  Color(0xFFDC2626), // red
  Color(0xFFD97706), // amber
  Color(0xFF16A34A), // green
];

/// Highlighter swatches — multiply blending does the transparency work.
const kHighlighterSwatches = [
  Color(0xFFFDE047), // yellow
  Color(0xFF86EFAC), // green
  Color(0xFF7DD3FC), // sky
  Color(0xFFFDA4AF), // pink
  Color(0xFFE9D5FF), // lilac
];

/// The editor's bottom bar:
///
///     [page scrubber]     — when the document has > 1 page
///     [selection actions]  — swaps in while a lasso selection is active
///     [tools row]          — pen / highlighter / eraser / lasso + options
///
/// Hot state flows through AnimatedBuilder on the page's ChangeNotifiers
/// (never rebuilds this whole bar at 120Hz); cold tool state lives in the
/// toolPalette provider.
class EditorToolbar extends ConsumerWidget {
  const EditorToolbar({
    super.key,
    required this.controllers,
    required this.isPdf,
    required this.onFit,
    required this.onAddPage,
    required this.pageIndex,
    required this.pageCount,
    required this.onPageSelected,
  });

  /// Controllers of the CURRENTLY VISIBLE page (null while it hydrates).
  final PageControllers? controllers;
  final bool isPdf;
  final VoidCallback onFit;
  final VoidCallback? onAddPage;
  final int pageIndex;
  final int pageCount;
  final ValueChanged<int> onPageSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = controllers?.selection;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pageCount > 1)
          _PageScrubber(
            index: pageIndex,
            count: pageCount,
            onSelect: onPageSelected,
          ),
        Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        if (selection == null)
          _ToolsRow(
            selection: null,
            isPdf: isPdf,
            onFit: onFit,
            onAddPage: onAddPage,
          )
        else
          AnimatedBuilder(
            animation: selection,
            builder: (context, _) => selection.hasSelection
                ? _SelectionActions(selection: selection)
                : _ToolsRow(
                    selection: selection,
                    isPdf: isPdf,
                    onFit: onFit,
                    onAddPage: onAddPage,
                  ),
          ),
      ],
    );
  }
}

class _PageScrubber extends StatelessWidget {
  const _PageScrubber({
    required this.index,
    required this.count,
    required this.onSelect,
  });

  final int index;
  final int count;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous page',
            onPressed: index > 0 ? () => onSelect(index - 1) : null,
            icon: const Icon(Icons.expand_less),
          ),
          Expanded(
            child: Slider(
              value: index.clamp(0, count - 1).toDouble(),
              max: (count - 1).toDouble(),
              // Continuous past 60 pages — a slider is a scrubber, not a
              // precise input; precise jumps use the page number dialog.
              divisions: count > 60 ? null : count - 1,
              onChanged: (v) => onSelect(v.round()),
            ),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: index < count - 1 ? () => onSelect(index + 1) : null,
            icon: const Icon(Icons.expand_more),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              '${index + 1} / $count',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolsRow extends ConsumerWidget {
  const _ToolsRow({
    required this.selection,
    required this.isPdf,
    required this.onFit,
    required this.onAddPage,
  });

  final SelectionController? selection;
  final bool isPdf;
  final VoidCallback onFit;
  final VoidCallback? onAddPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(toolPaletteProvider);
    final toolNotifier = ref.read(toolPaletteProvider.notifier);
    final input = ref.watch(inputSettingsProvider);
    final inputNotifier = ref.read(inputSettingsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      // OverflowBar (not Row): on phones the buttons wrap to a second line
      // instead of overflowing; on tablets everything sits on one line.
      child: OverflowBar(
        alignment: MainAxisAlignment.start,
        overflowAlignment: OverflowBarAlignment.end,
        spacing: 4,
        children: [
          SegmentedButton<ToolType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ToolType.pen,
                  icon: Icon(Icons.edit_outlined),
                  tooltip: 'Pen',
                ),
                ButtonSegment(
                  value: ToolType.highlighter,
                  icon: Icon(Icons.highlight_alt_outlined),
                  tooltip: 'Highlighter',
                ),
                ButtonSegment(
                  value: ToolType.eraser,
                  icon: Icon(Icons.auto_fix_normal_outlined),
                  tooltip: 'Eraser',
                ),
                ButtonSegment(
                  value: ToolType.lasso,
                  // lasso_select* icons ship only in newer Flutter icon sets;
                  // polyline_outlined (3.22) is the freeform-loop stand-in.
                  icon: Icon(Icons.polyline_outlined),
                  tooltip: 'Lasso',
                ),
              ],
              selected: {tool.tool},
              onSelectionChanged: (s) {
                // Changing tools never keeps a stale selection.
                selection?.clear();
                toolNotifier.select(s.first);
              },
            ),
          _InkOptionsButton(tool: tool),
          IconButton(
            tooltip: 'Fit page',
            icon: const Icon(Icons.crop_free),
            onPressed: onFit,
          ),
          if (!isPdf)
            IconButton(
              tooltip: 'Add page',
              icon: const Icon(Icons.post_add_outlined),
              onPressed: onAddPage,
            ),
          IconButton(
            tooltip: input.allowFingerDrawing
                ? 'Finger draws — tap to make finger scroll'
                : 'Finger scrolls — tap to let finger draw',
            isSelected: input.allowFingerDrawing,
            icon: Icon(
              input.allowFingerDrawing
                  ? Icons.touch_app_outlined
                  : Icons.swipe_outlined,
            ),
            onPressed: () => inputNotifier
                .setAllowFingerDrawing(!input.allowFingerDrawing),
          ),
        ],
      ),
    );
  }
}

/// Current-color dot → opens the ink options sheet (colors / size / eraser
/// mode — contents depend on the active tool).
class _InkOptionsButton extends StatelessWidget {
  const _InkOptionsButton({required this.tool});

  final ToolPaletteState tool;

  @override
  Widget build(BuildContext context) {
    final isPen = tool.tool == ToolType.pen;
    final isHighlighter = tool.tool == ToolType.highlighter;
    final hasColor = isPen || isHighlighter;
    final color = isHighlighter ? tool.highlighterColor : tool.penColor;
    final active = tool.tool != ToolType.lasso;
    return IconButton(
      tooltip: 'Color & size',
      onPressed: active ? () => showInkOptionsSheet(context) : null,
      // Erasers have no ink color — only the palette hint disappears.
      icon: Icon(Icons.palette_outlined, color: hasColor ? color : null),
    );
  }
}

/// Recolor / delete / done — selection ops flow through the SAME undo stack
/// as any other edit (see SelectionController).
class _SelectionActions extends ConsumerWidget {
  const _SelectionActions({required this.selection});

  final SelectionController selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(toolPaletteProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowAlignment: OverflowBarAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.polyline_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text('Selection active',
                  style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          IconButton(
            tooltip: 'Recolor with pen color',
            icon: Icon(Icons.format_color_fill_outlined, color: tool.penColor),
            onPressed: () => selection.recolor(tool.penColor.value),
          ),
          IconButton(
            tooltip: 'Delete selection',
            icon: const Icon(Icons.delete_outline),
            onPressed: selection.deleteSelection,
          ),
          IconButton(
            tooltip: 'Deselect',
            icon: const Icon(Icons.close),
            onPressed: selection.clear,
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with the active tool's color swatches + size slider.
/// Erasers get mode + size; the lasso explains itself instead.
Future<void> showInkOptionsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _InkOptionsSheet(),
  );
}

class _InkOptionsSheet extends ConsumerWidget {
  const _InkOptionsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(toolPaletteProvider);
    final notifier = ref.read(toolPaletteProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            switch (tool.tool) {
              ToolType.pen => _buildColors(context, kPenSwatches,
                  tool.penColor, notifier.setPenColor),
              ToolType.highlighter => _buildColors(context,
                  kHighlighterSwatches, tool.highlighterColor,
                  notifier.setHighlighterColor),
              ToolType.eraser => _buildEraser(context, tool, notifier),
              ToolType.lasso => const ListTile(
                  leading: Icon(Icons.polyline_outlined),
                  title: Text('Draw a loop around your ink to select it'),
                  subtitle: Text(
                      'Move, resize, rotate, recolor or delete — selection '
                      'edits share the same undo history as everything else.'),
                ),
            },
            const SizedBox(height: 8),
            switch (tool.tool) {
              ToolType.pen => _buildSize(
                  context,
                  label: 'Pen size',
                  value: tool.penSize,
                  min: 0.5,
                  max: 8,
                  onChanged: notifier.setPenSize),
              ToolType.highlighter => _buildSize(
                  context,
                  label: 'Highlighter size',
                  value: tool.highlighterSize,
                  min: 6,
                  max: 30,
                  onChanged: notifier.setHighlighterSize),
              ToolType.eraser => _buildSize(
                  context,
                  label: 'Eraser size',
                  value: tool.eraserSize,
                  min: 8,
                  max: 80,
                  onChanged: notifier.setEraserSize),
              ToolType.lasso => const SizedBox.shrink(),
            },
          ],
        ),
      ),
    );
  }

  Widget _buildColors(
    BuildContext context,
    List<Color> swatches,
    Color current,
    ValueChanged<Color> onColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Color', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final c in swatches)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _Swatch(
                    color: c,
                    selected: c == current,
                    onTap: () => onColor(c),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSize(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            Text(value.toStringAsFixed(1),
                style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildEraser(
    BuildContext context,
    ToolPaletteState tool,
    ToolPalette notifier,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Eraser mode', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 10),
        SegmentedButton<EraserMode>(
          segments: const [
            ButtonSegment(
                value: EraserMode.stroke,
                icon: Icon(Icons.remove_road_outlined),
                label: Text('Stroke')),
            ButtonSegment(
                value: EraserMode.pixel,
                icon: Icon(Icons.grain_outlined),
                label: Text('Pixel')),
          ],
          selected: {tool.eraserMode},
          onSelectionChanged: (s) => notifier.setEraserMode(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          tool.eraserMode == EraserMode.pixel
              ? 'Pixel splits strokes where they cross the eraser — geometry, '
                  'pressure and z-order are preserved.'
              : 'Stroke erases whole strokes with one touch.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
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
    return AspectRatio(
      aspectRatio: 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2.5,
            ),
          ),
          alignment: Alignment.center,
          child: selected
              ? Icon(
                  Icons.check,
                  size: 18,
                  color: color.computeLuminance() > 0.5
                      ? Colors.black87
                      : Colors.white,
                )
              : null,
        ),
      ),
    );
  }
}
