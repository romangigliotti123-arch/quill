// rig/tools/ptt.swift — synthesise a held push-to-talk modifier.
//
// Both apps under test are push-to-talk on a BARE MODIFIER, which nothing in
// the shell can express: osascript can only send modifiers *with* a key, and a
// plain CGEvent keyDown for keycode 61 is not what a modifier press looks like
// to the OS. A modifier press is a .flagsChanged event carrying the new flag
// set, so that is what this posts.
//
// The device-dependent bits matter. macOS's public masks (.maskAlternate etc.)
// cannot tell left Option from right Option, so an app that watches for RIGHT
// Option specifically — Quill does — will ignore an event that only carries the
// generic bit. The extra raw bits below are from IOLLEvent.h and are the only
// way to say "this physical key".
//
// build:  swiftc -O -o rig/bin/ptt rig/tools/ptt.swift
// usage:  ptt hold 61 3.5     ptt down 61     ptt up 61
//         ptt check           ptt selftest    ptt keycodes

import ApplicationServices
import CoreGraphics
import Foundation

// ── key tables ────────────────────────────────────────────────────────────────

struct ModKey {
    let code: CGKeyCode
    let name: String
    let generic: CGEventFlags
    let presence: CGEventFlags
}

let modKeys: [ModKey] = [
    ModKey(code: 55, name: "left-command",  generic: .maskCommand,      presence: CGEventFlags(rawValue: 0x0000_0008)),
    ModKey(code: 54, name: "right-command", generic: .maskCommand,      presence: CGEventFlags(rawValue: 0x0000_0010)),
    ModKey(code: 56, name: "left-shift",    generic: .maskShift,        presence: CGEventFlags(rawValue: 0x0000_0002)),
    ModKey(code: 60, name: "right-shift",   generic: .maskShift,        presence: CGEventFlags(rawValue: 0x0000_0004)),
    ModKey(code: 58, name: "left-option",   generic: .maskAlternate,    presence: CGEventFlags(rawValue: 0x0000_0020)),
    ModKey(code: 61, name: "right-option",  generic: .maskAlternate,    presence: CGEventFlags(rawValue: 0x0000_0040)),
    ModKey(code: 59, name: "left-control",  generic: .maskControl,      presence: CGEventFlags(rawValue: 0x0000_0001)),
    ModKey(code: 62, name: "right-control", generic: .maskControl,      presence: CGEventFlags(rawValue: 0x0000_2000)),
    ModKey(code: 63, name: "fn",            generic: .maskSecondaryFn,  presence: CGEventFlags(rawValue: 0x0000_0000)),
]

func lookup(_ code: CGKeyCode) -> ModKey? { modKeys.first { $0.code == code } }

func fail(_ msg: String, _ fixes: [String] = []) -> Never {
    FileHandle.standardError.write("FAIL  \(msg)\n".data(using: .utf8)!)
    for f in fixes { FileHandle.standardError.write("      \(f)\n".data(using: .utf8)!) }
    exit(1)
}

// ── permission ────────────────────────────────────────────────────────────────

func requireAccessibility() {
    guard AXIsProcessTrusted() else {
        fail("this process is not trusted for Accessibility, so it cannot post key events.",
             ["The rig drives both apps by synthesising a held modifier; without this",
              "permission every clip records silence and every number is fiction.",
              "",
              "fix: System Settings › Privacy & Security › Accessibility",
              "     add and enable your TERMINAL (Ghostty), not this binary.",
              "     Then fully quit and reopen the terminal — the grant is read at launch."])
    }
}

// ── posting ───────────────────────────────────────────────────────────────────

// `held` is the flag set that should be in effect AFTER this transition, which
// is what a real flagsChanged event carries.
func postModifier(_ key: ModKey, down: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key.code, keyDown: down) else {
        fail("CGEvent could not be created for keycode \(key.code)")
    }
    ev.type = .flagsChanged
    ev.flags = down ? key.generic.union(key.presence) : CGEventFlags(rawValue: 0)
    ev.post(tap: .cghidEventTap)
}

