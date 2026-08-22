import Foundation
import Testing
@testable import QuillKit

// Roman dictates email addresses and gets prose back. The real failure, from his
// own history on 20 Aug:
//
//   said:     "...send it to the Gmail Grace Kingston 20 at gmail.com?"
//   inserted: "...send it to the Gmail Grace Kingston 20 at gmail. Com?"
//
// The ". Com" half is already fixed. This is the other half: an address he spoke
// should arrive as an address.
//
// The dangerous direction is a false fire. "Meet me at the shop" must never
// become an email, and neither must "I'll look at netlify.com later" — the guard
// is that the step anchors on a DOMAIN and then refuses when the word in front of
// "at" is one that ordinary English puts there.

private func email(_ s: String) -> String { FastCleaner.formatSpokenEmails(in: s) }

// MARK: - The addresses he actually says

@Test func joinsANameAndADottedDomain() {
    #expect(email("Send it to Roman Gigliotti 123 at gmail.com")
            == "Send it to romangigliotti123@gmail.com")
}

@Test func joinsASpokenDomain() {
    #expect(email("my email is roman gigliotti at gmail dot com")
            == "my email is romangigliotti@gmail.com")
}

@Test func keepsADotInsideTheLocalPart() {
    #expect(email("email me at roman dot gigliotti at outlook dot com")
            == "email me at roman.gigliotti@outlook.com")
}

@Test func gluesADomainTheRecogniserSplitInTwo() {
    #expect(email("send the invoice to noah at kass barbers dot com dot au")
            == "send the invoice to noah@kassbarbers.com.au")
}

@Test func stopsAtTheProviderWordInFrontOfTheName() {
    // His real sentence. "Gmail" here names the service, it is not part of the
    // address — walking through it would produce gmailgracekingston20@gmail.com.
    #expect(email("send it to the Gmail Grace Kingston 20 at gmail.com?")
            == "send it to the Gmail gracekingston20@gmail.com?")
}

@Test func keepsTheTrailingPunctuation() {
    #expect(email("is it roman at gmail dot com?") == "is it roman@gmail.com?")
    #expect(email("write to roman at gmail.com.") == "write to roman@gmail.com.")
}

@Test func spokenDigitsInsideAnAddressBecomeDigits() {
    #expect(email("roman gigliotti one two three at gmail dot com")
            == "romangigliotti123@gmail.com")
}

@Test func lowercasesTheWholeAddress() {
    #expect(email("Send To Noah At Gmail Dot Com") == "Send To noah@gmail.com")
}

@Test func handlesACountryDomainAlreadyDotted() {
    #expect(email("invoice noah at kassbarbers.com.au please")
            == "invoice noah@kassbarbers.com.au please")
}

// MARK: - The false fires, which matter more

@Test func aPlaceIsNotAnEmail() {
    #expect(email("meet me at the shop at four") == "meet me at the shop at four")
}

@Test func aVerbBeforeAtRefusesEvenWithARealDomain() {
    // The whole sentence must come through untouched, not merely un-joined.
    #expect(email("I'll look at gmail.com later") == "I'll look at gmail.com later")
    #expect(email("we looked at netlify.com yesterday") == "we looked at netlify.com yesterday")
    #expect(email("it is hosted at netlify.com") == "it is hosted at netlify.com")
}

@Test func aDeterminerBeforeAtRefuses() {
    #expect(email("the docs are at three.js dot org") == "the docs are at three.js dot org")
}

@Test func noDomainMeansNoEmail() {
    #expect(email("I am at home") == "I am at home")
    #expect(email("give me five minutes at most") == "give me five minutes at most")
}

@Test func aSentenceBoundaryStopsTheLocalPart() {
    // "done" ends a sentence; the address begins after it.
    #expect(email("that is done. roman at gmail dot com") == "that is done. roman@gmail.com")
}

@Test func doesNotInventADomainFromAnOrdinaryDottedWord() {
    // node.js is a name, not a mail domain, and nobody is at it.
    #expect(email("the node.js version bump") == "the node.js version bump")
}

@Test func talkingAboutAnAddressDoesNotSwallowTheVerb() {
    // Found by replaying his own dictation history, not by imagining a case. This
    // sentence is him describing the feature, and the first version of the step
    // turned "if I say Roman Gigliotti, 123, at gmail.com" into
    // "if isayromangigliotti123@gmail.com" — the address is right and two of his
    // words are inside it.
    #expect(email("for example, if I say Roman Gigliotti, 123, at gmail.com, it should work")
            == "for example, if I say romangigliotti123@gmail.com, it should work")
}

@Test func anAddressTheRecogniserAlreadyBuiltIsLeftAlone() {
    #expect(email("mail romangigliotti123@gmail.com now")
            == "mail romangigliotti123@gmail.com now")
}

// MARK: - Through the whole cleaner

@Test func survivesTheFullCleanupPipeline() {
    let cleaned = FastCleaner().cleanFast("send it to roman gigliotti at gmail dot com")
    #expect(cleaned == "Send it to romangigliotti@gmail.com")
}

@Test func sentenceCasingDoesNotCapitaliseAnAddress() {
    // The address opens the sentence, so the capitaliser would have taken it.
    let cleaned = FastCleaner().cleanFast("roman at gmail dot com is the address")
    #expect(cleaned == "roman@gmail.com is the address")
}

@Test func theVocabularyCorrectorLeavesAnAddressAlone() {
    // "netlify" is in his dictionary. An address is not a misheard name.
    let corrector = VocabularyCorrector(vocabulary: Vocabulary(terms: ["Netlify", "Craigieburn"]))
    #expect(corrector.correct("mail noah@netlifi.com now") == "mail noah@netlifi.com now")
}

// MARK: - A noun in front of "at" is not an email address

/// The commonest shape in English — NOUN + "at" + DOMAIN — was being turned into
/// a fabricated address, because the stop-word list is determiners, pronouns and
/// verbs and has no entry for an ordinary noun.
///
/// "read the docs at netlify.com" came out "read the docs@netlify.com". Two of
/// these also glue two real words together: "the booking form at
/// kassbarbers.com.au" became "the bookingform@kassbarbers.com.au".
@Test func talkingAboutAWebsiteDoesNotProduceAnEmailAddress() {
    let cleaner = FastCleaner()
    for said in [
        "read the docs at netlify.com",
        "my site at romangigliotti.com",
        "the booking form at kassbarbers.com.au",
        "the pricing page at netlify.com",
        "the status page at firebase.google.com",
    ] {
        let out = cleaner.cleanFast(said)
        #expect(!out.contains("@"), "\(said) → \(out)")
    }
}

/// And the addresses people actually dictate still form. Every one of these
/// carries positive evidence: introduced by "to"/"email", a mail host, or a local
/// part that is not an ordinary English word.
@Test func spokenAddressesStillForm() {
    let cleaner = FastCleaner()
    let cases = [
        "send it to noah at kassbarbers.com.au",
        "email me at roman at gmail dot com",
        "my address is romangigliotti123 at gmail dot com",
        "forward it to accounts at netlify.com",
    ]
    for said in cases {
        let out = cleaner.cleanFast(said)
        #expect(out.contains("@"), "an address stopped forming: \(said) → \(out)")
    }
}
