import 'package:flutter/foundation.dart';

import '../../../core/database/collections/document.dart';
import '../../../core/database/collections/folder.dart';

/// How the shelf sorts documents. Pinned documents float first in BOTH
/// modes (see LibraryRepository._pinnedFirst).
enum LibrarySort { updated, name }

/// Grid or list presentation of the shelf.
enum LibraryViewMode { grid, list }

/// One emission of the merged folders+documents watch — the home screen
/// subscribes exactly once and gets consistent pairs even when both
/// collections change in the same instant.
@immutable
class LibrarySnapshot {
  const LibrarySnapshot({required this.folders, required this.documents});

  final List<Folder> folders;
  final List<Document> documents;

  bool get isEmpty => folders.isEmpty && documents.isEmpty;
}
