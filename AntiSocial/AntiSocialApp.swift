import SwiftUI

/// Anti-Social
///
/// A locked-down browser for Facebook and Instagram that only lets you reach
/// the parts you actually need: Messenger, Marketplace, notifications, and
/// your own posts, where you answer comments. Feeds, Reels, Watch, Stories,
/// Explore, other people's posts, and other people's profiles are blocked
/// before they load.
@main
struct AntiSocialApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var pool: WebViewPool

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _pool = StateObject(wrappedValue: WebViewPool(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(pool)
        }
    }
}
