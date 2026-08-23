import AppKit

/// Signed out by default, and staying that way changes nothing about Quill —
/// see `AccountStore`'s own doc comment for why. The sign-in/sign-up/sign-out
/// form itself; see `AccountSectionView` for the rest of the Account tab
/// this sits inside — what syncs, what stays local, connected devices, and
/// changing your password.
final class AccountCard: NSView {

    private enum Mode { case signIn, signUp }

    /// Fired once, right after a genuinely NEW account finishes creating —
    /// not on sign-in, even a first one on this Mac. Onboarding uses this to
    /// decide whether to show the MCP intro screen: Roman's ask was "as soon
    /// as they create an account," and someone signing into an account they
    /// already made on another Mac has likely already seen it there.
    var onCreatedAccount: (() -> Void)?

    private let style: DashboardStyle
    private let heading: NSTextField
    private let card: DashboardCardView

    private let emailField: SnippetsField
    private let passwordField: SnippetsField
    private let primary: DashboardButton
    private let toggleMode: DashboardButton
    private let signOut: DashboardButton
    private var status: NSTextField
    private let signedInLabel: NSTextField

    private var mode: Mode = .signIn { didSet { applyMode() } }
    private var account: AccountStore.Account?
    private var isBusy = false { didSet { applyBusy() } }
    private var observerID: UUID?

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        heading = DashboardType.label("Sign in", font: DashboardType.headline, color: style.inkSecondary)
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)

        emailField = SnippetsField(style: style, placeholder: "you@example.com", badgeSymbol: "envelope")
        passwordField = SnippetsField(style: style, placeholder: "Password", badgeSymbol: "lock", isSecure: true)
        primary = DashboardButton(title: "Log In", kind: .primary, style: style)
        toggleMode = DashboardButton(title: "New here? Create an account", kind: .ghost, style: style)
        signOut = DashboardButton(title: "Log Out", kind: .secondary, style: style)
        status = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary,
                                     lines: 2, lineHeight: 16)
        signedInLabel = DashboardType.label("", font: DashboardType.body, color: style.ink)

        super.init(frame: .zero)
        addSubview(heading)
        addSubview(card)
        card.addSubview(emailField)
        card.addSubview(passwordField)
        card.addSubview(primary)
        card.addSubview(toggleMode)
        card.addSubview(signOut)
        card.addSubview(status)
        card.addSubview(signedInLabel)

        primary.onClick = { [weak self] in self?.submit() }
        toggleMode.onClick = { [weak self] in
            guard let self, !self.isBusy else { return }
            self.mode = self.mode == .signIn ? .signUp : .signIn
        }
        signOut.onClick = { [weak self] in self?.performSignOut() }

        applyMode()
        observerID = AccountStore.shared.observe { [weak self] account in
            guard let self else { return }
            self.account = account
            self.setStatus(nil)
            self.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerID { AccountStore.shared.stopObserving(observerID) }
    }

    // MARK: - State

    private func applyMode() {
        primary.title = mode == .signIn ? "Log In" : "Create Account"
        toggleMode.title = mode == .signIn
            ? "New here? Create an account"
            : "Already have an account? Log in"
        setStatus(nil)
        needsLayout = true
    }

    /// `DashboardButton` has no `isEnabled` of its own — every button in this
    /// app is either shown or not. Dimmed to say "busy" without adding a
    /// property the other eleven screens using this control do not need, and
    /// guarded in `submit()` itself so a click queued during the dim cannot
    /// start a second request.
    private func applyBusy() {
        primary.alphaValue = isBusy ? 0.5 : 1
        toggleMode.alphaValue = isBusy ? 0.5 : 1
    }

    private func setStatus(_ text: String?, isError: Bool = false) {
        status.stringValue = text ?? ""
        // No red anywhere else in this app — see OnboardingKeyStep, which
        // answers a failed key check the same way: accentInk for it worked,
        // inkSecondary for it did not. Matched rather than reinvented.
        status.textColor = isError ? style.inkSecondary : style.inkTertiary
        needsLayout = true
    }

    private func submit() {
        guard !isBusy else { return }
        let email = emailField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.text
        guard !email.isEmpty, !password.isEmpty else {
            setStatus("Enter an email and a password.", isError: true)
            return
        }
        isBusy = true
        setStatus(mode == .signIn ? "Logging in…" : "Creating your account…")
        let action = mode
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if action == .signIn {
                    try await AccountStore.shared.signIn(email: email, password: password)
                } else {
                    try await AccountStore.shared.signUp(email: email, password: password)
                    self.onCreatedAccount?()
                }
                // `observe`'s handler clears status and redraws once the auth
                // state listener actually fires; nothing else to do here.
                self.passwordField.text = ""
            } catch {
                self.setStatus(error.localizedDescription, isError: true)
            }
            self.isBusy = false
        }
    }

    private func performSignOut() {
        AccountStore.shared.signOut()
        emailField.text = ""
        passwordField.text = ""
    }

    // MARK: - Layout

    func fittedHeight(width: CGFloat) -> CGFloat {
        26 + 8 + (account == nil ? 216 : 84)
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 2, y: 0, width: bounds.width - 4, height: 24)
        let cardTop: CGFloat = 26 + 8
        card.frame = NSRect(x: 0, y: cardTop, width: bounds.width, height: bounds.height - cardTop)

        let inset: CGFloat = 20
        let inner = bounds.width - inset * 2
        guard inner > 0 else { return }

        let signedIn = account != nil
        emailField.isHidden = signedIn
        passwordField.isHidden = signedIn
        primary.isHidden = signedIn
        toggleMode.isHidden = signedIn
        signedInLabel.isHidden = !signedIn
        signOut.isHidden = !signedIn
        status.isHidden = signedIn && status.stringValue.isEmpty

        if signedIn {
            signedInLabel.stringValue = "Signed in as \(account?.email ?? "")"
            let labelHeight = ceil(signedInLabel.fittingSize.height)
            signedInLabel.frame = NSRect(x: inset, y: 20, width: inner - 100, height: labelHeight)
            let signOutWidth = signOut.intrinsicWidth
            signOut.frame = NSRect(x: bounds.width - inset - signOutWidth, y: 16,
                                   width: signOutWidth, height: 28)
            if !status.stringValue.isEmpty {
                let statusHeight = DashboardType.size(status, width: inner).height
                status.frame = NSRect(x: inset, y: 52, width: inner, height: statusHeight)
            }
            return
        }

        var y: CGFloat = 16
        emailField.frame = NSRect(x: inset, y: y, width: inner, height: 34)
        y += 34 + 8
        passwordField.frame = NSRect(x: inset, y: y, width: inner, height: 34)
        y += 34 + 12

        let primaryWidth = max(120, primary.intrinsicWidth)
        primary.frame = NSRect(x: inset, y: y, width: primaryWidth, height: 30)
        y += 30 + 10

        let toggleHeight: CGFloat = 18
        toggleMode.frame = NSRect(x: inset, y: y, width: inner, height: toggleHeight)
        y += toggleHeight + 8

        if !status.stringValue.isEmpty {
            let statusHeight = DashboardType.size(status, width: inner).height
            status.frame = NSRect(x: inset, y: y, width: inner, height: statusHeight)
        }
    }
}

