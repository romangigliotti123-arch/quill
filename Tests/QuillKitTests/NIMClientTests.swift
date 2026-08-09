import Foundation
import Testing
@testable import QuillKit

// Everything here is offline and deterministic. The live behaviour — real
// latency, real 404s, real reasoning-model responses — is proved by the
// benchmark harness, not by the test suite, because a suite that needs NVIDIA
// to be up is a suite that fails on a train.

// MARK: - Key loading

@Test func keyPrefersTheEnvironmentOverTheFile() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-key-\(UUID().uuidString).txt")
    try "from-file".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let key = NIMKey.load(environment: [NIMKey.environmentVariable: "from-env"], fileURL: file)
    #expect(key == "from-env")
}

@Test func keyFallsBackToTheFileAndTrimsTheTrailingNewline() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-key-\(UUID().uuidString).txt")
    // A key file written by `echo` has a newline on the end; sending that in an
    // Authorization header is a 401 that looks exactly like a wrong key.
    try "nvapi-abc123\n".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(NIMKey.load(environment: [:], fileURL: file) == "nvapi-abc123")
}

@Test func missingKeyIsNilRatherThanAnError() {
    let absent = URL(fileURLWithPath: "/nonexistent/quill/nim-key.txt")
    #expect(NIMKey.load(environment: [:], fileURL: absent) == nil)
}

@Test func emptyKeyFileCountsAsNoKey() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-key-\(UUID().uuidString).txt")
    try "   \n".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(NIMKey.load(environment: [:], fileURL: file) == nil)
}

@Test func fingerprintIdentifiesTheKeyWithoutContainingIt() {
    let key = "nvapi-supersecret-value-do-not-log"
    let print1 = NIMKey.fingerprint(key)
    #expect(print1 == NIMKey.fingerprint(key))
    #expect(print1 != NIMKey.fingerprint(key + "x"))
    // The whole point: no substring of the key survives into the fingerprint.
    for length in 4 ... key.count {
        #expect(!print1.contains(key.prefix(length)))
    }
}

// MARK: - The key never leaves the client

