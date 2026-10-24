import 'package:isar/isar.dart';

part 'text_block.g.dart';

/// One text box on a page (the text tool — Notewise parity).
///
/// Storage layout:
///  • [x], [y] are the TOP-LEFT anchor in PAGE coordinates (logical points);
///  • [content] is plain text — newlines preserved; no rich formatting;
///  • [fontSize] is in PAGE points; the painter re-lays the glyphs at
///    `fontSize × current zoom` so text stays crisp at any magnification;
///  • [colorValue] mirrors the stroke colour convention (ARGB int).
///
/// Text blocks are a separate collection from [Stroke] — they never join the
/// ink undo stack in this iteration (their lifecycle is create / edit /
/// move / delete via the text tool itself).
@collection
class TextBlock {
  Id id = Isar.autoIncrement;

  /// Owning page.
  @Index()
  int pageId = 0;

  double x = 0;
  double y = 0;

  String content = '';

  double fontSize = 16;

  int colorValue = 0xFF111827;

  DateTime updatedAt = DateTime.now();
}
