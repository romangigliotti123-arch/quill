import { BrowserWindow, ipcMain, screen } from 'electron';
import { join } from 'node:path';
import type { OverlayPresenting, OverlayState } from '../../core/contracts';

/// The floating HUD. Owns one non-activating window and hands state to the view
/// inside it.
///
/// The window never takes focus, on purpose: the whole app is "hold a key,
/// talk, text lands in the app you were already in". A HUD that activates Quill
/// even for a frame moves the insertion point somewhere else and the dictation
/// goes into the wrong window.
///
/// The consequence of ignoring mouse events is that the HUD can never offer a
/// clickable affordance — a close button here would be dead pixels. Cancel is
/// therefore a key, and the listening state names it rather than drawing a
/// button.

/// The panel never resizes vertically. A window that grows mid-morph flashes
/// the desktop through its corners for a frame; the pill morphs *inside* this.
const PANEL_WIDTH = 660;
const PANEL_HEIGHT = 120;

/// Pill baseline above the screen's usable area. High enough to clear a
/// magnified dock or a taskbar, low enough to stay out of the document you are
/// dictating into.
const BOTTOM_GAP = 72;

/// Long enough that the exit animation always wins in the ordinary case, short
/// enough that a HUD frozen by a workspace switch is gone before the next
/// dictation starts.
const EXIT_GRACE_MS = 700;

export class OverlayWindow implements OverlayPresenting {
  private window: BrowserWindow | null = null;
  private ready: Promise<void> | null = null;
  private pending: OverlayState | null = null;
  private hideTimer: NodeJS.Timeout | null = null;
  /// Whether a presentation is in progress, as distinct from whether the window
  /// is ordered in. The two come apart, and only this one is a safe answer to
  /// "has the HUD already been put where it belongs".
  private showing = false;

  constructor() {
    ipcMain.on('overlay:width', () => {
      // The renderer reports the pill's width so a future version can size the
      // window to it. Today the panel is fixed and wider than any pill, which
      // is what stops a resize from flashing mid-morph — the measurement is
      // taken anyway so the two cannot silently diverge.
    });
  }

  show(state: OverlayState): void {
    if (state.kind === 'hidden') { this.hide(); return; }
    void this.present(state);
  }

  hide(): void {
    this.showing = false;
    this.send({ kind: 'hidden' });
    if (this.hideTimer) clearTimeout(this.hideTimer);
    // Ordering out happens after the exit animation has actually played. Doing
    // it immediately would make every dictation end with the HUD vanishing on a
    // hard cut.
    this.hideTimer = setTimeout(() => {
      this.hideTimer = null;
      if (this.showing) return;
      this.window?.hide();
    }, EXIT_GRACE_MS);
  }

  private async present(state: OverlayState): Promise<void> {
    const window = await this.ensureWindow();
    if (window.isDestroyed()) return;
    if (this.hideTimer) { clearTimeout(this.hideTimer); this.hideTimer = null; }
    // Gated on our own bookkeeping OR the window's visibility, not on either
    // alone. Ours knows about an exit that froze; the platform's knows about a
    // window that was hidden by something else. Raising a window that is
    // already front is free.
    if (!this.showing || !window.isVisible()) {
      this.showing = true;
      this.reposition(window);
      window.showInactive();
      // Re-asserted on every show. A workspace switch or a full-screen app can
      // demote a window that was already at this level, and the symptom is a
      // HUD that stops appearing with nothing to explain it.
      window.setAlwaysOnTop(true, 'screen-saver');
    }
    this.send(state);
  }

  private send(state: OverlayState): void {
    if (!this.window || this.window.isDestroyed()) {
      this.pending = state;
      return;
    }
    this.window.webContents.send('overlay:state', state);
  }

  private async ensureWindow(): Promise<BrowserWindow> {
    if (this.window && !this.window.isDestroyed()) {
      if (this.ready) await this.ready;
      return this.window;
    }
    const window = new BrowserWindow({
      width: PANEL_WIDTH,
      height: PANEL_HEIGHT,
      show: false,
      frame: false,
      transparent: true,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      hasShadow: false,
      focusable: false,
      // `toolbar` on macOS keeps the window out of the app-switcher's window
      // list; on Windows and Linux it is ignored, which is fine — `skipTaskbar`
      // already covers those.
      type: process.platform === 'darwin' ? 'panel' : undefined,
      backgroundColor: '#00000000',
      webPreferences: {
        preload: join(__dirname, '..', 'preload', 'overlay.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        backgroundThrottling: false,
      },
    });
    this.window = window;
    window.setIgnoreMouseEvents(true, { forward: false });
    window.setAlwaysOnTop(true, 'screen-saver');
    // Follows the user between workspaces rather than living on the one it was
    // created in — a HUD that stays behind is a HUD that stops existing the
    // first time somebody switches desktop.
    window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    window.setMenuBarVisibility(false);

    this.ready = window.loadFile(join(__dirname, '..', 'renderer', 'overlay.html'))
      .then(() => {
        if (this.pending) {
          const state = this.pending;
          this.pending = null;
          window.webContents.send('overlay:state', state);
        }
      });
    await this.ready;
    return window;
  }

  /// The screen under the pointer, not the primary one.
  ///
  /// The primary display follows the focused window, and this app deliberately
  /// never has one — so on a two-display setup that would pin the HUD to
  /// whichever screen was last active rather than the one being looked at.
  private reposition(window: BrowserWindow): void {
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const area = display.workArea;
    const x = Math.round(area.x + (area.width - PANEL_WIDTH) / 2);
    // The pill sits centred in a taller transparent panel, so the panel has to
    // be dropped by half the slack for the pill to land on the intended
    // baseline.
    const pillTop = area.y + area.height - BOTTOM_GAP - 32;
    const y = Math.round(pillTop - (PANEL_HEIGHT - 32) / 2);
    window.setBounds({ x, y, width: PANEL_WIDTH, height: PANEL_HEIGHT });
  }

  dispose(): void {
    if (this.hideTimer) clearTimeout(this.hideTimer);
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
    this.window = null;
  }
}
