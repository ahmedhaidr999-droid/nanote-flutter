import 'package:flutter/foundation.dart';

/// Broadcast "freeze page navigation" intent from the per-page input routers
/// to the editor's page pager.
///
/// Why it exists: the ink canvas consumes RAW pointer events via a bare
/// `Listener`, which does NOT participate in the gesture arena — so the
/// hosting `PageView`'s drag recognizer receives the SAME pointers. Any
/// pointer the router acts on (a stylus stroke, a two-finger pinch) must
/// therefore never also drive the pager, or the page "moves while I write".
///
/// Sources that activate the shield:
///  1. an active ink / erase / lasso / transform / pinch gesture on any
///     mounted page (its router is mid-flight);
///  2. a stylus in range (hovering or recently active — palm rejection's
///     800 ms window).
///
/// While ANY source is active the editor rebuilds the pager with
/// `NeverScrollableScrollPhysics` (kills in-flight drags, rejects fresh
/// ones); when it clears, the pager settles to the nearest page so it never
/// rests between pages.
class NavigationShield extends ChangeNotifier {
  final Map<Object, bool> _sources = {};

  /// True while any mounted page's router demands frozen navigation.
  bool get active => _sources.isNotEmpty;

  /// Publishes [value] for [source]. Sources are keyed by identity — each
  /// page's [InputRouter] registers itself here (a page's shield flips
  /// constantly during use, but the editor only rebuilds on the GLOBAL
  /// on/off edges thanks to this OR-merge).
  void set(Object source, bool value) {
    final current = _sources[source] ?? false;
    if (current == value) return;
    if (value) {
      _sources[source] = true;
    } else {
      _sources.remove(source);
    }
    notifyListeners();
  }
}
