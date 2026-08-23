import AppKit

/// Signed out by default, and staying that way changes nothing about Quill —
/// see `AccountStore`'s own doc comment for why. This is the one place in the
/// app that shows the fact of an account at all.
final class AccountCard: NSView {

    private enum Mode { case signIn, signUp }

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
        heading = DashboardType.label("Account", font: DashboardType.headline, color: style.inkSecondary)
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
        do {
            try AccountStore.shared.signOut()
            emailField.text = ""
            passwordField.text = ""
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
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
