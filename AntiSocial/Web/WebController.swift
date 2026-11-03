import Combine
import UIKit
import WebKit
import os

/// The things you can start from the compose button.
enum ComposeAction: String, CaseIterable, Identifiable {
    case post
    case reel
    case story
    case live
    case listing

    var id: String { rawValue }

    /// What the menu says. Instagram turns a video post into a reel, so its
    /// post item says so.
    func label(on site: SiteKind) -> String {
        switch self {
        case .post: return site == .instagram ? "New post or reel" : "New post"
        case .reel: return "New reel"
        case .story: return "New story"
        case .live: return "Go live"
        case .listing: return "Sell something"
        }
    }

    var systemImage: String {
        switch self {
        case .post: return "square.and.pencil"
        case .reel: return "film"
        case .story: return "circle.dashed"
        case .live: return "dot.radiowaves.left.and.right"
        case .listing: return "tag"
        }
    }

    /// What each site's compose menu offers.
    static func available(on site: SiteKind) -> [ComposeAction] {
        switch site {
        case .instagram: return [.post, .story]
        default: return [.post, .reel, .story, .live, .listing]
        }
    }
}

/// A short note for you, like where to tap to post. Shown in a banner.
struct Notice: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// A record of something the app refused to load.
struct BlockEvent: Identifiable {
    let id = UUID()
    let date: Date
    let tabTitle: String
    let url: URL
    let reason: String
}

/// Owns one WKWebView and enforces the allowlist on it.
///
/// There are two paths a navigation can take, and both are guarded:
/// - Real page loads go through `decidePolicyFor navigationAction`.
/// - In-page (single-page-app) URL changes are reported by the injected hook
///   and arrive in `userContentController(_:didReceive:)`.
@MainActor
final class WebController: NSObject, ObservableObject {

    let tab: WebTab
    let webView: WKWebView
    let container: UIView

    @Published private(set) var canGoBack = false
    @Published private(set) var pageTitle = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var loadError: String?
    @Published var lastBlock: BlockEvent?
    /// True while the app checks whether the post being opened is yours.
    @Published private(set) var isCheckingOwner = false
    /// A note to show in a banner, like where to tap to post.
    @Published private(set) var notice: Notice?

    var policy: AccessPolicy
    var externalLinks: AppSettings.ExternalLinkBehavior
    var onBlock: ((BlockEvent) -> Void)?
    /// Fired when the app works out which account is signed in, so the profile
    /// rules know which profile is yours without you typing it in Settings.
    var onLearnUsername: ((SiteKind, String) -> Void)?
    /// Fired after each full page load. The pool uses it to read your account
    /// numbers from the login cookies.
    var onPageFinished: (() -> Void)?

    /// Remembers which posts are yours and looks up new ones.
    let ownership: OwnershipChecker

    /// Shows up in the Xcode console while the app is attached. Handy for
    /// seeing exactly which URL a site tried to reach.
    private static let log = Logger(subsystem: "com.stefanoswald.antisocial", category: "policy")

