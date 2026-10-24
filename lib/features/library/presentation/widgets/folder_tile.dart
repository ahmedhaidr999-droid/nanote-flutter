import 'package:flutter/material.dart';

import '../../../../../core/database/collections/folder.dart';
import '../../../../../core/utils/date_labels.dart';

/// Grid card for one folder — a tinted "folder avatar" using the folder's
/// chosen color.
class FolderCard extends StatelessWidget {
  const FolderCard({
    super.key,
    required this.folder,
    required this.onOpen,
    required this.onLongPress,
  });

  final Folder folder;
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
              child: Container(
                color: Color(folder.colorValue).withOpacity(0.14),
                alignment: Alignment.center,
                child: Icon(
                  Icons.folder_outlined,
                  size: 48,
                  color: Color(folder.colorValue),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Folder · ${formatWhen(folder.updatedAt)}',
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

/// List row for one folder.
class FolderRow extends StatelessWidget {
  const FolderRow({
    super.key,
    required this.folder,
    required this.onOpen,
    required this.onLongPress,
  });

  final Folder folder;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onOpen,
      onLongPress: onLongPress,
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(folder.colorValue).withOpacity(0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.folder_outlined,
          color: Color(folder.colorValue),
        ),
      ),
      title: Text(
        folder.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('Folder · ${formatWhen(folder.updatedAt)}'),
    );
  }
}
