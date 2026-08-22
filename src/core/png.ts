import { deflateSync } from 'node:zlib';

/// A minimal PNG encoder.
///
/// Here because the build needs an icon FILE and the only rasteriser in reach
/// is inside a browser window — which is a lot of machinery to start, and one
/// more thing to go wrong in CI, for a square with five rectangles in it.
///
/// Truecolour with alpha, no interlacing, one filter type. That is the whole
/// PNG feature set an app icon needs.
export function encodePNG(rgba: Uint8Array, width: number, height: number): Buffer {
  // Each scanline is prefixed with its filter type. Type 0 (none) costs a few
  // kilobytes against type 4 and removes the only part of PNG encoding that is
  // easy to get subtly wrong.
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y += 1) {
    const at = y * (width * 4 + 1);
    raw[at] = 0;
    Buffer.from(rgba.buffer, rgba.byteOffset + y * width * 4, width * 4).copy(raw, at + 1);
  }

  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;    // bit depth
  header[9] = 6;    // colour type: truecolour with alpha
  header[10] = 0;   // deflate
  header[11] = 0;   // adaptive filtering
  header[12] = 0;   // no interlace

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function chunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([length, body, crc]);
}

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer: Buffer): number {
  let c = -1;
  for (let index = 0; index < buffer.length; index += 1) {
    c = CRC_TABLE[(c ^ buffer[index]!) & 0xff]! ^ (c >>> 8);
  }
  return (c ^ -1) >>> 0;
}
