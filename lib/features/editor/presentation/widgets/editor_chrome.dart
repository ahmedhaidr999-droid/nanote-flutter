import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/input_settings.dart';
import '../../domain/models/shape_tool.dart';
import '../../domain/models/tools.dart';
import '../canvas/ink_controller.dart';
import '../canvas/selection_controller.dart';
import 'editor_page_view.dart';

// ─────────────────────────────────────────────────────────────────────────
// Notewise chrome palette — the editor chrome is ALWAYS dark charcoal
// (matching the reference app), regardless of the app theme brightness.
// ─────────────────────────────────────────────────────────────────────────

const kChromePillColor = Color(0xFF22252E);
const kChromePillBorder = Color(0x1FFFFFFF);
const kChromeIconColor = Color(0xFFE6E8EE);
const kChromeIconDisabledColor = Color(0x55E6E8EE);
const kChromeActiveColor = Color(0xFF155EEF); // Nanote brand blue
const kChromeDividerColor = Color(0x24FFFFFF);
const kChromeShadow = BoxShadow(
  color: Color(0x52000000),
  blurRadius: 22,
  offset: Offset(0, 7),
);

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

/// Extended palette for the custom-color sheet ("+" chip).
const kExtendedSwatches = [
  Color(0xFF111827), Color(0xFF374151), Color(0xFF6B7280), Color(0xFF9CA3AF),
  Color(0xFFE5E7EB), Color(0xFFFFFFFF),
  Color(0xFFDC2626), Color(0xFFB91C1C), Color(0xFFF97316), Color(0xFFFBBF24),
  Color(0xFFFDE047), Color(0xFFA3E635),
  Color(0xFF16A34A), Color(0xFF0D9488), Color(0xFF06B6D4), Color(0xFF7DD3FC),
  Color(0xFF155EEF), Color(0xFF2563EB), Color(0xFF4F46E5), Color(0xFF8B5CF6),
  Color(0xFFA855F7), Color(0xFFD946EF), Color(0xFFEC4899), Color(0xFFF43F5E),
];

// ─────────────────────────────────────────────────────────────────────────
// Chrome shells
// ─────────────────────────────────────────────────────────────────────────

class _PillShell extends StatelessWidget {
  const _PillShell({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: kChromePillColor,
        borderRadius: BorderRadius.all(Radius.circular(26)),
        border: Border.fromBorderSide(BorderSide(color: kChromePillBorder)),
        boxShadow: [kChromeShadow],
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: child,
      ),
    );
  }
}

class _ChromeDivider extends StatelessWidget {
  const _ChromeDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: kChromeDividerColor,
    );
  }
}

/// A chrome icon button: 46×46 touch target, blue-circle fill when active.
class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.iconColor,
    this.child,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool enabled;
  final Color? iconColor;
  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? kChromeIconDisabledColor
        : (iconColor ?? kChromeIconColor);
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? kChromeActiveColor : Colors.transparent,
            ),
            child: child ??
                Icon(icon, size: 23, color: selected ? Colors.white : color),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Editor top chrome — nav pill (left) · tool pill (center) · eye (right)
// ─────────────────────────────────────────────────────────────────────────

/// The whole floating top area of the editor (Notewise layout):
///
///     [◀][grid][+]        [undo][redo] | [hand][lasso][pen][hi][eraser][shape][text] [⌃]        [eye]
///                          [ context pill: sizes · colors · + ]
class EditorTopChrome extends ConsumerStatefulWidget {
  const EditorTopChrome({
    super.key,
    required this.controllers,
    required this.onBack,
    required this.onThumbnails,
    this.onAddPage,
    required this.onToggleReadMode,
    required this.onOpenSettings,
  });

  /// Controllers of the CURRENTLY VISIBLE page (null while hydrating).
  final PageControllers? controllers;
  final VoidCallback onBack;
  final VoidCallback onThumbnails;
  final VoidCallback? onAddPage;
  final VoidCallback onToggleReadMode;
  final VoidCallback onOpenSettings;

