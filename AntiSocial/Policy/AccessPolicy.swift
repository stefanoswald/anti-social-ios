import Foundation

/// Settings the policy needs. Kept as a plain value so it is cheap to copy
/// into the web view delegates.
struct PolicyOptions: Equatable {
    var facebookUsername: String = ""
    var instagramUsername: String = ""
    /// Your numeric account IDs, read from each site's own login cookie.
    /// Links often name you by number instead of by username.
    var facebookUserID: String = ""
    var instagramUserID: String = ""
    /// Lets you publish: the composer, Marketplace listings, creating a Story,
    /// and Go Live.
    var allowPosting: Bool = true
    /// Other people's posts, Reels, and stories open when you tap them. The
    /// next one never opens by itself: swiping or autoplay into it is blocked.
    /// When this is off, only your own posts open, plus everything inside
    /// your groups.
    var openTappedPosts: Bool = true

    /// Every name the sites might use for you, lowercased.
    var ownIdentity: OwnIdentity {
        OwnIdentity(
            facebook: Self.names(facebookUsername, facebookUserID),
            instagram: Self.names(instagramUsername, instagramUserID)
        )
    }

    private static func names(_ values: String...) -> Set<String> {
        Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }
}

/// Who you are on each site, as lowercased usernames and numeric IDs.
struct OwnIdentity: Equatable {
    var facebook: Set<String> = []
    var instagram: Set<String> = []

    func names(for site: SiteKind) -> Set<String> {
        switch site {
        case .facebook: return facebook
        case .instagram: return instagram
        case .other: return []
        }
    }
}

/// What kind of single thing a link opens.
enum PostKind: Hashable {
    case facebookReel
    case facebookVideo
    case facebookPhoto
    case facebookPost
    case facebookGroupPost
    case facebookStory
    case instagramPost
    case instagramReel
    /// instagram.com/reels/<code>/ opens the swipeable Reels player.
    case instagramReelsPlayer
    case instagramStory
    case instagramHighlight
    /// Someone else's profile. It opens when you tap it, like a post, and
    /// only scrolls a short way (see Injected).
    case facebookProfile
    case instagramProfile

    var isProfile: Bool {
        self == .facebookProfile || self == .instagramProfile
    }

    /// Reels and videos, the things a player swipes through.
    var isVideo: Bool {
        switch self {
        case .facebookReel, .facebookVideo, .instagramReel, .instagramReelsPlayer:
            return true
        default:
            return false
        }
    }

    var isStory: Bool {
        switch self {
        case .facebookStory, .instagramStory, .instagramHighlight:
            return true
        default:
            return false
        }
    }
}

/// One post, Reel, video, photo, or story, named so the app can check whose
/// it is.
struct PostRef: Hashable {
    let site: SiteKind
    /// A stable name for the post, like "fb:video:1299494788874394" or
    /// "ig:DefPxYVO9YH". The app remembers your posts by this.
    let key: String
    /// The page to fetch to find out who made the post.
    let lookupURL: URL
    let kind: PostKind
    /// Set when the link itself names someone else as the owner. Such a post
    /// opens only if you tapped it, or if the app already knows it is yours
    /// (a collab, say).
    var otherOwner: String? = nil
}

/// What a link to a single post says about itself.
struct PostLink: Equatable {
    let ref: PostRef
    /// The username or ID in the link, lowercased, if the link names one.
    let owner: String?
    /// Posts and photos inside a group. Everything in your groups opens.
    var inGroup: Bool = false

    var kind: PostKind { ref.kind }
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
    /// A single post. It opens if it is yours, or if you tapped it. Anything
    /// else (the next Reel, autoplay) is blocked.
    case verify(PostRef)
}

enum SiteKind {
    case facebook
    case instagram
    case other
}

