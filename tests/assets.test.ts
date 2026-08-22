import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';
import { decodeWav, resample } from '../src/core/wav';
import { drawMark, rgbaToBgra } from '../src/core/mark';
import { encodePNG } from '../src/core/png';

// MARK: - WAV
//
// This decoder exists so the speech engine can be checked without a person and
// a microphone, which makes it the thing every platform verification rests on.
// A decoder that quietly returns near-silence would make that verification
// report "no speech found" for a file full of speech.

function wav(options: {
  bits: number; channels: number; rate: number; float?: boolean;
  frames: number[][];
}): Uint8Array {
  const { bits, channels, rate, float = false, frames } = options;
  const bytes = bits / 8;
  const data = Buffer.alloc(frames.length * channels * bytes);
  frames.forEach((frame, index) => {
    frame.forEach((value, channel) => {
      const at = (index * channels + channel) * bytes;
      if (float) data.writeFloatLE(value, at);
      else if (bits === 8) data.writeUInt8(Math.min(255, Math.round(value * 127) + 128), at);
      else if (bits === 16) data.writeInt16LE(Math.round(value * 32_767), at);
      else if (bits === 24) {
        const v = Math.round(value * 8_388_607);
        data.writeUIntLE(v < 0 ? v + 0x1000000 : v, at, 3);
      } else data.writeInt32LE(Math.round(value * 2_147_483_647), at);
    });
  });

  const fmt = Buffer.alloc(16);
  fmt.writeUInt16LE(float ? 3 : 1, 0);
  fmt.writeUInt16LE(channels, 2);
  fmt.writeUInt32LE(rate, 4);
  fmt.writeUInt32LE(rate * channels * bytes, 8);
  fmt.writeUInt16LE(channels * bytes, 12);
  fmt.writeUInt16LE(bits, 14);

  const chunk = (id: string, body: Buffer): Buffer => {
    const header = Buffer.alloc(8);
    header.write(id, 0, 'ascii');
    header.writeUInt32LE(body.length, 4);
    return Buffer.concat([header, body]);
  };
  const rest = Buffer.concat([Buffer.from('WAVE', 'ascii'), chunk('fmt ', fmt), chunk('data', data)]);
  const riff = Buffer.alloc(8);
  riff.write('RIFF', 0, 'ascii');
  riff.writeUInt32LE(rest.length, 4);
  return new Uint8Array(Buffer.concat([riff, rest]));
}

test('every bit depth decodes to the same waveform', () => {
  const frames = [[0], [0.5], [-0.5], [1], [-1]];
  for (const bits of [8, 16, 24, 32]) {
    const audio = decodeWav(wav({ bits, channels: 1, rate: 16_000, frames }));
    assert.equal(audio.sampleRate, 16_000);
    assert.equal(audio.samples.length, 5);
    for (let index = 0; index < frames.length; index += 1) {
      // 8-bit has one part in 128 to work with, so the tolerance is its.
      assert.ok(Math.abs(audio.samples[index]! - frames[index]![0]!) < 0.02,
        `${bits}-bit sample ${index} came back as ${audio.samples[index]}`);
    }
  }
});

test('8-bit is read as unsigned, which is the one that comes back as a buzz', () => {
  // Silence in an 8-bit WAV is the byte 128, not 0. Read as signed it is
  // full-scale, and the file sounds like a square wave.
  const audio = decodeWav(wav({ bits: 8, channels: 1, rate: 16_000, frames: [[0], [0], [0]] }));
  for (const sample of audio.samples) assert.ok(Math.abs(sample) < 0.01);
});

test('float samples are read as floats', () => {
  const audio = decodeWav(wav({
    bits: 32, float: true, channels: 1, rate: 44_100, frames: [[0.25], [-0.75]],
  }));
  assert.ok(Math.abs(audio.samples[0]! - 0.25) < 1e-6);
  assert.ok(Math.abs(audio.samples[1]! + 0.75) < 1e-6);
});

test('stereo is mixed down rather than interleaved', () => {
  // Handing the model an interleaved buffer is not an error anywhere — it is
  // simply the same speech at double speed, transcribed as gibberish.
  const audio = decodeWav(wav({
    bits: 16, channels: 2, rate: 16_000, frames: [[1, -1], [0.5, 0.5]],
  }));
  assert.equal(audio.channels, 2);
  assert.equal(audio.samples.length, 2);
  assert.ok(Math.abs(audio.samples[0]!) < 0.01, 'opposed channels should cancel');
  assert.ok(Math.abs(audio.samples[1]! - 0.5) < 0.01);
});

test('a chunk that is not fmt or data is stepped over, not walked into', () => {
  // `say` and every recorder on macOS write a LIST chunk. Assuming `fmt ` comes
  // first and `data` second reads the metadata as audio.
  const base = Buffer.from(wav({ bits: 16, channels: 1, rate: 16_000, frames: [[0.5], [-0.5]] }));
  const list = Buffer.alloc(8 + 10);
  list.write('LIST', 0, 'ascii');
  list.writeUInt32LE(10, 4);
  const spliced = Buffer.concat([base.subarray(0, 12), list, base.subarray(12)]);
  spliced.writeUInt32LE(spliced.length - 8, 4);
  const audio = decodeWav(new Uint8Array(spliced));
  assert.equal(audio.samples.length, 2);
  assert.ok(Math.abs(audio.samples[0]! - 0.5) < 0.01);
});