  @override
  ConsumerState<EditorTopChrome> createState() => _EditorTopChromeState();
}

class _EditorTopChromeState extends ConsumerState<EditorTopChrome> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final tool = ref.watch(toolPaletteProvider);
    final selection = widget.controllers?.selection;

    // A live lasso selection swaps the tool pill for the actions pill.
    final Widget centerPill;
    if (selection != null) {
      centerPill = AnimatedBuilder(
        animation: selection,
        builder: (context, _) => selection.hasSelection
            ? _SelectionPill(selection: selection)
            : _buildToolPill(tool),
      );
    } else {
      centerPill = _buildToolPill(tool);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Left navigation pill ────────────────────────────────────
            _PillShell(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ChromeButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Back to library',
                    selected: false,
                    onTap: widget.onBack,
                  ),
                  _ChromeButton(
                    icon: Icons.grid_view_outlined,
                    tooltip: 'Page thumbnails',
                    selected: false,
                    onTap: widget.onThumbnails,
                  ),
                  if (widget.onAddPage != null)
                    _ChromeButton(
                      icon: Icons.post_add_outlined,
                      tooltip: 'Add page',
                      selected: false,
                      onTap: widget.onAddPage,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // ── Center tool pill (scales down, never clips) ─────────────
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: centerPill,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // ── Read mode eye ───────────────────────────────────────────
            _PillShell(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ChromeButton(
                    icon: Icons.visibility_outlined,
                    tooltip: 'Read mode (hide tools)',
                    selected: false,
                    onTap: widget.onToggleReadMode,
                  ),
                  _ChromeButton(
                    icon: Icons.more_horiz,
                    tooltip: 'Input & touch settings',
                    selected: false,
                    onTap: widget.onOpenSettings,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!_collapsed) ...[
          const SizedBox(height: 8),
          _ContextPill(tool: tool),
        ],
      ],
    );
  }

  Widget _buildToolPill(ToolPaletteState tool) {
    final notifier = ref.read(toolPaletteProvider.notifier);
    return _PillShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Undo/redo — live from the CURRENT page's ink controller.
          _UndoRedo(ink: widget.controllers?.ink),
          const _ChromeDivider(),
          for (final t in const [
            ToolType.hand,
            ToolType.lasso,
            ToolType.pen,
            ToolType.highlighter,
            ToolType.eraser,
            ToolType.shape,
            ToolType.text,
          ])
            _ChromeButton(
              icon: switch (t) {
                ToolType.hand => Icons.pan_tool_outlined,
                ToolType.lasso => Icons.polyline_outlined,
                ToolType.pen => Icons.edit_outlined,
                ToolType.highlighter => Icons.highlight_alt_outlined,
                ToolType.eraser => Icons.auto_fix_normal_outlined,
                ToolType.shape => Icons.category_outlined,
                ToolType.text => Icons.title,
              },
              tooltip: switch (t) {
                ToolType.hand => 'Hand (pan)',
                ToolType.lasso => 'Lasso',
                ToolType.pen => 'Pen',
                ToolType.highlighter => 'Highlighter',
                ToolType.eraser => 'Eraser',
                ToolType.shape => 'Shapes',
                ToolType.text => 'Text',
              },
              selected: tool.tool == t,
              onTap: () {
                widget.controllers?.selection.clear();
                notifier.select(t);
              },
            ),
          const _ChromeDivider(),
          _ChromeButton(
            icon: _collapsed
                ? Icons.keyboard_arrow_down
                : Icons.keyboard_arrow_up,
            tooltip: _collapsed ? 'Expand toolbar' : 'Collapse toolbar',
            selected: false,
            onTap: () => setState(() => _collapsed = !_collapsed),
          ),
        ],
      ),
    );
  }
}

class _UndoRedo extends StatelessWidget {
  const _UndoRedo({this.ink});

