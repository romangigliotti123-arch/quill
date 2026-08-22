// The speech engine, and the microphone, in one hidden window.
//
// # Why this is a renderer and not the main process
//
// Two things have to live in the same place: the audio and the model.
//
// The audio, because `getUserMedia` and `AudioWorklet` exist only in a renderer.
// Capturing in the main process would mean a native audio module — the thing
// this port is built to avoid, because a native module that has no prebuilt
// binary for the user's machine is an app that will not install.
//
// The model, because it should be next to the audio. Whisper is fed the whole
// buffer from the start on every partial (see `transcribe` below), so the
// alternative is copying a growing Float32Array across an IPC boundary five
// times a second for the length of the dictation. Keeping both here means the
// audio never leaves this window.
//
// # What replaced Apple's SpeechAnalyzer
//
// Whisper, through `@huggingface/transformers`, running on WebGPU where the
// machine has it and WebAssembly where it does not. That is the only speech
// stack that (a) runs offline after a first download, (b) needs no per-platform
// binary, and (c) is actually accurate.
//
// It is a genuinely different shape from Apple's, and the difference drives the
// design below:
//
//   Apple's        streaming. Feed it buffers, it emits revisions as it goes.
//   Whisper's      batch. Hand it audio, get a transcript.
//
// So streaming is built here instead: every `PARTIAL_INTERVAL_MS`, the audio
// captured so far is transcribed from the beginning. That is quadratic work,
// which sounds alarming and is not, for a reason worth writing down — a
// dictation is seconds long, `base.en` transcribes ten seconds of audio in well
// under a second on CPU, and the partials stop the moment the key comes up. The
// cap below keeps a pathological case bounded.
//
// Re-transcribing from the start also produces exactly the semantics the live
// typer was written against: the WHOLE best-so-far text on every update, freely
// revised. That contract is unchanged from the macOS build, which is why
// nothing downstream had to move.

const state = {
  pipeline: null,
  pipelineKey: null,
  loading: null,
  stream: null,
  context: null,
  node: null,
  source: null,
  chunks: [],
  sampleCount: 0,
  running: false,
  session: 0,
  partialTimer: null,
  busy: false,
  lastText: '',
  prompt: null,
  deviceLostReported: false,
};

/// 16 kHz mono is what Whisper expects, and resampling in the browser's own
/// audio graph is both free and better than anything done by hand afterwards.
const SAMPLE_RATE = 16_000;

/// How often a partial is produced.
///
/// Fast enough that words appear while you are still speaking; slow enough that
/// the model is not still working on the previous partial when the next is due.
/// The busy flag below makes overruns harmless rather than cumulative.
const PARTIAL_INTERVAL_MS = 900;

/// Below this there is not enough audio for the model to say anything useful,
/// and asking anyway produces hallucinated fragments — Whisper's characteristic
/// failure on near-silence is to invent a phrase rather than return nothing.
const MINIMUM_PARTIAL_SECONDS = 0.7;

/// Hard ceiling on a single dictation. Two minutes of 16 kHz mono is 7.7 MB of
/// Float32, and a transcribe over it takes long enough that partials stop being
/// partials. Beyond this the audio stops being accumulated and what has been
/// heard is kept — losing the tail of a runaway recording is better than
/// wedging.
const MAXIMUM_SECONDS = 120;

/// Phrases Whisper emits when it is handed silence or noise. They are not
/// transcription, they are the model's training data leaking through, and they
/// must never reach a document.
const HALLUCINATIONS = [
  'thank you.', 'thanks for watching!', 'thank you for watching.',
  'thanks for watching.', 'you', '.', 'bye.', 'so.', 'okay.',
  '[blank_audio]', '[ silence ]', '[music]', '(upbeat music)',
  'subtitles by the amara.org community', 'transcription by castingwords',
];

function send(channel, payload) {
  window.quillSTT.send(channel, payload);
}

function log(message) {
  send('stt:log', String(message));
}

// MARK: - Model

