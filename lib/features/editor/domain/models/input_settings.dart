import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'input_settings.freezed.dart';
part 'input_settings.g.dart';

/// Cold input preferences (change rarely → Riverpod home). The hot router
/// receives them as plain fields on [PalmRejectionPolicy] — it must never
/// watch providers mid-gesture.
@freezed
class InputSettingsState with _$InputSettingsState {
  const factory InputSettingsState({
    /// "Draw with finger": a lone touch inks instead of panning.
    @Default(false) bool allowFingerDrawing,

    /// Palm-rejection heuristics master switch.
    @Default(true) bool palmRejection,
  }) = _InputSettingsState;
}

@riverpod
class InputSettings extends _$InputSettings {
  @override
  InputSettingsState build() => const InputSettingsState();

  void setAllowFingerDrawing(bool v) =>
      state = state.copyWith(allowFingerDrawing: v);

  void setPalmRejection(bool v) => state = state.copyWith(palmRejection: v);
}