  final InkController? ink;

  @override
  Widget build(BuildContext context) {
    final controller = ink;
    if (controller == null) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChromeButton(
            icon: Icons.undo,
            tooltip: 'Undo',
            selected: false,
            enabled: false,
            onTap: null,
          ),
          _ChromeButton(
            icon: Icons.redo,
            tooltip: 'Redo',
            selected: false,
            enabled: false,
            onTap: null,
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChromeButton(
            icon: Icons.undo,
            tooltip: 'Undo',
            selected: false,
            enabled: controller.canUndo,
            onTap: controller.undo,
          ),
          _ChromeButton(
            icon: Icons.redo,
            tooltip: 'Redo',
            selected: false,
            enabled: controller.canRedo,
            onTap: controller.redo,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Contextual sub-pill (Notewise's second toolbar row)
// ─────────────────────────────────────────────────────────────────────────

class _ContextPill extends ConsumerWidget {
  const _ContextPill({required this.tool});

  final ToolPaletteState tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (tool.tool) {
      case ToolType.pen:
        return _InkContext(
          sizes: kPenSizePresets,
          size: tool.penSize,
          onSize: (s) => ref.read(toolPaletteProvider.notifier).setPenSize(s),
          swatches: kPenSwatches,
          color: tool.penColor,
          onColor: (c) =>
              ref.read(toolPaletteProvider.notifier).setPenColor(c),
        );
      case ToolType.highlighter:
        return _InkContext(
          sizes: kHighlighterSizePresets,
          size: tool.highlighterSize,
          onSize: (s) => ref
              .read(toolPaletteProvider.notifier)
              .setHighlighterSize(s),
          swatches: kHighlighterSwatches,
          color: tool.highlighterColor,
          onColor: (c) => ref
              .read(toolPaletteProvider.notifier)
              .setHighlighterColor(c),
        );
      case ToolType.eraser:
        return _EraserContext(tool: tool);
      case ToolType.shape:
        return _ShapeContext(tool: tool);
      case ToolType.text:
        return _TextContext(tool: tool);
      case ToolType.hand:
      case ToolType.lasso:
        return const SizedBox.shrink();
    }
  }
}

/// Shared row for ink-like tools: thickness presets · color swatches · "+".
class _InkContext extends ConsumerWidget {
  const _InkContext({
    required this.sizes,
    required this.size,
    required this.onSize,
    required this.swatches,
    required this.color,
    required this.onColor,
  });

  final List<double> sizes;
  final double size;
  final ValueChanged<double> onSize;
  final List<Color> swatches;
  final Color color;
  final ValueChanged<Color> onColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _PillShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in sizes)
            _ThicknessChip(
              thickness: s,
              selected: (size - s).abs() < 0.05,
              onTap: () => onSize(s),
            ),
          const _ChromeDivider(),
          for (final c in swatches)
            _SwatchChip(
              color: c,
              selected: c == color,
              onTap: () => onColor(c),
            ),
          _SwatchPlusChip(
              current: color,
              onPick: (c) => onColor(c)),
        ],
      ),
    );
  }
}

class _EraserContext extends ConsumerWidget {
  const _EraserContext({required this.tool});

  final ToolPaletteState tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(toolPaletteProvider.notifier);
    return _PillShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChromeButton(
            icon: Icons.remove_road_outlined,
            tooltip: 'Stroke eraser',
            selected: tool.eraserMode == EraserMode.stroke,
            onTap: () => notifier.setEraserMode(EraserMode.stroke),
          ),
          _ChromeButton(
            icon: Icons.grain_outlined,
            tooltip: 'Pixel eraser',
            selected: tool.eraserMode == EraserMode.pixel,
            onTap: () => notifier.setEraserMode(EraserMode.pixel),
          ),
          const _ChromeDivider(),
          for (final s in kEraserSizePresets)
            _SizeDotChip(
              diameter: s,
              selected: (tool.eraserSize - s).abs() < 0.05,
              onTap: () => notifier.setEraserSize(s),
            ),
        ],
      ),
    );
  }
}

