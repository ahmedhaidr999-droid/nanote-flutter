import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/models/tools.dart';
import 'ink_controller.dart';
import 'input_policy.dart';
import 'navigation_shield.dart';
import 'selection_controller.dart';
import 'viewport_controller.dart';

enum _Mode { idle, inking, erasing, lassoing, transforming, panning, pinching }

/// Routes RAW pointer events (no gesture arena — zero-latency) through the
/// [InputPolicy] to one of:
///
///  • inking / erasing / lassoing / transforming — stylus, mouse, or a lone
///    finger when "draw with finger" is enabled;
///  • panning — one finger, desktop wheel;
///  • pinching — two fingers;
///  • native trackpad pan/zoom via PointerPanZoom* events.
///
/// Touch routing model (v1.1 — the dual-gesture fix):
///  • a LONE finger is PAGE NAVIGATION, owned natively by the hosting
///    PageView (whose ScrollConfiguration admits touch only). The router
///    tracks it but never pans the viewport — no gesture can be driven by
///    both the router and the pager at once;
///  • TWO fingers = pinch/pan, owned by the router (the pager is frozen
///    via [NavigationShield] for the duration — and stays frozen until the
///    pager settles to the nearest page);
///  • stylus/mouse always ink/erase/lasso and NEVER navigate — the pager
///    ignores their device kinds entirely.
///
/// Palm safety is layered:
///  1. the POLICY may verdict a touch `ignore` outright (stylus in range /
///     huge contact area) — ignored pointers are never tracked, so neither
///     their downs nor moves affect anything;
///  2. touches arriving while a stylus gesture is active are tracked but
///     inert (and the shield keeps the pager frozen while they rest);
///  3. a second finger while FINGER-drawing/lassoing cancels the gesture
///     and upgrades to a pinch — the user's intent flips to navigation.
///
/// Everything is a plain state machine over pointer ids — no GestureDetectors,
/// no recognizers competing in an arena, no 100ms waits.
class InputRouter {
  InputRouter({
    required this.ink,
    required this.viewport,
    this.selection,
    InputPolicy? policy,
  }) : policy = policy ?? const PalmRejectionPolicy();

  final InkController ink;
  final ViewportController viewport;
  final SelectionController? selection;

  /// Current policy & tool; the hosting widget refreshes these on cold-state
  /// changes. Never swapped mid-gesture by the UI (tool changes clear the
  /// selection first).
  InputPolicy policy;
  ToolPaletteState tool = const ToolPaletteState();

  /// Set by the hosting canvas (see [InkCanvas]). While ANY mounted page's
  /// router reports an active gesture / stylus-in-range, the editor freezes
  /// the page pager so a pen stroke or a pinch can never also scroll pages.
  NavigationShield? navigationShield;

  _Mode _mode = _Mode.idle;

  int? _inkPointer;
  PointerDeviceKind? _inkDeviceKind;

  int? _lassoPointer;
  bool _lassoIsTouch = false;

  /// Tracked touch pointer id → latest screen position. NOTE: touches the
  /// policy rejected are deliberately absent — an untracked pointer is a
  /// no-op for every subsequent event.
  final Map<int, Offset> _touches = {};

  // Pinch snapshot (captured when the 2nd finger lands).
  Matrix4? _pinchBase;
  Offset? _pinchBaseFocal;
  double? _pinchBaseSpan;

  // Trackpad gesture snapshot.
  Matrix4? _pzBase;
  Offset? _pzStart;

  // Stylus range tracking (palm rejection signal #1).
  DateTime? _lastStylusHover;
  static const _stylusRangeWindow = Duration(milliseconds: 800);

  // Nudges the shield when the hover window lapses silently.
  Timer? _shieldTimer;

  bool get _stylusInRange {
    final h = _lastStylusHover;
    return h != null && DateTime.now().difference(h) < _stylusRangeWindow;
  }

  InputPolicyContext get _context =>
      InputPolicyContext(stylusInRange: _stylusInRange);

  void _noteStylusActivity(PointerDeviceKind kind) {
    if (kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.invertedStylus) {
      // Active stylus contact implies in-range; refreshes the hover window.
      _lastStylusHover = DateTime.now();
    }
  }

  // ── Stylus hover (Apple Pencil / S-Pen in proximity) ────────────────────

