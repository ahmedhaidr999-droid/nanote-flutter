import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/database/collections/stroke.dart' show PenStyle;

import 'shape_tool.dart';

part 'tools.freezed.dart';
part 'tools.g.dart';

/// Palette tools. `lasso` shipped in Step 3; `hand`, `shape` and `text` are
/// the Notewise-parity additions — APPENDED (never reordered: ordinal storage
/// rule) and runtime-only (the palette is never persisted).
enum ToolType { pen, highlighter, eraser, lasso, hand, shape, text }

enum EraserMode { pixel, stroke }

/// Pen thickness presets (Notewise's thin / medium / thick row).
const kPenSizePresets = [1.2, 2.6, 4.8];

/// Highlighter thickness presets.
const kHighlighterSizePresets = [8.0, 14.0, 24.0];

/// Shape stroke thickness presets.
const kShapeSizePresets = [1.5, 3.0, 5.0];

/// Eraser diameter presets (S / M / L).
const kEraserSizePresets = [12.0, 24.0, 48.0];

/// Text font-size presets (page points).
const kTextSizePresets = [12.0, 16.0, 22.0];

/// Pen opacity presets (XNota's opacity row).
const kPenOpacityPresets = [1.0, 0.6, 0.35];

/// Sticky-note background presets (XNota sticky palette).
const kStickySwatches = [
  Color(0xFFFFF3A3), // classic yellow
  Color(0xFFFFD8BE), // peach
  Color(0xFFC7F2D0), // mint
  Color(0xFFCFE5FF), // sky
  Color(0xFFEFD4FF), // lilac
];

@freezed
class ToolPaletteState with _$ToolPaletteState {
  const factory ToolPaletteState({
    @Default(ToolType.pen) ToolType tool,
    @Default(Color(0xFF155EEF)) Color penColor,
    @Default(2.6) double penSize,
    @Default(PenStyle.regular) PenStyle penStyle,
    @Default(1.0) double penOpacity,
    @Default(Color(0xFFFDE047)) Color highlighterColor,
    @Default(14) double highlighterSize,
    @Default(EraserMode.stroke) EraserMode eraserMode,
    @Default(24) double eraserSize,
    @Default(ShapeType.line) ShapeType shapeType,
    @Default(2.6) double shapeSize,
    @Default(Color(0xFF111827)) Color textColor,
    @Default(16) double textSize,
    @Default(false) bool textSticky,
    @Default(Color(0xFFFFF3A3)) Color stickyColor,
  }) = _ToolPaletteState;
}

/// Cold tool state (changes rarely → Riverpod is the right home).
/// The 120Hz pointer hot path deliberately never flows through here —
/// see [InkController] for why.
///
/// Shape strokes deliberately reuse [penColor] — one ink identity for all
/// "pen-like" output keeps the contextual sub-pill simple and matches how
/// people actually use shape tools (pick a color, draw shapes and notes).
@riverpod
class ToolPalette extends _$ToolPalette {
  @override
  ToolPaletteState build() => const ToolPaletteState();

  void select(ToolType t) => state = state.copyWith(tool: t);
  void setPenColor(Color c) => state = state.copyWith(penColor: c);
  void setPenSize(double s) => state = state.copyWith(penSize: s);
  void setPenStyle(PenStyle s) => state = state.copyWith(penStyle: s);
  void setPenOpacity(double o) =>
      state = state.copyWith(penOpacity: o.clamp(0.1, 1.0));
  void setHighlighterColor(Color c) =>
      state = state.copyWith(highlighterColor: c);
  void setHighlighterSize(double s) =>
      state = state.copyWith(highlighterSize: s);
  void setEraserMode(EraserMode m) => state = state.copyWith(eraserMode: m);
  void setEraserSize(double s) => state = state.copyWith(eraserSize: s);
  void setShapeType(ShapeType t) => state = state.copyWith(shapeType: t);
  void setShapeSize(double s) => state = state.copyWith(shapeSize: s);
  void setTextColor(Color c) => state = state.copyWith(textColor: c);
  void setTextSize(double s) => state = state.copyWith(textSize: s);
  void setTextSticky(bool v) => state = state.copyWith(textSticky: v);
  void setStickyColor(Color c) => state = state.copyWith(stickyColor: c);
}
