import 'package:isar/isar.dart';

part 'folder.g.dart';

/// A user folder in the Nanote library.
///
/// Tree strategy — indexed [parentId], NOT IsarLink self-references:
///  • `WHERE parentId = ?` is a pure index lookup → instant child listing at
///    any nesting depth (University → Stage 3 → Pathology → Lectures…).
///  • Moving a folder (with its entire subtree) is a single-field update;
///    IsarLinks would require link-graph surgery.
///  • Cycle protection (a folder moved into its own descendant) is a cheap
///    ancestor walk enforced in the repository layer, where it belongs.
@collection
class Folder {
  Id id = Isar.autoIncrement;

  /// Display name. Value-indexed (not hashed) → efficient prefix search in
  /// the quick-find bar. Siblings may share names, like macOS Finder.
  @Index(type: IndexType.value)
  String name = 'Untitled folder';

  /// Parent folder id. `null` → top-level shelf (library root).
  @Index()
  int? parentId;

  /// ARGB tint for the folder avatar (chosen from the fixed brand palette).
  int colorValue = 0xFF155EEF;

  /// Manual ordering position among siblings (drag-and-drop reordering).
  int sortIndex = 0;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();

  Folder({
    this.id = Isar.autoIncrement,
    this.name = 'Untitled folder',
    this.parentId,
    this.colorValue = 0xFF155EEF,
    this.sortIndex = 0,
  });
}
