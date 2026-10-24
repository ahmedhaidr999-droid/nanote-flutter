// gen_icon.mjs — Nanote app icon generator (committed regeneration source)
//
// Produces:
//   /home/z/my-project/nanote/assets/icon/nanote_icon.png             (1024×1024: blue rounded square + white N)
//   /home/z/my-project/nanote/assets/icon/nanote_icon_foreground.png  (1024×1024: transparent bg, white N @ 55% for Android adaptive icon)
//
// Regenerate with:
//   cd /home/z/my-project/icon-tool && bun gen_icon.mjs
//
// Design spec (Nanote brand mark):
//   - Brand blue #155EEF background, full-canvas rounded rect (radius 232, squircle-like).
//   - Bold white "N" drawn geometrically (NO system fonts):
//       * right stem            capsule x 648..744, y 280..744
//       * left stem (lower)     capsule x 280..376, y 472..744
//       * detached dot          capsule x 280..376, y 280..384  (gap of blue y 384..472)
//       * diagonal              stroke (328,496)→(696,720), width 96, round caps
//   - Foreground variant wraps the same glyph in translate(512,512)·scale(0.55)·translate(-512,-512)
//     so the glyph sits in the Android adaptive-icon safe zone (~55% of canvas).

import { createCanvas, loadImage } from '@napi-rs/canvas';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const SIZE = 1024;
const BRAND_BLUE = '#155EEF'; // RGB(21, 94, 239)
const WHITE = '#FFFFFF';

const OUT_MAIN = '/home/z/my-project/nanote/assets/icon/nanote_icon.png';
const OUT_FOREGROUND =
  '/home/z/my-project/nanote/assets/icon/nanote_icon_foreground.png';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a rounded-rect path. Uses native ctx.roundRect when available,
/// otherwise falls back to arcTo corner construction (quadratic-equivalent).
function roundedRectPath(ctx, x, y, w, h, r) {
  ctx.beginPath();
  if (typeof ctx.roundRect === 'function') {
    ctx.roundRect(x, y, w, h, r);
  } else {
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }
}

/// Draw the white "N" glyph in the 1024×1024 design coordinate space.
/// (Callers may pre-transform the context — e.g. the 55% safe-zone scale.)
function drawGlyph(ctx) {
  ctx.fillStyle = WHITE;

  // Right stem: full glyph height. Width 96 (stroke thickness), radius 48 → capsule ends.
  roundedRectPath(ctx, 648, 280, 96, 744 - 280, 48);
  ctx.fill();

  // Left stem, lower part: starts at y=472 (the stem is "short").
  roundedRectPath(ctx, 280, 472, 96, 744 - 472, 48);
  ctx.fill();

  // Detached dot atop the left stem: y 280..384, leaving a visible 88px gap
  // (y 384..472) where the brand blue shows through.
  roundedRectPath(ctx, 280, 280, 96, 384 - 280, 48);
  ctx.fill();

  // Diagonal: from top of left-stem-lower-part (328 = left stem center x,
  // y just below its top) to bottom of right stem (696 = right stem center x,
  // y just inside its bottom). Round caps so it visually joins both stems.
  ctx.strokeStyle = WHITE;
  ctx.lineWidth = 96;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(328, 496);
  ctx.lineTo(696, 720);
  ctx.stroke();
}

/// Main launcher icon: blue rounded square + glyph.
function makeMainIcon() {
  const canvas = createCanvas(SIZE, SIZE);
  const ctx = canvas.getContext('2d');

  // Background — squircle-like rounded rect, radius 232; corners stay transparent.
  ctx.fillStyle = BRAND_BLUE;
  roundedRectPath(ctx, 0, 0, SIZE, SIZE, 232);
  ctx.fill();

  drawGlyph(ctx);
  return canvas;
}

