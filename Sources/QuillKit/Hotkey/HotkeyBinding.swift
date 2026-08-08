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