class _ShapeContext extends ConsumerWidget {
  const _ShapeContext({required this.tool});

  final ToolPaletteState tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(toolPaletteProvider.notifier);
    return _PillShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in const [
            ShapeType.line,
            ShapeType.arrow,
            ShapeType.rectangle,
            ShapeType.ellipse,
            ShapeType.triangle,
          ])
            _ChromeButton(
              icon: switch (s) {
                ShapeType.line => Icons.horizontal_rule,
                ShapeType.arrow => Icons.north_east,
                ShapeType.rectangle => Icons.crop_square,
                ShapeType.ellipse => Icons.trip_origin,
                ShapeType.triangle => Icons.change_history_outlined,
              },
              tooltip: switch (s) {
                ShapeType.line => 'Line',
                ShapeType.arrow => 'Arrow',
                ShapeType.rectangle => 'Rectangle',
                ShapeType.ellipse => 'Ellipse',
                ShapeType.triangle => 'Triangle',
              },
              selected: tool.shapeType == s,
              onTap: () => notifier.setShapeType(s),
            ),
          const _ChromeDivider(),
          for (final s in kShapeSizePresets)
            _ThicknessChip(
              thickness: s,
              selected: (tool.shapeSize - s).abs() < 0.05,
              onTap: () => notifier.setShapeSize(s),
            ),
          const _ChromeDivider(),
          for (final c in kPenSwatches)
            _SwatchChip(
              color: c,
              selected: c == tool.penColor,
              onTap: () => notifier.setPenColor(c),
            ),
          _SwatchPlusChip(
            current: tool.penColor,
            onPick: (c) => notifier.setPenColor(c),
          ),
        ],
      ),
    );
  }
}

class _TextContext extends ConsumerWidget {
  const _TextContext({required this.tool});

