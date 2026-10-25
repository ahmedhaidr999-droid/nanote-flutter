# Nanote

**Offline-first, vector-based note-taking app for Android tablets & iPad. 100% local — no cloud, no AI, no accounts.**

تطبيق ملاحظات متجهي يعمل بدون إنترنت بالكامل — بدون سحابة، بدون حسابات.

> Built with Flutter · Isar DB · Riverpod · pdfx

## Features

- Pressure-sensitive vector ink (Catmull-Rom → Bézier, variable-width outlines)
- **8 pen styles**: pen, pencil, calligraphy nib, neon glow, dashed, speed brush, taper, rainbow — plus per-stroke opacity
- Palm rejection: stylus-range lockout, contact-area threshold, finger-drawing toggle
- Pen · Highlighter (multiply blend) · Pixel/Stroke eraser · Lasso (move, scale, rotate, recolor, delete) · Hand · Shapes (line/arrow/rect/ellipse/triangle) · Text · **Sticky notes**
- Floating Notewise-style editor chrome: nav pill, tool pill, contextual rows, page badge with zoom menu, edge arrows, thumbnails rail, read mode
- **Trash** — soft delete, restore, delete forever (XNota parity)
- **Offline export** — whole document to PDF, single page to PNG. No network, no accounts
- Infinite nested folders, grid/list library, sorting & search
- PDF import & annotation — 1000+ page documents, virtualized raster tile cache
- Per-page undo/redo, Material 3 light/dark themes, keep-awake while inking, haptic stroke ticks

## Build

Requires Flutter ≥ 3.22. The `android/` platform folder is generated on demand.

```bash
flutter create --platforms=android --org com.nanote .
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run flutter_launcher_icons
flutter build apk --release
```

CI (GitHub Actions) performs all of the above on every push — grab the ready-made APK from the [Releases](../../releases) page.

## Project layout

```
lib/
  app/            # shell, M3 theme, go_router
  core/
    database/     # Isar collections (Folder, Document, NotePage, Stroke) + provider
    utils/        # path helpers, date labels
  features/
    editor/       # canvas engine: input router, palm rejection, lasso, painters
    library/      # home shelf: folders, documents, create/import flows
    pdf/          # pdfx raster service, LRU tile cache, import pipeline
```

## Brand icon

`assets/icon/nanote_icon.png` — blue rounded square (#155EEF), bold white "N", detached dot atop the left stem. Regenerate with `bun tool/icon/gen_icon.mjs`.