test('a compressed WAV says so instead of returning noise', () => {
  const bytes = Buffer.from(wav({ bits: 16, channels: 1, rate: 16_000, frames: [[0]] }));
  bytes.writeUInt16LE(17, 20); // IMA ADPCM
  assert.throws(() => decodeWav(new Uint8Array(bytes)), /unsupported WAV format/);
});

test('resampling changes the length and keeps the shape', () => {
  const source = new Float32Array(44_100);
  for (let index = 0; index < source.length; index += 1) {
    source[index] = Math.sin((2 * Math.PI * 100 * index) / 44_100);
  }
  const out = resample(source, 44_100, 16_000);
  assert.equal(out.length, 16_000);
  // A 100 Hz sine still peaks near 1 and troughs near -1 after resampling; a
  // resampler with an off-by-one in its index arithmetic flattens it.
  assert.ok(Math.max(...out) > 0.95);
  assert.ok(Math.min(...out) < -0.95);
  assert.equal(resample(source, 16_000, 16_000), source, 'a no-op should not copy');
});

// MARK: - The mark

test('a tray-sized mark lands on whole pixels', () => {
  // Laid out proportionally, a 22-pixel icon gives bars 1.28 pixels wide and
  // renders as a grey smudge. Every column has to be fully on or fully off.
  for (const size of [16, 22, 24, 32]) {
    const pixels = drawMark({ size, tile: false, tileColour: [0, 0, 0], barColour: [0, 0, 0] });
    for (let index = 3; index < pixels.length; index += 4) {
      const alpha = pixels[index]!;
      assert.ok(alpha === 0 || alpha === 255,
        `size ${size} has a partly covered pixel (alpha ${alpha})`);
    }
  }
});

test('the mark is not blank, which is the failure that started all this', () => {
  // `nativeImage.createFromDataURL` accepts an SVG, returns an EMPTY image, and
  // reports no error — so the tray drew nothing for as long as that was the way
  // this was done.
  for (const size of [16, 22, 1024]) {
    const pixels = drawMark({ size, tile: size > 64, tileColour: [59, 109, 110], barColour: [255, 255, 255] });
    let opaque = 0;
    for (let index = 3; index < pixels.length; index += 4) if (pixels[index]! > 0) opaque += 1;
    assert.ok(opaque > size, `a ${size}px mark has only ${opaque} visible pixels`);
  }
});

test('a large mark keeps its rounded tile', () => {
  const size = 128;
  const pixels = drawMark({ size, tile: true, tileColour: [59, 109, 110], barColour: [255, 255, 255] });
  const alphaAt = (x: number, y: number) => pixels[(y * size + x) * 4 + 3]!;
  assert.equal(alphaAt(0, 0), 0, 'the corner should be outside the tile');
  assert.equal(alphaAt(size / 2, size / 2), 255, 'the middle should be solid');
});

test('the bitmap handed to Electron is BGRA, not RGBA', () => {
  // `createFromBitmap` swaps them silently. A red icon where a teal one belongs
  // is the only symptom.
  const rgba = new Uint8Array([10, 20, 30, 40]);
  assert.deepEqual([...rgbaToBgra(rgba)], [30, 20, 10, 40]);
});

// MARK: - PNG

test('the PNG encoder writes a file a decoder would accept', () => {
  const size = 4;
  const pixels = drawMark({ size: 64, tile: true, tileColour: [1, 2, 3], barColour: [4, 5, 6] });
  const png = encodePNG(pixels, 64, 64);
  assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(png.subarray(12, 16).toString('ascii'), 'IHDR');
  assert.equal(png.readUInt32BE(16), 64);
  assert.equal(png.readUInt32BE(20), 64);
  assert.equal(png[24], 8, 'bit depth');
  assert.equal(png[25], 6, 'truecolour with alpha');
  assert.equal(png.subarray(png.length - 8, png.length - 4).toString('ascii'), 'IEND');
  void size;
});

test('the pixels survive the round trip', () => {
  const width = 3;
  const height = 2;
  const rgba = new Uint8Array(width * height * 4);
  for (let index = 0; index < rgba.length; index += 1) rgba[index] = (index * 7) % 256;
  const png = encodePNG(rgba, width, height);

  // Pull the IDAT back out and undo the per-scanline filter byte.
  let at = 8;
  let idat = Buffer.alloc(0);
  while (at < png.length) {
    const length = png.readUInt32BE(at);
    const type = png.subarray(at + 4, at + 8).toString('ascii');
    if (type === 'IDAT') idat = Buffer.concat([idat, png.subarray(at + 8, at + 8 + length)]);
    at += length + 12;
  }
  const raw = inflateSync(idat);
  for (let y = 0; y < height; y += 1) {
    const rowAt = y * (width * 4 + 1);
    assert.equal(raw[rowAt], 0, 'filter type should be none');
    for (let x = 0; x < width * 4; x += 1) {
      assert.equal(raw[rowAt + 1 + x], rgba[y * width * 4 + x]);
    }
  }
});
