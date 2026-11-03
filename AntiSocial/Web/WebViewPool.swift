import Combine
import Foundation
import WebKit

/// Keeps one web view alive per tab so switching tabs never reloads, and
/// pushes settings changes into every controller.
///
/// All controllers share the default (persistent) data store, so logging in
/// once covers every tab and survives relaunches.
@MainActor
final class WebViewPool: ObservableObject {

    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @Published private(set) var blockLog: [BlockEvent] = []

    /// Which posts are yours. Shared by every tab.
    let ownership: OwnershipChecker

    private let dataStore = WKWebsiteDataStore.default()
    private var controllers: [String: WebController] = [:]
    private var settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var lastIdentityRefresh: Date = .distantPast
    private var isLookingUpUsername = false
    private var lastUsernameLookup: Date = .distantPast
    private var configPushPending = false
    private var lastOpenTappedPosts: Bool

    init(settings: AppSettings) {
        self.settings = settings
        self.ownership = OwnershipChecker(dataStore: WKWebsiteDataStore.default())
        self.lastOpenTappedPosts = settings.openTappedPosts

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value lands. Apply on the
                // next turn of the run loop so we read the new value.
                DispatchQueue.main.async { self?.applySettings() }
            }
            .store(in: &cancellables)

        // New posts learned as yours go into every page's settings, in one
        // batch, a moment later.
        ownership.onChange = { [weak self] in
            self?.scheduleConfigPush()
        }

        refreshIdentity(force: true)
    }

    func controller(for tab: WebTab) -> WebController {
        if let existing = controllers[tab.id] {
            return existing
        }
        let controller = WebController(
            tab: tab,
            dataStore: dataStore,
            policy: AccessPolicy(options: settings.policyOptions),
            externalLinks: settings.externalLinks,
            hideDistractions: settings.hideDistractions,
            viewportWidth: settings.viewportWidth(for: AccessPolicy.site(for: tab.home)),
            pageConfig: pageConfig(),
            userAgent: userAgent(for: tab),
            ownership: ownership
        )
        controller.onBlock = { [weak self] event in
            self?.record(event)
        }
        controller.onLearnUsername = { [weak self] site, username in
            self?.learn(site, username: username)
        }
        controller.onPageFinished = { [weak self] in
            self?.refreshIdentity(force: false)
        }
        controllers[tab.id] = controller
        return controller
    }

    /// Signs out of everything by wiping cookies and site data, then reloads
    /// each tab at its home page (which will show the login form).
    func clearWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
        for controller in controllers.values {
            controller.goHome()
        }
    }

    func clearBlockLog() {
        blockLog.removeAll()
    }

    /// The app worked out which account is signed in. Save it so the profile
    /// rules and the compose button both know, and so it survives a relaunch.
    private func learn(_ site: SiteKind, username: String) {
        switch site {
        case .facebook:
            guard settings.facebookUsername.caseInsensitiveCompare(username) != .orderedSame else { return }
            settings.facebookUsername = username
        case .instagram:
            // Only fills an empty name. A name you typed or the app already
            // learned is never replaced by a guess from a page.
            guard settings.instagramUsername.isEmpty else { return }
            settings.instagramUsername = username
        case .other:
            break
        }
    }

    /// Whatever the app currently believes your Instagram handle is.
    var instagramUsername: String { settings.instagramUsername }

    // MARK: - Private

    private func applySettings() {
        let options = settings.policyOptions
        let config = pageConfig()
        // Switching "Open other people's posts I tap" off should also apply
        // to the page you are looking at right now.
        let turnedOffTapped = !settings.openTappedPosts && lastOpenTappedPosts
        lastOpenTappedPosts = settings.openTappedPosts
        for controller in controllers.values {
            controller.policy = AccessPolicy(options: options)
            controller.externalLinks = settings.externalLinks
            controller.applyConfiguration(
                userAgent: userAgent(for: controller.tab),
                hideDistractions: settings.hideDistractions,
                viewportWidth: settings.viewportWidth(for: AccessPolicy.site(for: controller.tab.home)),
                pageConfig: config
            )
            if turnedOffTapped {
                controller.forgetTappedPosts()
                controller.recheckCurrentPage()
            }
        }
    }

    /// What the pages need to know: whether a post you tap may open, every
    /// name the sites use for you, and the posts already known to be yours.
    private func pageConfig() -> String {
        let identity = settings.policyOptions.ownIdentity
        return Injected.configScript(
            tapOpensPosts: settings.openTappedPosts,
            facebookNames: identity.facebook.sorted(),
            instagramNames: identity.instagram.sorted(),
            knownPosts: ownership.recentKeys(limit: 600)
        )
    }

    private func scheduleConfigPush() {
        guard !configPushPending else { return }
        configPushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.configPushPending = false
            self.applySettings()
        }
    }

    // MARK: - Who you are

    /// Reads your account numbers from the sites' own login cookies (c_user on
    /// Facebook, ds_user_id on Instagram). Links often name you by number, so
    /// the app needs both your username and your number to spot your posts.
    func refreshIdentity(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastIdentityRefresh) > 20 else { return }
        lastIdentityRefresh = now
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.applyIdentity(from: cookies)
            }
        }
    }

    private func applyIdentity(from cookies: [HTTPCookie]) {
        func value(_ name: String, domain: String) -> String? {
            cookies.first { $0.name == name && $0.domain.lowercased().hasSuffix(domain) }?.value
        }

        if let id = value("c_user", domain: "facebook.com"), AccessPolicy.isDigits(id), settings.facebookUserID != id {
            settings.facebookUserID = id
        }
        if let id = value("ds_user_id", domain: "instagram.com"), AccessPolicy.isDigits(id), settings.instagramUserID != id {
            settings.instagramUserID = id
        }

        // Knows your Facebook number but not your username yet: look it up
        // on your own profile page. Accounts without a custom username have
        // nothing to find, so this runs at most every few hours.
        let facebookID = settings.facebookUserID
        guard settings.facebookUsername.isEmpty, !facebookID.isEmpty, !isLookingUpUsername,
              Date().timeIntervalSince(lastUsernameLookup) > 6 * 3600 else { return }
        isLookingUpUsername = true
        lastUsernameLookup = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let name = await self.ownership.facebookUsername(forID: facebookID)
            self.isLookingUpUsername = false
            if let name, self.settings.facebookUsername.isEmpty {
                self.settings.facebookUsername = name
            }
        }
    }

    private func userAgent(for tab: WebTab) -> String {
        switch AccessPolicy.site(for: tab.home) {
        case .facebook:
            return settings.desktopModeFacebook ? Self.desktopUserAgent : Self.mobileUserAgent
        case .instagram:
            return settings.desktopModeInstagram ? Self.desktopUserAgent : Self.mobileUserAgent
        case .other:
            return Self.mobileUserAgent
        }
    }

    private func record(_ event: BlockEvent) {
        blockLog.insert(event, at: 0)
        if blockLog.count > 100 {
            blockLog.removeLast(blockLog.count - 100)
        }
    }
}
