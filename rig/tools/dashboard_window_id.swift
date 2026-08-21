// Quill's dashboard lives on whichever Space it was opened on, and
// `screencapture` without arguments only ever photographs the current one — which
// is why the first attempts came back showing VS Code. Capturing by window id
// works regardless of Space.
//
// Filtering on width alone was not enough: the menu bar belongs to Quill too when
// it is the active app, and it is 3420 points wide. The dashboard is the one that
// is also tall.
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (id: Int, area: Double) = (0, 0)
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Quill",
          let id = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width > 600, height > 400
    else { continue }
    if width * height > best.area { best = (id, width * height) }
}
if best.id != 0 { print(best.id) }
