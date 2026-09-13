import Foundation

/// One tab in the app. Each tab owns a web view that starts at `home` and is
/// bounced back to `home` whenever a blocked page tries to load.
struct WebTab: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let home: URL

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

    static let instagramInbox = WebTab(
        id: "ig-inbox",
        title: "IG Inbox",
        systemImage: "paperplane.fill",
        home: URL(string: "https://www.instagram.com/direct/inbox/")!
    )

    static let instagramNotifications = WebTab(
        id: "ig-notifications",
        title: "IG Alerts",
        systemImage: "heart.fill",
        home: URL(string: "https://www.instagram.com/notifications/")!
    )

    static let all: [WebTab] = [
        .facebookMessages,
        .facebookMarketplace,
        .facebookNotifications,
        .instagramInbox,
        .instagramNotifications
    ]
}
