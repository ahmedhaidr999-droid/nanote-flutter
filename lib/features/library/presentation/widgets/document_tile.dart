import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../../core/database/collections/document.dart';
import '../../../../../core/utils/date_labels.dart';
import '../../../../../core/utils/path_helpers.dart';
import 'paper_preview.dart';

/// Cover thumbnail: imported PDFs read their pre-rendered cover from disk
/// (never re-raster the PDF for a grid card); notebooks render their paper
/// procedurally — always true to the document's template + shade.
class DocumentThumbnail extends StatelessWidget {
  const DocumentThumbnail({super.key, required this.document});

  final Document document;

  @override
  Widget build(BuildContext context) {
    final thumbPath = document.thumbnailPath;
    if (document.type == DocumentType.pdf && thumbPath != null) {
      return FutureBuilder<String>(
        future: absolutePathOf(thumbPath),
        builder: (context, snapshot) {
          final path = snapshot.data;
          if (path == null) {
            return const _PlaceholderCover(child: CircularProgressIndicator(strokeWidth: 2));
          }
          return Image.file(
            File(path),
            fit: BoxFit.cover,
            cacheWidth: 480,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _PlaceholderCover(
              child: Icon(Icons.picture_as_pdf_outlined, size: 32),
            ),
          );
        },
      );
    }
    return PaperPreview(
      template: document.paperTemplate,
      shade: document.paperShade,
      cornerRadius: 0,
    );
  }
}

class _PlaceholderCover extends StatelessWidget {
  const _PlaceholderCover({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// Grid card for one document.
class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.document,
    required this.onOpen,
    required this.onLongPress,
  });

  final Document document;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DocumentThumbnail(document: document),
                  if (document.pinned)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.push_pin,
                            size: 12, color: scheme.onPrimary),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        document.type == DocumentType.pdf
                            ? Icons.picture_as_pdf_outlined
                            : Icons.book_outlined,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          document.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatWhen(document.updatedAt)} · '
                    '${document.pageCount} ${document.pageCount == 1 ? 'page' : 'pages'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// List row for one document.
class DocumentRow extends StatelessWidget {
  const DocumentRow({
    super.key,
    required this.document,
    required this.onOpen,
    required this.onLongPress,
  });

  final Document document;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onOpen,
      onLongPress: onLongPress,
      leading: SizedBox(
        width: 44,
        height: 58,
        child: DocumentThumbnail(document: document),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              document.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (document.pinned) ...[
            const SizedBox(width: 6),
            Icon(Icons.push_pin, size: 14, color: scheme.primary),
          ],
        ],
      ),
      subtitle: Text(
        '${document.type == DocumentType.pdf ? 'PDF' : 'Notebook'} · '
        '${formatWhen(document.updatedAt)} · '
        '${document.pageCount} ${document.pageCount == 1 ? 'page' : 'pages'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
