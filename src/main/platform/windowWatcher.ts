import { ChildProcess, spawn, spawnSync } from 'node:child_process';

/// Who has the keyboard focus, on three operating systems, without a native
/// module.
///
/// # What this replaces
///
/// The macOS build asked `NSWorkspace.frontmostApplication` for the bundle
/// identifier and process id, and asked the Accessibility API for the focused
/// *element* inside that app. Two things came out of it: the app context (is
/// this a terminal, an editor, or prose?) and the focus-held check that stops
/// live typing scattering half a sentence across two windows.
///
/// Neither API exists off macOS, and neither has a single cross-platform
/// answer. What each platform does have:
///
///   Windows   `GetForegroundWindow` through a long-lived PowerShell host, so
///             the cost is one process for the life of the app rather than one
///             per query.
///   X11       `xprop -root -spy _NET_ACTIVE_WINDOW`, which STREAMS focus
///             changes rather than being polled at all.
///   Wayland   nothing generic. `swaymsg` and `hyprctl` are used where they
///             exist; on GNOME and KDE the answer is honestly "unknown".
///   macOS     `lsappinfo front`, cached, because this app also runs there.
///
/// # What "unknown" means to a caller
///
/// It means *assume nothing changed*. That is the same fallback the macOS build
/// used when the Accessibility API declined to answer, and the reasoning is
/// unchanged: being too strict loses text (live typing abandons a good
/// dictation), being too loose risks typing into the wrong window. On the
/// platforms where the answer is unavailable, live typing therefore behaves as
/// it did on a Mac with AX unavailable — it keeps going, and the paste fallback
/// is what catches a genuinely moved focus.

export interface ActiveWindow {
  /// Executable name on Windows and macOS, WM_CLASS on X11, app_id on Wayland.
  /// Lowercased, no path. This is what `appContextOf` and the style profile are
  /// keyed on.
  process: string;
  /// Window title, when the platform gives one cheaply. Not used for any
  /// decision — only shown in diagnostics — because a title changes as the user
  /// types and would make focus look like it moved constantly.
  title: string | null;
  /// A value that changes when focus moves and does not otherwise. On Windows
  /// it is the process id; on X11 the window id; elsewhere the process name.
  identity: string;
}

type Listener = (window: ActiveWindow | null) => void;

export class WindowWatcher {
  private current: ActiveWindow | null = null;
  private helper: ChildProcess | null = null;
  private poller: NodeJS.Timeout | null = null;
  private readonly listeners: Listener[] = [];
  private started = false;
  /// Set once when the platform has no way to answer, so the failure is
  /// reported to the Help screen instead of being retried forever.
  private unsupportedReason: string | null = null;

  get reason(): string | null { return this.unsupportedReason; }

  start(): void {
    if (this.started) return;
    this.started = true;
    switch (process.platform) {
      case 'win32': this.startWindows(); break;
      case 'darwin': this.startPolling(400, readMacFront); break;
      default: this.startLinux(); break;
    }
  }

  stop(): void {
    this.started = false;
    if (this.poller) clearInterval(this.poller);
    this.poller = null;
    if (this.helper) {
      this.helper.kill();
      this.helper = null;
    }
  }

  onChange(listener: Listener): void { this.listeners.push(listener); }

  /// The last known answer. Never blocks — the whole design is that focus is
  /// tracked in the background and read instantly, because the live typer asks
  /// this several times a second and an unbounded call there froze the macOS
  /// build's own UI for six seconds when the target app was busy.
  get active(): ActiveWindow | null { return this.current; }

  private publish(window: ActiveWindow | null): void {
    const before = this.current?.identity ?? null;
    this.current = window;
    if ((window?.identity ?? null) === before) return;
    for (const listener of this.listeners) listener(window);
  }

  // MARK: Windows

