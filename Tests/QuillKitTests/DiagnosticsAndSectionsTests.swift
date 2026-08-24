import AppKit
import Testing
@testable import QuillKit

// The two sections that were placeholders until today, and the health check the
// Help screen is built on.

// MARK: - Diagnostics

@Test func everyPermissionGetsACheckAndSoDoTheTwoSilentBlockers() {
    let checks = Diagnostics.run()
    for permission in Permission.allCases {
        #expect(checks.contains { $0.title == permission.rawValue },
                "no check for \(permission.rawValue)")
    }
    // These two are why the screen exists. Neither is a permission, neither
    // raises an error, and either one makes the dictation key silently dead.
    #expect(checks.contains { $0.title == "Secure Input" })
    #expect(checks.contains { $0.title == "Event tap" })
}

@Test func nothingIsReportedAsBrokenWithoutSayingWhatToDo() {
    for check in Diagnostics.run() where check.status != .pass {
        #expect(check.remedy != nil, "\(check.title) is not passing and offers no remedy")
        #expect(!check.detail.isEmpty)
    }
}

@Test func noTwoChecksShareATitle() {
    // Two rows called "Microphone" — the permission and the open device — is how
    // a screen about trust becomes one you have to decode.
    let titles = Diagnostics.run().map(\.title)
    #expect(Set(titles).count == titles.count, "duplicate check titles: \(titles)")
}

// MARK: - Transforms

@Test @MainActor func theTransformsScreenShowsEveryTransformTheEngineHas() {
    let store = TransformStore(inMemory: TransformStore.shared.ordered)
    let view = TransformsSectionView(style: .dark, store: store)
    view.frame = NSRect(origin: .zero, size: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize).size)
    view.layoutSubtreeIfNeeded()

    func rows(_ v: NSView) -> [TransformRowView] {
        v.subviews.flatMap { ($0 as? TransformRowView).map { [$0] } ?? rows($0) }
    }
    #expect(rows(view).count == store.ordered.count)
    #expect(!store.ordered.isEmpty, "the seed catalogue is empty, so this proves nothing")
}

@Test @MainActor func aTransformThatCannotWorkOfflineSaysSoRatherThanLookingIdentical() {
    // The offline column is the one Flow structurally cannot fill in, so it is
    // the one that must never be quietly blank.
    let offline = Transform(name: "Bullets", instruction: "x", triggers: ["a"], keywords: [],
                            offline: .bulletList, isBuiltIn: true, useCount: 0, created: Date())
    let online = Transform(name: "Empathise", instruction: "y", triggers: ["b"], keywords: [],
                           offline: .none, isBuiltIn: true, useCount: 0, created: Date())
    #expect(offline.worksOffline)
    #expect(!online.worksOffline)

    func text(_ v: NSView) -> String {
        v.subviews.map { ($0 as? NSTextField)?.attributedStringValue.string ?? text($0) }
            .joined(separator: "\n")
    }
    let refusing = TransformDetailView(transform: online, style: .dark)
    refusing.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
    refusing.layoutSubtreeIfNeeded()
    // Case-insensitive: the claim this pins is that the screen SAYS the transform
    // refuses, not where the sentence happens to start. The copy was shortened
    // from a paragraph of rationale to "Refuses. There is no offline version of
    // this one." and a literal lowercase match turned a copy edit into a failure.
    #expect(text(refusing).lowercased().contains("refuses"))
}

// MARK: - Help

@Test @MainActor func helpNamesWhatIsWrongRatherThanSayingSomethingWentWrong() {
    let blocked = [
        Diagnostics.Check(title: "Secure Input", status: .fail,
                          detail: "On. While it is, macOS refuses every event tap.",
                          remedy: "Quit whatever turned it on."),
        Diagnostics.Check(title: "Event tap", status: .pass, detail: "Installs.", remedy: nil),
    ]
    let view = HelpSectionView(style: .dark, checks: blocked)
    view.frame = NSRect(origin: .zero, size: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize).size)
    view.layoutSubtreeIfNeeded()

    func text(_ v: NSView) -> String {
        v.subviews.map { ($0 as? NSTextField)?.attributedStringValue.string ?? text($0) }
            .joined(separator: "\n")
    }
    let rendered = text(view)
    #expect(rendered.contains("Secure Input"))
    #expect(rendered.contains("stopping Quill working"), "the summary must state the count, not a mood")
    #expect(rendered.contains("Quit whatever turned it on"), "a diagnosis with no treatment is half a screen")
}

