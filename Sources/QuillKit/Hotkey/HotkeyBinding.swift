import CoreGraphics
import Foundation

/// Which key means "dictate", and the flag arithmetic needed to recognise it.
///
/// Only bare modifiers are supported, which is a deliberate constraint: a bare
/// modifier is the one trigger that never collides with normal typing, and it is
/// also the one trigger Carbon's RegisterEventHotKey physically cannot express —
/// hence the event tap next door.
public struct HotkeyBinding: Equatable, Sendable {

    public let keyCode: UInt16

    public init(keyCode: UInt16) {
        self.keyCode = keyCode
    }

    /// Right Option: reachable by the right thumb, unused by every editor, and on
    /// a Mac layout it only ever produces alternate glyphs when combined.
    public static let rightOption = HotkeyBinding(keyCode: 61)

    public static let escapeKeyCode: UInt16 = 53

    /// The generic (side-agnostic) flag this key contributes.
    public var genericMask: CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63:     return .maskSecondaryFn
        default:     return []
        }
    }

    /// The flag to test for "is this specific key down".
    ///
    /// The generic masks cannot tell left from right, so with left Option already
    /// held, releasing right Option still leaves .maskAlternate set and the release
    /// is missed — the recording never stops. These device-dependent bits from
    /// IOLLEvent.h are the only way to ask about one physical key; there is no
    /// Swift constant for them.
    public var presenceMask: CGEventFlags {
        switch keyCode {
        case 55: return CGEventFlags(rawValue: 0x0000_0008) // left ⌘
        case 54: return CGEventFlags(rawValue: 0x0000_0010) // right ⌘
        case 56: return CGEventFlags(rawValue: 0x0000_0002) // left ⇧
        case 60: return CGEventFlags(rawValue: 0x0000_0004) // right ⇧
        case 58: return CGEventFlags(rawValue: 0x0000_0020) // left ⌥
        case 61: return CGEventFlags(rawValue: 0x0000_0040) // right ⌥
        case 59: return CGEventFlags(rawValue: 0x0000_0001) // left ⌃
        case 62: return CGEventFlags(rawValue: 0x0000_2000) // right ⌃
        default: return genericMask
        }
    }

    public var displayName: String {
        switch keyCode {
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 56: return "Left Shift"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "Fn"
        default: return "Key \(keyCode)"
        }
    }

    /// The symbol a Mac user actually reads a modifier as. Written on a keycap
    /// beside the side, because "⌥" alone cannot say which of the two you mean.
    public var glyph: String {
        switch keyCode {
        case 54, 55: return "⌘"
        case 56, 60: return "⇧"
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 63:     return "fn"
        default:     return "?"
        }
    }

    /// "R", "L", or empty for a key that has only one of itself.
    public var sideLabel: String {
        switch keyCode {
        case 55, 56, 58, 59: return "L"
        case 54, 60, 61, 62: return "R"
        default: return ""
        }
    }

    /// Short form for a keycap: "⌥R".
    public var capText: String { glyph + sideLabel }

    /// Every key a user is allowed to bind, in the order they are offered.
    ///
    /// Right-hand modifiers lead because they are the ones no app has claimed —
    /// left ⌘ and left ⌃ are bindable, but binding them means every ⌘C in the
    /// machine now arms a dictation for 120 ms first. They are offered anyway
    /// (the choice is the user's) and the screen says so rather than hiding them.
    public static let assignable: [HotkeyBinding] = [61, 62, 60, 54, 58, 59, 56, 55, 63].map {
        HotkeyBinding(keyCode: $0)
    }

    /// Whether this key is one people type with constantly. Drives the one line
    /// of warning on the settings screen; does not prevent the choice.
    public var isBusyKey: Bool {
        switch keyCode {
        case 55, 56, 58, 59: return true   // every left-hand modifier
        default: return false
        }
    }

    /// Modifiers that make a gesture "not alone". Caps Lock is absent on purpose:
    /// it is a latched state, not something a user is holding, and someone with it
    /// on should still be able to dictate.
    public static let isolationMask: CGEventFlags =
        [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    /// The four modifiers a chord can actually contain.
    ///
    /// Arrow and Return keyDowns arrive with .maskSecondaryFn (and sometimes the
    /// numeric-pad flag) set on a built-in keyboard, so a comparison against raw
    /// flags silently never matches. Everything asking "was anything held with
    /// this key" masks down to these first.
    public static let chordMask: CGEventFlags =
        [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Keycodes whose flagsChanged should abort an in-flight gesture. Caps Lock is
    /// excluded to stay consistent with `isolationMask` — a modifier that cannot
    /// stop a gesture from arming must not be able to abort it either.
    public static func isTrackedModifier(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62, 63: return true
        default: return false
        }
    }
}

/// Where the event tap gets its keys from.
///
/// A protocol rather than a direct reference to the settings singleton so the
/// engine can be driven from a test with fixed bindings, and so nothing on the
/// tap thread has to know that settings live in a JSON file. Read on every
/// keystroke: a cached binding is a binding that needs a relaunch to change.
public protocol HotkeyBindingProviding: AnyObject, Sendable {
    /// Held down while speaking.
    var hold: HotkeyBinding { get }
    /// Tapped once to start and once to stop. May be the same key as `hold`, in
    /// which case it is reached by double-tapping instead.
    var toggle: HotkeyBinding { get }
    /// True while a settings screen is recording a new binding, during which the
    /// engine must ignore every key — otherwise assigning a key also fires it.
    var isCapturingHotkey: Bool { get }
    /// Whether ⌥⌫ may be claimed at all. Read on the tap thread alongside the
    /// bindings, for the same reason they are: a setting that only takes effect
    /// on the next launch is a preference file, not a setting.
    var undoChord: Bool { get }
}

public extension HotkeyBindingProviding {
    /// Default for the test doubles, which care about keys rather than chords.
    var undoChord: Bool { true }
}

/// Fixed bindings, for tests and for anything that must not touch the disk.
public final class StaticHotkeyBindings: HotkeyBindingProviding, @unchecked Sendable {
    public let hold: HotkeyBinding
    public let toggle: HotkeyBinding
    public var isCapturingHotkey: Bool { false }

    public init(hold: HotkeyBinding = .rightOption, toggle: HotkeyBinding = .rightOption) {
        self.hold = hold
        self.toggle = toggle
    }
}