async function ensurePipeline(options) {
  const key = `${options.model}|${options.device}`;
  if (state.pipeline && state.pipelineKey === key) return state.pipeline;
  if (state.loading && state.pipelineKey === key) return state.loading;

  state.pipelineKey = key;
  state.loading = (async () => {
    const { pipeline, env } = await import(options.libraryURL);

    // This window never touches the network. Every request the library makes
    // goes to `models.quill.invalid`, which the main process serves — from disk
    // when the file is already there, and from Hugging Face through Chromium's
    // own network stack when it is not. See `modelProxy.ts` for why: Hugging
    // Face redirects large files to whichever CDN it is using this month, and a
    // content policy that lists them is a list that goes stale into silence.
    env.allowLocalModels = false;
    env.allowRemoteModels = true;
    env.remoteHost = options.modelHost;
    // One cache, in a folder the user can see and delete, rather than two — one
    // here and one in Chromium's opaque storage where "how much disk is this"
    // has no answer.
    env.useBrowserCache = false;
    if (env.backends?.onnx?.wasm) {
      env.backends.onnx.wasm.wasmPaths = options.wasmURL;
      // One thread, and this is a measurement rather than a default.
      //
      // The page IS cross-origin isolated — it is served from an origin with
      // COOP and COEP set, so `SharedArrayBuffer` exists and asking for four
      // threads gives four. Both ways of using them fail on this runtime:
      //
      //   threads on the main thread   the first inference never returns. A
      //                                threaded WASM build starts its pthreads
      //                                from the thread it runs on, and that
      //                                thread has to reach the event loop for
      //                                them to come up. Measured as a hang at
      //                                exactly the 300 s timeout.
      //   threads in a proxy worker    `no available backend found. ERR:
      //                                [wasm] [object Event]` — the worker dies
      //                                at construction.
      //
      // So: one thread, which works, at 1.4x real time for the model this ships
      // with (3.84 s of audio in 5.4 s on an M5, CPU only). The isolation is
      // left in place because it costs nothing and it is the hard part — if a
      // later runtime fixes the worker, this becomes a one-line change rather
      // than a redesign.
      env.backends.onnx.wasm.numThreads = 1;
      env.backends.onnx.wasm.proxy = false;
    }

    log(`backend ${options.device}, isolated=${self.crossOriginIsolated}, threads=${env.backends?.onnx?.wasm?.numThreads}`);

    const wanted = options.device === 'webgpu' && 'gpu' in navigator ? 'webgpu' : 'wasm';
    // The same weights on both backends, and `q8` is not one of them.
    //
    // `q8` is the obvious choice for a CPU backend and it does not load at all:
    // "Missing required scale: model.decoder.embed_tokens.weight_merged_0_scale"
    // out of the runtime's quantisation pass, on the published
    // `decoder_model_merged_quantized.onnx`. `q4` loads on both backends and is
    // the same file for both, so switching between CPU and GPU costs no second
    // download.
    //
    // Measured on 3.84 s of speech, M5 MacBook Air, from the cache:
    //
    //   webgpu  q4 decoder    2.8 s
    //   wasm    q4 decoder    5.4 s
    //   wasm    fp32 decoder  37.1 s   — more accurate, and unusable
    //   wasm    q8 decoder    fails to build a session
    //
    // `QUILL_DTYPE` overrides it, as a JSON object. That is how the table above
    // was measured and how the next runtime version will be checked.
    const dtype = JSON.parse(window.quillSTT.dtypeOverride || 'null')
      ?? { encoder_model: 'fp32', decoder_model_merged: 'q4' };

    const build = async (device) => pipeline('automatic-speech-recognition', options.model, {
      device,
      dtype,
      progress_callback: (progress) => {
        if (!progress || typeof progress.progress !== 'number') return;
        send('stt:progress', {
          file: progress.file ?? '',
          progress: progress.progress,
          status: progress.status ?? '',
        });
      },
    });

    try {
      state.pipeline = await build(wanted);
      send('stt:ready', { device: wanted, model: options.model });
    } catch (error) {
      if (wanted === 'wasm') throw error;
      // WebGPU is missing on a lot of Linux setups and on older Windows
      // drivers, and it fails at pipeline construction rather than at first
      // use. Falling back is silent to the user but not to the log — a model
      // running on the CPU when the user expected the GPU is a five-times
      // latency difference they are entitled to know about.
      log(`WebGPU unavailable, falling back to CPU: ${error}`);
      state.pipeline = await build('wasm');
      send('stt:ready', { device: 'wasm', model: options.model, fellBack: true });
    }
    return state.pipeline;
  })();

  try {
    return await state.loading;
  } finally {
    state.loading = null;
  }
}

// MARK: - Audio

async function openMicrophone(deviceId) {
  const constraints = {
    audio: {
      channelCount: 1,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
    },
  };
  try {
    return await navigator.mediaDevices.getUserMedia(constraints);
  } catch (error) {
    if (deviceId) {
      // The chosen device is gone — unplugged, or a Bluetooth headset that
      // changed profile. Falling back to the system default is what the user
      // means by "just work", and the coordinator stamps the device that was
      // actually used so history never claims a microphone that recorded
      // nothing.
      log(`chosen microphone unavailable (${error}); using the system default`);
      return navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1 } });
    }
    throw error;
  }
}

const WORKLET = `
class QuillCapture extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel && channel.length > 0) {
      let peak = 0;
      for (let i = 0; i < channel.length; i += 1) {
        const value = channel[i] < 0 ? -channel[i] : channel[i];
        if (value > peak) peak = value;
      }
      this.port.postMessage({ samples: channel.slice(0), peak });
    }
    return true;
  }
}
registerProcessor('quill-capture', QuillCapture);
`;

