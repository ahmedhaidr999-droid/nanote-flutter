import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

/// Nanote — offline-first vector notes. No cloud. No AI. No accounts.
///
/// Cold start is intentionally minimal: Isar opens lazily inside the
/// `isar` provider when the library first queries, so the first frame
/// never waits on disk I/O.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: NanoteApp()));
}
