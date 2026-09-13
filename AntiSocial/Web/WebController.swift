import Combine
import UIKit
import WebKit
import os

/// The things you can start from the compose button.
enum ComposeAction: String, CaseIterable, Identifiable {
    case post
    case story
    case live
    case listing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .post: return "New post"
        case .story: return "New story"
        case .live: return "Go live"
        case .listing: return "Sell something"
        }
    }

    var systemImage: String {
        switch self {
        case .post: return "square.and.pencil"
        case .story: return "circle.dashed"
        case .live: return "dot.radiowaves.left.and.right"
        case .listing: return "tag"
        }
    }
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

    var policy: AccessPolicy
    var externalLinks: AppSettings.ExternalLinkBehavior
    var onBlock: ((BlockEvent) -> Void)?
    /// Fired when the app works out which account is signed in, so the profile
    /// rules know which profile is yours without you typing it in Settings.
    var onLearnUsername: ((SiteKind, String) -> Void)?

    /// Shows up in the Xcode console while the app is attached. Handy for
    /// seeing exactly which URL a site tried to reach.
    private static let log = Logger(subsystem: "com.stefanoswald.antisocial", category: "policy")

    private var observations: [NSKeyValueObservation] = []
    private var hasLoadedOnce = false
    private var lastBounce: Date = .distantPast
    private var currentHideDistractions: Bool
    private var currentViewportWidth: Int
    /// Set while facebook.com/me is resolving. Facebook answers it with a
    /// redirect to your own profile, which is how the app learns your username.
    private var awaitingOwnProfile = false
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
        userAgent: String
    ) {
        self.tab = tab
        self.policy = policy
        self.externalLinks = externalLinks
        self.currentHideDistractions = hideDistractions
        self.currentViewportWidth = viewportWidth

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
            viewportWidth: viewportWidth
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

    func goHome() {
        clearError()
        webView.load(URLRequest(url: tab.home))
    }

    /// Opens the right page for a compose action on this tab's site. Facebook
    /// and Instagram both put the composer in a dialog on your own profile, so
    /// most of these just land you there and let the page do the rest.
    func compose(_ action: ComposeAction, ownInstagramUsername: String) {
        let site = AccessPolicy.site(for: tab.home)

        switch (site, action) {
        case (.instagram, _):
            let name = ownInstagramUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                loadError = "Open your Instagram inbox once so the app can learn your username, or type it into Settings."
                return
            }
            load(URL(string: "https://www.instagram.com/\(name)/")!)

        case (_, .post):
            // Facebook resolves /me to your own profile, where the composer is.
            load(URL(string: "https://www.facebook.com/me")!)
        case (_, .story):
            load(URL(string: "https://www.facebook.com/stories/create")!)
        case (_, .live):
            load(URL(string: "https://www.facebook.com/live/producer")!)
        case (_, .listing):
            load(URL(string: "https://www.facebook.com/marketplace/create")!)
        }
    }

    private func load(_ url: URL) {
        clearError()
        awaitingOwnProfile = (url.path.lowercased() == "/me")
        webView.load(URLRequest(url: url))
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
        if webView.url == nil {
            goHome()
        } else {
            webView.reload()
        }
    }

    private func clearError() {
        if loadError != nil {
            loadError = nil
        }
    }

    /// Applies a settings change. Reloads once if anything that affects the
    /// page (user agent, injected scripts) actually changed.
    func applyConfiguration(userAgent: String, hideDistractions: Bool, viewportWidth: Int) {
        var needsReload = false

        if webView.customUserAgent != userAgent {
            webView.customUserAgent = userAgent
            needsReload = true
        }

        if hideDistractions != currentHideDistractions || viewportWidth != currentViewportWidth {
            currentHideDistractions = hideDistractions
            currentViewportWidth = viewportWidth
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            Self.installScripts(in: controller, hideDistractions: hideDistractions, viewportWidth: viewportWidth)
            needsReload = true
        }

        if needsReload && hasLoadedOnce {
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

    private static func installScripts(in controller: WKUserContentController, hideDistractions: Bool, viewportWidth: Int) {
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
        webView.evaluateJavaScript("window.__as_hide && window.__as_hide();", completionHandler: nil)

        let now = Date()
        let tooSoon = now.timeIntervalSince(lastBounce) < 1.0
        lastBounce = now

        if !tooSoon,
           webView.canGoBack,
           let backURL = webView.backForwardList.backItem?.url,
           case .allow = policy.decide(backURL) {
            webView.goBack()
        } else {
            goHome()
        }
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

        switch policy.decide(url) {
        case .allow:
            Self.log.info("[\(self.tab.title, privacy: .public)] allow \(url.absoluteString, privacy: .public)")
            decisionHandler(Self.allowWithoutAppLink)

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
        webView.evaluateJavaScript("window.__as_show && window.__as_show();", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        // -999 is "cancelled", which is what our own blocks look like.
        guard nsError.code != NSURLErrorCancelled else { return }
        if webView.url == nil || !hasLoadedOnce {
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
        // WebKit killed the page (memory pressure). Bring it back.
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
        switch policy.decide(url) {
        case .allow:
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
            switch policy.decide(url, inPage: true) {
            case .allow:
                Self.log.info("[\(self.tab.title, privacy: .public)] in-page (\(why, privacy: .public)) allow \(url.absoluteString, privacy: .public)")
                webView.evaluateJavaScript("window.__as_show && window.__as_show();", completionHandler: nil)
            case .external:
                // A page cannot pushState to another origin, so this is only
                // here for completeness.
                recordBlock(url, reason: "Outside link")
                bounce()
            case .block(let reason):
                recordBlock(url, reason: reason)
                bounce()
            }
        case "owner":
            guard let name = body["username"] as? String, !name.isEmpty else { return }
            let site: SiteKind = (body["site"] as? String) == "instagram" ? .instagram : .facebook
            if site == .instagram, policy.options.instagramUsername.caseInsensitiveCompare(name) != .orderedSame {
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
