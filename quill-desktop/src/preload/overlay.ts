import { contextBridge, ipcRenderer } from 'electron';
import type { OverlayState } from '../core/contracts';

/// The HUD's only door. It receives states and reports one measurement; it can
/// do nothing else, which is appropriate for a window that floats over every
/// other application on the machine.
contextBridge.exposeInMainWorld('quillOverlay', {
  onState(handler: (state: OverlayState) => void): void {
    ipcRenderer.on('overlay:state', (_event, state: OverlayState) => handler(state));
  },
  reportWidth(width: number): void {
    ipcRenderer.send('overlay:width', width);
  },
});