  void onPointerHover(PointerHoverEvent e) {
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      _lastStylusHover = DateTime.now();
    }
    _scheduleShield(); // hover streams re-arm the palm-rejection window
  }

  // ── Trackpad (native pan/zoom) ──────────────────────────────────────────

  void onPointerPanZoomStart(PointerPanZoomStartEvent e) {
    _pzBase = Matrix4.copy(viewport.matrix);
    _pzStart = e.localPosition;
  }

  void onPointerPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    final base = _pzBase;
    final start = _pzStart;
    if (base == null || start == null) return;
    final ratio = e.scale > 0 ? e.scale : 1.0;
    viewport.applyPinch(
      base: base,
      baseFocal: start,
      newFocal: e.localPosition,
      ratio: ratio,
    );
  }

  void onPointerPanZoomEnd(PointerPanZoomEndEvent e) {
    _pzBase = null;
    _pzStart = null;
  }

  // ── Pointer lifecycle ───────────────────────────────────────────────────

  void onPointerDown(PointerDownEvent e) {
    try {
      _pointerDown(e);
    } finally {
      // Every early return below must still re-evaluate the shield — a
      // stylus down arms it immediately, before any mode settles.
      _scheduleShield();
    }
  }

  void _pointerDown(PointerDownEvent e) {
    _noteStylusActivity(e.kind);
    if (e.kind == PointerDeviceKind.trackpad) return; // pan-zoom events only

    // A second finger while FINGER-drawing → cancel and upgrade to pinch.
    if (_mode == _Mode.inking &&
        _inkDeviceKind == PointerDeviceKind.touch &&
        e.kind == PointerDeviceKind.touch) {
      ink.cancelStroke();
      _inkPointer = null;
      _inkDeviceKind = null;
      _mode = _Mode.idle;
      _touches[e.pointer] = e.localPosition;
      _beginPinch();
      return;
    }

    // A second finger while FINGER-lassoing/transforming → same upgrade.
    if ((_mode == _Mode.lassoing || _mode == _Mode.transforming) &&
        _lassoIsTouch &&
        e.kind == PointerDeviceKind.touch) {
      selection?.cancelGesture();
      _lassoPointer = null;
      _mode = _Mode.idle;
      _touches[e.pointer] = e.localPosition;
      _beginPinch();
      return;
    }

    final role = policy.roleFor(e, _context);
    if (role == PointerRole.ignore) return; // palm — completely untracked

    // Track every non-rejected touch (for pan/pinch AND so finger-ink can
    // upgrade to pinch later).
    if (e.kind == PointerDeviceKind.touch) {
      _touches[e.pointer] = e.localPosition;
    }

    switch (role) {
      case PointerRole.ignore:
        return;

      case PointerRole.erase:
        // Hardware eraser tip (Pencil's back end) — erases regardless of
        // the selected tool.
        if (_inkPointer != null || _mode != _Mode.idle) return;
        _inkPointer = e.pointer;
        _inkDeviceKind = e.kind;
        _mode = _Mode.erasing;
        final page = viewport.screenToPage(e.localPosition);
        ink.beginErase(page);
        ink.eraseSegment(page, tool.eraserSize, tool.eraserMode);
        return;

      case PointerRole.pan:
        if (_mode == _Mode.inking ||
            _mode == _Mode.erasing ||
            _mode == _Mode.lassoing ||
            _mode == _Mode.transforming) {
          return; // stylus gesture active — this touch rests inert (palm-safe)
        }
        if (_touches.length >= 2) {
          _beginPinch(); // two fingers = zoom / pan the page
        }
        // A LONE finger is page navigation — the hosting PageView owns it
        // natively (its ScrollConfiguration admits touch ONLY, so stylus
        // strokes can never flip pages). The router merely tracks the
        // finger so a second one can upgrade to a pinch.
        return;

      case PointerRole.ink:
        if (_inkPointer != null ||
            _lassoPointer != null ||
            _mode == _Mode.lassoing ||
            _mode == _Mode.transforming) {
          return; // a gesture already owns the canvas
        }
        switch (tool.tool) {
          case ToolType.pen:
          case ToolType.highlighter:
            _inkPointer = e.pointer;
            _inkDeviceKind = e.kind;
            _mode = _Mode.inking;
            ink.beginStroke(
              viewport.screenToPage(e.localPosition),
              _pressureOf(e),
              tool,
            );

          case ToolType.eraser:
            _inkPointer = e.pointer;
            _inkDeviceKind = e.kind;
            _mode = _Mode.erasing;
            final page = viewport.screenToPage(e.localPosition);
            ink.beginErase(page);
            ink.eraseSegment(page, tool.eraserSize, tool.eraserMode);

          case ToolType.lasso:
            final sel = selection;
            if (sel == null) return;
            _lassoPointer = e.pointer;
            _lassoIsTouch = e.kind == PointerDeviceKind.touch;

            final handle = sel.hitTestHandle(e.localPosition);
            if (handle != null) {
              sel.beginTransform(handle, e.localPosition);
              _mode = _Mode.transforming;
              return;
            }
            final page = viewport.screenToPage(e.localPosition);
            if (sel.hasSelection && sel.hitTestSelection(page)) {
              sel.beginTransform(SelectionHandle.move, e.localPosition);
              _mode = _Mode.transforming;
            } else {
              sel.beginLoop(page);
              _mode = _Mode.lassoing;
            }
        }
    }
  }

  void onPointerMove(PointerMoveEvent e) {
    if (e.pointer == _inkPointer) {
      final page = viewport.screenToPage(e.localPosition);
      if (_mode == _Mode.inking) {
        ink.appendPoint(page, _pressureOf(e));
      } else if (_mode == _Mode.erasing) {
        ink.eraseSegment(page, tool.eraserSize, tool.eraserMode);
      }
      return;
    }

    if (e.pointer == _lassoPointer) {
      if (_mode == _Mode.lassoing) {
        selection?.extendLoop(viewport.screenToPage(e.localPosition));
      } else if (_mode == _Mode.transforming) {
        selection?.updateTransform(e.localPosition);
      }
      return;
    }

    if (_touches.containsKey(e.pointer)) {
      _touches[e.pointer] = e.localPosition;
      if (_mode == _Mode.panning) {
        viewport.panBy(e.delta);
      } else if (_mode == _Mode.pinching) {
        _updatePinch();
      }
    }
  }

  void onPointerUp(PointerUpEvent e) {
    try {
      _finish(e.pointer, cancel: false);
    } finally {
      _scheduleShield();
    }
  }

  void onPointerCancel(PointerCancelEvent e) {
    try {
      _finish(e.pointer, cancel: true);
    } finally {
      _scheduleShield();
    }
  }

  /// Desktop testing convenience: wheel pans the canvas.
  void onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      viewport.panBy(-e.scrollDelta);
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────

  void _finish(int pointer, {required bool cancel}) {
    if (pointer == _inkPointer) {
      if (cancel) {
        ink.cancelStroke();
      } else if (_mode == _Mode.inking) {
        ink.endStroke();
      } else if (_mode == _Mode.erasing) {
        ink.endErase();
      }
      _inkPointer = null;
      _inkDeviceKind = null;
      _touches.remove(pointer);
      _settleModeFromTouches();
      return;
    }

    if (pointer == _lassoPointer) {
      if (cancel) {
        selection?.cancelGesture();
      } else if (_mode == _Mode.lassoing) {
        selection?.endLoop();
      } else if (_mode == _Mode.transforming) {
        selection?.endTransform();
      }
      _lassoPointer = null;
      _touches.remove(pointer);
      _settleModeFromTouches();
      return;
    }

    if (!_touches.containsKey(pointer)) return; // rejected palm, untracked
    _touches.remove(pointer);
    if (_mode == _Mode.panning) {
      if (_touches.isEmpty) _mode = _Mode.idle;
    } else if (_mode == _Mode.pinching) {
      if (_touches.length == 1) {
        _mode = _Mode.panning; // keep scrolling with the remaining finger
      } else if (_touches.isEmpty) {
        _mode = _Mode.idle;
      } else {
        _beginPinch(); // rebase on the remaining fingers
      }
    }
  }

  /// After an ink/lasso gesture ends, remaining touches rest INERT — they
  /// are almost always the resting palm. Pinches may only start from FRESH
  /// pointer-downs (two fingers landing), and lone fingers belong to the
  /// PageView, never to the viewport. (The post-pinch single-finger pan
  /// continuation in [_finish] is the one deliberate exception.)
  void _settleModeFromTouches() {
    _mode = _Mode.idle;
  }

  // ── Navigation shield plumbing ────────────────────────────────────────

  bool get _shieldWanted => _mode != _Mode.idle || _stylusInRange;

  void _scheduleShield() {
    final shield = navigationShield;
    if (shield == null) return;
    shield.set(this, _shieldWanted);
    if (_stylusInRange) {
      // The hover window lapses silently (no event arrives) — nudge the
      // shield when it does so the pager unfreezes exactly on time.
      _shieldTimer?.cancel();
      _shieldTimer = Timer(
        _stylusRangeWindow + const Duration(milliseconds: 50),
        () => navigationShield?.set(this, _shieldWanted),
      );
    }
  }

  /// Stops the hover timer and detaches from the shared shield. Called by
  /// the hosting canvas on dispose.
  void dispose() {
    _shieldTimer?.cancel();
    _shieldTimer = null;
    navigationShield?.set(this, false);
    navigationShield = null;
  }

  void _beginPinch() {
    _mode = _Mode.pinching;
    _pinchBase = Matrix4.copy(viewport.matrix);
    _pinchBaseFocal = _focal();
    _pinchBaseSpan = _span();
  }

  void _updatePinch() {
    final base = _pinchBase;
    final f0 = _pinchBaseFocal;
    final d0 = _pinchBaseSpan;
    if (base == null || f0 == null || d0 == null || d0 < 1) return;
    final d1 = _span();
    if (d1 < 1) return;
    viewport.applyPinch(
      base: base,
      baseFocal: f0,
      newFocal: _focal(),
      ratio: d1 / d0,
    );
  }

  Offset _focal() {
    if (_touches.isEmpty) return Offset.zero;
    var x = 0.0;
    var y = 0.0;
    for (final p in _touches.values) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / _touches.length, y / _touches.length);
  }

  double _span() {
    final pts = _touches.values.toList(growable: false);
    if (pts.length < 2) return 0;
    return (pts[0] - pts[1]).distance;
  }

  double _pressureOf(PointerEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return 0.5;
    final p = e.pressure;
    if (p <= 0 || p > 1 || p.isNaN) return 0.5;
    return p;
  }
}