// ── chords ────────────────────────────────────────────────────────────────────
//
// Wispr Flow's push-to-talk is Ctrl+Shift+D — a chord, not a bare modifier — and
// a chord is a different animal: the modifiers arrive as flagsChanged, but the
// letter is a real keyDown that must carry the accumulated flags, and it has to
// STAY down for the whole utterance. Posting the letter without the flags, or
// releasing it early, gets you an app that never starts listening and a run of
// empty transcripts that looks exactly like a broken microphone.

let letterCodes: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

let modAliases: [String: UInt16] = [
    "control": 59, "ctrl": 59, "lcontrol": 59, "rcontrol": 62,
    "shift": 56, "lshift": 56, "rshift": 60,
    "option": 58, "alt": 58, "loption": 58, "roption": 61,
    "command": 55, "cmd": 55, "lcommand": 55, "rcommand": 54,
    "fn": 63,
]

/// "control+shift+d" -> ([ctrl, shift], keycode for d). A bare keycode still works.
func parseSpec(_ spec: String) -> ([ModKey], UInt16?) {
    var mods: [ModKey] = []
    var plain: UInt16?
    for rawPart in spec.lowercased().split(separator: "+") {
        let part = String(rawPart)
        if let code = modAliases[part], let k = lookup(code) { mods.append(k); continue }
        if let code = UInt16(part), let k = lookup(code) { mods.append(k); continue }
        if let code = letterCodes[part] { plain = code; continue }
        if let code = UInt16(part) { plain = code; continue }
        fail("could not understand '\(part)' in '\(spec)'",
             ["expected something like: control+shift+d, or a bare modifier keycode",
              "see: ptt keycodes"])
    }
    return (mods, plain)
}

