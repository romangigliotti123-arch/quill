import { contextBridge, ipcRenderer } from 'electron';

/// The speech window's only door.
///
/// `contextIsolation` is on and `nodeIntegration` is off, which is not
/// ceremony: this window downloads a model over the network and then executes
/// WebAssembly from it. Giving that page `require` would put the user's whole
/// filesystem one supply-chain incident away from a speech model.

export interface STTCommand {
  command: 'prepare' | 'start' | 'stop' | 'cancel' | 'devices' | 'samples';
  id?: number;
  deviceId?: string | null;
  prompt?: string | null;
  /// Only for `samples` — 16 kHz mono audio, in place of a microphone.
  samples?: number[];
  options?: {
    model: string;
    device: 'webgpu' | 'wasm';
    libraryURL: string;
    wasmURL: string;
    modelHost: string;
  };
}

contextBridge.exposeInMainWorld('quillSTT', {
  platform: process.platform,
  /// `QUILL_DTYPE`, as a JSON object, for measuring model variants without a
  /// rebuild. The table it produced is in `stt.js` beside the default.
  dtypeOverride: process.env.QUILL_DTYPE ?? '',
  send(channel: string, payload: unknown): void {
    ipcRenderer.send('stt:event', { channel, payload });
  },
  onCommand(handler: (message: STTCommand) => void): void {
    ipcRenderer.on('stt:command', (_event, message: STTCommand) => handler(message));
  },
});
