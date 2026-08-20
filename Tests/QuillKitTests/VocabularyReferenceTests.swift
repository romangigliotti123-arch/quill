import Foundation
import Testing
@testable import QuillKit

// The committed reference vocabulary, checked for the failure mode that has no
// symptom.
//
// `Vocabulary.loadOutcome` maps an unreadable file to `(seed, isDamaged: true)`
// and the app carries on with the shipped 71-term seed. Nothing on screen says
// so. A file that is valid JSON but the wrong shape — a bare array instead of
// `{"terms": [...]}`, say — therefore looks exactly like a working dictionary
// while doing nothing at all, which is the same class of silent failure
// VocabularyBook was written to stop.
//
// This decodes the committed copy the way the app does. It does not read the
// live file in Application Support: a test that depends on a path outside the
// repo passes or fails for reasons that have nothing to do with the commit.

private let referenceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // QuillKitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("rig/vocabulary.reference.json")

@Test func theReferenceVocabularyDecodesRatherThanSilentlyFallingBack() throws {
    let data = try Data(contentsOf: referenceURL)
    let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: data)
    #expect(vocabulary.terms.count > 100, "expected a real list, got \(vocabulary.terms.count)")
    #expect(!vocabulary.terms.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty },
            "a blank term matches nothing and hides a formatting mistake")
}

@Test func theReferenceVocabularyHasNoDuplicates() throws {
    let data = try Data(contentsOf: referenceURL)
    let terms = try JSONDecoder().decode(Vocabulary.self, from: data).terms
    var seen = Set<String>()
    var duplicates: [String] = []
    for term in terms {
        let key = term.lowercased()
        if !seen.insert(key).inserted { duplicates.append(term) }
    }
    // VocabularyBook.add refuses duplicates, but a hand-edited file is not
    // written through it, and a doubled term is dead weight in every scan.
    #expect(duplicates.isEmpty, "duplicated: \(duplicates)")
}

@Test func everyReferenceTermCouldActuallyMatchSomething() throws {
    let data = try Data(contentsOf: referenceURL)
    let terms = try JSONDecoder().decode(Vocabulary.self, from: data).terms
    // bestMatch requires a normalised candidate of at least three characters, so
    // a one- or two-letter term can never be reached however it is spoken.
    let tooShort = terms.filter {
        $0.filter(\.isLetter).count < 3
    }
    #expect(tooShort.isEmpty, "unreachable, shorter than the matcher's floor: \(tooShort)")
}
