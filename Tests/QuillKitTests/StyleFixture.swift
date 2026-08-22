import Foundation
@testable import QuillKit

extension StyleProfile {
    /// A profile that has already learned two things, for the tests that need
    /// one.
    ///
    /// This used to be the app's shipped default — British spelling and
    /// contractions, seeded at full vote weight, because those are two facts
    /// about the author. Which meant the Style screen greeted every other user by
    /// reporting two of somebody else's habits as things it had "learned" about
    /// them, on the day they installed it.
    ///
    /// The tests still want a learned profile to assert against, so it lives
    /// here. The app now starts blank and learns both within a few dictations,
    /// from the user's own words, which is the whole point of the feature.
    static let romanDefault: StyleProfile = {
        var p = StyleProfile(preset: .casual)
        p.spelling = StyleTrait(seeding: .british, votes: StyleProfile.minimumSupport)
        p.contractions = StyleTrait(seeding: true, votes: StyleProfile.minimumSupport)
        return p
    }()
}
