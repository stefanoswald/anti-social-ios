import Foundation

/// The answer to "is this post yours?"
enum Ownership: Equatable {
    case mine
    case someoneElse(String)
    /// The page did not say, or the app does not know your account yet.
    case unknown
}

/// Reads a fetched post page and works out who made the post.
///
/// Facebook and Instagram put the post's own address in the page header
/// (`og:url` and the canonical link), and that address carries the owner's
/// username: facebook.com/<owner>/videos/<id>/ or
/// instagram.com/<owner>/reel/<code>/. Facebook also tucks the owner's ID
/// into its app link. This is plain text work with no web view involved, so
/// it is easy to test.
enum OwnershipParser {

    /// Who made the post on `html`, as lowercased usernames or numeric IDs,
    /// best guess first. Empty when the page does not say.
    static func owners(html: String, finalURL: URL?, site: SiteKind) -> [String] {
        var found: [String] = []
        func add(_ value: String?) {
            guard let value = value?.lowercased(), !value.isEmpty, !found.contains(value) else { return }
            found.append(value)
        }

        var addresses: [URL] = []
        if let finalURL { addresses.append(finalURL) }
        addresses += pageURLs(in: html).compactMap { URL(string: $0) }
        for address in addresses where AccessPolicy.site(for: address) == site {
            add(AccessPolicy.postLink(in: address)?.owner)
        }

        let head = headSection(of: html)
        switch site {
        case .facebook:
            let appLinks = metaContents(in: head, attribute: "property", value: "al:ios:url")
                + metaContents(in: head, attribute: "property", value: "al:android:url")
            for appLink in appLinks {
                add(facebookOwner(inAppLink: decodeEntities(appLink)))
            }
            if found.isEmpty {
                add(firstCapture(#""(?:owner|video_owner)":\{"__typename":"(?:User|Page)","id":"(\d+)""#, in: html))
            }
        case .instagram:
            if found.isEmpty {
                // "3 likes, 0 comments - magictrickguy on October 12, 2026: ..."
                for description in metaContents(in: head, attribute: "name", value: "description") {
                    add(firstCapture(#" - ([A-Za-z0-9._]{1,30}) on "#, in: decodeEntities(description)))
                }
            }
        case .other:
            break
        }
        return found
    }

    /// Turns the owners found on a page into an answer. Says "someone else"
    /// only when it could have recognised you in the same form: a number is
    /// compared with your ID, and a name with your username.
    static func verdict(owners: [String], ownNames: Set<String>) -> Ownership {
        guard !owners.isEmpty else { return .unknown }
        if owners.contains(where: { ownNames.contains($0) }) {
            return .mine
        }
        let knowsID = ownNames.contains { AccessPolicy.isDigits($0) }
        let knowsName = ownNames.contains { !AccessPolicy.isDigits($0) }
        for owner in owners {
            let isID = AccessPolicy.isDigits(owner)
            if (isID && knowsID) || (!isID && knowsName) {
                return .someoneElse(owner)
            }
        }
        return .unknown
    }

    /// The page's own address as the page states it: `og:url` first, then
    /// the canonical link. Entities are decoded.
    static func pageURLs(in html: String) -> [String] {
        let head = headSection(of: html)
        let raw = metaContents(in: head, attribute: "property", value: "og:url")
            + linkHrefs(in: head, rel: "canonical")
        return raw.map { decodeEntities($0) }
    }

    /// Facebook's app link for a post looks like
    /// fb://watch/discover/story?id=<base64 of "S:_I<owner id>:VK:<video id>">.
    static func facebookOwner(inAppLink link: String) -> String? {
        guard let components = URLComponents(string: link),
              let encoded = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let decoded = decodeBase64(encoded) else {
            return nil
        }
        return firstCapture(#"_I(\d+):"#, in: decoded)
    }

    // MARK: - Text helpers

    /// The page header, where the meta tags live. Scanning only this part
    /// keeps the work small on pages that run to a megabyte.
    static func headSection(of html: String) -> String {
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            return String(html[..<end.lowerBound])
        }
        return String(html.prefix(400_000))
    }

    static func metaContents(in html: String, attribute: String, value: String) -> [String] {
        var results: [String] = []
        for tag in allMatches(#"<meta\b[^>]*>"#, in: html) {
            guard attributeValue(attribute, in: tag)?.lowercased() == value.lowercased(),
                  let content = attributeValue("content", in: tag) else { continue }
            results.append(content)
        }
        return results
    }

    static func linkHrefs(in html: String, rel: String) -> [String] {
        var results: [String] = []
        for tag in allMatches(#"<link\b[^>]*>"#, in: html) {
            guard attributeValue("rel", in: tag)?.lowercased() == rel.lowercased(),
                  let href = attributeValue("href", in: tag) else { continue }
            results.append(href)
        }
        return results
    }

    static func attributeValue(_ name: String, in tag: String) -> String? {
        firstCapture("(?i)\\b\(name)\\s*=\\s*\"([^\"]*)\"", in: tag)
            ?? firstCapture("(?i)\\b\(name)\\s*=\\s*'([^']*)'", in: tag)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&quot;": "\"", "&#039;": "'", "&#39;": "'", "&#x27;": "'",
            "&lt;": "<", "&gt;": ">", "&#x2F;": "/", "&#47;": "/"
        ]
        for (entity, character) in entities {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Last, so "&amp;quot;" becomes "&quot;" and not a quote mark.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func decodeBase64(_ text: String) -> String? {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized += "="
        }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
