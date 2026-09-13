import Foundation

/// Settings the policy needs. Kept as a plain value so it is cheap to copy
/// into the web view delegates.
struct PolicyOptions: Equatable {
    var facebookUsername: String = ""
    var instagramUsername: String = ""
    var allowReelPermalinks: Bool = false
    var allowGroupPosts: Bool = true
    /// Lets you publish: the composer, Marketplace listings, creating a Story,
    /// and Go Live. Watching other people's Reels and Stories stays blocked
    /// either way, so this opens the outbox, not the feed.
    var allowPosting: Bool = true
}

/// What to do with a navigation.
enum PolicyDecision: Equatable {
    /// Load it.
    case allow
    /// Do not load it. `reason` is short and user-facing ("Home feed").
    case block(reason: String)
    /// The link leaves Facebook and Instagram. The app decides whether to hand
    /// it to Safari or drop it.
    case external(URL)
}

enum SiteKind {
    case facebook
    case instagram
    case other
}

/// The allowlist. Everything not explicitly allowed here is blocked.
///
/// The rules work on URL paths, so they hold no matter what the page looks
/// like. Element hiding (see `Injected.swift`) is only cosmetic on top of this.
struct AccessPolicy {

    var options: PolicyOptions

    init(options: PolicyOptions = PolicyOptions()) {
        self.options = options
    }

    // MARK: - Public

    /// `inPage` is true when the page changed its own URL (a single-page-app
    /// navigation) rather than loading fresh. Some create flows reuse paths
    /// that mean something else on a cold load, so the two are not identical.
    func decide(_ url: URL, inPage: Bool = false) -> PolicyDecision {
        guard let scheme = url.scheme?.lowercased() else {
            return .block(reason: "Unknown link")
        }

        switch scheme {
        case "about", "blob", "data":
            return .allow
        case "http", "https":
            break
        case "mailto", "tel", "sms", "facetime", "maps":
            return .external(url)
        default:
            // fb://, instagram://, itms-apps:// and friends. These try to open
            // the real apps. Never.
            return .block(reason: "App link")
        }

        let host = (url.host ?? "").lowercased()

        if Self.isLinkShimHost(host) {
            return shimDecision(url)
        }

        // Messenger has no feed. Every path there is a conversation.
        if Self.hostMatches(host, any: Self.messengerHosts) {
            return .allow
        }

        // Image and attachment servers. A tapped photo or a downloaded file
        // can land here as a full page. Nothing to scroll.
        if Self.hostMatches(host, any: Self.staticHosts) {
            return .allow
        }

        switch Self.site(for: url) {
        case .facebook:
            return decideFacebook(url, inPage: inPage)
        case .instagram:
            return decideInstagram(url, inPage: inPage)
        case .other:
            return .external(url)
        }
    }

    /// Login, checkpoint, and consent pages. After one of these finishes it
    /// usually redirects to the home feed. When that redirect gets blocked the
    /// app should jump to the tab's home instead of leaving the login form on
    /// screen.
    func isAuthPage(_ url: URL?) -> Bool {
        guard let url else { return true }
        let first = Self.segments(of: url).first ?? ""
        switch Self.site(for: url) {
        case .facebook:
            return Self.facebookAuthSegments.contains(first)
        case .instagram:
            return Self.instagramAuthSegments.contains(first)
        case .other:
            return false
        }
    }

    /// Reads a username out of a Facebook profile URL, which is what
    /// facebook.com/me redirects to. Returns nil for anything that is not
    /// shaped like a profile, so a redirect to the feed teaches nothing.
    static func ownProfileName(from url: URL) -> String? {
        guard site(for: url) == .facebook else { return nil }
        let segments = segments(of: url)

        if segments.first == "profile.php", let id = queryValue(url, named: "id"), !id.isEmpty {
            return id
        }

        guard segments.count == 1, let name = segments.first else { return nil }
        // Reject the things a vanity URL can never be.
        guard !name.contains("."), name.count >= 3,
              facebookBlockedSegments[name] == nil,
              !facebookAllowedSegments.contains(name) else {
            return nil
        }
        return name
    }

    static func site(for url: URL) -> SiteKind {
        let host = (url.host ?? "").lowercased()
        if hostMatches(host, any: facebookHosts) { return .facebook }
        if hostMatches(host, any: instagramHosts) { return .instagram }
        return .other
    }

    // MARK: - Facebook

    private static let facebookHosts = [
        "facebook.com", "fb.com", "messenger.com", "meta.com", "fb.me"
    ]

    private static let messengerHosts = [
        "messenger.com"
    ]

    private static let staticHosts = [
        "fbcdn.net", "fbsbx.com", "facebook.net", "cdninstagram.com"
    ]