func postChord(_ mods: [ModKey], _ plain: UInt16?, down: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    if down {
        var flags = CGEventFlags(rawValue: 0)
        for m in mods {
            flags = flags.union(m.generic).union(m.presence)
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: m.code, keyDown: true) {
                ev.type = .flagsChanged
                ev.flags = flags
                ev.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
        if let plain, let ev = CGEvent(keyboardEventSource: src, virtualKey: plain, keyDown: true) {
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    } else {
        var flags = CGEventFlags(rawValue: 0)
        for m in mods { flags = flags.union(m.generic).union(m.presence) }
        if let plain, let ev = CGEvent(keyboardEventSource: src, virtualKey: plain, keyDown: false) {
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
            usleep(8_000)
        }
        // Release in reverse so the flag set stays coherent on the way down.
        for m in mods.reversed() {
            flags = flags.subtracting(m.generic).subtracting(m.presence)
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: m.code, keyDown: false) {
                ev.type = .flagsChanged
                ev.flags = flags
                ev.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
    }
}

// ── selftest ──────────────────────────────────────────────────────────────────
//
// Proves the whole mechanism at the OS level without needing either app: install
// an event tap, post a synthetic right-Option down/up, and confirm the tap sees
// the event WITH the right-Option presence bit set. If this passes, "the rig can
// hold a hotkey" is a measured fact rather than an assumption.

var sawDown = false
var sawUp = false
var probeKey = ModKey(code: 61, name: "right-option", generic: .maskAlternate,
                      presence: CGEventFlags(rawValue: 0x0000_0040))

func selftest() -> Never {
    requireAccessibility()

    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .flagsChanged {
            let f = event.flags
            let isOurKey = event.getIntegerValueField(.keyboardEventKeycode) == Int64(probeKey.code)
            if isOurKey {
                if f.contains(probeKey.generic) && f.rawValue & probeKey.presence.rawValue != 0 {
                    sawDown = true
                } else if sawDown {
                    sawUp = true
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .listenOnly,
                                      eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                      callback: callback, userInfo: nil) else {
        fail("could not create an event tap to observe our own events.",
             ["Usually Secure Input is on (a password field or a terminal with",
              "Secure Keyboard Entry). Turn it off and retry."])
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
        postModifier(probeKey, down: true)
        Thread.sleep(forTimeInterval: 0.25)
        postModifier(probeKey, down: false)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { CFRunLoopStop(CFRunLoopGetCurrent()) }

    let deadline = Date().addingTimeInterval(2.5)
    while Date() < deadline && !(sawDown && sawUp) {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }

    print("  accessibility  : trusted")
    print("  event tap      : created")
    print("  synthetic down : \(sawDown ? "observed with right-Option presence bit" : "NOT OBSERVED")")
    print("  synthetic up   : \(sawUp ? "observed" : "NOT OBSERVED")")
    if sawDown && sawUp {
        print("\n  ok — synthesised push-to-talk is delivered by the OS and is")
        print("  distinguishable as the RIGHT modifier. The rig can drive both apps.")
        exit(0)
    }
    fail("synthetic modifier events were not observed by our own tap.",
         ["The rig cannot hold a push-to-talk key, so no run would capture audio.",
          "Check Secure Input, and that the terminal has Accessibility."])
}

// ── main ──────────────────────────────────────────────────────────────────────

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("usage: ptt hold <keycode|chord> <seconds> | down <spec> | up <spec> | check | selftest | keycodes\n       chord example: control+shift+d")
    exit(2)
}

switch cmd {
case "keycodes":
    for k in modKeys { print(String(format: "  %-3d  %@", k.code, k.name)) }

case "check":
    if AXIsProcessTrusted() {
        print("  accessibility: trusted")
        exit(0)
    }
    fail("accessibility not granted for this process.",
         ["System Settings › Privacy & Security › Accessibility → add your terminal,",
          "then quit and reopen it."])

case "selftest":
    selftest()

case "down", "up":
    requireAccessibility()
    guard args.count >= 2 else { fail("need a keycode or chord (see: ptt keycodes)") }
    if args[1].contains("+") {
        let (mods, plain) = parseSpec(args[1])
        postChord(mods, plain, down: cmd == "down")
    } else {
        guard let code = UInt16(args[1]), let key = lookup(code) else {
            fail("need a supported modifier keycode (see: ptt keycodes)")
        }
        postModifier(key, down: cmd == "down")
    }
    // Do not exit the instant after posting.
    //
    // CGEvent.post hands the event to the window server and returns; delivery to
    // other processes happens after. A process that exits immediately can have
    // its event dropped in that window, and it fails silently — no error, no
    // return value, the keystroke simply never happened.
    //
    // This was losing roughly a quarter of every eval run. The app would receive
    // a key *release* with no matching press, produce no dictation, and the rig
    // would report "Quill produced NO transcript" — a rig bug wearing an app
    // bug's clothes, for most of a day. `ptt hold` never showed it because it
    // sleeps between the press and the release, which is the whole difference.
    Thread.sleep(forTimeInterval: 0.15)

case "hold":
    requireAccessibility()
    guard args.count >= 3, let secs = Double(args[2]) else {
        fail("usage: ptt hold <keycode|chord> <seconds>")
    }
    if args[1].contains("+") {
        let (mods, plain) = parseSpec(args[1])
        postChord(mods, plain, down: true)
        Thread.sleep(forTimeInterval: secs)
        postChord(mods, plain, down: false)
        exit(0)
    }
    guard let code = UInt16(args[1]), let key = lookup(code) else {
        fail("need a supported modifier keycode (see: ptt keycodes)")
    }
    postModifier(key, down: true)
    // A modifier held by a human is re-asserted by the hardware; some apps arm
    // on the transition only, so a single down + sleep is faithful enough, but
    // the flags must stay coherent for the whole window.
    Thread.sleep(forTimeInterval: secs)
    postModifier(key, down: false)

default:
    fail("unknown command: \(cmd)", ["try: ptt selftest"])
}
