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

/// The editor's floating tool pill (Notewise-style), overlaid on the canvas
/// by the editor screen:
///
///     [pen | highlighter | eraser | lasso] | [color] [fit] [+ page]
///
/// A lasso selection swaps the pill for a compact actions pill (recolor /
/// delete / deselect). Hot state flows through AnimatedBuilder on the page's
/// SelectionController (never rebuilds the pill at 120Hz); cold tool state
/// lives in the toolPalette provider.
class EditorToolbar extends ConsumerWidget {
  const EditorToolbar({
    super.key,
    required this.controllers,
    required this.isPdf,
    required this.onFit,
    this.onAddPage,
  });

  /// Controllers of the CURRENTLY VISIBLE page (null while it hydrates).
  final PageControllers? controllers;
  final bool isPdf;
  final VoidCallback onFit;
  final VoidCallback? onAddPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = controllers?.selection;
    final Widget pill;
    if (selection == null) {
      pill = _ToolsPill(
        selection: null,
        isPdf: isPdf,
        onFit: onFit,
        onAddPage: onAddPage,
      );
    } else {
      pill = AnimatedBuilder(
        animation: selection,
        builder: (context, _) => selection.hasSelection
            ? _SelectionPill(selection: selection)
            : _ToolsPill(
                selection: selection,
                isPdf: isPdf,
                onFit: onFit,
                onAddPage: onAddPage,
              ),
      );
    }
    // Scale down (never up) on narrow phones instead of clipping.
    return FittedBox(fit: BoxFit.scaleDown, child: pill);
  }
}

// ── Pill chrome ──────────────────────────────────────────────────────────────

/// Shared pill visual: elevated rounded container with a soft shadow.
class _PillShell extends StatelessWidget {
  const _PillShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: scheme.outlineVariant.withOpacity(0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.45 : 0.18),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 26,
      color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.7),
    );
  }
}

// ── Tools pill ──────────────────────────────────────────────────────────────

class _ToolsPill extends ConsumerWidget {
  const _ToolsPill({
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

    return _PillShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in ToolType.values) ...[
              _ToolChip(
                icon: switch (t) {
                  ToolType.pen => Icons.edit_outlined,
                  ToolType.highlighter => Icons.highlight_alt_outlined,
                  ToolType.eraser => Icons.auto_fix_normal_outlined,
                  // lasso_select* ships only in newer Flutter icon sets;
                  // polyline_outlined (3.22) is the freeform-loop stand-in.
                  ToolType.lasso => Icons.polyline_outlined,
                },
                label: switch (t) {
                  ToolType.pen => 'Pen',
                  ToolType.highlighter => 'Highlighter',
                  ToolType.eraser => 'Eraser',
                  ToolType.lasso => 'Lasso',
                },
                selected: tool.tool == t,
                onTap: () {
                  // Changing tools never keeps a stale selection.
                  selection?.clear();
                  toolNotifier.select(t);
                },
              ),
              const SizedBox(width: 2),
            ],
            const SizedBox(width: 6),
            const _PillDivider(),
            const SizedBox(width: 6),
            if (tool.tool == ToolType.pen ||
                tool.tool == ToolType.highlighter) ...[
              _ColorDotButton(tool: tool),
              const SizedBox(width: 2),
            ],
            _PillIconButton(
              tooltip: 'Fit page',
              icon: Icons.crop_free,
              onTap: onFit,
            ),
            if (!isPdf)
              _PillIconButton(
                tooltip: 'Add page',
                icon: Icons.post_add_outlined,
                onTap: onAddPage,
              ),
          ],
        ),
      ),
    );
  }
}

/// A single 48×48 touch-friendly tool chip — selected tools fill with the
/// theme's primary color (Notewise's filled-circle affordance).
class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? scheme.primary
                  : scheme.surfaceContainerHighest.withOpacity(0.4),
            ),
            child: Icon(
              icon,
              size: 22,
              color: selected
                  ? scheme.onPrimary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact circular icon button for pill utilities (fit / add page / …).
class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.tooltip,
    required this.icon,
    this.onTap,
    this.iconColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              icon,
              size: 22,
              color: iconColor ??
                  (onTap == null
                      ? scheme.onSurfaceVariant.withOpacity(0.38)
                      : scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// Current-color dot — opens the ink options sheet (colors / size / touch).
class _ColorDotButton extends StatelessWidget {
  const _ColorDotButton({required this.tool});

  final ToolPaletteState tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tool.tool == ToolType.highlighter
        ? tool.highlighterColor
        : tool.penColor;
    return Tooltip(
      message: 'Color & size',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showInkOptionsSheet(context),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.outlineVariant,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Selection pill ───────────────────────────────────────────────────────────

/// Recolor / delete / done — selection ops flow through the SAME undo stack
/// as any other edit (see SelectionController).
class _SelectionPill extends ConsumerWidget {
  const _SelectionPill({required this.selection});

  final SelectionController selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tool = ref.watch(toolPaletteProvider);
    return _PillShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.polyline_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              'Selection',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            const _PillDivider(),
            const SizedBox(width: 12),
            _PillIconButton(
              tooltip: 'Recolor with pen color',
              icon: Icons.format_color_fill_outlined,
              iconColor: tool.penColor,
              onTap: () => selection.recolor(tool.penColor.value),
            ),
            _PillIconButton(
              tooltip: 'Delete selection',
              icon: Icons.delete_outline,
              onTap: selection.deleteSelection,
            ),
            _PillIconButton(
              tooltip: 'Deselect',
              icon: Icons.close,
              onTap: selection.clear,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Ink options sheet ───────────────────────────────────────────────────────

/// Bottom sheet with the active tool's color swatches + size slider, plus
/// touch settings (finger drawing / palm rejection). Erasers get mode + size;
/// the lasso explains itself instead.
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
    final input = ref.watch(inputSettingsProvider);
    final inputNotifier = ref.read(inputSettingsProvider.notifier);

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
            const SizedBox(height: 20),
            Text('Touch', style: Theme.of(context).textTheme.labelLarge),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.touch_app_outlined),
              title: const Text('Draw with finger'),
              subtitle: const Text(
                  'A single finger inks instead of navigating pages.'),
              value: input.allowFingerDrawing,
              onChanged: inputNotifier.setAllowFingerDrawing,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.pan_tool_outlined),
              title: const Text('Palm rejection'),
              subtitle: const Text(
                  'Ignore stray touches while the stylus is in range and '
                  'large palm contacts.'),
              value: input.palmRejection,
              onChanged: inputNotifier.setPalmRejection,
            ),
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
