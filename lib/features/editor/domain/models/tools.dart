import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

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

@freezed
class ToolPaletteState with _$ToolPaletteState {
  const factory ToolPaletteState({
    @Default(ToolType.pen) ToolType tool,
    @Default(Color(0xFF155EEF)) Color penColor,
    @Default(2.6) double penSize,
    @Default(Color(0xFFFDE047)) Color highlighterColor,
    @Default(14) double highlighterSize,
    @Default(EraserMode.stroke) EraserMode eraserMode,
    @Default(24) double eraserSize,
    @Default(ShapeType.line) ShapeType shapeType,
    @Default(2.6) double shapeSize,
    @Default(Color(0xFF111827)) Color textColor,
    @Default(16) double textSize,
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
}
