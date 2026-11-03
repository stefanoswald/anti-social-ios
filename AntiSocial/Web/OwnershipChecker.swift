import Combine
import Foundation
import WebKit

/// Works out whether a post is yours, and remembers the answer.
///
/// The fast path is memory. The app remembers every post it has seen with
/// your name in the link, every post on your own Reels grid, and every post
/// it has checked before. Anything new is looked up once: the app fetches the
/// post's page and reads who the page says made it.
@MainActor
final class OwnershipChecker: ObservableObject {

    /// How many posts the app knows are yours. Shown in Diagnostics.
    @Published private(set) var knownCount = 0

    /// Fired when new posts are added to the list, so the pages can learn
    /// them too.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let dataStore: WKWebsiteDataStore
    private var mineInOrder: [String]
    private var mine: Set<String>
    private var others: [String: String] = [:]
    private var inFlight: [String: Task<Ownership, Never>] = [:]

    private static let storageKey = "ownPostKeys"
    private static let maxRemembered = 3000

    init(dataStore: WKWebsiteDataStore, defaults: UserDefaults = .standard) {
        self.dataStore = dataStore
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        mineInOrder = saved
        mine = Set(saved)
        knownCount = saved.count
    }

    /// The answer if the app already has one.
    func verdict(for ref: PostRef) -> Ownership? {
        if mine.contains(ref.key) { return .mine }
        if let owner = others[ref.key] { return .someoneElse(owner) }
        return nil
    }

    /// Remembers posts as yours, saving once for the whole batch. Returns the
    /// ones that were new.
    @discardableResult
    func markMine(_ keys: [String]) -> [String] {
        var added: [String] = []
        for key in keys where !key.isEmpty && !mine.contains(key) {
            mine.insert(key)
            mineInOrder.append(key)
            others[key] = nil
            added.append(key)
        }
        guard !added.isEmpty else { return [] }
        if mineInOrder.count > Self.maxRemembered {
            let extra = mineInOrder.count - Self.maxRemembered
            for old in mineInOrder.prefix(extra) {
                mine.remove(old)
            }
            mineInOrder.removeFirst(extra)
        }
        defaults.set(mineInOrder, forKey: Self.storageKey)
        knownCount = mineInOrder.count
        onChange?()
        return added
    }

    /// The most recently learned posts, newest last.
    func recentKeys(limit: Int) -> [String] {
        Array(mineInOrder.suffix(limit))
    }

    func forgetAll() {
        mine = []
        mineInOrder = []
        others = [:]
        defaults.removeObject(forKey: Self.storageKey)
        knownCount = 0
        onChange?()
    }

    /// Answers whether the post is yours, looking it up if needed. Two
    /// requests for the same post share one lookup.
    func check(_ ref: PostRef, identity: OwnIdentity) async -> Ownership {
        if let known = verdict(for: ref) {
            return known
        }
        if let running = inFlight[ref.key] {
            return await running.value
        }

        let names = identity.names(for: ref.site)
        let task = Task<Ownership, Never> {
            let cookies = await self.cookieHeader(for: ref.lookupURL)
            return await PostPageFetcher.lookUp(ref, ownNames: names, cookies: cookies)
        }
        inFlight[ref.key] = task
        let result = await task.value
        inFlight[ref.key] = nil

        switch result {
        case .mine:
            markMine([ref.key])
        case .someoneElse(let owner):
            others[ref.key] = owner
        case .unknown:
            break
        }
        return result
    }

    /// Finds your Facebook username from your account number by looking at
    /// your own profile page. Used when the app knows the number (from the
    /// login cookie) before it has seen your username.
    func facebookUsername(forID id: String) async -> String? {
        guard AccessPolicy.isDigits(id),
              let url = URL(string: "https://www.facebook.com/profile.php?id=\(id)") else {
            return nil
        }
        let cookies = await cookieHeader(for: url)
        return await PostPageFetcher.username(onProfile: url, cookies: cookies)
    }

    /// The cookies the web views hold for the post's site, so a second
    /// lookup can see posts that only your friends can see.
    private func cookieHeader(for url: URL) async -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Fetches post pages off the main thread. Nothing here touches the web
/// views or stores cookies: the session keeps no cookie jar, and the signed-in
/// lookup passes your cookies along for that one request only.
enum PostPageFetcher {

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        // Short, so a slow network never leaves a post covered for long.
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

    /// First as a visitor, which answers cleanly for public posts. Then, if
    /// that says nothing, as you.
    static func lookUp(_ ref: PostRef, ownNames: Set<String>, cookies: String?) async -> Ownership {
        var attempts: [String?] = [nil]
        if let cookies {
            attempts.append(cookies)
        }
        for cookieHeader in attempts {
            guard let page = await fetch(ref.lookupURL, cookieHeader: cookieHeader) else { continue }
            let owners = OwnershipParser.owners(html: page.html, finalURL: page.finalURL, site: ref.site)
            let answer = OwnershipParser.verdict(owners: owners, ownNames: ownNames)
            if answer != .unknown {
                return answer
            }
        }
        return .unknown
    }

    static func username(onProfile url: URL, cookies: String?) async -> String? {
        var attempts: [String?] = [nil]
        if let cookies {
            attempts.append(cookies)
        }
        for cookieHeader in attempts {
            guard let page = await fetch(url, cookieHeader: cookieHeader) else { continue }
            var candidates: [URL] = []
            if let finalURL = page.finalURL {
                candidates.append(finalURL)
            }
            candidates += OwnershipParser.pageURLs(in: page.html).compactMap { URL(string: $0) }
            for candidate in candidates {
                if let name = AccessPolicy.ownProfileName(from: candidate), !AccessPolicy.isDigits(name) {
                    return name
                }
            }
        }
        return nil
    }

    static func fetch(_ url: URL, cookieHeader: String?) async -> (html: String, finalURL: URL?)? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        do {
            let redirects = SameSiteRedirects(site: AccessPolicy.site(for: url))
            let (data, response) = try await session.data(for: request, delegate: redirects)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                return nil
            }
            let html = String(decoding: data.prefix(4_000_000), as: UTF8.self)
            return (html, response.url)
        } catch {
            return nil
        }
    }
}

/// Keeps a lookup on the post's own site. A redirect anywhere else is not
/// followed, so your cookies never travel to another site.
private final class SameSiteRedirects: NSObject, URLSessionTaskDelegate {
    private let site: SiteKind

    init(site: SiteKind) {
        self.site = site
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              site != .other, AccessPolicy.site(for: url) == site else {
            completionHandler(nil)
            return
        }
        // Your cookies go only to the exact host they were sent to first.
        var next = request
        let original = task.originalRequest
        let sameHost = url.host?.lowercased() == original?.url?.host?.lowercased()
        next.setValue(sameHost ? original?.value(forHTTPHeaderField: "Cookie") : nil, forHTTPHeaderField: "Cookie")
        completionHandler(next)
    }
}