// MARK: - Change password

/// Visible only while signed in. Re-proves the current password with a
/// normal sign-in before changing it — see `AccountStore.changePassword`.
final class ChangePasswordCard: NSView {

    private let style: DashboardStyle
    private let heading: NSTextField
    private let card: DashboardCardView

    private let currentField: SnippetsField
    private let newField: SnippetsField
    private let confirmField: SnippetsField
    private let submit: DashboardButton
    private var status: NSTextField

    private var isSignedIn = false {
        didSet {
            isHidden = !isSignedIn
            needsLayout = true
            superview?.needsLayout = true
        }
    }
    private var isBusy = false { didSet { submit.alphaValue = isBusy ? 0.5 : 1 } }
    private var observerID: UUID?

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        heading = DashboardType.label("Change password", font: DashboardType.headline, color: style.inkSecondary)
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)

        currentField = SnippetsField(style: style, placeholder: "Current password",
                                     badgeSymbol: "lock", isSecure: true)
        newField = SnippetsField(style: style, placeholder: "New password",
                                 badgeSymbol: "lock.rotation", isSecure: true)
        confirmField = SnippetsField(style: style, placeholder: "Confirm new password",
                                     badgeSymbol: "checkmark", isSecure: true)
        submit = DashboardButton(title: "Update password", kind: .primary, style: style)
        status = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary,
                                     lines: 2, lineHeight: 16)

        super.init(frame: .zero)
        isHidden = true
        addSubview(heading)
        addSubview(card)
        card.addSubview(currentField)
        card.addSubview(newField)
        card.addSubview(confirmField)
        card.addSubview(submit)
        card.addSubview(status)

        submit.onClick = { [weak self] in self?.submitChange() }
        observerID = AccountStore.shared.observe { [weak self] account in
            self?.isSignedIn = account != nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerID { AccountStore.shared.stopObserving(observerID) }
    }

    private func setStatus(_ text: String?, isError: Bool = false) {
        status.stringValue = text ?? ""
        status.textColor = isError ? style.inkSecondary : style.inkTertiary
        needsLayout = true
        superview?.needsLayout = true
    }

    private func submitChange() {
        guard !isBusy else { return }
        let current = currentField.text
        let new = newField.text
        let confirm = confirmField.text
        guard !current.isEmpty, !new.isEmpty else {
            setStatus("Enter your current and new password.", isError: true)
            return
        }
        guard new == confirm else {
            setStatus("The new password and its confirmation don't match.", isError: true)
            return
        }
        isBusy = true
        setStatus("Updating…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AccountStore.shared.changePassword(currentPassword: current, newPassword: new)
                self.currentField.text = ""
                self.newField.text = ""
                self.confirmField.text = ""
                self.setStatus("Password updated.")
            } catch {
                self.setStatus(error.localizedDescription, isError: true)
            }
            self.isBusy = false
        }
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        guard isSignedIn else { return 0 }
        let statusHeight = status.stringValue.isEmpty ? 0
            : DashboardType.size(status, width: width - 40).height + DashboardSpace.sm
        return 26 + 8 + 16 + (34 + 8) * 3 + 4 + 30 + 16 + statusHeight
    }

    override func layout() {
        super.layout()
        guard isSignedIn else { return }
        heading.frame = NSRect(x: 2, y: 0, width: bounds.width - 4, height: 24)
        let cardTop: CGFloat = 26 + 8
        card.frame = NSRect(x: 0, y: cardTop, width: bounds.width, height: bounds.height - cardTop)

        let inset: CGFloat = 20
        let inner = bounds.width - inset * 2
        guard inner > 0 else { return }

        var y: CGFloat = 16
        currentField.frame = NSRect(x: inset, y: y, width: inner, height: 34)
        y += 34 + 8
        newField.frame = NSRect(x: inset, y: y, width: inner, height: 34)
        y += 34 + 8
        confirmField.frame = NSRect(x: inset, y: y, width: inner, height: 34)
        y += 34 + 12

        let submitWidth = max(160, submit.intrinsicWidth)
        submit.frame = NSRect(x: inset, y: y, width: submitWidth, height: 30)
        y += 30 + 10

        if !status.stringValue.isEmpty {
            let statusHeight = DashboardType.size(status, width: inner).height
            status.frame = NSRect(x: inset, y: y, width: inner, height: statusHeight)
        }
    }
}

