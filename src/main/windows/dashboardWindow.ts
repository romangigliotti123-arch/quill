import { BrowserWindow, shell } from 'electron';
import { join } from 'node:path';

/// The dashboard.
///
/// Sized to match the macOS build exactly, so a screenshot from either one can
/// be compared with the other, and so the layout breakpoints in the stylesheet
/// mean the same thing on all three platforms.
const SIZE = { width: 1350, height: 850 };
const MINIMUM = { width: 1060, height: 700 };

export class DashboardWindow {
  private window: BrowserWindow | null = null;

  show(): void {
    if (this.window && !this.window.isDestroyed()) {
      if (this.window.isMinimized()) this.window.restore();
      this.window.show();
      this.window.focus();
      return;
    }
    this.window = this.build();
  }

  get isOpen(): boolean {
    return this.window !== null && !this.window.isDestroyed() && this.window.isVisible();
  }

  toggle(): void {
    if (this.isOpen) this.window?.hide();
    else this.show();
  }

  private build(): BrowserWindow {
    const window = new BrowserWindow({
      ...SIZE,
      minWidth: MINIMUM.width,
      minHeight: MINIMUM.height,
      show: false,
      title: 'Quill',
      // A hidden title bar with the traffic lights or the caption buttons still
      // drawn over the content, so the sidebar material runs up behind them the
      // way it does in a native app. On Linux the platform draws no controls at
      // all under this setting, which is why the shell also handles Escape and
      // the tray menu offers "Close window".
      titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'hidden',
      titleBarOverlay: process.platform === 'win32'
        ? { color: '#00000000', symbolColor: '#8a8a8e', height: 52 }
        : false,
      backgroundColor: '#00000000',
      // Vibrancy where the platform has it. The stylesheet paints a solid
      // canvas colour underneath regardless, so a platform without it gets a
      // flat window rather than a transparent hole.
      vibrancy: process.platform === 'darwin' ? 'sidebar' : undefined,
      backgroundMaterial: process.platform === 'win32' ? 'mica' : undefined,
      autoHideMenuBar: true,
      webPreferences: {
        preload: join(__dirname, '..', 'preload', 'dashboard.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        spellcheck: true,
      },
    });

    // A content-policy violation in a renderer is silent unless it is
    // forwarded — the element simply renders wrong, and the DOM still shows the
    // markup that was refused. One `display:flex` dropped this way cost an
    // afternoon; the forwarding is what makes the next one a log line.
    window.webContents.on('console-message', (event) => {
      if (event.level !== 'error' && event.level !== 'warning') return;
      // eslint-disable-next-line no-console
      console.log(`[quill/dashboard] ${event.message}`);
    });

    void window.loadFile(join(__dirname, '..', 'renderer', 'dashboard.html'));
    window.once('ready-to-show', () => window.show());

    // Nothing in this window should ever open a window of its own, and any
    // link that tries goes to the user's browser instead — a renderer that can
    // spawn a `BrowserWindow` is a renderer that can spawn one without a
    // preload.
    window.webContents.setWindowOpenHandler(({ url }) => {
      if (/^https:\/\//.test(url)) void shell.openExternal(url);
      return { action: 'deny' };
    });
    window.webContents.on('will-navigate', (event) => event.preventDefault());

    window.on('closed', () => { this.window = null; });
    return window;
  }

  /// Writes a PNG of every screen to a directory and quits.
  ///
  /// A design that can only be reviewed by launching the app and clicking
  /// through ten tabs is a design nobody reviews, and one that is never
  /// reviewed on the platform it was ported TO is a design that is only right
  /// on the machine it was written on. `QUILL_CAPTURE=<dir>` makes the whole
  /// dashboard inspectable from a shell — including from a Windows or Linux CI
  /// runner, where nobody is sitting in front of it.
  async capture(directory: string, sections: string[]): Promise<void> {
    const window = this.window;
    if (!window || window.isDestroyed()) return;
    const { mkdirSync, writeFileSync } = await import('node:fs');
    const { join } = await import('node:path');
    mkdirSync(directory, { recursive: true });
    for (const section of sections) {
      await window.webContents.executeJavaScript(
        'document.querySelectorAll(".nav-row").forEach((row) => { '
        + `if (row.textContent.trim().toLowerCase() === ${JSON.stringify(section)}) row.click(); });`,
      );
      // The sections render asynchronously — a capture taken before the data
      // lands is a screenshot of an empty pane, which is worse than none.
      await new Promise((resolve) => { setTimeout(resolve, 900); });
      const image = await window.webContents.capturePage();
      writeFileSync(join(directory, `${section}.png`), image.toPNG());
    }
  }

  /// Evaluates one expression in the dashboard and returns its value. See the
  /// `QUILL_PROBE` hook in `main.ts`.
  async evaluate(expression: string): Promise<unknown> {
    const window = this.window;
    if (!window || window.isDestroyed()) return null;
    return window.webContents.executeJavaScript(expression, true);
  }

  send(channel: string, payload: unknown): void {
    if (!this.window || this.window.isDestroyed()) return;
    this.window.webContents.send(channel, payload);
  }

  dispose(): void {
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
    this.window = null;
  }
}
