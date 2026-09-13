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

    private let dataStore = WKWebsiteDataStore.default()
    private var controllers: [String: WebController] = [:]
    private var settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        self.settings = settings

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value lands. Apply on the
                // next turn of the run loop so we read the new value.
                DispatchQueue.main.async { self?.applySettings() }
            }
            .store(in: &cancellables)
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
            userAgent: userAgent(for: tab)
        )
        controller.onBlock = { [weak self] event in
            self?.record(event)
        }
        controller.onLearnUsername = { [weak self] site, username in
            self?.learn(site, username: username)
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
            guard settings.instagramUsername.caseInsensitiveCompare(username) != .orderedSame else { return }
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
        for controller in controllers.values {
            controller.policy = AccessPolicy(options: options)
            controller.externalLinks = settings.externalLinks
            controller.applyConfiguration(
                userAgent: userAgent(for: controller.tab),
                hideDistractions: settings.hideDistractions,
                viewportWidth: settings.viewportWidth(for: AccessPolicy.site(for: controller.tab.home))
            )
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
