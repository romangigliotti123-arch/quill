/// The Quill mark, as pixels.
///
/// # Why this is not an SVG
///
/// It was, and the SVG did not rasterise. `nativeImage.createFromDataURL` takes
/// PNG, JPEG and BMP — not SVG — and it does not fail loudly: it returns an
/// EMPTY image, which a tray silently draws as nothing. An app whose icon is a
/// blank square in the menu bar looks broken in the one place a user cannot
/// avoid seeing it, and there is no error anywhere to explain it.
///
/// Rasterising through a hidden `BrowserWindow` would work for the build-time
/// icon and not for the tray, which is rebuilt every time recording starts and
/// stops. So the mark is drawn here instead: one function, no rasteriser, no
/// asset file, usable from the tray, from the build script, and from a test.
///
/// # Why it is drawn rather than shipped as a file
///
/// The Dock icon, the tray icon and the mark inside the window are ONE identity.
/// The moment they are three PNGs, somebody edits one of them and the other two
/// quietly stop matching — with nothing to catch it. Deriving all three from
/// this makes that impossible rather than merely unlikely.

export interface MarkOptions {
  /// Pixel size of the square.
  size: number;
  /// Draw the rounded tile behind the bars. False gives bars alone, which is
  /// what a menu-bar template image wants.
  tile: boolean;
  /// `[r, g, b]`, 0–255.
  tileColour: [number, number, number];
  barColour: [number, number, number];
}

/// How many bars the grid can actually hold.
///
/// Seven bars at 16 pixels would need sub-pixel stripes, which resolve to a
/// smudge no matter how carefully they are anti-aliased. The counts here are
/// what `barRects` can lay out at two whole pixels wide with a whole-pixel gap:
/// three below 20, five below 64, seven above.
function barHeights(size: number): number[] {
  if (size < 20) return [0.44, 0.94, 0.44];
  if (size < 64) return [0.30, 0.66, 0.94, 0.66, 0.30];
  return [0.26, 0.46, 0.74, 0.94, 0.74, 0.46, 0.26];
}

/// Coverage of one pixel by a rounded rectangle, sampled rather than computed.
///
/// 3×3 supersampling. Exact analytic coverage of a rounded corner is a page of
/// arithmetic for a difference nobody can see at any size this is drawn at, and
/// nine samples is enough that a 16-pixel icon has no visible stair-stepping.
function coverage(
  px: number, py: number,
  x: number, y: number, width: number, height: number, radius: number,
): number {
  let hits = 0;
  for (let sy = 0; sy < 3; sy += 1) {
    for (let sx = 0; sx < 3; sx += 1) {
      const cx = px + (sx + 0.5) / 3;
      const cy = py + (sy + 0.5) / 3;
      if (insideRounded(cx, cy, x, y, width, height, radius)) hits += 1;
    }
  }
  return hits / 9;
}

function insideRounded(
  cx: number, cy: number,
  x: number, y: number, width: number, height: number, radius: number,
): boolean {
  if (cx < x || cy < y || cx > x + width || cy > y + height) return false;
  const r = Math.min(radius, width / 2, height / 2);
  if (r <= 0) return true;
  // Only the four corner boxes need the circle test; everything else is inside
  // by the bounds check above.
  const nearestX = cx < x + r ? x + r : (cx > x + width - r ? x + width - r : cx);
  const nearestY = cy < y + r ? y + r : (cy > y + height - r ? y + height - r : cy);
  if (nearestX === cx || nearestY === cy) return true;
  const dx = cx - nearestX;
  const dy = cy - nearestY;
  return dx * dx + dy * dy <= r * r;
}