    private var observations: [NSKeyValueObservation] = []
    private var hasLoadedOnce = false
    private var lastBounce: Date = .distantPast
    private var currentHideDistractions: Bool
    private var currentViewportWidth: Int
    private var currentPageConfig: String
    /// Bumped for every in-page ownership check, so a slow answer about a post
    /// you already left does not act on the page you are on now.
    private var checkGeneration = 0
    /// The post an in-page check is about, while one runs.
    private var pendingCheckKey: String?
    /// True while an in-page check runs.
    private var inPageCheckActive = false
    /// Real page loads waiting for an ownership answer.
    private var loadChecksRunning = 0
    /// True while the page is hidden (a post being checked, or on the way
    /// out after a block).
    private var pageHidden = false
    /// Set while facebook.com/me is resolving. Facebook answers it with a
    /// redirect to your own profile, which is how the app learns your username.
    private var awaitingOwnProfile = false
    /// Posts you tapped, and when. A tapped post opens. The next one does not
    /// open by itself.
    private var tapGrants: [String: Date] = [:]
    /// Posts already open or opened in this tab. Coming back to one is fine.
    private var openedKeys: Set<String> = []
    /// The last post shown, to return to when a player moves on to someone
    /// else's.
    private var lastShownPostURL: URL?
    /// How the page last changed its own address (pushState, replaceState, ...).
    private var lastInPageWhy = ""
    /// The address the page last reported, to tell where an in-page change
    /// came from.
    private var lastPageURL: URL?
    /// When you last tapped anywhere on the page. A tap that does not name a
    /// post (a shared-post card, a share link that redirects) still opens the
    /// first post it leads to, as long as that post is reached from a page
    /// that is not a post itself. A player moving on from one post to the
    /// next never counts.
    private var lastClickAt: Date = .distantPast
    /// How long a tap counts for the post it opens.
    private static let tapWindow: TimeInterval = 10
    /// A composer to open once its page has loaded.
    private struct PendingCompose {
        let action: ComposeAction
        let site: SiteKind
        let steps: [[String: Any]]
        let started: Date
    }
    private var pendingCompose: PendingCompose?
    /// The compose action whose script is running on the page.
    private var composeInFlight: ComposeAction?
    private let refreshControl = UIRefreshControl()

