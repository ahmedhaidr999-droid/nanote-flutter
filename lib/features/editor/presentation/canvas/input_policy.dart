import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// What the router should DO with a pointer that just went down.
enum PointerRole { ink, erase, pan, ignore }

/// Snapshot of stylus-range state the policy evaluates touches against.
@immutable
class InputPolicyContext {
  const InputPolicyContext({required this.stylusInRange});

  /// A stylus is (or very recently was) hovering/contacting the screen —
  /// derived from hover events + recent stylus activity in [InputRouter].
  final bool stylusInRange;
}

/// Decides which physical device may lay down ink.
///
/// The router asks the policy ONCE per pointer-down; everything after that
/// (moves, ups) is routed by pointer id — policy logic never runs on the
/// 120Hz move stream.
abstract class InputPolicy {
  const InputPolicy();

  PointerRole roleFor(PointerDownEvent event, InputPolicyContext context);

  /// Hardware eraser tip (Apple Pencil's back end) — routes to the eraser
  /// regardless of the selected tool.
  bool isEraserTip(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.invertedStylus;
}

/// Permissive fallback (unit tests, desktop-mouse-only environments):
/// stylus/mouse ink, touch pans, trackpad handled natively.
class PermissiveInputPolicy extends InputPolicy {
  const PermissiveInputPolicy();

  @override
  PointerRole roleFor(PointerDownEvent event, InputPolicyContext context) {
    switch (event.kind) {
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.mouse:
        return PointerRole.ink;
      case PointerDeviceKind.invertedStylus:
        return PointerRole.erase;
      case PointerDeviceKind.trackpad:
        return PointerRole.ignore; // arrives as PointerPanZoom* events
      case PointerDeviceKind.touch:
      case PointerDeviceKind.unknown:
        return PointerRole.pan;
    }
  }
}

/// Production policy — strict palm rejection, GoodNotes/Notewise semantics:
///
///  1. Stylus & mouse always ink; the Pencil's eraser end always erases.
///  2. A touch landing while a stylus is in range (hovering or actively
///     writing) is a palm → completely ignored (not even a pan).
///  3. A touch with a huge contact area is a palm regardless of stylus
///     state → ignored. (`radiusMajor` is in logical pixels; a resting
///     palm ≈ 25–45 mm ≈ >100 lpx on an iPad, a fingertip ≈ 40–55.)
///  4. Otherwise a touch pans/zooms — unless the user enabled
///     "draw with finger", in which case a lone finger inks.
class PalmRejectionPolicy extends InputPolicy {
  const PalmRejectionPolicy({
    this.enabled = true,
    this.allowFingerDrawing = false,
    this.palmContactRadiusPx = 80,
  });

  /// Master switch for heuristics (1)–(3). When off, touches behave
  /// per [allowFingerDrawing] with no palm filtering.
  final bool enabled;

  /// "Draw with finger" user preference.
  final bool allowFingerDrawing;

  /// Contact-radius threshold (logical px) above which a touch is a palm.
  final double palmContactRadiusPx;

  @override
  PointerRole roleFor(PointerDownEvent event, InputPolicyContext context) {
    switch (event.kind) {
      case PointerDeviceKind.stylus:
        return PointerRole.ink;
      case PointerDeviceKind.invertedStylus:
        return PointerRole.erase;
      case PointerDeviceKind.mouse:
        return PointerRole.ink;
      case PointerDeviceKind.trackpad:
        return PointerRole.ignore; // native pan/zoom via PointerPanZoom*
      case PointerDeviceKind.touch:
      case PointerDeviceKind.unknown:
        if (!enabled) {
          return allowFingerDrawing ? PointerRole.ink : PointerRole.pan;
        }
        if (context.stylusInRange) return PointerRole.ignore; // rule 2
        if (event.radiusMajor > palmContactRadiusPx) return PointerRole.ignore; // rule 3
        return allowFingerDrawing ? PointerRole.ink : PointerRole.pan; // rule 4
    }
  }
}