  final ToolPaletteState tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(toolPaletteProvider.notifier);
    return _PillShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in kTextSizePresets)
            _ThicknessChip(
              thickness: s / 2.2, // visual weight proportional to font size
              selected: (tool.textSize - s).abs() < 0.05,
              onTap: () => notifier.setTextSize(s),
            ),
          const _ChromeDivider(),
          for (final c in kPenSwatches)
            _SwatchChip(
              color: c,
              selected: c == tool.textColor,
              onTap: () => notifier.setTextColor(c),
            ),
          _SwatchPlusChip(
            current: tool.textColor,
            onPick: (c) => notifier.setTextColor(c),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Chips
// ─────────────────────────────────────────────────────────────────────────

/// Line-weight chip: a horizontal bar whose thickness encodes the preset.
class _ThicknessChip extends StatelessWidget {
  const _ThicknessChip({
    required this.thickness,
    required this.selected,
    required this.onTap,
  });

  final double thickness;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: thickness.toStringAsFixed(1),
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? kChromeActiveColor.withOpacity(0.22)
                  : Colors.transparent,
            ),
            child: Container(
              width: 22,
              height: thickness.clamp(1.2, 10.0),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF9EC0FF) : kChromeIconColor,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Eraser size chip: a dot whose diameter encodes the preset.
class _SizeDotChip extends StatelessWidget {
  const _SizeDotChip({
    required this.diameter,
    required this.selected,
    required this.onTap,
  });

  final double diameter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = (diameter / 48 * 26).clamp(8.0, 26.0);
    return Tooltip(
      message: diameter.toStringAsFixed(0),
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 46,
            height: 46,
            child: Center(
              child: Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? const Color(0xFF9EC0FF)
                      : kChromeIconColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwatchChip extends StatelessWidget {
  const _SwatchChip({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: selected ? 'Current color' : 'Pick color',
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 46,
            height: 46,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 27,
                height: 27,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Colors.white : const Color(0x33FFFFFF),
                    width: selected ? 2.6 : 1.4,
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

/// The "+" chip — opens the extended color palette sheet.
class _SwatchPlusChip extends StatelessWidget {
  const _SwatchPlusChip({required this.current, required this.onPick});

  final Color current;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return _ChromeButton(
      icon: Icons.add,
      tooltip: 'More colors',
      selected: false,
      onTap: () => showColorPaletteSheet(context, current, onPick),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Selection pill (lasso actions) — Notewise dark restyle
// ─────────────────────────────────────────────────────────────────────────

class _SelectionPill extends ConsumerWidget {
  const _SelectionPill({required this.selection});

  final SelectionController selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(toolPaletteProvider);
    return _PillShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.polyline_outlined, size: 20, color: Color(0xFF9EC0FF)),
          const SizedBox(width: 10),
          Text(
            'Selection',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: kChromeIconColor,
                ),
          ),
          const SizedBox(width: 8),
          const _ChromeDivider(),
          _ChromeButton(
            icon: Icons.format_color_fill_outlined,
            tooltip: 'Recolor with pen color',
            selected: false,
            iconColor: tool.penColor,
            onTap: () => selection.recolor(tool.penColor.value),
          ),
          _ChromeButton(
            icon: Icons.delete_outline,
            tooltip: 'Delete selection',
            selected: false,
            onTap: selection.deleteSelection,
          ),
          _ChromeButton(
            icon: Icons.close,
            tooltip: 'Deselect',
            selected: false,
            onTap: selection.clear,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Touch settings sheet (the "…" menu)
// ─────────────────────────────────────────────────────────────────────────

/// Finger-drawing & palm-rejection switches — the two cold input
/// preferences the hot router reads via its policy.
Future<void> showTouchSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final input = ref.watch(inputSettingsProvider);
        final notifier = ref.read(inputSettingsProvider.notifier);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Input & touch',
                    style: Theme.of(context).textTheme.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.touch_app_outlined),
                  title: const Text('Draw with finger'),
                  subtitle: const Text(
                      'A single finger inks instead of navigating pages. '
                      'Page swiping is disabled while this is on.'),
                  value: input.allowFingerDrawing,
                  onChanged: notifier.setAllowFingerDrawing,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.pan_tool_outlined),
                  title: const Text('Palm rejection'),
                  subtitle: const Text(
                      'Ignore stray touches while the stylus is in range and '
                      'large palm contacts.'),
                  value: input.palmRejection,
                  onChanged: notifier.setPalmRejection,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Extended color palette sheet
// ─────────────────────────────────────────────────────────────────────────

Future<void> showColorPaletteSheet(
  BuildContext context,
  Color current,
  ValueChanged<Color> onPick,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Colors', style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 6,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1,
              children: [
                for (final c in kExtendedSwatches)
                  GestureDetector(
                    onTap: () {
                      onPick(c);
                      Navigator.of(sheetContext).pop();
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == current
                              ? Theme.of(sheetContext).colorScheme.onSurface
                              : Theme.of(sheetContext)
                                  .colorScheme
                                  .outlineVariant,
                          width: c == current ? 3 : 1.2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Page badge (bottom-left) + zoom menu
// ─────────────────────────────────────────────────────────────────────────

/// Notewise's floating "28 / 28 | 233%" badge. Tapping the page segment
/// opens the jump-to-page dialog; tapping the zoom segment opens the zoom
/// menu (fit page / fit width / 100% / in / out).
class EditorPageBadge extends StatelessWidget {
  const EditorPageBadge({
    super.key,
    required this.controllers,
    required this.index,
    required this.count,
    required this.onPrev,
    required this.onNext,
    required this.onJump,
    required this.onFitPage,
    required this.onFitWidth,
    required this.onZoom100,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final PageControllers? controllers;
  final int index;
  final int count;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onJump;
  final VoidCallback onFitPage;
  final VoidCallback onFitWidth;
  final VoidCallback onZoom100;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final viewport = controllers?.viewport;
    return _PillShell(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BadgeChevron(
            icon: Icons.expand_less,
            tooltip: 'Previous page',
            enabled: index > 0,
            onTap: onPrev,
          ),
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onJump,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '${index + 1} / $count',
                style: const TextStyle(
                  color: kChromeIconColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
          _BadgeChevron(
            icon: Icons.expand_more,
            tooltip: 'Next page',
            enabled: index < count - 1,
            onTap: onNext,
          ),
          const _ChromeDivider(),
          if (viewport == null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                '—',
                style: TextStyle(color: kChromeIconColor, fontSize: 13.5),
              ),
            )
          else
            AnimatedBuilder(
              animation: viewport,
              builder: (context, _) => PopupMenuButton<String>(
                tooltip: 'Zoom',
                color: kChromePillColor,
                position: PopupMenuPosition.over,
                onSelected: (v) {
                  switch (v) {
                    case 'fit':
                      onFitPage();
                    case 'width':
                      onFitWidth();
                    case '100':
                      onZoom100();
                    case 'in':
                      onZoomIn();
                    case 'out':
                      onZoomOut();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'fit',
                    child: _zoomRow(Icons.crop_free, 'Fit page'),
                  ),
                  PopupMenuItem(
                    value: 'width',
                    child: _zoomRow(Icons.aspect_ratio, 'Fit width'),
                  ),
                  PopupMenuItem(
                    value: '100',
                    child: _zoomRow(Icons.filter_1_outlined, '100%'),
                  ),
                  PopupMenuItem(
                    value: 'in',
                    child: _zoomRow(Icons.zoom_in, 'Zoom in'),
                  ),
                  PopupMenuItem(
                    value: 'out',
                    child: _zoomRow(Icons.zoom_out, 'Zoom out'),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '${(viewport.scale * 100).round()}%',
                    style: const TextStyle(
                      color: kChromeIconColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _zoomRow(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: kChromeIconColor),
        const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(
            color: kChromeIconColor,
            fontWeight: FontWeight.w500,
            fontSize: 13.5,
          ),
        ),
      ],
    );
  }
}

class _BadgeChevron extends StatelessWidget {
  const _BadgeChevron({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 38,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        tooltip: tooltip,
        onPressed: enabled ? onTap : null,
        icon: Icon(
          icon,
          color: enabled ? kChromeIconColor : kChromeIconDisabledColor,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Right-edge page arrows (Notewise's double-arrow page turner)
// ─────────────────────────────────────────────────────────────────────────

class EditorEdgeNav extends StatelessWidget {
  const EditorEdgeNav({
    super.key,
    required this.index,
    required this.count,
    required this.onPrev,
    required this.onNext,
  });

  final int index;
  final int count;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _EdgeButton(
          icon: Icons.keyboard_double_arrow_up,
          tooltip: 'Previous page',
          enabled: index > 0,
          onTap: onPrev,
        ),
        const SizedBox(height: 8),
        _EdgeButton(
          icon: Icons.keyboard_double_arrow_down,
          tooltip: 'Next page',
          enabled: index < count - 1,
          onTap: onNext,
        ),
      ],
    );
  }
}

class _EdgeButton extends StatelessWidget {
  const _EdgeButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Material(
        color: kChromePillColor,
        shape: const CircleBorder(
          side: BorderSide(color: kChromePillBorder),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 22,
              color: enabled ? kChromeIconColor : kChromeIconDisabledColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Read-mode exit pill (shown while the chrome is hidden)
// ─────────────────────────────────────────────────────────────────────────

class ReadModeExitPill extends StatelessWidget {
  const ReadModeExitPill({super.key, required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return _PillShell(
      padding: const EdgeInsets.all(4),
      child: _ChromeButton(
        icon: Icons.visibility_off_outlined,
        tooltip: 'Exit read mode',
        selected: false,
        onTap: onExit,
      ),
    );
  }
}