    /// Private-but-widely-used policy value that tells WebKit not to hand the
    /// navigation to an installed app through a universal link. Falls back to
    /// plain `.allow` if the value is ever rejected.
    private static let allowWithoutAppLink: WKNavigationActionPolicy =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    init(
        tab: WebTab,
        dataStore: WKWebsiteDataStore,
        policy: AccessPolicy,
        externalLinks: AppSettings.ExternalLinkBehavior,
        hideDistractions: Bool,
        viewportWidth: Int,
        pageConfig: String,
        userAgent: String,
        ownership: OwnershipChecker
    ) {
        self.tab = tab
        self.policy = policy
        self.externalLinks = externalLinks
        self.currentHideDistractions = hideDistractions
        self.currentViewportWidth = viewportWidth
        self.currentPageConfig = pageConfig
        self.ownership = ownership

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        // Nothing plays until you tap it. No autoplaying video anywhere.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        self.webView = webView

        let container = UIView()
        container.backgroundColor = .systemBackground
        self.container = container

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        Self.installScripts(
            in: configuration.userContentController,
            hideDistractions: hideDistractions,
            viewportWidth: viewportWidth,
            pageConfig: pageConfig
        )
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: Injected.handlerName)

        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        observe()
    }

    // MARK: - Public actions

    /// Called from the SwiftUI view's `makeUIView`. Defer the actual load so
    /// no published property changes while SwiftUI is mid-update.
    func loadHomeIfNeeded() {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        Task { @MainActor in
            self.goHome()
        }
    }

    /// Where this tab starts. Your Instagram posts live at your own profile,
    /// so that one depends on knowing your username.
    var homeURL: URL? {
        guard tab == .instagramMyPosts else { return tab.home }
        let name = policy.options.instagramUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return URL(string: "https://www.instagram.com/\(name)/")
    }

    func goHome() {
        clearError()
        guard let url = homeURL else {
            loadError = "Open IG Inbox once so the app can learn your Instagram username. Then come back here."
            return
        }
        load(url)
    }

    /// Opens the composer for a compose action on this tab's site. Facebook's
    /// post box and Reel button sit far down your profile, so the app scrolls
    /// to them and opens them. Instagram's + button opens your photo picker,
    /// which only works from a real tap, so the app makes it glow instead.
    func compose(_ action: ComposeAction, ownInstagramUsername: String) {
        switch AccessPolicy.site(for: tab.home) {
        case .instagram:
            let name = ownInstagramUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let profile = URL(string: "https://www.instagram.com/\(name)/") else {
                showNotice("Open IG Inbox once so the app can learn your Instagram username, or type it into Settings.")
                return
            }
            startCompose(action, url: profile, site: .instagram, steps: [
                ["svg": "New post", "glow": true, "name": "plus"]
            ])

        case .facebook, .other:
            switch action {
            case .post:
                // Facebook resolves /me to your own profile.
                startCompose(action, url: URL(string: "https://www.facebook.com/me")!, site: .facebook, steps: [
                    ["startsWith": "What's on your mind", "name": "post-box"]
                ])
            case .reel:
                startCompose(action, url: URL(string: "https://www.facebook.com/me")!, site: .facebook, steps: [
                    ["label": "Reel", "name": "reel-button"]
                ])
            case .story:
                load(URL(string: "https://www.facebook.com/stories/create")!)
            case .live:
                load(URL(string: "https://www.facebook.com/live/producer")!)
            case .listing:
                load(URL(string: "https://www.facebook.com/marketplace/create")!)
            }
        }
    }

    private func startCompose(_ action: ComposeAction, url: URL, site: SiteKind, steps: [[String: Any]]) {
        load(url)
        pendingCompose = PendingCompose(action: action, site: site, steps: steps, started: Date())
    }

    /// Runs the composer script once the page it needs has loaded.
    private func runPendingCompose() {
        guard let pending = pendingCompose else { return }
        guard Date().timeIntervalSince(pending.started) < 30 else {
            pendingCompose = nil
            return
        }
        guard let url = webView.url, AccessPolicy.site(for: url) == pending.site else { return }
        pendingCompose = nil
        composeInFlight = pending.action
        webView.evaluateJavaScript(Injected.composeScript(steps: pending.steps), completionHandler: nil)
    }

    /// What to tell you once the composer script has done its part.
    private func composeNotice(for action: ComposeAction, opened: Bool) -> String? {
        if AccessPolicy.site(for: tab.home) == .instagram {
            switch (action, opened) {
            case (.story, true):
                return "Tap the glowing + button, then choose Story."
            case (.story, false):
                return "Tap the + button at the bottom of Instagram, then choose Story."
            case (_, true):
                return "Tap the glowing + button, then pick a photo or video. A video becomes a reel."
            case (_, false):
                return "Tap the + button at the bottom of Instagram, then pick a photo or video."
            }
        }
        guard !opened else { return nil }
        if action == .reel {
            return "Facebook did not open its Reel window. Scroll down your profile to the Reel button."
        }
        return "Facebook did not open its post window. Scroll down your profile to What's on your mind?"
    }

    private func showNotice(_ text: String) {
        let next = Notice(text: text)
        notice = next
        // Clear it again, so the banner does not come back when you return
        // to this tab later.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.notice?.id == next.id {
                self?.notice = nil
            }
        }
    }

    private func load(_ url: URL) {
        clearError()
        endOwnerCheck()
        // Any other page load cancels a composer that was waiting to open.
        pendingCompose = nil
        composeInFlight = nil
        awaitingOwnProfile = (url.path.lowercased() == "/me")
        webView.load(URLRequest(url: url))
    }

    /// Drops the in-page ownership check in progress. Its answer, when it
    /// comes, is about a page you have already left.
    private func endOwnerCheck() {
        checkGeneration += 1
        pendingCheckKey = nil
        inPageCheckActive = false
        updateCheckingState()
    }

    private func updateCheckingState() {
        let checking = inPageCheckActive || loadChecksRunning > 0
        if isCheckingOwner != checking {
            isCheckingOwner = checking
        }
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            goHome()
        }
    }

    func reload() {
        clearError()
        if webView.url == nil || pageHidden {
            // A hidden page is a post that was refused or is still being
            // checked. Reloading it would only show it. Start over instead.
            goHome()
        } else {
            webView.reload()
        }
    }

    /// Forgets every post opened by a tap. Used when "Open other people's
    /// posts I tap" is switched off, before `recheckCurrentPage`.
    func forgetTappedPosts() {
        openedKeys.removeAll()
        tapGrants.removeAll()
        lastClickAt = .distantPast
    }

    /// Checks the page you are on against the current rules, and leaves it if
    /// it no longer passes. Used when "Open other people's posts I tap" is
    /// switched off.
    func recheckCurrentPage() {
        guard hasLoadedOnce, let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        if !isAllowedWithoutChecking(url) {
            goHome()
        }
    }

    private func clearError() {
        if loadError != nil {
            loadError = nil
        }
    }

    /// Applies a settings change. Reloads once if anything that affects the
    /// page (user agent, injected scripts) actually changed. A change to the
    /// page settings alone (who you are, which posts are yours) reaches the
    /// open page directly, with no reload.
    func applyConfiguration(userAgent: String, hideDistractions: Bool, viewportWidth: Int, pageConfig: String) {
        var needsReload = false

        if webView.customUserAgent != userAgent {
            webView.customUserAgent = userAgent
            needsReload = true
        }

        let scriptsChanged = hideDistractions != currentHideDistractions || viewportWidth != currentViewportWidth
        let configChanged = pageConfig != currentPageConfig

        if scriptsChanged || configChanged {
            currentHideDistractions = hideDistractions
            currentViewportWidth = viewportWidth
            currentPageConfig = pageConfig
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            Self.installScripts(
                in: controller,
                hideDistractions: hideDistractions,
                viewportWidth: viewportWidth,
                pageConfig: pageConfig
            )
            if scriptsChanged {
                needsReload = true
            } else if webView.url != nil {
                webView.evaluateJavaScript(pageConfig, completionHandler: nil)
            }
        }

        if needsReload && hasLoadedOnce {
            goHome()
        } else if hasLoadedOnce, webView.url == nil, loadError != nil, homeURL != nil {
            // Your posts tab was waiting for your Instagram username.
            goHome()
        }
    }

    /// Runs the diagnostics script and returns its JSON.
    func pageMap() async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(Injected.pageMap) { result, error in
                if let text = result as? String {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: "{\"error\": \"\(error?.localizedDescription ?? "no result")\"}")
                }
            }
        }
    }

    // MARK: - Setup

    private static func installScripts(
        in controller: WKUserContentController,
        hideDistractions: Bool,
        viewportWidth: Int,
        pageConfig: String
    ) {
        let config = WKUserScript(
            source: pageConfig,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(config)

        let hook = WKUserScript(
            source: Injected.navigationHook,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(hook)

        if viewportWidth > 0 {
            let viewport = WKUserScript(
                source: Injected.viewportScript(width: viewportWidth),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(viewport)
        }

        guard hideDistractions else { return }

        let hideEarly = WKUserScript(
            source: Injected.hidingScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let hideLate = WKUserScript(
            source: Injected.hidingScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(hideEarly)
        controller.addUserScript(hideLate)
    }

    private func observe() {
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.pageTitle = view.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.currentURL = view.url }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in
                    self?.isLoading = view.isLoading
                    if !view.isLoading { self?.refreshControl.endRefreshing() }
                }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            }
        ]
    }

    @objc private func handleRefresh() {
        reload()
    }

    // MARK: - Policy handling

    private func recordBlock(_ url: URL, reason: String) {
        let event = BlockEvent(date: Date(), tabTitle: tab.title, url: url, reason: reason)
        lastBlock = event
        onBlock?(event)
        let from = webView.url?.absoluteString ?? "nil"
        Self.log.notice("[\(self.tab.title, privacy: .public)] BLOCKED (\(reason, privacy: .public)) \(url.absoluteString, privacy: .public) <- from \(from, privacy: .public)")
    }

    private func handleExternal(_ url: URL) {
        switch externalLinks {
        case .safari:
            UIApplication.shared.open(url)
        case .block:
            recordBlock(url, reason: "Outside link")
        }
    }

    /// Get away from a blocked in-page navigation. Prefer stepping back to the
    /// previous allowed page so scroll position and state survive. Fall back
    /// to the tab's home page.
    private func bounce() {
        hidePage()

        let now = Date()
        let tooSoon = now.timeIntervalSince(lastBounce) < 1.0
        lastBounce = now

        if !tooSoon,
           webView.canGoBack,
           let backURL = webView.backForwardList.backItem?.url,
           isAllowedWithoutChecking(backURL) {
            webView.goBack()
        } else {
            goHome()
        }
    }

    /// Allowed outright, a post already known to be yours, or a post you
    /// opened with a tap.
    private func isAllowedWithoutChecking(_ url: URL) -> Bool {
        switch policy.decide(url) {
        case .allow:
            return true
        case .verify(let ref):
            return ownership.verdict(for: ref) == .mine
                || (policy.options.openTappedPosts && openedKeys.contains(ref.key))
        case .block, .external:
            return false
        }
    }

    private func hidePage() {
        pageHidden = true
        webView.evaluateJavaScript("window.__as_hide && window.__as_hide();", completionHandler: nil)
    }

    private func showPage() {
        pageHidden = false
        webView.evaluateJavaScript("window.__as_show && window.__as_show();", completionHandler: nil)
    }

    /// The post a URL points at, judged the same way the rules judge it
    /// (redirect wrappers included).
    private func pendingKey(for url: URL?) -> String? {
        guard let url, case .verify(let ref) = policy.decide(url, inPage: true) else { return nil }
        return ref.key
    }

    // MARK: - Your posts

    /// A single post is about to show. Open it if it is yours or you tapped
    /// it; otherwise block it. `decisionHandler` is set for real page loads,
    /// which wait for the answer before anything loads. In-page changes have
    /// already happened, so the page is hidden until the answer comes back.
    private func verify(
        _ ref: PostRef,
        url: URL,
        decisionHandler: ((WKNavigationActionPolicy) -> Void)?
    ) {
        let inPage = decisionHandler == nil
        if inPage {
            checkGeneration += 1
            pendingCheckKey = ref.key
        }
        let generation = checkGeneration

        // Yours, or something you tapped: open it now.
        let mine = ownership.verdict(for: ref) == .mine
        if mine || (policy.options.openTappedPosts && isTapped(ref.key)) {
            if inPage {
                inPageCheckActive = false
                pendingCheckKey = nil
            }
            updateCheckingState()
            openPost(ref, url: url, decisionHandler: decisionHandler)
            return
        }

        if let known = ownership.verdict(for: ref) {
            finishCheck(known, ref: ref, url: url, generation: generation, decisionHandler: decisionHandler)
            return
        }
        if let other = ref.otherOwner {
            // The link names someone else, and this is not a collab the app
            // has seen on your grid.
            finishCheck(.someoneElse(other), ref: ref, url: url, generation: generation, decisionHandler: decisionHandler)
            return
        }

        if inPage {
            inPageCheckActive = true
            hidePage()
        } else {
            loadChecksRunning += 1
        }
        updateCheckingState()

        let identity = policy.options.ownIdentity
        Self.log.info("[\(self.tab.title, privacy: .public)] checking owner of \(ref.key, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler?(.cancel)
                return
            }
            let answer = await self.ownership.check(ref, identity: identity)
            if !inPage {
                self.loadChecksRunning = max(0, self.loadChecksRunning - 1)
            }
            self.finishCheck(answer, ref: ref, url: url, generation: generation, decisionHandler: decisionHandler)
        }
    }

    private func finishCheck(
        _ answer: Ownership,
        ref: PostRef,
        url: URL,
        generation: Int,
        decisionHandler: ((WKNavigationActionPolicy) -> Void)?
    ) {
        // For in-page changes, act only if this is still the latest check and
        // you are still on that post.
        let isCurrent = generation == checkGeneration
        if decisionHandler == nil && isCurrent {
            inPageCheckActive = false
            pendingCheckKey = nil
        }
        updateCheckingState()

        // The rules may have changed while the check ran (your name was just
        // learned, say), so the page may now pass outright.
        if decisionHandler == nil, isCurrent, let here = currentURL ?? webView.url,
           case .allow = policy.decide(here, inPage: true) {
            showPage()
            return
        }
        let actOnPage = isCurrent && pendingKey(for: currentURL ?? webView.url) == ref.key

        if answer == .mine {
            Self.log.info("[\(self.tab.title, privacy: .public)] yours: \(ref.key, privacy: .public)")
            if let decisionHandler {
                openPost(ref, url: url, decisionHandler: decisionHandler)
            } else if actOnPage {
                openPost(ref, url: url, decisionHandler: nil)
            }
            pushKnown([ref.key])
            return
        }

        let reason = blockReason(for: ref, answer: answer)
        if let decisionHandler {
            decisionHandler(.cancel)
            recordBlock(url, reason: reason)
            if webView.url == nil || policy.isAuthPage(webView.url) {
                goHome()
            }
        } else if actOnPage {
            recordBlock(url, reason: reason)
            leaveBlockedPost(ref)
        }
    }

    /// Shows a post that passed: yours, or one you tapped.
    private func openPost(_ ref: PostRef, url: URL, decisionHandler: ((WKNavigationActionPolicy) -> Void)?) {
        markOpened(ref, url: url)
        if let decisionHandler {
            decisionHandler(Self.allowWithoutAppLink)
        } else {
            webView.evaluateJavaScript(Injected.openedScript([ref.key]), completionHandler: nil)
            showPage()
        }
    }

    /// A post is open. Coming back to it later is fine.
    private func markOpened(_ ref: PostRef, url: URL) {
        openedKeys.insert(ref.key)
        lastShownPostURL = url
        lastClickAt = .distantPast
    }

    /// Short words for the "Blocked" banner.
    private func blockReason(for ref: PostRef, answer: Ownership) -> String {
        if !policy.options.openTappedPosts {
            return answer == .unknown ? "Could not confirm it is your post" : "Not your post"
        }
        if ref.kind.isVideo {
            return "Next Reel"
        }
        if ref.kind.isStory {
            return "Next story"
        }
        return "Only posts you tap open"
    }

    /// Gets away from a post that moved on by itself. Facebook's Reels player
    /// swaps the address in place (replaceState), so there is no history
    /// entry to step back to. Going back to the last post shown is the
    /// natural way out.
    private func leaveBlockedPost(_ ref: PostRef) {
        if lastInPageWhy == "replaceState", let previous = lastShownPostURL,
           pendingKey(for: previous) != ref.key {
            hidePage()
            load(previous)
        } else {
            bounce()
        }
    }

    /// Remembers a tap. A tap on a link to a post lets that post open. Any
    /// tap at all also lets the next post reached from a non-post page open
    /// (see `lastClickAt`).
    private func noteTap(_ url: URL?) {
        let now = Date()
        lastClickAt = now
        if let key = pendingKey(for: url) {
            tapGrants[key] = now
        }
        if tapGrants.count > 200 {
            tapGrants = tapGrants.filter { now.timeIntervalSince($0.value) < Self.tapWindow }
        }
    }

    /// Uses up a recent tap for this post. `from` is the page the post was
    /// reached from. A real page load (`inPage` false) needs no such check,
    /// because a player never makes one on its own.
    @discardableResult
    private func useRecentTap(_ key: String, from: URL?, inPage: Bool) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastClickAt) < Self.tapWindow else { return false }
        if inPage {
            guard let from, AccessPolicy.postLink(in: from) == nil else { return false }
        }
        lastClickAt = .distantPast
        tapGrants[key] = now
        return true
    }

    private func isTapped(_ key: String) -> Bool {
        if openedKeys.contains(key) {
            return true
        }
        guard let at = tapGrants[key] else { return false }
        return Date().timeIntervalSince(at) < Self.tapWindow
    }

    /// A link that names you proves the post is yours. Remember it.
    private func learnFromURL(_ url: URL) {
        guard let key = policy.ownedPostKey(in: url) else { return }
        if !ownership.markMine([key]).isEmpty {
            pushKnown([key])
        }
    }

    /// Links the page pointed out as yours. Each one is checked here again:
    /// it counts only if it names you, or if it sits on your own grid and is
    /// the kind of post that grid holds (Reels and videos on Facebook).
    private func learnLinks(_ hrefs: [String], reportedPage: URL) {
        let page = webView.url ?? reportedPage
        let onGrid = policy.isOwnPostGrid(page)
        let gridKind = AccessPolicy.site(for: page) == .facebook ? "fb:video:" : "ig:"
        var keys: [String] = []
        for href in hrefs.prefix(300) {
            guard let url = URL(string: href, relativeTo: page)?.absoluteURL else { continue }
            if let key = policy.ownedPostKey(in: url) {
                keys.append(key)
            } else if onGrid, let key = AccessPolicy.postLink(in: url)?.ref.key, key.hasPrefix(gridKind) {
                keys.append(key)
            }
        }
        let learned = ownership.markMine(keys)
        if !learned.isEmpty {
            Self.log.info("[\(self.tab.title, privacy: .public)] learned \(learned.count) of your posts")
            pushKnown(learned)
        }
    }

    /// Tells the open page about posts now known to be yours.
    private func pushKnown(_ keys: [String]) {
        guard !keys.isEmpty, webView.url != nil else { return }
        webView.evaluateJavaScript(Injected.addKnownScript(keys), completionHandler: nil)
    }
}

