import Foundation
import Combine

/// User-adjustable behavior. Stored in UserDefaults so it survives relaunches.
final class AppSettings: ObservableObject {

    enum ExternalLinkBehavior: String, CaseIterable, Identifiable {
        case safari
        case block

        var id: String { rawValue }

        var label: String {
            switch self {
            case .safari: return "Open in Safari"
            case .block: return "Block"
            }
        }
    }

    private enum Key {
        static let facebookUsername = "facebookUsername"
        static let instagramUsername = "instagramUsername"
        static let desktopModeFacebook = "desktopModeFacebook"
        static let desktopModeInstagram = "desktopModeInstagram"
        static let allowReelPermalinks = "allowReelPermalinks"
        static let allowGroupPosts = "allowGroupPosts"
        static let externalLinks = "externalLinks"
        static let showBlockToasts = "showBlockToasts"
        static let hideDistractions = "hideDistractions"
        static let desktopViewportWidth = "desktopViewportWidth"
        static let allowPosting = "allowPosting"
    }

    /// Layout widths (in CSS pixels) the desktop site can be squeezed into.
    /// Smaller means bigger text on the phone but a more cramped page.
    static let desktopViewportChoices: [Int] = [600, 680, 760, 840, 980]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            // Facebook's mobile site refuses to show Messenger and bounces to
            // the feed, so Facebook gets the desktop site by default.
            Key.desktopModeFacebook: true,
            Key.desktopModeInstagram: false,
            Key.allowReelPermalinks: false,
            Key.allowGroupPosts: true,
            Key.externalLinks: ExternalLinkBehavior.safari.rawValue,
            Key.showBlockToasts: true,
            Key.hideDistractions: true,
            Key.desktopViewportWidth: 760,
            Key.allowPosting: true
        ])
        facebookUsername = defaults.string(forKey: Key.facebookUsername) ?? ""
        instagramUsername = defaults.string(forKey: Key.instagramUsername) ?? ""
        desktopModeFacebook = defaults.bool(forKey: Key.desktopModeFacebook)
        desktopModeInstagram = defaults.bool(forKey: Key.desktopModeInstagram)
        allowReelPermalinks = defaults.bool(forKey: Key.allowReelPermalinks)
        allowGroupPosts = defaults.bool(forKey: Key.allowGroupPosts)
        externalLinks = ExternalLinkBehavior(rawValue: defaults.string(forKey: Key.externalLinks) ?? "") ?? .safari
        showBlockToasts = defaults.bool(forKey: Key.showBlockToasts)
        hideDistractions = defaults.bool(forKey: Key.hideDistractions)
        desktopViewportWidth = defaults.integer(forKey: Key.desktopViewportWidth)
        allowPosting = defaults.bool(forKey: Key.allowPosting)
    }

    /// Your own Facebook username (the part after facebook.com/). Lets you open
    /// your own profile to find your posts. Leave blank to block all profiles.
    @Published var facebookUsername: String {
        didSet { defaults.set(facebookUsername, forKey: Key.facebookUsername) }
    }

    /// Your own Instagram username. Same idea as above.
    @Published var instagramUsername: String {
        didSet { defaults.set(instagramUsername, forKey: Key.instagramUsername) }
    }

    /// Ask Facebook for the desktop site. Use this only if the mobile site
    /// refuses to show Messenger and pushes you to the app instead.
    @Published var desktopModeFacebook: Bool {
        didSet { defaults.set(desktopModeFacebook, forKey: Key.desktopModeFacebook) }
    }

    @Published var desktopModeInstagram: Bool {
        didSet { defaults.set(desktopModeInstagram, forKey: Key.desktopModeInstagram) }
    }

    /// Let a single Reel open when a notification points at it (to answer
    /// comments on your own Reels). Off by default because a Reel page can
    /// swipe into the next Reel.
    @Published var allowReelPermalinks: Bool {
        didSet { defaults.set(allowReelPermalinks, forKey: Key.allowReelPermalinks) }
    }

    /// Let single group posts open from notifications. Group feeds stay blocked.
    @Published var allowGroupPosts: Bool {
        didSet { defaults.set(allowGroupPosts, forKey: Key.allowGroupPosts) }
    }

    /// What to do with links that leave Facebook or Instagram.
    @Published var externalLinks: ExternalLinkBehavior {
        didSet { defaults.set(externalLinks.rawValue, forKey: Key.externalLinks) }
    }

    /// Show a short banner when something gets blocked.
    @Published var showBlockToasts: Bool {
        didSet { defaults.set(showBlockToasts, forKey: Key.showBlockToasts) }
    }

    /// Hide feed links, Reels tabs, and similar bait inside the pages.
    @Published var hideDistractions: Bool {
        didSet { defaults.set(hideDistractions, forKey: Key.hideDistractions) }
    }

    /// Lets you publish: the composer, Marketplace listings, creating a Story,
    /// and Go Live. Watching Reels and other people's Stories stays blocked.
    @Published var allowPosting: Bool {
        didSet { defaults.set(allowPosting, forKey: Key.allowPosting) }
    }

    /// How wide the desktop site lays itself out, in CSS pixels, when desktop
    /// mode is on. The page is scaled to fit the phone, so narrower is larger.
    @Published var desktopViewportWidth: Int {
        didSet { defaults.set(desktopViewportWidth, forKey: Key.desktopViewportWidth) }
    }

    /// The viewport width to force for a tab, or 0 to leave the page alone.
    func viewportWidth(for site: SiteKind) -> Int {
        switch site {
        case .facebook:
            return desktopModeFacebook ? desktopViewportWidth : 0
        case .instagram:
            return desktopModeInstagram ? desktopViewportWidth : 0
        case .other:
            return 0
        }
    }

    /// Snapshot used by the policy engine so it never touches UI state.
    var policyOptions: PolicyOptions {
        PolicyOptions(
            facebookUsername: facebookUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            instagramUsername: instagramUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            allowReelPermalinks: allowReelPermalinks,
            allowGroupPosts: allowGroupPosts,
            allowPosting: allowPosting
        )
    }
}