/// The bar rectangles, snapped to whole pixels at small sizes.
///
/// This is not a nicety. Laid out proportionally, a 22-pixel icon gives bars
/// 1.28 pixels wide with 1.27-pixel gaps — every bar lands half on one pixel
/// and half on the next, and the mark renders as a grey smudge with two black
/// smears in it. Anti-aliasing cannot rescue a stripe pattern finer than the
/// pixel grid; only landing on the grid can.
///
/// Above 64 pixels the proportional layout is right and the snapping would
/// visibly quantise the design, so it is left alone.
function barRects(size: number, inset: number, tileSize: number) {
  const heights = barHeights(size);
  const middle = size / 2;

  if (size >= 64) {
    const span = tileSize * (heights.length >= 7 ? 0.62 : heights.length === 5 ? 0.58 : 0.56);
    const pitch = span / heights.length;
    const width = Math.max(pitch * 0.5, 1);
    const startX = inset + (tileSize - span) / 2 + (pitch - width) / 2;
    return heights.map((factor, index) => {
      const height = Math.max(tileSize * 0.5 * factor, width);
      return {
        x: startX + index * pitch, y: middle - height / 2, width, height, radius: width / 2,
      };
    });
  }

  const width = Math.max(2, Math.round(size * 0.09));
  const gap = Math.max(1, Math.round(width * 0.75));
  const span = heights.length * width + (heights.length - 1) * gap;
  const startX = Math.round((size - span) / 2);
  return heights.map((factor, index) => {
    // Matched parity with the icon, so `(size - height) / 2` is a whole number
    // and every bar is centred on the same axis rather than each one being
    // rounded a different way.
    let height = Math.round(size * 0.5 * factor);
    if ((height % 2) !== (size % 2)) height += 1;
    height = Math.max(height, width);
    return {
      x: startX + index * (width + gap),
      y: (size - height) / 2,
      width,
      height,
      // A 2-pixel bar cannot have a visible round cap; asking for one only
      // knocks the corners off and thins it.
      radius: width >= 4 ? width / 2 : 0,
    };
  });
}

/// RGBA, row-major, `size * size * 4` bytes.
export function drawMark(options: MarkOptions): Uint8Array {
  const { size, tile, tileColour, barColour } = options;
  const pixels = new Uint8Array(size * size * 4);

  const inset = tile ? size * 0.09 : 0;
  const tileSize = size - inset * 2;
  const tileRadius = tileSize * 0.2237;
  const bars = barRects(size, inset, tileSize);

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;

      if (tile) {
        const t = coverage(x, y, inset, inset, tileSize, tileSize, tileRadius);
        if (t > 0) {
          r = tileColour[0];
          g = tileColour[1];
          b = tileColour[2];
          a = t;
        }
      }

      let barCover = 0;
      for (const bar of bars) {
        barCover = Math.max(barCover, coverage(x, y, bar.x, bar.y, bar.width, bar.height, bar.radius));
        if (barCover >= 1) break;
      }
      if (barCover > 0) {
        // Source-over: the bar sits on the tile where there is one, and on
        // nothing where there is not.
        const outAlpha = barCover + a * (1 - barCover);
        r = (barColour[0] * barCover + r * a * (1 - barCover)) / (outAlpha || 1);
        g = (barColour[1] * barCover + g * a * (1 - barCover)) / (outAlpha || 1);
        b = (barColour[2] * barCover + b * a * (1 - barCover)) / (outAlpha || 1);
        a = outAlpha;
      }

      const offset = (y * size + x) * 4;
      pixels[offset] = Math.round(r);
      pixels[offset + 1] = Math.round(g);
      pixels[offset + 2] = Math.round(b);
      pixels[offset + 3] = Math.round(a * 255);
    }
  }
  return pixels;
}

/// Electron's `createFromBitmap` wants BGRA rather than RGBA, and gets it
/// silently wrong rather than complaining — a red icon where a teal one should
/// be is the tell.
export function rgbaToBgra(pixels: Uint8Array): Uint8Array {
  const out = new Uint8Array(pixels.length);
  for (let index = 0; index < pixels.length; index += 4) {
    out[index] = pixels[index + 2]!;
    out[index + 1] = pixels[index + 1]!;
    out[index + 2] = pixels[index]!;
    out[index + 3] = pixels[index + 3]!;
  }
  return out;
}
