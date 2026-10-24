import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App-documents root + relative-path resolution.
///
/// EVERYTHING the app stores (imported PDFs, thumbnails) lives under the
/// OS documents directory and is referenced by paths RELATIVE to it —
/// absolute paths die on device migration / backup restore / app updates.
///
/// The root is resolved ONCE (library cards call [absolutePathOf] per
/// build — that must never hit the platform channel each time).
Directory? _rootMemo;

Future<Directory> appDocsRoot() async {
  final memo = _rootMemo;
  if (memo != null) return memo;
  return _rootMemo = await getApplicationDocumentsDirectory();
}

/// `<docs>/pdfs/` — imported PDF payloads.
Future<Directory> pdfsDir() async {
  final root = await appDocsRoot();
  final dir = Directory(p.join(root.path, 'pdfs'));
  await dir.create(recursive: true);
  return dir;
}

/// `<docs>/thumbs/` — pre-rendered cover thumbnails for the library grid.
Future<Directory> thumbsDir() async {
  final root = await appDocsRoot();
  final dir = Directory(p.join(root.path, 'thumbs'));
  await dir.create(recursive: true);
  return dir;
}

/// Resolves a stored relative path ('pdfs/x.pdf') to an absolute one.
Future<String> absolutePathOf(String relative) async =>
    p.join((await appDocsRoot()).path, relative);