@Test @MainActor func helpDoesNotClaimEverythingIsFineWhenItIsNot() {
    let allGood = Permission.allCases.map {
        Diagnostics.Check(title: $0.rawValue, status: .pass, detail: "Granted.", remedy: nil)
    }
    func text(_ v: NSView) -> String {
        v.subviews.map { ($0 as? NSTextField)?.attributedStringValue.string ?? text($0) }
            .joined(separator: "\n")
    }
    let good = HelpSectionView(style: .dark, checks: allGood)
    good.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    good.layoutSubtreeIfNeeded()
    #expect(text(good).contains("in place"))

    let warned = HelpSectionView(style: .dark, checks: allGood + [
        Diagnostics.Check(title: "Input device", status: .warn,
                          detail: "CoreAudio will not name an input device.",
                          remedy: "Check a microphone is connected.")
    ])
    warned.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    warned.layoutSubtreeIfNeeded()
    #expect(!text(warned).contains("Everything Quill needs is in place"))
}

/// Roman, after granting the three permissions one at a time:
/// *"the help tab looks really messed up whenever i grant something."*
///
/// It was. `rebuildGroups()` took the old groups off the screen and left them in
/// the array it packs, so every rebuild appended three more blocks that no
/// longer existed. The column packer still reserved their heights, so the real
/// content slid down by a screenful and the two columns ended up starting at
/// different heights — worse each time, since granting all three permissions
/// rebuilds three times.
///
/// The first layout is always right, which is why every screenshot of this
/// screen looked correct and no test caught it. This one rebuilds before it
/// measures.
@Test @MainActor func grantingAPermissionDoesNotPushTheHelpScreenDown() {
    func checks(_ status: Diagnostics.Check.Status) -> [Diagnostics.Check] {
        Permission.allCases.map {
            Diagnostics.Check(title: $0.rawValue, status: status,
                              detail: status == .pass ? "Granted." : "Denied.",
                              remedy: status == .pass ? nil : "Grant it in System Settings.")
        }
    }
    func groups(in view: NSView) -> [SettingsGroup] {
        (view as? SettingsGroup).map { [$0] } ?? view.subviews.flatMap(groups(in:))
    }

    let view = HelpSectionView(style: .dark, checks: checks(.fail))
    view.frame = NSRect(x: 0, y: 0, width: 1350, height: 850)
    view.layoutSubtreeIfNeeded()
    let firstLayout = groups(in: view).map(\.frame.minY).min()

    // Three grants, three rebuilds — alternating so each one is a real change.
    for status in [Diagnostics.Check.Status.pass, .fail, .pass] {
        view.refresh(with: checks(status))
        view.layoutSubtreeIfNeeded()
    }

    let laidOut = groups(in: view)
    #expect(laidOut.count == 3, "\(laidOut.count) groups on screen; the screen has three")
    #expect(laidOut.map(\.frame.minY).min() == firstLayout,
            "the top of the content moved after a rebuild — dead blocks are still being packed")

    // Both columns start level. Three blocks over two columns means two of them
    // begin at the same y; a hidden block above one of them is what broke that.
    let tops = Set(laidOut.map { ($0.frame.minY * 100).rounded() })
    #expect(tops.count == 2, "the two columns no longer start at the same height")
}

// MARK: - The registry

@Test @MainActor func everySectionInTheSidebarHasAScreenBehindIt() {
    // A section that exists but is not registered renders as a blank pane in the
    // app while still looking finished in its own preview PNG.
    let registry = DashboardSectionRegistry.shared
    for section in DashboardSection.allCases {
        #expect(registry.dashboardView(for: section, style: .dark) != nil,
                "\(section.rawValue) has no view registered")
    }
}

// MARK: - Input devices

@Test func theMicrophonePickerNeverOffersCoreAudiosOwnScratchDevices() {
    // `CADefaultDeviceAggregate-47292-0` turned up in the picker on this Mac,
    // offered as something to choose. It is an aggregate CoreAudio builds for
    // itself while an app is recording — real device ID, real input channels, a
    // process ID in the middle of its name, and no use whatsoever to a person.
    for device in AudioDeviceInfo.inputDevices() {
        #expect(!device.name.hasPrefix("CADefaultDeviceAggregate"),
                "system scratch device offered to the user: \(device.name)")
        #expect(!device.uid.hasPrefix("~"), "private aggregate offered: \(device.uid)")
        #expect(!device.name.isEmpty)
    }
}

// MARK: - The screenshot harness must not report a blank screen as a screen

