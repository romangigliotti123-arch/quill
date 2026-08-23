/// A WAV reader, for the one thing that cannot be tested without real audio.
///
/// Only what `QUILL_TRANSCRIBE` needs: uncompressed PCM, any channel count, any
/// sample rate, resampled to the 16 kHz mono the model wants. Everything else —
/// ADPCM, µ-law, the extensible header — throws by name rather than returning
/// silence, because silence is what a broken decoder and a quiet recording look
/// like to everything downstream.

export interface WavAudio {
  samples: Float32Array;
  sampleRate: number;
  channels: number;
}

export function decodeWav(buffer: Uint8Array): WavAudio {
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  const tag = (at: number) => String.fromCharCode(...buffer.subarray(at, at + 4));
  if (tag(0) !== 'RIFF' || tag(8) !== 'WAVE') throw new Error('not a WAV file');

  let format = 0;
  let channels = 0;
  let sampleRate = 0;
  let bits = 0;
  let data: Uint8Array | null = null;

  // Chunks, in whatever order this encoder felt like. `fmt ` usually precedes
  // `data` and is not required to.
  let at = 12;
  while (at + 8 <= buffer.length) {
    const id = tag(at);
    const size = view.getUint32(at + 4, true);
    const body = at + 8;
    if (id === 'fmt ') {
      format = view.getUint16(body, true);
      channels = view.getUint16(body + 2, true);
      sampleRate = view.getUint32(body + 4, true);
      bits = view.getUint16(body + 14, true);
      // WAVE_FORMAT_EXTENSIBLE hides the real format code in the extension.
      if (format === 0xfffe && size >= 26) format = view.getUint16(body + 24, true);
    } else if (id === 'data') {
      data = buffer.subarray(body, Math.min(body + size, buffer.length));
    }
    at = body + size + (size % 2); // chunks are word-aligned
  }

  if (!data) throw new Error('the WAV file has no data chunk');
  if (format !== 1 && format !== 3) {
    throw new Error(`unsupported WAV format ${format} — only uncompressed PCM is read here`);
  }

  const frames = Math.floor(data.length / (channels * (bits / 8)));
  const mono = new Float32Array(frames);
  const read = sampleReader(data, bits, format);
  for (let frame = 0; frame < frames; frame += 1) {
    let sum = 0;
    for (let channel = 0; channel < channels; channel += 1) {
      sum += read(frame * channels + channel);
    }
    mono[frame] = sum / channels;
  }
  return { samples: mono, sampleRate, channels };
}

function sampleReader(data: Uint8Array, bits: number, format: number): (index: number) => number {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  if (format === 3 && bits === 32) return (i) => view.getFloat32(i * 4, true);
  if (bits === 16) return (i) => view.getInt16(i * 2, true) / 32_768;
  if (bits === 32) return (i) => view.getInt32(i * 4, true) / 2_147_483_648;
  // 8-bit WAV is unsigned, which is the one that comes back as a loud buzz if
  // it is read as signed.
  if (bits === 8) return (i) => (data[i]! - 128) / 128;
  if (bits === 24) {
    return (i) => {
      const at = i * 3;
      const value = data[at]! | (data[at + 1]! << 8) | (data[at + 2]! << 16);
      return (value & 0x800000 ? value - 0x1000000 : value) / 8_388_608;
    };
  }
  throw new Error(`unsupported WAV bit depth ${bits}`);
}

/// Linear resampling.
///
/// Not the best resampler; good enough for a verification instrument, where the
/// question is whether the words come back and not whether the audio is
/// pristine. The real capture path resamples in the browser's own audio graph,
/// which is better than anything written by hand here.
export function resample(samples: Float32Array, from: number, to: number): Float32Array {
  if (from === to) return samples;
  const ratio = from / to;
  const out = new Float32Array(Math.floor(samples.length / ratio));
  for (let index = 0; index < out.length; index += 1) {
    const source = index * ratio;
    const low = Math.floor(source);
    const high = Math.min(low + 1, samples.length - 1);
    const mix = source - low;
    out[index] = samples[low]! * (1 - mix) + samples[high]! * mix;
  }
  return out;
}
