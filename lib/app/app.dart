import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

/// App shell — Material 3 + go_router + light/dark themes.
///
/// The editor keeps the system theme for chrome only; the PAPER shade is a
/// per-document property users pick explicitly (dark ink on dark paper is a
/// readability hazard the app refuses to create automatically).
class NanoteApp extends StatelessWidget {
  const NanoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Nanote',
      debugShowCheckedModeBanner: false,
      theme: nanoteTheme(Brightness.light),
      darkTheme: nanoteTheme(Brightness.dark),
      routerConfig: nanoteRouter,
    );
  }
}