// MARK: - Devices

/// Every Mac signed into this account, and when it last synced — see
/// `SyncEngine.fetchDevices()`. A snapshot, not a live feed: there is no push
/// channel for "another Mac just synced", so this refreshes by asking again,
/// on appearance and whenever the account changes.
final class DevicesCard: NSView {

    private let style: DashboardStyle
    private let heading: NSTextField
    private let refreshButton: DashboardButton
    private let card: DashboardCardView
    private let empty: NSTextField
    private var rows: [SectionKeyValueRow] = []

    private var isSignedIn = false {
        didSet {
            isHidden = !isSignedIn
            if isSignedIn, !oldValue { refresh() }
            needsLayout = true
            superview?.needsLayout = true
        }
    }
    private var devices: [SyncEngine.DeviceEntry] = [] {
        didSet {
            rebuildRows()
            needsLayout = true
            superview?.needsLayout = true
        }
    }
    private var observerID: UUID?

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        heading = DashboardType.label("Devices connected", font: DashboardType.headline, color: style.inkSecondary)
        refreshButton = DashboardButton(title: "Refresh", kind: .ghost, style: style)
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        empty = DashboardType.label("No devices have synced yet.", font: DashboardType.callout,
                                    color: style.inkTertiary)

        super.init(frame: .zero)
        isHidden = true
        addSubview(heading)
        addSubview(refreshButton)
        addSubview(card)
        card.addSubview(empty)

        refreshButton.onClick = { [weak self] in self?.refresh() }
        observerID = AccountStore.shared.observe { [weak self] account in
            self?.isSignedIn = account != nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerID { AccountStore.shared.stopObserving(observerID) }
    }

    private func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.devices = await SyncEngine.shared.fetchDevices()
        }
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = devices.map { device in
            let label = device.isThisDevice ? "\(device.name) (this Mac)" : device.name
            let when: String
            if let lastSyncedAt = device.lastSyncedAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                when = "Synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: Date()))"
            } else {
                when = "Not synced yet"
            }
            let row = SectionKeyValueRow(label, when, style: style)
            card.addSubview(row)
            return row
        }
        empty.isHidden = !devices.isEmpty
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        guard isSignedIn else { return 0 }
        let rowsHeight = devices.isEmpty ? 40 : CGFloat(devices.count) * SectionKeyValueRow.height
        return 26 + 8 + 16 + rowsHeight + 16
    }

    override func layout() {
        super.layout()
        guard isSignedIn else { return }
        let headingSize = heading.fittingSize
        let refreshWidth = refreshButton.intrinsicWidth
        heading.frame = NSRect(x: 2, y: 0,
                               width: min(headingSize.width, bounds.width - refreshWidth - 12),
                               height: 24)
        refreshButton.frame = NSRect(x: bounds.width - refreshWidth, y: 0, width: refreshWidth, height: 24)

        let cardTop: CGFloat = 26 + 8
        card.frame = NSRect(x: 0, y: cardTop, width: bounds.width, height: bounds.height - cardTop)
        let inset: CGFloat = 20
        let inner = bounds.width - inset * 2
        guard inner > 0 else { return }

        if devices.isEmpty {
            empty.frame = NSRect(x: inset, y: 16, width: inner, height: 20)
        } else {
            var y: CGFloat = 12
            for row in rows {
                row.frame = NSRect(x: inset, y: y, width: inner, height: SectionKeyValueRow.height)
                y += SectionKeyValueRow.height
            }
        }
    }
}

