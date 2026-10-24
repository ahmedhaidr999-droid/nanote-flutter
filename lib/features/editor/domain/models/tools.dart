import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'tools.freezed.dart';
part 'tools.g.dart';

/// Palette tools. `lasso` ships as a value already so the enum never needs
/// reordering (ordinal storage rule); its interaction logic lands in Step 3.
enum ToolType { pen, highlighter, eraser, lasso }

enum EraserMode { pixel, stroke }

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
  }) = _ToolPaletteState;
}

/// Cold tool state (changes rarely → Riverpod is the right home).
/// The 120Hz pointer hot path deliberately never flows through here —
/// see [InkController] for why.
@riverpod
class ToolPalette extends _$ToolPalette {
  @override
  ToolPaletteState build() => const ToolPaletteState();

  void select(ToolType t) => state = state.copyWith(tool: t);
  void setPenColor(Color c) => state = state.copyWith(penColor: c);
  void setPenSize(double s) => state = state.copyWith(penSize: s);
  void setHighlighterColor(Color c) => state = state.copyWith(highlighterColor: c);
  void setHighlighterSize(double s) => state = state.copyWith(highlighterSize: s);
  void setEraserMode(EraserMode m) => state = state.copyWith(eraserMode: m);
  void setEraserSize(double s) => state = state.copyWith(eraserSize: s);
}