@Test func errorBodiesAreRedactedBeforeTheyCanBeLogged() {
    let key = "nvapi-leaked-key-0123456789"
    let body = Data(#"{"detail":"rejected token nvapi-leaked-key-0123456789 for account x"}"#.utf8)
    let detail = NIMClient.errorDetail(from: body, redacting: key)
    #expect(!detail.contains(key))
    #expect(detail.contains("[redacted]"))
}

@Test func noConfiguredErrorMessageEverContainsAKey() {
    let key = "nvapi-leaked-key-0123456789"
    let messages = [
        NIMError.notConfigured.localizedDescription,
        NIMError.unauthorized.localizedDescription,
        NIMError.offline("no internet connection").localizedDescription,
        NIMError.modelUnavailable(model: "m", detail: "d").localizedDescription,
        NIMError.emptyCompletion(model: "m").localizedDescription,
        NIMError.deadlineExceeded(milliseconds: 250).localizedDescription,
    ]
    for m in messages { #expect(!m.contains(key)) }
}

// MARK: - NVIDIA's two error envelopes

@Test func readsTheRoutingLayerEnvelope() {
    // Real 404 body from integrate.api.nvidia.com for a model that is in
    // /v1/models but not served to this account.
    let body = Data(#"{"status":404,"title":"Not Found","detail":"Function 'abc': Not found for account 'xyz'"}"#.utf8)
    #expect(NIMClient.errorDetail(from: body, redacting: "k").hasPrefix("Function 'abc'"))
}

@Test func readsTheModelServerEnvelope() {
    // Real 503 body: a different shape entirely, from a different layer.
    let body = Data(#"{"error":{"message":"ResourceExhausted: Worker local total request limit reached (17/16)","type":"Service Unavailable","code":503}}"#.utf8)
    #expect(NIMClient.errorDetail(from: body, redacting: "k").contains("ResourceExhausted"))
}

@Test func fallsBackToRawBodyWhenTheEnvelopeIsUnrecognised() {
    #expect(NIMClient.errorDetail(from: Data("<html>502</html>".utf8), redacting: "k").contains("502"))
}

// MARK: - Classification

@Test func networkFailuresAreToldApartFromCredentialFailures() {
    #expect(NIMClient.classify(URLError(.notConnectedToInternet)) == .offline("no internet connection"))
    #expect(NIMClient.classify(URLError(.dnsLookupFailed))
            == .offline("DNS could not resolve integrate.api.nvidia.com"))
    #expect(NIMClient.classify(URLError(.timedOut)) == .offline("the request timed out"))
    #expect(NIMClient.classify(URLError(.cancelled)) == .cancelled)
    // A wifi that answers everything with its own login page is not "offline",
    // and telling the user to check their connection would be wrong.
    #expect(NIMClient.classify(URLError(.secureConnectionFailed))
            == .offline("TLS failed — this looks like a captive portal, not NVIDIA"))
}

// MARK: - Circuit breaker policy

@Test func aDeadlineMissMustNotTripTheBreaker() {
    // Regression. With deadlineExceeded tripping the breaker, two dictations at
    // the coordinator's 250ms deadline — which misses ~89% of the time — switched
    // the AI off for the following minute. Caught by the live harness, not by
    // reading the code.
    #expect(NIMError.deadlineExceeded(milliseconds: 250).trippsBreaker == false)
    #expect(NIMError.offline("x").trippsBreaker == true)
    #expect(NIMError.rateLimited(retryAfter: nil).trippsBreaker == true)
    // A bad key is not a network problem. Short-circuiting on it would hide the
    // one failure the user actually has to act on.
    #expect(NIMError.unauthorized.trippsBreaker == false)
    #expect(NIMError.modelUnavailable(model: "m", detail: "d").trippsBreaker == false)
}

@Test func onlyTransientFailuresAreRetried() {
    #expect(NIMError.rateLimited(retryAfter: 1).isTransient)
    #expect(NIMError.serviceUnavailable(status: 503, detail: "").isTransient)
    #expect(!NIMError.unauthorized.isTransient)
    #expect(!NIMError.modelUnavailable(model: "m", detail: "").isTransient)
    #expect(!NIMError.emptyCompletion(model: "m").isTransient)
}

// MARK: - The dictation path never blocks

@Test func noKeyMeansAnImmediateNilRatherThanAWait() async {
    let client = NIMClient(config: .default, key: nil)
    #expect(client.isConfigured == false)
    #expect(client.keyFingerprint == "none")

    let clock = ContinuousClock()
    let start = clock.now
    let result = await client.cleanedTranscript("Send it to Carlo", deadline: .milliseconds(450))
    let elapsed = start.duration(to: clock.now)

    #expect(result == nil)
    // Not "fast enough" — it must not touch the network at all.
    #expect(elapsed < .milliseconds(50))
}

@Test func emptyInputIsNotWorthARoundTrip() async {
    let client = NIMClient(config: .default, key: "unused-in-this-test")
    #expect(await client.cleanedTranscript("   \n ", deadline: .milliseconds(450)) == nil)
}

// MARK: - Output guard

private let selfCorrection = "Send it to Noah no wait send it to Carlo instead and tell him the bed frames are ready"
private let goodClean = "Send it to Carlo instead and tell him the bed frames are ready."

@Test func acceptsAPlausibleCleanup() {
    #expect(AIOutputGuard.sanitise(goodClean, against: selfCorrection) == goodClean)
}

@Test func unwrapsQuotesLabelsAndCodeFences() {
    // All three observed from real models on this endpoint.
    #expect(AIOutputGuard.sanitise("\"\(goodClean)\"", against: selfCorrection) == goodClean)
    #expect(AIOutputGuard.sanitise("Cleaned text: \(goodClean)", against: selfCorrection) == goodClean)
    #expect(AIOutputGuard.sanitise("```\n\(goodClean)\n```", against: selfCorrection) == goodClean)
}

@Test func doesNotEatQuotesThatArePartOfTheSentence() {
    let input = "tell him to type \"quill\" and then \"enter\""
    let out = "Tell him to type \"quill\" and then \"enter\"."
    #expect(AIOutputGuard.sanitise(out, against: input) == out)
}

@Test func rejectsAModelThatAnsweredInsteadOfCleaning() {
    let essay = "Sure! Here is what I would send to Carlo: Hi Carlo, just letting you know the "
              + "bed frames are ready for collection whenever suits you. Let me know a good time "
              + "and I will get them loaded up. Cheers, Roman"
    #expect(AIOutputGuard.sanitise(essay, against: selfCorrection) == nil)
}

@Test func rejectsASummary() {
    #expect(AIOutputGuard.sanitise("Bed frames ready.", against: selfCorrection) == nil)
}

@Test func rejectsCommentaryAroundTheAnswer() {
    #expect(AIOutputGuard.sanitise("I cleaned this up.\n\n\(goodClean)", against: selfCorrection) == nil)
}

@Test func rejectsEmptyOutput() {
    #expect(AIOutputGuard.sanitise("   \n  ", against: selfCorrection) == nil)
}

// MARK: - Vocabulary preservation

private let vocabTerms = Vocabulary.seed.contextualStrings

@Test func rejectsAnOutputThatNormalisedOneOfRomansWords() {
    // Measured, 20 runs out of 20, on every prompt variant that did not carry an
    // explicit word list: the model turns "nxt" into "next". FastCleaner got it
    // right and the model undoes it, so the model loses.
    let input = "Push the graphify build to Netlify, then check Phy's door for the nxt onboarding records."
    let output = "Push the graphify build to Netlify, then check Phy's door for the next onboarding records."
    #expect(AIOutputGuard.droppedVocabulary(from: input, to: output, terms: vocabTerms) == ["nxt"])
    #expect(AIOutputGuard.sanitise(output, against: input, preserving: vocabTerms) == nil)
}

@Test func rejectsAnOutputThatOnlyChangedTheCasingOfATerm() {
    // "Graphify" appeared in 17 of 20 runs of one prompt variant. The casing is
    // the term, so this is a rejection, not a nitpick.
    let input = "Push the graphify build to Netlify."
    let output = "Push the Graphify build to Netlify."
    #expect(AIOutputGuard.sanitise(output, against: input, preserving: vocabTerms) == nil)
}

@Test func acceptsAnOutputThatKeptEveryTerm() {
    let input = "Push the graphify build to Netlify, then check Phy's door for the nxt onboarding records."
    let output = "Push the graphify build to Netlify. Then check Phy's door for the nxt onboarding records."
    #expect(AIOutputGuard.sanitise(output, against: input, preserving: vocabTerms) == output)
}

@Test func aTermThatWasNeverInTheInputIsNotRequiredInTheOutput() {
    // The check is one-directional on purpose. It asks "did you give back what I
    // gave you", not "did you use my word list".
    #expect(AIOutputGuard.droppedVocabulary(
        from: "Send it to Carlo", to: "Send it to Carlo.", terms: vocabTerms).isEmpty)
}

