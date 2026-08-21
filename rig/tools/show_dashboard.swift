// Opens Quill's dashboard from the command line.
//
// The dashboard is a menu-bar window: `open` on an already-running accessory app
// does not deliver a reopen, so there is no way to get it on screen from a shell
// — which meant the translucency, the whole point of the redesign, could not be
// looked at. The app already listens for this notification so a second launch
// can hand over to the first; posting it directly is the same door.
import Foundation

DistributedNotificationCenter.default().postNotificationName(
    .init("com.romangigliotti.quill.showWindow"), object: nil, userInfo: nil, deliverImmediately: true)
print("posted")