/// Android adaptive-icon foreground: transparent background, glyph scaled
/// into the central ~55% safe zone. Background color comes from
/// adaptive_icon_background (#155EEF) in pubspec.yaml, NOT from this file.
function makeForeground() {
  const canvas = createCanvas(SIZE, SIZE);
  const ctx = canvas.getContext('2d');

  ctx.save();
  ctx.translate(512, 512);
  ctx.scale(0.55, 0.55);
  ctx.translate(-512, -512);
  drawGlyph(ctx);
  ctx.restore();

  return canvas;
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

const near = (v, target, tol = 3) => Math.abs(v - target) <= tol;

/// Load a written PNG, assert 1024×1024, sample named pixels, run assertions.
/// Returns {pass: boolean} and prints a report.
async function verifyPng(file, checks) {
  const img = await loadImage(file);
  const width = img.width;
  const height = img.height;

  const canvas = createCanvas(width, height);
  const ctx = canvas.getContext('2d');
  ctx.drawImage(img, 0, 0);

  let pass = width === SIZE && height === SIZE;

  console.log(`\n=== Verifying ${file} ===`);
  console.log(`dimensions: ${width}x${height} (expected 1024x1024) ${
    width === SIZE && height === SIZE ? '✓' : '✗ FAIL'
  }`);

  for (const { name, x, y, expect, label } of checks) {
    const d = ctx.getImageData(x, y, 1, 1).data;
    const [r, g, b, a] = d;
    const ok = expect(r, g, b, a);
    if (!ok) pass = false;
    console.log(
      `  pixel ${name} (${x},${y}) -> rgba(${r},${g},${b},${a}) ` +
        `expect [${label}] ${ok ? '✓' : '✗ FAIL'}`,
    );
  }
  return { pass };
}

const isWhite = (r, g, b, a) => a === 255 && r >= 250 && g >= 250 && b >= 250;
const isBlue = (r, g, b, a) =>
  a === 255 && near(r, 21) && near(g, 94) && near(b, 239);
const isTransparent = (_r, _g, _b, a) => a === 0;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  // Ensure the output directory exists (it should already, but be safe).
  mkdirSync(dirname(OUT_MAIN), { recursive: true });

  const mainIcon = makeMainIcon();
  const foreground = makeForeground();

  writeFileSync(OUT_MAIN, await mainIcon.encode('png'));
  writeFileSync(OUT_FOREGROUND, await foreground.encode('png'));
  console.log(`Wrote ${OUT_MAIN}`);
  console.log(`Wrote ${OUT_FOREGROUND}`);

  // --- Main icon checks ---
  //  (8,8)      — outside the radius-232 corner arc → transparent
  //  (512,60)   — plain background area → brand blue #155EEF
  //  (328,700)  — center of left stem lower part → white
  //  (328,332)  — center of detached dot → white
  //  (328,428)  — center of the gap between dot and stem → brand blue (proves dot is detached)
  //  (696,600)  — center of right stem → white
  //  (512,608)  — on the diagonal center-line → white
  const main = await verifyPng(OUT_MAIN, [
    { name: 'corner', x: 8, y: 8, expect: isTransparent, label: 'transparent' },
    { name: 'bg', x: 512, y: 60, expect: isBlue, label: '#155EEF blue' },
    { name: 'left-stem', x: 328, y: 700, expect: isWhite, label: 'white' },
    { name: 'dot', x: 328, y: 332, expect: isWhite, label: 'white' },
    { name: 'gap-blue', x: 328, y: 428, expect: isBlue, label: '#155EEF blue' },
    { name: 'right-stem', x: 696, y: 600, expect: isWhite, label: 'white' },
    { name: 'diagonal', x: 512, y: 608, expect: isWhite, label: 'white' },
  ]);

  // --- Foreground checks (glyph scaled by 0.55 about the canvas center) ---
  //  glyph (328,700) → fg (411,615) : left stem  → white
  //  glyph (328,332) → fg (411,413) : dot         → white
  //  (8,8) and (512,512)            : background  → transparent
  const fg = await verifyPng(OUT_FOREGROUND, [
    { name: 'corner', x: 8, y: 8, expect: isTransparent, label: 'transparent' },
    { name: 'center', x: 512, y: 512, expect: isTransparent, label: 'transparent' },
    { name: 'left-stem(55%)', x: 411, y: 615, expect: isWhite, label: 'white' },
    { name: 'dot(55%)', x: 411, y: 413, expect: isWhite, label: 'white' },
  ]);

  const allPass = main.pass && fg.pass;
  console.log(
    `\n${allPass ? 'ALL VERIFICATIONS PASSED ✓' : 'VERIFICATION FAILED ✗'}`,
  );
  if (!allPass) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