@Test func aRenderedSectionThatDrewNothingIsCaught() {
    // The harness emitted blank panels for its entire existence and called it
    // success: the section was parented at zero opacity for a cross-fade, AppKit
    // does not draw a transparent subtree, and out came a valid PNG with a zero
    // exit code and a printed path. Every screen "verified by screenshot" in this
    // project was verified against an empty rectangle.
    //
    // So the harness now inspects what it produced. This test holds that check
    // honest from both directions — a flat fill has to fail it, and the real
    // thing has to pass.
    func image(fill: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        fill(context)
        return context.makeImage()!
    }

    let blank = image { context in
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    }
    #expect(DashboardPreviewRenderer.distinctTonesInPanel(of: blank)
              < DashboardPreviewRenderer.blankPanelThreshold)

    let drawn = image { context in
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        for row in 0 ..< 30 {
            context.setFillColor(NSColor(white: 0.2 + Double(row) * 0.02, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: row * 10, width: 400, height: 6))
        }
    }
    #expect(DashboardPreviewRenderer.distinctTonesInPanel(of: drawn)
              >= DashboardPreviewRenderer.blankPanelThreshold)
}

@Test func aLoopbackInputIsAWarningAndNotATick() {
    // An eval run left this Mac's system input on BlackHole 2ch. Every dictation
    // after it recorded perfect digital silence, the app said "nothing was heard,
    // try again", and the one check that could have explained it — the input
    // device — showed a green OK and the words "Listening to BlackHole 2ch."
    //
    // A loopback carries what other applications play into it. Pointing dictation
    // at one is not a marginal setup; it is a microphone that cannot hear.
    #expect(AudioDeviceInfo.isLoopback("BlackHole 2ch"))
    #expect(AudioDeviceInfo.isLoopback("Loopback Audio"))
    #expect(AudioDeviceInfo.isLoopback("Soundflower (2ch)"))
    #expect(AudioDeviceInfo.isLoopback("VB-Cable"))

    #expect(!AudioDeviceInfo.isLoopback("MacBook Air Microphone"))
    #expect(!AudioDeviceInfo.isLoopback("AirPods Pro"))
    #expect(!AudioDeviceInfo.isLoopback("Shure MV7"))
}

// MARK: - MCP

/// The paste-into-Claude prompt has to work for someone who knows nothing about
/// Quill, because that is exactly who Claude is when it reads it.
///
/// Editing `claude_desktop_config.json` by hand means knowing where it is, that
/// it may not exist yet, and that `mcpServers` is a dictionary to merge into
/// rather than replace — three chances to silently drop every other MCP server
/// you had. Handing the job to a Claude with a terminal removes all three, but
/// only if the prompt carries everything it needs.
@Test @MainActor func theClaudePromptCarriesEverythingClaudeWouldHaveToGuess() {
    let prompt = MCPConnectionDetails.claudePrompt

    // The path is read off the running bundle, so under the test runner it is
    // the runner's own — the shape is what can be checked here, and
    // `theCopyablePathPointsAtTheRealServer` below checks the real one.
    #expect(prompt.contains(MCPConnectionDetails.binaryPath))
    #expect(prompt.contains("Contents/MacOS/QuillMCP"))
    #expect(prompt.contains("get_writing_voice"), "the tool it should call to prove the setup worked")
    #expect(prompt.contains("claude mcp add quill"), "Claude Code's own one-liner")
    #expect(prompt.contains("claude_desktop_config.json"), "and where Claude Desktop keeps its config")
    #expect(prompt.contains("merge, don't overwrite"),
            "without this a rewrite of that file drops every other server the user had")
    #expect(prompt.lowercased().contains("signed in"),
            "a signed-out Quill is the one failure that is not a config problem, and looks exactly like one")

    // A `\`-continuation inside a Swift multi-line string joins the lines but
    // keeps the continued line's indentation, so the first version of this
    // pasted with eight spaces sitting in the middle of its sentences. Invisible
    // in the source; only printing the built string shows it.
    for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
        let body = line.drop { $0 == " " }
        #expect(!body.contains("   "), "stray indentation inside a line: \(line)")
    }
}

/// The snippet and the prompt must name one path, and it must be a real file.
@Test @MainActor func theCopyablePathPointsAtTheRealServer() throws {
    #expect(MCPConnectionDetails.configSnippet.contains(MCPConnectionDetails.binaryPath))

    // The shipped bundle, not this test process's. Skipped rather than failed
    // when Quill is not installed, so a fresh clone still runs green.
    let installed = "/Applications/Quill.app/Contents/MacOS/QuillMCP"
    try #require(FileManager.default.fileExists(atPath: installed),
                 "Quill is not installed; nothing to check the path against")
    #expect(FileManager.default.isExecutableFile(atPath: installed))
}