// MARK: - The Account tab

/// Everything about the optional account, in one place: sign in/out, what
/// syncs to it versus what stays on this Mac, which devices are connected,
/// and changing your password. Settings used to hold a compact version of
/// just the sign-in card — this is what it grew into once "which of my
/// devices have my data" and "change my password" needed somewhere to live.
public final class AccountSectionView: NSView {

    private let scroll = NSScrollView()
    private let content = SettingsFlippedView()
    private let header: DashboardSectionHeader
    private let accountCard: AccountCard
    private let syncedCard: SectionCard
    private let localCard: SectionCard
    private let devicesCard: DevicesCard
    private let passwordCard: ChangePasswordCard
    private var observerID: UUID?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        header = DashboardSectionHeader(title: "Account", style: style)
        accountCard = AccountCard(style: style)
        syncedCard = SectionCard(style: style, title: "Synced to your account")
        localCard = SectionCard(style: style, title: "Stays on this device")
        devicesCard = DevicesCard(style: style)
        passwordCard = ChangePasswordCard(style: style)

        super.init(frame: .zero)
        wantsLayer = true

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = content
        addSubview(scroll)

        content.addSubview(header)
        content.addSubview(accountCard)

        // What actually moves to a second Mac, named plainly rather than left
        // to be inferred from watching it happen — see `SyncEngine`'s own doc
        // comment for the exact same list, which this mirrors on purpose.
        for item in ["Dictation history", "Dictionary", "Snippets", "Transforms", "Learned style", "Your AI key"] {
            let row = SectionBulletRow(item, style: style)
            syncedCard.add(row) { width in row.height(for: width) }
        }
        for item in ["Hotkey and microphone"] {
            let row = SectionBulletRow(item, style: style)
            localCard.add(row) { width in row.height(for: width) }
        }
        content.addSubview(syncedCard)
        content.addSubview(localCard)
        content.addSubview(devicesCard)
        content.addSubview(passwordCard)

        // The two cards below react to their own state, but the frames around
        // them are computed once per `layout()` pass by this view — a sign-in
        // that only marks itself for relayout leaves everything below it
        // sized for the state that just ended.
        observerID = AccountStore.shared.observe { [weak self] _ in
            self?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerID { AccountStore.shared.stopObserving(observerID) }
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let x = DashboardMetrics.contentPaddingX
        let width = max(0, bounds.width - x * 2)
        guard width > 0 else { return }

        header.frame = NSRect(x: x, y: DashboardMetrics.contentPaddingY, width: width, height: header.height)
        var y = DashboardSectionHeader.contentTop(for: header)

        let accountHeight = accountCard.fittedHeight(width: width)
        accountCard.frame = NSRect(x: x, y: y, width: width, height: accountHeight)
        y += accountHeight + DashboardSpace.lg

        let gap = DashboardSpace.lg
        let half = ((width - gap) / 2).rounded(.down)
        let infoHeight = max(syncedCard.fittedHeight(width: half), localCard.fittedHeight(width: half))
        syncedCard.frame = NSRect(x: x, y: y, width: half, height: infoHeight)
        localCard.frame = NSRect(x: x + half + gap, y: y, width: width - half - gap, height: infoHeight)
        y += infoHeight

        let devicesHeight = devicesCard.fittedHeight(width: width)
        if devicesHeight > 0 {
            y += DashboardSpace.lg
            devicesCard.frame = NSRect(x: x, y: y, width: width, height: devicesHeight)
            y += devicesHeight
        } else {
            devicesCard.frame = NSRect(x: x, y: y, width: width, height: 0)
        }

        let passwordHeight = passwordCard.fittedHeight(width: width)
        if passwordHeight > 0 {
            y += DashboardSpace.lg
            passwordCard.frame = NSRect(x: x, y: y, width: width, height: passwordHeight)
            y += passwordHeight
        } else {
            passwordCard.frame = NSRect(x: x, y: y, width: width, height: 0)
        }

        content.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: max(bounds.height, y + DashboardSpace.md))
    }
}
