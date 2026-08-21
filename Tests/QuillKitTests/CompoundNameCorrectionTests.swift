import Testing
@testable import QuillKit

// The compound tool names in FastCleaner.corrections — "get hub" -> "GitHub".
//
// Every entry here is a name the recogniser splits into two ordinary English
// words, which is the one shape neither correction layer can reach:
// VocabularyCorrector refuses single words the spell checker accepts, and a
// two-word span of ordinary English is held to a near-exact bar that "get hub"
// does not clear against "github" by letters alone.
//
// The `mustNotFire` half is the important half. A missed correction costs a
// correction; a false fire rewrites a sentence the user meant and they will not
// notice. Every case below was found firing during development, not invented:
// "I need to get hub caps for the car" really did become "I need to GitHub caps
// for the car" before the anchors were added.

private func clean(_ s: String) -> String { FastCleaner.applyCorrections(to: s) }

@Test func repairsCompoundNamesThatAreNotOrdinaryEnglish() {
    #expect(clean("push it to git hub tonight") == "push it to GitHub tonight")
    #expect(clean("the gethub repo") == "the GitHub repo")
    #expect(clean("the post gres database") == "the Postgres database")
    #expect(clean("deploy to cloud flare") == "deploy to Cloudflare")
    #expect(clean("ask chat gpt about it") == "ask ChatGPT about it")
    #expect(clean("bundle it with web pack") == "bundle it with webpack")
    #expect(clean("open vs code") == "open VS Code")
    #expect(clean("a node js server") == "a Node.js server")
    #expect(clean("built with next js") == "built with Next.js")
    #expect(clean("a three js scene") == "a Three.js scene")
}

@Test func repairsAmbiguousCompoundNamesOnlyWithTheirAnchor() {
    #expect(clean("it is on get hub already") == "it is on GitHub already")
    #expect(clean("check the get hub repo") == "check the GitHub repo")
    #expect(clean("I pushed to get hub") == "I pushed to GitHub")
    #expect(clean("push it to get hub") == "push it to GitHub")
    #expect(clean("rewrite it in type script") == "rewrite it in TypeScript")
    #expect(clean("open the type script file") == "open the TypeScript file")
    #expect(clean("upload it to you tube") == "upload it to YouTube")
    #expect(clean("watch the you tube video") == "watch the YouTube video")
    #expect(clean("check my linked in profile") == "check my LinkedIn profile")
    #expect(clean("sync thing is running") == "Syncthing is running")
    #expect(clean("style it with tail wind") == "style it with Tailwind")
    #expect(clean("put it in air table") == "put it in Airtable")
}

@Test func leavesOrdinaryEnglishContainingThoseWordsAlone() {
    // Each of these fired before the anchors existed.
    let untouched = [
        "I need to get hub caps for the car",
        "I had to get hub caps",
        "we need to get hub bolts",
        "the wheel hub",
        "you tube of toothpaste",
        "can you tube the sample",
        "did you tube feed update",
        "the air table was covered in dust",
        "I linked in the report",
        "a tail wind helped the flight",
        "type script tags by hand",
        "sync thing up later",
    ]
    for sentence in untouched {
        #expect(clean(sentence) == sentence, "rewrote: \(sentence)")
    }
}

// Heard in a real dictation on 21 Aug 2026, in Roman's own voice, reading a
// paragraph written to exercise this table. These are the two misses from that
// run that a literal entry can fix without guessing.
@Test func repairsTheManglingsFromTheFirstRealVoiceRun() {
    #expect(clean("with a fire stall back end") == "with a Firestore back end")
    #expect(clean("the old no. js version") == "the old Node.js version")
    #expect(clean("the old no js version") == "the old Node.js version")
    #expect(clean("a no js server") == "a Node.js server")
}

@Test func doesNotTurnAnOrdinaryNoIntoNode() {
    // "no" answering a question about JavaScript is why those entries are
    // anchored on "version" and "server" rather than matching "no js" alone.
    let untouched = [
        "no js is not required here",
        "the answer is no",
    ]
    for sentence in untouched {
        #expect(clean(sentence) == sentence, "rewrote: \(sentence)")
    }
}

// Second real-voice run, 21 Aug 2026. Same paragraph, different manglings.
@Test func repairsTheManglingsFromTheSecondRealVoiceRun() {
    #expect(clean("Sing thinking is finally keeping my notes")
            == "Syncthing is finally keeping my notes")
    #expect(clean("I rewrote the whole thing in Types Group over the weekend")
            == "I rewrote the whole thing in TypeScript over the weekend")
    #expect(clean("the old note js version") == "the old Node.js version")
}

@Test func leavesTheNetlifyManglingAloneBecauseItIsOrdinaryEnglish() {
    // "not a fly" is a real phrase. An entry mapping it to Netlify would rewrite
    // this sentence, which is worse than leaving "The sites are not a fly" wrong.
    let sentence = "there is a fly in the kitchen and it will not leave"
    #expect(clean(sentence) == sentence)
    #expect(clean("that is not a fly it is a wasp") == "that is not a fly it is a wasp")
}
