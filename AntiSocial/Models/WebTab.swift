import Foundation

/// One page in the app. Each page owns a web view that starts at `home` and is
/// bounced back to `home` whenever a blocked page tries to load.
struct WebTab: Identifiable, Hashable {
    let id: String
    let title: String
    /// The label in the switch at the top of a tab that holds more than one
    /// page.
    let shortTitle: String
    let systemImage: String
    let home: URL

    init(id: String, title: String, shortTitle: String? = nil, systemImage: String, home: URL) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.systemImage = systemImage
        self.home = home
    }

    static let facebookMessages = WebTab(
        id: "fb-messages",
        title: "Messages",
        systemImage: "bubble.left.and.bubble.right.fill",
        home: URL(string: "https://www.facebook.com/messages/")!
    )

    static let facebookMarketplace = WebTab(
        id: "fb-marketplace",
        title: "Marketplace",
        systemImage: "storefront.fill",
        home: URL(string: "https://www.facebook.com/marketplace/")!
    )

    static let facebookNotifications = WebTab(
        id: "fb-notifications",
        title: "Alerts",
        systemImage: "bell.fill",
        home: URL(string: "https://www.facebook.com/notifications/")!
    )

    /// Your own Facebook profile. Facebook answers /me with a redirect to it.
    static let facebookMyPosts = WebTab(
        id: "fb-my-posts",
        title: "My Posts",
        systemImage: "square.grid.2x2.fill",
        home: URL(string: "https://www.facebook.com/me")!
    )

    /// The groups you are in. Each group opens in full. The mixed Groups feed
    /// stays blocked.
    static let facebookGroups = WebTab(
        id: "fb-groups",
        title: "Groups",
        systemImage: "person.3.fill",
        home: URL(string: "https://www.facebook.com/groups/joins/")!
    )

    static let instagramInbox = WebTab(
        id: "ig-inbox",
        title: "IG Inbox",
        systemImage: "paperplane.fill",
        home: URL(string: "https://www.instagram.com/direct/inbox/")!
    )

    static let instagramNotifications = WebTab(
        id: "ig-notifications",
        title: "IG Alerts",
        shortTitle: "Alerts",
        systemImage: "heart.fill",
        home: URL(string: "https://www.instagram.com/notifications/")!
    )

    /// Your own Instagram grid. The real address needs your username, so the
    /// web controller swaps it in when it loads (see `homeURL`).
    static let instagramMyPosts = WebTab(
        id: "ig-my-posts",
        title: "My Posts",
        systemImage: "square.grid.3x3.fill",
        home: URL(string: "https://www.instagram.com/")!
    )
}

/// One button in the tab bar. Most hold a single page. The two Alerts tabs
/// also hold your own posts, and the Facebook one holds your groups. You pick
/// the page with a switch at the top.
struct TabGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let pages: [WebTab]

    static let messages = TabGroup(
        id: "messages",
        title: "Messages",
        systemImage: "bubble.left.and.bubble.right.fill",
        pages: [.facebookMessages]
    )

    static let marketplace = TabGroup(
        id: "marketplace",
        title: "Marketplace",
        systemImage: "storefront.fill",
        pages: [.facebookMarketplace]
    )

    static let facebook = TabGroup(
        id: "facebook",
        title: "Alerts",
        systemImage: "bell.fill",
        pages: [.facebookNotifications, .facebookMyPosts, .facebookGroups]
    )

    static let instagramInbox = TabGroup(
        id: "ig-inbox",
        title: "IG Inbox",
        systemImage: "paperplane.fill",
        pages: [.instagramInbox]
    )

    static let instagram = TabGroup(
        id: "instagram",
        title: "IG Alerts",
        systemImage: "heart.fill",
        pages: [.instagramNotifications, .instagramMyPosts]
    )

    static let all: [TabGroup] = [
        .messages,
        .marketplace,
        .facebook,
        .instagramInbox,
        .instagram
    ]
}