  private startWindows(): void {
    // One PowerShell host for the life of the app, reading a line on stdin and
    // writing the answer on stdout. Spawning `powershell.exe` per query costs
    // 150–400 ms, which is not a price the live-typing path can pay.
    const script = `
$ErrorActionPreference = 'SilentlyContinue'
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class QuillWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
}
"@
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  $h = [QuillWin]::GetForegroundWindow()
  $pid = 0
  [void][QuillWin]::GetWindowThreadProcessId($h, [ref]$pid)
  $name = ''
  try { $name = (Get-Process -Id $pid).ProcessName } catch { $name = '' }
  $sb = New-Object System.Text.StringBuilder 512
  [void][QuillWin]::GetWindowTextW($h, $sb, 512)
  Write-Output ("{0}|{1}|{2}" -f $pid, $name, $sb.ToString())
}`.trim();

    try {
      this.helper = spawn('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script,
      ], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    } catch (error) {
      this.unsupportedReason = `PowerShell could not be started: ${String(error)}`;
      return;
    }

    let buffer = '';
    this.helper.stdout?.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8');
      let newline = buffer.indexOf('\n');
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf('\n');
        if (line.length === 0) continue;
        const [pid, name, ...rest] = line.split('|');
        if (!pid || !name) continue;
        this.publish({
          process: `${name.toLowerCase()}.exe`,
          title: rest.join('|') || null,
          identity: pid,
        });
      }
    });
    this.helper.on('exit', () => {
      this.helper = null;
      if (this.started) this.unsupportedReason = 'the focus helper stopped unexpectedly';
    });

    this.poller = setInterval(() => {
      this.helper?.stdin?.write('\n');
    }, 400);
    this.poller.unref?.();
    this.helper.stdin?.write('\n');
  }

  // MARK: Linux

  private startLinux(): void {
    const session = (process.env.XDG_SESSION_TYPE ?? '').toLowerCase();
    const hasX11 = process.env.DISPLAY !== undefined && session !== 'wayland';

    if (hasX11 && which('xprop')) {
      // `-spy` streams a line every time the active window changes. No polling,
      // no process per query, and it reacts the instant focus moves.
      this.startX11Spy();
      return;
    }
    if (which('swaymsg')) {
      this.startPolling(400, readSway);
      return;
    }
    if (which('hyprctl')) {
      this.startPolling(400, readHyprland);
      return;
    }
    this.unsupportedReason = hasX11
      ? 'xprop is not installed, so Quill cannot see which window is focused. '
        + 'Install x11-utils to get per-app formatting and the focus check.'
      : 'This Wayland compositor does not expose the focused window to other '
        + 'applications. Quill still dictates; it just cannot tell a terminal '
        + 'from a text editor, so everything is formatted as prose.';
  }

  private startX11Spy(): void {
    try {
      this.helper = spawn('xprop', ['-root', '-spy', '_NET_ACTIVE_WINDOW'], {
        stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch (error) {
      this.unsupportedReason = `xprop could not be started: ${String(error)}`;
      return;
    }
    let buffer = '';
    const handle = (): void => {
      let newline = buffer.indexOf('\n');
      while (newline >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf('\n');
        const match = /0x[0-9a-fA-F]+/.exec(line);
        if (!match) continue;
        this.publish(readX11Window(match[0]));
      }
    };
    this.helper.stdout?.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8');
      handle();
    });
    this.helper.on('exit', () => {
      this.helper = null;
      if (this.started) this.unsupportedReason = 'xprop stopped unexpectedly';
    });
    // `-spy` only reports CHANGES, so the first answer has to be asked for.
    const initial = spawnSync('xprop', ['-root', '_NET_ACTIVE_WINDOW'], { encoding: 'utf8' });
    const first = /0x[0-9a-fA-F]+/.exec(initial.stdout ?? '');
    if (first) this.publish(readX11Window(first[0]));
  }

  private startPolling(intervalMs: number, read: () => ActiveWindow | null): void {
    const tick = (): void => { this.publish(read()); };
    tick();
    this.poller = setInterval(tick, intervalMs);
    this.poller.unref?.();
  }
}

// MARK: - Per-platform readers

function which(command: string): boolean {
  const probe = process.platform === 'win32' ? 'where' : 'which';
  try {
    return spawnSync(probe, [command], { stdio: 'ignore' }).status === 0;
  } catch {
    return false;
  }
}

function readX11Window(id: string): ActiveWindow | null {
  if (id === '0x0') return null;
  const result = spawnSync('xprop', ['-id', id, 'WM_CLASS', '_NET_WM_NAME'], { encoding: 'utf8' });
  const output = result.stdout ?? '';
  // WM_CLASS is `"instance", "class"`. The class is the useful half — "Code",
  // "Alacritty", "firefox" — and is what the context table is keyed on.
  const classMatch = /WM_CLASS\(STRING\) = "([^"]*)", "([^"]*)"/.exec(output);
  const titleMatch = /_NET_WM_NAME\(UTF8_STRING\) = "((?:[^"\\]|\\.)*)"/.exec(output);
  const name = (classMatch?.[2] ?? classMatch?.[1] ?? '').toLowerCase();
  if (name.length === 0) return null;
  return { process: name, title: titleMatch?.[1] ?? null, identity: id };
}

function readSway(): ActiveWindow | null {
  const result = spawnSync('swaymsg', ['-t', 'get_tree', '-r'], { encoding: 'utf8' });
  if (result.status !== 0 || !result.stdout) return null;
  try {
    const tree = JSON.parse(result.stdout) as Record<string, unknown>;
    const focused = findFocusedNode(tree);
    if (!focused) return null;
    const name = String(focused.app_id ?? (focused.window_properties as { class?: string } | undefined)?.class ?? '');
    if (name.length === 0) return null;
    return {
      process: name.toLowerCase(),
      title: typeof focused.name === 'string' ? focused.name : null,
      identity: String(focused.id ?? name),
    };
  } catch {
    return null;
  }
}

function findFocusedNode(node: Record<string, unknown>): Record<string, unknown> | null {
  if (node.focused === true) return node;
  for (const key of ['nodes', 'floating_nodes']) {
    const children = node[key];
    if (!Array.isArray(children)) continue;
    for (const child of children) {
      const found = findFocusedNode(child as Record<string, unknown>);
      if (found) return found;
    }
  }
  return null;
}

function readHyprland(): ActiveWindow | null {
  const result = spawnSync('hyprctl', ['activewindow', '-j'], { encoding: 'utf8' });
  if (result.status !== 0 || !result.stdout) return null;
  try {
    const window = JSON.parse(result.stdout) as { class?: string; title?: string; address?: string };
    if (!window.class) return null;
    return {
      process: window.class.toLowerCase(),
      title: window.title ?? null,
      identity: window.address ?? window.class,
    };
  } catch {
    return null;
  }
}

function readMacFront(): ActiveWindow | null {
  // `lsappinfo` is present on every macOS install and answers in a few
  // milliseconds; `osascript` would need Automation permission and takes
  // hundreds.
  const result = spawnSync('lsappinfo', ['front'], { encoding: 'utf8' });
  const handle = (result.stdout ?? '').trim();
  if (handle.length === 0) return null;
  const info = spawnSync('lsappinfo', ['info', '-only', 'name', handle], { encoding: 'utf8' });
  const match = /"LSDisplayName"="([^"]*)"/.exec(info.stdout ?? '');
  const name = match?.[1];
  if (!name) return null;
  return { process: name.toLowerCase(), title: null, identity: handle };
}