/// The rules. Every feed is blocked, and the rest is allowed only when it is
/// listed here.
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

    /// When a link itself proves the post is yours (your username or ID is in
    /// it), returns the post's key so later bare links to the same post open
    /// right away.
    func ownedPostKey(in url: URL) -> String? {
        guard let link = Self.postLink(in: url),
              let owner = link.owner,
              isOwn(owner, on: link.ref.site) else {
            return nil
        }
        return link.ref.key
    }

    /// Pages that list only your own posts: your Reels and Videos tabs on
    /// Facebook, and your grid on Instagram. Every post linked from one of
    /// these is yours, even when the link does not say so.
    func isOwnPostGrid(_ url: URL) -> Bool {
        let segments = Self.segments(of: url)
        switch Self.site(for: url) {
        case .facebook:
            if segments.first == "profile.php" {
                guard let id = Self.queryValue(url, named: "id"), isOwn(id, on: .facebook) else { return false }
                let tab = (Self.queryValue(url, named: "sk") ?? "").lowercased()
                return tab.hasPrefix("reels") || tab.hasPrefix("videos")
            }
            guard segments.count >= 2, isOwn(segments[0], on: .facebook) else { return false }
            return segments[1] == "reels" || segments[1] == "videos"
        case .instagram:
            guard let first = segments.first, isOwn(first, on: .instagram) else { return false }
            return segments.count == 1 || segments[1] == "reels"
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
        guard !name.contains("."), name.count >= 3, !isFacebookRoute(name) else {
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

    /// Describes a link to one post, Reel, video, photo, or story. Nil for
    /// anything else (feeds, profiles, inboxes).
    static func postLink(in url: URL) -> PostLink? {
        switch site(for: url) {
        case .facebook: return facebookPostLink(url)
        case .instagram: return instagramPostLink(url)
        case .other: return nil
        }
    }

    // MARK: - Your posts

    private func isOwn(_ name: String, on site: SiteKind) -> Bool {
        let name = name.lowercased()
        return !name.isEmpty && options.ownIdentity.names(for: site).contains(name)
    }

    /// Whether the app knows you well enough to say that `owner` is not you.
    /// A number can only be ruled out once your ID is known, and a name once
    /// your username is known.
    private func canRuleOut(_ owner: String, on site: SiteKind) -> Bool {
        let names = options.ownIdentity.names(for: site)
        if Self.isDigits(owner) {
            return names.contains { Self.isDigits($0) }
        }
        return names.contains { !Self.isDigits($0) }
    }

    private func decidePost(_ link: PostLink) -> PolicyDecision {
        // Everything inside your groups opens.
        if link.inGroup {
            return .allow
        }
        let site = link.ref.site
        if let owner = link.owner {
            if isOwn(owner, on: site) {
                return .allow
            }
            if canRuleOut(owner, on: site) {
                var ref = link.ref
                ref.otherOwner = owner
                return .verify(ref)
            }
        }
        return .verify(link.ref)
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
        // The things this app exists for.
        "messages", "marketplace", "notifications",
        // Login and account plumbing.
        "login", "login.php", "checkpoint", "two_step_verification", "two_factor",
        "recover", "recover.php", "confirmemail.php", "device-based", "auth", "oauth",
        "dialog", "x", "security", "cookie", "consent", "privacy", "policies",
        "policy", "legal", "terms", "help", "settings", "logout", "logout.php",
        "accountscenter", "ajax", "api", "async", "rsrc.php", "si", "images",
        "language", "mobile",
        // Redirect helpers used by notification links. Single posts under
        // these (photo, permalink.php, story.php) are judged as posts first.
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

    /// First segments that are Facebook features, never usernames.
    private static let facebookRouteSegments: Set<String> = [
        "reel", "watch", "video", "videos", "video.php", "groups", "profile.php",
        "l.php", "media", "sharer", "sharer.php", "plugins", "story", "stories"
    ]

    /// Second segments under /stories/ that are pages, not someone's stories.
    private static let facebookStoryPages: Set<String> = ["create", "archive"]

    static func isFacebookRoute(_ segment: String) -> Bool {
        let segment = segment.lowercased()
        return facebookRouteSegments.contains(segment)
            || facebookAllowedSegments.contains(segment)
            || facebookBlockedSegments[segment] != nil
    }

    private func decideFacebook(_ url: URL, inPage: Bool = false) -> PolicyDecision {
        let segments = Self.segments(of: url)
        guard let first = segments.first else {
            return .block(reason: "Home feed")
        }

        if first == "l.php" {
            return shimDecision(url)
        }

        // One post, Reel, video, photo, or story. Checked before anything
        // else because some of these sit under segments that are otherwise
        // always allowed (photo, permalink.php) or always blocked (stories).
        if let link = Self.facebookPostLink(url) {
            return decidePost(link)
        }

        if Self.facebookAllowedSegments.contains(first) {
            return .allow
        }

        // Accounts without a vanity name live at /profile.php?id=<number>.
        if first == "profile.php" {
            let id = Self.queryValue(url, named: "id")
            if let id, isOwn(id, on: .facebook) {
                return .allow
            }
            if let id, Self.isDigits(id) {
                return profileDecision(site: .facebook, name: id)
            }
            return .block(reason: "Profile")
        }

        // Groups: any one group is fine, with everything in it. The mixed
        // feed of all your groups and the suggestions are not.
        if first == "groups" {
            return decideGroups(url, segments: segments)
        }

        // Publishing. These sit underneath segments that are otherwise
        // blocked, so they have to be checked before the blocklist.
        // Creating a Story is allowed; the Stories feed is not.
        // Going live is allowed; the Live directory of other people's
        // broadcasts is not.
        if options.allowPosting, segments.count >= 2 {
            switch (first, segments[1]) {
            case ("stories", "create"),
                 ("live", "producer"),
                 ("reel", "create"),
                 ("reels", "create"),
                 ("media", "upload"),
                 ("video", "upload"):
                return .allow
            default:
                break
            }
        }

        // Your own story archive.
        if first == "stories", segments.count >= 2, segments[1] == "archive" {
            return .allow
        }

        if let reason = Self.facebookBlockedSegments[first] {
            return .block(reason: reason)
        }

        switch first {
        case "reel":
            return .block(reason: "Reels")
        case "watch":
            // /watch/?v=123 is one video and was handled above. /watch/ alone
            // is the video feed.
            return .block(reason: "Watch")
        case "video", "videos", "video.php":
            return .block(reason: "Video feed")
        default:
            break
        }

        // Everything left looks like /<username>/... which is a profile.
        // Yours is open, with all its tabs (posts, Reels, videos, photos).
        if isOwn(first, on: .facebook) {
            return .allow
        }

        // Someone else's opens when you tap a link to it, so you can see who
        // they are. The page only scrolls a short way (see Injected).
        if !Self.isFacebookRoute(first), Self.isFacebookName(first) {
            return profileDecision(site: .facebook, name: first)
        }

        return .block(reason: "Profile")
    }

    /// Someone else's profile: opens like a post you tap, and never by itself.
    /// Every tab of one profile (about, photos) shares one key.
    private func profileDecision(site: SiteKind, name: String) -> PolicyDecision {
        let owner = name.lowercased()
        let isInstagram = site == .instagram
        let home = isInstagram ? "https://www.instagram.com/\(owner)/" : "https://www.facebook.com/\(owner)/"
        let ref = PostRef(
            site: site,
            key: (isInstagram ? "ig" : "fb") + ":profile:" + owner,
            lookupURL: URL(string: home) ?? URL(string: "https://www.facebook.com/")!,
            kind: isInstagram ? .instagramProfile : .facebookProfile,
            otherOwner: owner
        )
        return .verify(ref)
    }

    /// Facebook vanity names: lowercase letters, digits, "." and "-".
    private static func isFacebookName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 100 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            let letter = scalar.value >= 97 && scalar.value <= 122
            let digit = scalar.value >= 48 && scalar.value <= 57
            return letter || digit || scalar == "." || scalar == "-"
        }
    }

    private func decideGroups(_ url: URL, segments: [String]) -> PolicyDecision {
        guard segments.count >= 2 else {
            // facebook.com/groups/ is the mixed feed of all your groups.
            if Self.queryValue(url, named: "category") == "create" {
                return .allow
            }
            return .block(reason: "Groups feed")
        }
        switch segments[1] {
        case "feed":
            return .block(reason: "Groups feed")
        case "discover":
            return .block(reason: "Group suggestions")
        default:
            // joins (your groups), create, and any one group.
            return .allow
        }
    }

    private static func facebookPostLink(_ url: URL) -> PostLink? {
        let raw = rawSegments(of: url)
        guard let firstRaw = raw.first else { return nil }
        let first = firstRaw.lowercased()
        let lookup = facebookLookupURL(for: url)

        func link(_ key: String, owner: String?, kind: PostKind, inGroup: Bool = false) -> PostLink {
            PostLink(
                ref: PostRef(site: .facebook, key: key, lookupURL: lookup, kind: kind),
                owner: owner.flatMap { $0.isEmpty ? nil : $0.lowercased() },
                inGroup: inGroup
            )
        }

        switch first {
        case "reel":
            guard raw.count >= 2, isDigits(raw[1]) else { return nil }
            return link("fb:video:\(raw[1])", owner: nil, kind: .facebookReel)

        case "watch", "video.php":
            guard let video = queryValue(url, named: "v"), isDigits(video) else { return nil }
            return link("fb:video:\(video)", owner: nil, kind: .facebookVideo)

        case "videos", "video":
            guard raw.count >= 2, isDigits(raw[1]) else { return nil }
            return link("fb:video:\(raw[1])", owner: nil, kind: .facebookVideo)

        case "photo", "photo.php":
            guard let photo = queryValue(url, named: "fbid"), isDigits(photo) else { return nil }
            let set = queryValue(url, named: "set") ?? ""
            // Photos in a group carry the group (idorvanity) or a group set.
            let inGroup = !(queryValue(url, named: "idorvanity") ?? "").isEmpty
                || set.hasPrefix("g.") || set.hasPrefix("gm.")
            return link("fb:photo:\(photo)", owner: ownerOfPhotoSet(set), kind: .facebookPhoto, inGroup: inGroup)

        case "permalink.php", "story.php":
            guard let story = queryValue(url, named: "story_fbid"), !story.isEmpty else { return nil }
            return link("fb:post:\(story)", owner: queryValue(url, named: "id"), kind: .facebookPost)

        case "groups":
            guard raw.count >= 4, ["posts", "permalink"].contains(raw[2].lowercased()) else { return nil }
            return link("fb:group:\(raw[1].lowercased()):\(raw[3])", owner: nil, kind: .facebookGroupPost, inGroup: true)

        case "stories":
            // /stories/<owner id>/<story>/ is one person's stories.
            guard raw.count >= 2, !facebookStoryPages.contains(raw[1].lowercased()) else { return nil }
            let bucket = raw[1]
            return link("fb:story:\(bucket.lowercased())", owner: bucket, kind: .facebookStory)

        default:
            break
        }

        // /<username>/posts/<id>, /<username>/videos/<id>, /<username>/photos/.../<id>
        guard raw.count >= 3, !isFacebookRoute(first) else { return nil }
        switch raw[1].lowercased() {
        case "posts", "permalink":
            return link("fb:post:\(raw[2])", owner: first, kind: .facebookPost)
        case "videos":
            guard let video = raw.dropFirst(2).last(where: { isDigits($0) }) else { return nil }
            return link("fb:video:\(video)", owner: first, kind: .facebookVideo)
        case "photos":
            guard let photo = raw.dropFirst(2).last(where: { isDigits($0) }) else { return nil }
            return link("fb:photo:\(photo)", owner: first, kind: .facebookPhoto)
        default:
            return nil
        }
    }

    /// Photo links carry the album they came from. "pb.<owner id>.<...>" is
    /// the owner's profile photos, which names the owner.
    private static func ownerOfPhotoSet(_ set: String?) -> String? {
        guard let parts = set?.split(separator: ".", omittingEmptySubsequences: false),
              parts.count >= 2, parts[0] == "pb" else { return nil }
        let owner = String(parts[1])
        return isDigits(owner) ? owner : nil
    }

    /// The post's own page without tracking clutter, on the desktop host,
    /// which is the version that names the owner in its header.
    private static func facebookLookupURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let keep: Set<String> = ["v", "fbid", "story_fbid", "id", "set"]
        let items = (components.queryItems ?? []).filter { keep.contains($0.name) }
        components.queryItems = items.isEmpty ? nil : items
        components.fragment = nil
        components.scheme = "https"
        let host = (components.host ?? "").lowercased()
        if host == "facebook.com" || host == "m.facebook.com" || host == "mbasic.facebook.com" || host == "web.facebook.com" {
            components.host = "www.facebook.com"
        }
        return components.url ?? url
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

    static func isInstagramRoute(_ segment: String) -> Bool {
        let segment = segment.lowercased()
        return ["p", "reel", "tv", "linkshim", "create"].contains(segment)
            || instagramAllowedSegments.contains(segment)
            || instagramBlockedSegments[segment] != nil
    }

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
        if first == "create", segments.count >= 2 {
            if options.allowPosting, inPage || Self.instagramCreateSteps.contains(segments[1]) {
                return .allow
            }
            // Never the profile of the person called "create".
            return .block(reason: options.allowPosting ? "Create page" : "Posting is off")
        }

        // One post, Reel, or story. This is where you answer comments.
        if let link = Self.instagramPostLink(url) {
            return decidePost(link)
        }

        if let reason = Self.instagramBlockedSegments[first] {
            return .block(reason: reason)
        }

        switch first {
        case "reel":
            return .block(reason: "Reels")
        case "p", "tv":
            return .block(reason: "Feed")
        default:
            break
        }

        if isOwn(first, on: .instagram) {
            // Posts other people tagged you in are their posts. The grid opens
            // only when their posts open when you tap them.
            if segments.count >= 2, segments[1] == "tagged", !options.openTappedPosts {
                return .block(reason: "Tagged posts")
            }
            return .allow
        }

        // Someone else's profile opens when you tap a link to it.
        if Self.isInstagramUsername(first) {
            return profileDecision(site: .instagram, name: first)
        }

        return .block(reason: "Profile")
    }

    private static func instagramPostLink(_ url: URL) -> PostLink? {
        let raw = rawSegments(of: url)
        guard let firstRaw = raw.first else { return nil }
        let first = firstRaw.lowercased()

        func link(_ code: String, owner: String?, kind: PostKind) -> PostLink {
            let lookup = URL(string: "https://www.instagram.com/p/\(code)/") ?? url
            return PostLink(
                ref: PostRef(site: .instagram, key: "ig:\(code)", lookupURL: lookup, kind: kind),
                owner: owner?.lowercased()
            )
        }

        switch first {
        case "stories":
            guard raw.count >= 2 else { return nil }
            if raw[1].lowercased() == "highlights" {
                guard raw.count >= 3, isDigits(raw[2]) else { return nil }
                let id = raw[2]
                let highlightLookup = URL(string: "https://www.instagram.com/stories/highlights/\(id)/") ?? url
                return PostLink(
                    ref: PostRef(site: .instagram, key: "ig:highlight:\(id)", lookupURL: highlightLookup, kind: .instagramHighlight),
                    owner: nil
                )
            }
            let user = raw[1].lowercased()
            guard isInstagramUsername(user) else { return nil }
            let storyLookup = URL(string: "https://www.instagram.com/stories/\(user)/") ?? url
            return PostLink(
                ref: PostRef(site: .instagram, key: "ig:story:\(user)", lookupURL: storyLookup, kind: .instagramStory),
                owner: user
            )

        case "p", "tv", "reel", "reels":
            guard raw.count >= 2, isShortcode(raw[1]) else { return nil }
            let kind: PostKind
            switch first {
            case "reel": kind = .instagramReel
            case "reels": kind = .instagramReelsPlayer
            default: kind = .instagramPost
            }
            return link(raw[1], owner: nil, kind: kind)
        default:
            break
        }

        // Newer links put the username first: /<user>/p/<code>/ and
        // /<user>/reel/<code>/.
        guard raw.count >= 3, isShortcode(raw[2]), !isInstagramRoute(first) else { return nil }
        switch raw[1].lowercased() {
        case "p", "tv":
            return link(raw[2], owner: first, kind: .instagramPost)
        case "reel":
            return link(raw[2], owner: first, kind: .instagramReel)
        default:
            return nil
        }
    }

    /// Words that sit where a post code would, but are pages, not posts.
    private static let instagramNonCodes: Set<String> = [
        "audio", "comments", "liked_by", "embed", "create", "explore"
    ]

    /// Instagram usernames: up to 30 letters, digits, "." and "_".
    private static func isInstagramUsername(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 30 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || scalar == "." || scalar == "_"
        }
    }

    /// Instagram post codes: letters, digits, "-" and "_".
    private static func isShortcode(_ text: String) -> Bool {
        guard text.count >= 5, text.count <= 80,
              !instagramNonCodes.contains(text.lowercased()) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || scalar == "-" || scalar == "_"
        }
    }

    // MARK: - Link shims

    private static let linkShimHosts = [
        "l.facebook.com", "lm.facebook.com", "l.messenger.com", "l.instagram.com"
    ]

    private static func isLinkShimHost(_ host: String) -> Bool {
        hostMatches(host, any: linkShimHosts)
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
        rawSegments(of: url).map { $0.lowercased() }
    }

    /// Path segments as written. Instagram post codes and some Facebook post
    /// IDs are case-sensitive, so these are not lowercased.
    static func rawSegments(of url: URL) -> [String] {
        url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    static func queryValue(_ url: URL, named name: String) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }
        return items.first { $0.name == name }?.value
    }
}
