import { contextBridge, ipcRenderer } from 'electron';

/// The dashboard's only door.
///
/// One `invoke` and three event subscriptions. Everything the window can reach
/// is enumerated in `src/main/ipc.ts`, which is a file a reviewer can read in
/// one sitting — the point of the design rather than a happy accident.
contextBridge.exposeInMainWorld('quill', {
  platform: process.platform,
  invoke(name: string, payload?: unknown): Promise<unknown> {
    return ipcRenderer.invoke('quill:invoke', { name, payload });
  },
  on(channel: 'settings' | 'speech' | 'focus' | 'activity', handler: (payload: unknown) => void): void {
    ipcRenderer.on(`quill:${channel}`, (_event, payload) => handler(payload));
  },
});
