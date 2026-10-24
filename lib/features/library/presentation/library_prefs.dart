import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../domain/library_models.dart';

part 'library_prefs.g.dart';

/// Library presentation preferences (cold UI state — Riverpod home).
/// Kept in memory for v1; persisting to Isar later only means swapping the
/// `build()` body, no call-site changes.
@immutable
class LibraryPrefsState {
  const LibraryPrefsState({
    this.viewMode = LibraryViewMode.grid,
    this.sort = LibrarySort.updated,
    this.searching = false,
    this.query = '',
  });

  final LibraryViewMode viewMode;
  final LibrarySort sort;

  /// Quick-find is open; [query] is live while typing.
  final bool searching;
  final String query;

  /// A non-empty trimmed query (used by the repository provider).
  String? get effectiveQuery {
    final t = query.trim();
    return t.isEmpty ? null : t;
  }

  LibraryPrefsState copyWith({
    LibraryViewMode? viewMode,
    LibrarySort? sort,
    bool? searching,
    String? query,
    bool clearQuery = false,
  }) {
    return LibraryPrefsState(
      viewMode: viewMode ?? this.viewMode,
      sort: sort ?? this.sort,
      searching: searching ?? this.searching,
      query: clearQuery ? '' : (query ?? this.query),
    );
  }
}

@riverpod
class LibraryPrefs extends _$LibraryPrefs {
  @override
  LibraryPrefsState build() => const LibraryPrefsState();

  void setViewMode(LibraryViewMode mode) => state = state.copyWith(viewMode: mode);

  void setSort(LibrarySort sort) => state = state.copyWith(sort: sort);

  void startSearch() => state = state.copyWith(searching: true);

  void endSearch() =>
      state = state.copyWith(searching: false, clearQuery: true);

  /// Keystroke-level. Re-subscribes the snapshot provider → live results.
  void setQuery(String q) => state = state.copyWith(query: q);
}
