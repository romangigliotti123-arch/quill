import { Menu, Tray, app, nativeImage, type NativeImage } from 'electron';
import { drawMark, rgbaToBgra } from '../../core/mark';

/// The menu-bar item, on three platforms that each call it something else.
///
/// # What this replaces, and the one thing that genuinely does not port
///
/// macOS has `NSStatusItem`, which is guaranteed to exist and guaranteed to be
/// visible. Windows has a notification-area icon, which is the same thing and
/// works the same way — except that Windows hides new icons in the overflow
/// chevron by default, so a first-run user may have to drag it out.
///
/// Linux is the one that does not port cleanly, and pretending otherwise would
/// be a worse app. There is no tray in Wayland's protocol; what exists is the
/// StatusNotifierItem D-Bus spec, which KDE implements, which GNOME does NOT
/// implement without the AppIndicator extension, and which Electron can only
/// reach when libayatana-appindicator is installed.
///
/// So the tray is treated as a CONVENIENCE, never as the only way in:
///
///   * a global shortcut opens the dashboard whether or not there is a tray,
///   * launching Quill a second time raises the existing window rather than
///     starting a second copy,
///   * and if the tray fails to create, the app says so on the Help screen
///     instead of appearing not to have started.
///
/// An app whose only affordance is an icon the desktop refuses to draw is an
/// app that looks broken to the person who installed it.

export interface TrayActions {
  toggleDashboard(): void;
  toggleDictation(): void;
  isRecording(): boolean;
  undo(): void;
  hasUndo(): boolean;
  quit(): void;
}

export class TrayIcon {
  private tray: Tray | null = null;
  private failed: string | null = null;

  get failureReason(): string | null { return this.failed; }

  create(actions: TrayActions): void {
    try {
      this.tray = new Tray(icon(false));
    } catch (error) {
      this.failed = String(error);
      // eslint-disable-next-line no-console
      console.error('[quill] the tray icon could not be created', error);
      return;
    }
    this.tray.setToolTip('Quill — hold your dictation key and speak');
    // A left click should do the obvious thing. On Linux a left click opens the
    // context menu instead (the platform gives no separate click event through
    // AppIndicator), which is why the menu's first item is the same action.
    this.tray.on('click', () => actions.toggleDashboard());
    this.rebuild(actions);
  }

  rebuild(actions: TrayActions): void {
    if (!this.tray) return;
    const recording = actions.isRecording();
    this.tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open Quill', click: () => actions.toggleDashboard() },
      { type: 'separator' },
      {
        label: recording ? 'Stop dictating' : 'Start dictating',
        click: () => actions.toggleDictation(),
      },
      {
        label: 'Take back the last insertion',
        enabled: actions.hasUndo(),
        click: () => actions.undo(),
      },
      { type: 'separator' },
      { label: `Quill ${app.getVersion()}`, enabled: false },
      { label: 'Quit', click: () => actions.quit() },
    ]));
    this.tray.setImage(icon(recording));
  }

  dispose(): void {
    this.tray?.destroy();
    this.tray = null;
  }
}

/// The mark, drawn rather than shipped as a file.
///
/// A tray icon has to be a template image on macOS (so it inverts with the menu
/// bar), a small mono bitmap on Windows, and whatever the theme wants on Linux.
/// One drawing routine covers all three and cannot drift from the in-app mark
/// the way three asset files would.
///
/// `createFromBitmap` rather than `createFromDataURL` with an SVG: nativeImage
/// does not rasterise SVG and does not say so — it returns an EMPTY image,
/// which a tray draws as nothing at all. An icon that is silently blank in the
/// menu bar is the worst possible failure for the one control a user cannot
/// avoid seeing.
function icon(recording: boolean): NativeImage {
  const size = process.platform === 'win32' ? 16 : 22;
  // Red while recording, on every platform. A template image is tinted by the
  // menu bar and would lose the colour, which is the one moment the colour is
  // the whole message.
  const bar: [number, number, number] = recording ? [209, 80, 60] : [0, 0, 0];
  const pixels = drawMark({ size, tile: false, tileColour: [0, 0, 0], barColour: bar });
  const image = nativeImage.createFromBitmap(Buffer.from(rgbaToBgra(pixels)), {
    width: size,
    height: size,
  });
  // A template image is tinted by macOS to match the menu bar, light or dark.
  // Marking it so on the other platforms would make it invisible, since they
  // draw the bitmap as given.
  if (process.platform === 'darwin' && !recording) image.setTemplateImage(true);
  return image;
}
