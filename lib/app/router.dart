import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/editor/presentation/screens/editor_screen.dart';
import '../features/library/presentation/screens/home_screen.dart';
import '../features/library/presentation/screens/trash_screen.dart';

/// Declarative navigation:
///
///     /                    → library root shelf
///     /folder/:fid         → a folder's shelf (pushed repeatedly for
///                            arbitrarily deep nesting — the back stack IS
///                            the folder path)
///     /trash               → trashed documents (restore / purge)
///     /doc/:did            → the editor for one document
final GoRouter nanoteRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'library',
      builder: (context, state) => const HomeScreen(folderId: null),
      routes: [
        GoRoute(
          path: 'folder/:fid',
          name: 'folder',
          builder: (context, state) {
            final fid = int.tryParse(state.pathParameters['fid'] ?? '');
            if (fid == null) return const HomeScreen(folderId: null);
            return HomeScreen(folderId: fid);
          },
        ),
        GoRoute(
          path: 'trash',
          name: 'trash',
          builder: (context, state) => const TrashScreen(),
        ),
        GoRoute(
          path: 'doc/:did',
          name: 'editor',
          builder: (context, state) {
            final did = int.tryParse(state.pathParameters['did'] ?? '');
            if (did == null) return const HomeScreen(folderId: null);
            return EditorScreen(documentId: did);
          },
        ),
      ],
    ),
  ],
);

/// Route helpers — single place that knows URL shapes.
void openFolder(BuildContext context, int folderId) =>
    context.push('/folder/$folderId');

void openDocument(BuildContext context, int documentId) =>
    context.push('/doc/$documentId');

void openTrash(BuildContext context) => context.push('/trash');