    private static let facebookAuthSegments: Set<String> = [
        "login", "login.php", "checkpoint", "two_step_verification", "two_factor",
        "recover", "confirmemail.php", "device-based", "auth", "oauth", "dialog",
        "x", "security", "cookie", "consent", "privacy", "logout", "logout.php",
        "accountscenter", "recover.php"
    ]

    /// First path segments that are always fine on Facebook.
    private static let facebookAllowedSegments: Set<String> = [
        // The three things this app exists for.
        "messages", "marketplace", "notifications",
        // Login and account plumbing.
        "login", "login.php", "checkpoint", "two_step_verification", "two_factor",
        "recover", "recover.php", "confirmemail.php", "device-based", "auth", "oauth",
        "dialog", "x", "security", "cookie", "consent", "privacy", "policies",
        "policy", "legal", "terms", "help", "settings", "logout", "logout.php",
        "accountscenter", "ajax", "api", "async", "rsrc.php", "si", "images",
        "language", "mobile",
        // Redirect helpers used by notification links.
        "n", "nd", "share", "permalink.php", "story.php", "photo.php", "photo",
        "comment", "ufi", "a", "notifications.php", "messages.php",
        // Your own creator tools. No feed on these pages.
        "professional_dashboard", "content", "me"
    ]

    private static let facebookBlockedSegments: [String: String] = [
        "home.php": "Home feed",
        "reels": "Reels",
        "stories": "Stories",
        "friends": "Friends",
        "gaming": "Gaming",
        "games": "Gaming",
        "events": "Events",
        "memories": "Memories",
        "saved": "Saved",
        "bookmarks": "Menu",
        "menu": "Menu",
        "pages": "Pages",
        "hashtag": "Hashtag feed",
        "search": "Search",
        "fundraisers": "Fundraisers",
        "dating": "Dating",
        "jobs": "Jobs",
        "weather": "Weather",
        "news": "News",
        "offers": "Offers",
        "live": "Live",
        "places": "Places",
        "people": "People",
        "public": "Public posts",
        "topic": "Topics",
        "explore": "Explore",
        "feeds": "Feeds",
        "profile.php": "Profile"
    ]

    private func decideFacebook(_ url: URL, inPage: Bool = false) -> PolicyDecision {
        let segments = Self.segments(of: url)
        guard let first = segments.first else {
            return .block(reason: "Home feed")
        }

        if first == "l.php" {
            return shimDecision(url)
        }

        if Self.facebookAllowedSegments.contains(first) {
            return .allow
        }

        // Accounts without a vanity name live at /profile.php?id=<number>.
        // Enter that number as your username to allow it.
        if first == "profile.php",
           !options.facebookUsername.isEmpty,
           Self.queryValue(url, named: "id") == options.facebookUsername {
            return .allow
        }

        // Publishing. These sit underneath segments that are otherwise
        // blocked, so they have to be checked before the blocklist.
        // Creating a Story is allowed; watching other people's is not.
        // Going live is allowed; the Live directory of other people's
        // broadcasts is not.
        if options.allowPosting, segments.count >= 2 {
            switch (first, segments[1]) {
            case ("stories", "create"),
                 ("live", "producer"),
                 ("reel", "create"),
                 ("media", "upload"),
                 ("video", "upload"):
                return .allow
            default:
                break
            }
        }

        if let reason = Self.facebookBlockedSegments[first] {
            return .block(reason: reason)
        }

        switch first {
        case "reel":
            if segments.count >= 2 && options.allowReelPermalinks {
                return .allow
            }
            return .block(reason: "Reels")

        case "watch":
            // /watch/?v=123 is one video. /watch/ alone is the video feed.
            if Self.hasQueryItem(url, named: "v") {
                return .allow
            }
            return .block(reason: "Watch")

        case "video", "videos":
            if segments.count >= 2 || Self.hasQueryItem(url, named: "v") {
                return .allow
            }
            return .block(reason: "Video feed")

        case "groups":
            // /groups/<id>/posts/<id> and /groups/<id>/permalink/<id> are single
            // posts. Anything shorter is a group feed or the groups feed.
            if segments.count >= 4,
               ["posts", "permalink"].contains(segments[2]),
               options.allowGroupPosts {
                return .allow
            }
            return .block(reason: "Groups")

        default:
            break
        }

        // Everything left looks like /<username>/... which is a profile.
        let isOwnProfile = !options.facebookUsername.isEmpty
            && first == options.facebookUsername.lowercased()

        if segments.count >= 2 {
            switch segments[1] {
            case "posts", "permalink", "photos":
                return .allow
            case "videos":
                // /<user>/videos/<id> is one video. /<user>/videos is a list.
                return segments.count >= 3 ? .allow : .block(reason: "Video list")
            case "reels":
                return .block(reason: "Reels")
            default:
                return isOwnProfile ? .allow : .block(reason: "Profile")
            }
        }

        return isOwnProfile ? .allow : .block(reason: "Profile")
    }