async function startCapture(deviceId) {
  state.stream = await openMicrophone(deviceId);

  // The graph resamples to 16 kHz for us. Doing it by hand afterwards means
  // writing a resampler, and a bad one costs accuracy that no amount of
  // cleanup gets back.
  state.context = new AudioContext({ sampleRate: SAMPLE_RATE });
  const blob = new Blob([WORKLET], { type: 'application/javascript' });
  const url = URL.createObjectURL(blob);
  try {
    await state.context.audioWorklet.addModule(url);
  } finally {
    URL.revokeObjectURL(url);
  }

  state.source = state.context.createMediaStreamSource(state.stream);
  state.node = new AudioWorkletNode(state.context, 'quill-capture');
  state.node.port.onmessage = (event) => {
    if (!state.running) return;
    const { samples, peak } = event.data;
    if (state.sampleCount < MAXIMUM_SECONDS * SAMPLE_RATE) {
      state.chunks.push(samples);
      state.sampleCount += samples.length;
    }
    send('stt:level', peak);
  };
  state.source.connect(state.node);
  // Connected to a zero-gain sink rather than left dangling: some browsers stop
  // pulling from a worklet that is not part of a path to a destination, and the
  // symptom is a microphone that goes quiet after a few seconds.
  const sink = state.context.createGain();
  sink.gain.value = 0;
  state.node.connect(sink);
  sink.connect(state.context.destination);

  // A device that disappears mid-sentence. The track ends, and everything heard
  // before that is still real — the coordinator inserts it and says why it
  // stops where it does.
  for (const track of state.stream.getAudioTracks()) {
    track.addEventListener('ended', () => {
      if (!state.running || state.deviceLostReported) return;
      state.deviceLostReported = true;
      send('stt:inputLost', null);
    });
  }
}

function stopCapture() {
  if (state.node) { state.node.port.onmessage = null; state.node.disconnect(); }
  if (state.source) state.source.disconnect();
  if (state.stream) for (const track of state.stream.getTracks()) track.stop();
  if (state.context) void state.context.close();
  state.node = null;
  state.source = null;
  state.stream = null;
  state.context = null;
}