// MARK: - WKNavigationDelegate

extension WebController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Frames inside the page (login widgets, attachments) are not
        // navigations the user made. Leave them alone unless they try to load
        // an app link.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            if let scheme = url.scheme?.lowercased(), ["http", "https", "about", "blob", "data"].contains(scheme) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
            return
        }

        // Leaving the page before its composer opened cancels the composer.
        // The app's own loads and redirects come through as .other.
        if navigationAction.navigationType == .backForward || navigationAction.navigationType == .linkActivated {
            pendingCompose = nil
        }

        // facebook.com/me lands on your own profile. That redirect is the one
        // reliable way to find out who you are, so let it through and remember.
        if awaitingOwnProfile, AccessPolicy.site(for: url) == .facebook,
           let learned = AccessPolicy.ownProfileName(from: url) {
            awaitingOwnProfile = false
            Self.log.notice("[\(self.tab.title, privacy: .public)] learned facebook username \(learned, privacy: .public)")
            onLearnUsername?(.facebook, learned)
            policy.options.facebookUsername = learned
            decisionHandler(Self.allowWithoutAppLink)
            return
        }

        // A link you tapped yourself.
        if navigationAction.navigationType == .linkActivated {
            noteTap(url)
        }

        switch policy.decide(url) {
        case .allow:
            Self.log.info("[\(self.tab.title, privacy: .public)] allow \(url.absoluteString, privacy: .public)")
            learnFromURL(url)
            decisionHandler(Self.allowWithoutAppLink)

        case .verify(let ref):
            // A share link you tapped redirects here.
            useRecentTap(ref.key, from: nil, inPage: false)
            verify(ref, url: url, decisionHandler: decisionHandler)

        case .external(let target):
            Self.log.notice("[\(self.tab.title, privacy: .public)] EXTERNAL \(target.absoluteString, privacy: .public)")
            decisionHandler(.cancel)
            handleExternal(target)

        case .block(let reason):
            decisionHandler(.cancel)
            recordBlock(url, reason: reason)
            // A login or consent page just finished and tried to send us to
            // the feed. Go somewhere useful instead of sitting on the form.
            if webView.url == nil || policy.isAuthPage(webView.url) {
                goHome()
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        clearError()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        Self.log.info("[\(self.tab.title, privacy: .public)] redirect -> \(webView.url?.absoluteString ?? "nil", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastPageURL = webView.url
        // A new page replaced the old one. A check about a different post on
        // the old page no longer matters.
        if let pending = pendingCheckKey, pendingKey(for: webView.url) != pending {
            endOwnerCheck()
        }
        if pendingCheckKey == nil {
            showPage()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        runPendingCompose()
        onPageFinished?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        // -999 is "cancelled", which is what our own blocks look like.
        guard nsError.code != NSURLErrorCancelled else { return }
        // A hidden page means the app was leaving it. If that trip failed,
        // say so instead of leaving a blank screen.
        if webView.url == nil || !hasLoadedOnce || pageHidden {
            loadError = nsError.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        loadError = nsError.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit stopped the page, almost always because it used too much
        // memory. Note it in Diagnostics, then bring the page back.
        if let url = webView.url ?? currentURL {
            let event = BlockEvent(date: Date(), tabTitle: tab.title, url: url, reason: "Page reloaded after running out of memory")
            onBlock?(event)
            Self.log.notice("[\(self.tab.title, privacy: .public)] web content process ended, reloading")
        }
        reload()
    }
}

// MARK: - WKUIDelegate

extension WebController: WKUIDelegate {

    /// Links that ask for a new window (target="_blank", window.open). There is
    /// no second window here. Load them in place if they pass the policy.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        // On iOS a page can open a window only from a tap, so this is one.
        noteTap(url)
        switch policy.decide(url) {
        case .allow, .verify:
            // A post goes through the normal check on its way in.
            webView.load(URLRequest(url: url))
        case .external(let target):
            handleExternal(target)
        case .block(let reason):
            recordBlock(url, reason: reason)
        }
        return nil
    }

    /// Posting a photo or going live asks for the camera and the microphone.
    /// Without this the page's request is denied without ever asking you.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Only the two sites the app exists for may ask at all.
        guard let url = frame.request.url, AccessPolicy.site(for: url) != .other else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(.prompt)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, fallback: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert) { completionHandler(false) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        present(alert) { completionHandler(nil) }
    }

    private func present(_ alert: UIAlertController, fallback: @escaping () -> Void) {
        guard let presenter = Self.topViewController() else {
            fallback()
            return
        }
        presenter.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - WKScriptMessageHandler

extension WebController: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Injected.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "url":
            guard let string = body["url"] as? String, let url = URL(string: string) else { return }
            currentURL = url
            let why = body["why"] as? String ?? "?"
            lastInPageWhy = why
            let from = lastPageURL
            lastPageURL = url
            switch policy.decide(url, inPage: true) {
            case .allow:
                Self.log.info("[\(self.tab.title, privacy: .public)] in-page (\(why, privacy: .public)) allow \(url.absoluteString, privacy: .public)")
                endOwnerCheck()
                learnFromURL(url)
                // A post that opens outright (yours, or in a group) is where a
                // player that moves on gets sent back to.
                lastShownPostURL = AccessPolicy.postLink(in: url) != nil ? url : nil
                showPage()
            case .verify(let ref):
                if why == "pushState" || why == "replaceState" || why == "poll" {
                    useRecentTap(ref.key, from: from, inPage: true)
                }
                verify(ref, url: url, decisionHandler: nil)
            case .external:
                // A page cannot pushState to another origin, so this is only
                // here for completeness.
                endOwnerCheck()
                recordBlock(url, reason: "Outside link")
                bounce()
            case .block(let reason):
                endOwnerCheck()
                recordBlock(url, reason: reason)
                bounce()
            }

        case "tap":
            noteTap((body["href"] as? String).flatMap { URL(string: $0) })

        case "compose":
            guard let action = composeInFlight else { return }
            composeInFlight = nil
            let opened = body["ok"] as? Bool ?? false
            Self.log.info("[\(self.tab.title, privacy: .public)] compose \(action.rawValue, privacy: .public) opened: \(opened)")
            if let text = composeNotice(for: action, opened: opened) {
                showNotice(text)
            }

        case "links":
            guard let hrefs = body["hrefs"] as? [String],
                  let pageString = body["page"] as? String,
                  let page = URL(string: pageString) else { return }
            learnLinks(hrefs, reportedPage: page)

        case "owner":
            guard let name = body["username"] as? String, !name.isEmpty else { return }
            let site: SiteKind = (body["site"] as? String) == "instagram" ? .instagram : .facebook
            // Fill in an empty username only. Pages also show other people's
            // pictures (commenters, say), so a guess never replaces a known name.
            if site == .instagram, policy.options.instagramUsername.isEmpty {
                Self.log.notice("[\(self.tab.title, privacy: .public)] learned instagram username \(name, privacy: .public)")
                policy.options.instagramUsername = name
                onLearnUsername?(.instagram, name)
            }

        default:
            break
        }
    }
}

/// WKUserContentController holds its handlers strongly. This proxy breaks the
/// cycle so the controller can be freed.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