@Test func theSystemPromptCarriesNoWordList() {
    // Regression on the measured finding: with the list in the prompt, the model
    // spends from it — "Builda Bed" turned up in a sentence about bed frames that
    // never mentioned the brand. Protection is the guard's job, not the prompt's.
    for term in ["Builda Bed", "Craigieburn", "graphify", "Firestore", "nxt"] {
        #expect(!AIConfig.cleanupSystemPrompt.contains(term))
    }
}

@Test func rejectsTheBrandNameThatLeakedOutOfThePrompt() {
    // The measured regression: an earlier system prompt framed the vocabulary as
    // "leave these spellings alone, they are correct", and llama-3.1-8b read it
    // as a substitution list and returned this. The prompt was fixed; the guard
    // is the backstop for the next time a model does something similar.
    #expect(AIOutputGuard.sanitise("Carlo, the Builda Bed frames are ready.", against: selfCorrection) == nil)
}

// MARK: - Config

@Test func defaultsAreTheBenchmarkedOnes() {
    // If someone swaps the model, the benchmark comment on AIConfig no longer
    // describes what ships. Failing here is the reminder to re-measure.
    #expect(AIConfig.default.model == "meta/llama-3.1-8b-instruct")
    #expect(AIConfig.default.temperature == 0)
    #expect(AIConfig.default.chatCompletionsURL.absoluteString
            == "https://integrate.api.nvidia.com/v1/chat/completions")
    #expect(AIConfig.default.modelsURL.absoluteString
            == "https://integrate.api.nvidia.com/v1/models")
}

@Test func theRecommendedDeadlineIsLongerThanTheCoordinatorsCurrentOne() {
    // Measured: 11% of calls land inside 250ms, 97% inside 450ms.
    #expect(AIConfig.recommendedCleanupDeadline > AIConfig.currentCoordinatorDeadline)
    #expect(AIConfig.recommendedCleanupDeadline.milliseconds == 450)
    #expect(AIConfig.currentCoordinatorDeadline.milliseconds == 250)
}