    // MARK: - Instagram

    private static let instagramHosts = [
        "instagram.com", "cdninstagram.com", "ig.me"
    ]

    private static let instagramAuthSegments: Set<String> = [
        "accounts", "challenge", "auth_platform", "oauth", "login", "two_factor",
        "consent", "session", "coming_soon", "logout"
    ]

    private static let instagramAllowedSegments: Set<String> = [
        "direct", "notifications",
        "accounts", "challenge", "auth_platform", "oauth", "api", "ajax", "graphql",
        "logging", "qp", "web", "login", "logout", "session", "consent", "terms",
        "legal", "privacy", "about", "emails", "two_factor", "coming_soon",
        "static", "data", "push", "help", "settings", "your_activity"
    ]

    /// Steps in Instagram's post composer.
    private static let instagramCreateSteps: Set<String> = [
        "select", "style", "crop", "filter", "details", "caption", "share",
        "edit", "story", "reel", "post", "cover", "location", "tag"
    ]

    private static let instagramBlockedSegments: [String: String] = [
        "explore": "Explore",
        "reels": "Reels",
        "stories": "Stories",
        "search": "Search",
        "shopping": "Shopping",
        "shop": "Shopping",
        "locations": "Locations",
        "topics": "Topics",
        "guides": "Guides",
        "live": "Live",
        "lite": "Feed",
        "threads": "Threads"
    ]

    private func decideInstagram(_ url: URL, inPage: Bool = false) -> PolicyDecision {
        let segments = Self.segments(of: url)
        guard let first = segments.first else {
            return .block(reason: "Home feed")
        }

        if first == "linkshim" {
            return shimDecision(url)
        }

        if Self.instagramAllowedSegments.contains(first) {
            return .allow
        }

        // The create flow. Careful here: "create" is also a real person's
        // username, so instagram.com/create on its own is that profile, not a
        // composer. Only the deeper step paths are the create flow. When the
        // page pushes the URL itself the user cannot have typed it, so any
        // step name is fine; on a cold load only the known steps are.
        if options.allowPosting, first == "create", segments.count >= 2 {
            if inPage || Self.instagramCreateSteps.contains(segments[1]) {
                return .allow
            }
        }

        if let reason = Self.instagramBlockedSegments[first] {
            return .block(reason: reason)
        }

        switch first {
        case "p", "tv":
            // A single post. This is where you answer comments.
            return segments.count >= 2 ? .allow : .block(reason: "Feed")

        case "reel":
            if segments.count >= 2 && options.allowReelPermalinks {
                return .allow
            }
            return .block(reason: "Reels")

        default:
            break
        }

        // Newer links put the username first: /<user>/p/<code>/ and
        // /<user>/reel/<code>/. Still a single post.
        if segments.count >= 3 {
            switch segments[1] {
            case "p", "tv":
                return .allow
            case "reel":
                return options.allowReelPermalinks ? .allow : .block(reason: "Reels")
            default:
                break
            }
        }

        let isOwnProfile = !options.instagramUsername.isEmpty
            && first == options.instagramUsername.lowercased()

        if isOwnProfile {
            if segments.count >= 2 && segments[1] == "reels" {
                return .block(reason: "Reels")
            }
            return .allow
        }

        return .block(reason: "Profile")
    }

    // MARK: - Link shims

    private static let linkShimHosts = [
        "l.facebook.com", "lm.facebook.com", "l.messenger.com", "l.instagram.com"
    ]

    private static func isLinkShimHost(_ host: String) -> Bool {
        linkShimHosts.contains(host)
    }

    /// Facebook and Instagram wrap outbound links in a redirect page with the
    /// real target in a `u` parameter. Unwrap it and treat it as external.
    private func shimDecision(_ url: URL) -> PolicyDecision {
        if let target = Self.queryValue(url, named: "u"),
           let targetURL = URL(string: target) {
            return decide(targetURL)
        }
        return .block(reason: "Redirect")
    }

    // MARK: - Helpers

    private static func hostMatches(_ host: String, any domains: [String]) -> Bool {
        for domain in domains where host == domain || host.hasSuffix("." + domain) {
            return true
        }
        return false
    }

    /// Lowercased, non-empty path segments. "/Messages/t/123/" -> ["messages", "t", "123"].
    static func segments(of url: URL) -> [String] {
        url.path
            .lowercased()
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func hasQueryItem(_ url: URL, named name: String) -> Bool {
        queryValue(url, named: name) != nil
    }

    static func queryValue(_ url: URL, named name: String) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }
        return items.first { $0.name == name }?.value
    }
}