function collectAudio() {
  const out = new Float32Array(state.sampleCount);
  let offset = 0;
  for (const chunk of state.chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

// MARK: - Transcription

function looksLikeHallucination(text) {
  const lowered = text.trim().toLowerCase();
  if (lowered.length === 0) return true;
  return HALLUCINATIONS.includes(lowered);
}

/// Whether the loaded model accepts a language.
///
/// The `.en` suffix is Whisper's own naming convention for its English-only
/// checkpoints and is what the generation config is keyed on, so it is the same
/// answer the library computes — just reached without asking it.
function isMultilingual(key) {
  const model = String(key ?? '').split('|')[0];
  return !/\.en$/i.test(model);
}

async function transcribe(audio, session) {
  const pipe = state.pipeline;
  if (!pipe) return null;
  const result = await pipe(audio, {
    // Whisper's own biasing channel, and the one thing here that Apple's
    // recogniser accepted and then ignored — measured, the same audio with 0
    // biasing terms and with 25 produced byte-identical text. This one works,
    // which is why the Dictionary is fed to it.
    ...(state.prompt ? { initial_prompt: state.prompt } : {}),
    // `language` and `task` ONLY on a multilingual model. An English-only
    // checkpoint — `base.en`, the default — throws outright when it is given
    // either: "Cannot specify `task` or `language` for an English-only model".
    // Passing them unconditionally made every single dictation on the default
    // model fail, with a message that names a generation config rather than the
    // model choice that caused it.
    ...(isMultilingual(state.pipelineKey) ? { language: 'english', task: 'transcribe' } : {}),
    // Greedy. A beam search costs several times as much for a difference the
    // cleanup pass makes up for anyway, and this runs on the critical path.
    num_beams: 1,
    do_sample: false,
    // Chunked long-form decoding, so a dictation over 30 seconds does not get
    // silently truncated to Whisper's window.
    chunk_length_s: 30,
    stride_length_s: 5,
    return_timestamps: false,
  });
  if (session !== state.session) return null;
  const text = Array.isArray(result) ? (result[0]?.text ?? '') : (result?.text ?? '');
  return typeof text === 'string' ? text.trim() : '';
}

async function emitPartial() {
  if (state.busy || !state.running) return;
  if (state.sampleCount < MINIMUM_PARTIAL_SECONDS * SAMPLE_RATE) return;
  state.busy = true;
  const session = state.session;
  try {
    const text = await transcribe(collectAudio(), session);
    if (text === null || session !== state.session) return;
    if (looksLikeHallucination(text)) return;
    if (text === state.lastText) return;
    state.lastText = text;
    send('stt:partial', { text, isFinal: false });
  } catch (error) {
    log(`partial failed: ${error}`);
  } finally {
    state.busy = false;
  }
}

// MARK: - Commands

async function handle(message) {
  switch (message.command) {
    case 'prepare':
      try {
        await ensurePipeline(message.options);
      } catch (error) {
        log(`prepare failed: ${error && error.stack ? error.stack : error}`);
        send('stt:error', `The speech model could not be loaded: ${error}`);
      }
      return;

    case 'start': {
      state.session += 1;
      const session = state.session;
      state.chunks = [];
      state.sampleCount = 0;
      state.lastText = '';
      state.deviceLostReported = false;
      state.prompt = message.prompt || null;
      try {
        await ensurePipeline(message.options);
        if (session !== state.session) return;
        await startCapture(message.deviceId || null);
        if (session !== state.session) { stopCapture(); return; }
        state.running = true;
        state.partialTimer = setInterval(() => { void emitPartial(); }, PARTIAL_INTERVAL_MS);
        send('stt:started', null);
      } catch (error) {
        stopCapture();
        state.running = false;
        send('stt:error', describeCaptureFailure(error));
      }
      return;
    }

    case 'stop': {
      const session = state.session;
      state.running = false;
      if (state.partialTimer) clearInterval(state.partialTimer);
      state.partialTimer = null;
      const audio = collectAudio();
      stopCapture();
      // Wait for any partial still in flight, so the final transcribe is not
      // queued behind it on a single-threaded WASM backend.
      while (state.busy) await new Promise((resolve) => setTimeout(resolve, 20));
      let text = '';
      try {
        if (audio.length >= MINIMUM_PARTIAL_SECONDS * SAMPLE_RATE) {
          const final = await transcribe(audio, session);
          if (final !== null && !looksLikeHallucination(final)) text = final;
        }
      } catch (error) {
        log(`final transcribe failed: ${error}`);
      }
      send('stt:final', { id: message.id, text });
      return;
    }

    case 'cancel':
      state.session += 1;
      state.running = false;
      if (state.partialTimer) clearInterval(state.partialTimer);
      state.partialTimer = null;
      state.chunks = [];
      state.sampleCount = 0;
      state.lastText = '';
      stopCapture();
      send('stt:cancelled', { id: message.id });
      return;

    // A dictation with no microphone in it.
    //
    // Everything above needs a person holding a key and speaking, which cannot
    // be done on a build machine — and the speech path is the one part of this
    // app whose failure makes the rest pointless. This runs the same pipeline
    // over samples handed in from outside, so `QUILL_TRANSCRIBE` can prove on
    // any platform that the model loads, the model proxy serves it, and
    // the words come back right.
    case 'samples': {
      state.session += 1;
      const session = state.session;
      try {
        await ensurePipeline(message.options);
        const audio = new Float32Array(message.samples);
        const text = await transcribe(audio, session);
        send('stt:final', { id: message.id, text: text ?? '' });
      } catch (error) {
        log(`sample transcribe failed: ${error && error.stack ? error.stack : error}`);
        send('stt:final', { id: message.id, text: '' });
      }
      return;
    }

    case 'devices': {
      let devices = [];
      try {
        // Labels are only populated once permission has been granted, which is
        // why this is asked after a capture rather than at launch.
        devices = (await navigator.mediaDevices.enumerateDevices())
          .filter((device) => device.kind === 'audioinput')
          .map((device) => ({ id: device.deviceId, label: device.label || 'Microphone' }));
      } catch (error) {
        log(`could not list devices: ${error}`);
      }
      send('stt:devices', { id: message.id, devices });
      return;
    }

    default:
      log(`unknown command ${message.command}`);
  }
}

function describeCaptureFailure(error) {
  const name = error && error.name ? error.name : '';
  switch (name) {
    case 'NotAllowedError':
      // `process` does not exist in a sandboxed renderer; the platform comes
      // across the bridge instead.
      return window.quillSTT.platform === 'darwin'
        ? 'Quill was refused the microphone. Grant it in System Settings \u25b8 Privacy & Security \u25b8 Microphone.'
        : 'Quill was refused the microphone. Allow microphone access for Quill in your system settings.';
    case 'NotFoundError':
      return 'No microphone was found.';
    case 'NotReadableError':
      return 'The microphone is in use by another application.';
    case 'OverconstrainedError':
      return 'The chosen microphone is no longer available. Pick another in Settings.';
    default:
      return `The microphone could not be opened: ${error}`;
  }
}

window.quillSTT.onCommand((message) => { void handle(message); });
send('stt:up', null);
