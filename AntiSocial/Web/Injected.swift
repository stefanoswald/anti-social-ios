import Foundation
import WebKit

/// JavaScript and CSS pushed into every page.
///
/// Two jobs:
/// 1. Tell the app about in-page navigations. Facebook and Instagram are
///    single-page apps, so tapping a link often changes the URL without a real
///    page load. The native navigation delegate never sees those. The hook
///    below reports every URL change so the policy can still bounce it.
/// 2. Hide feed links, Reels tabs, and "open the app" nags so the pages stop
///    baiting you. This is cosmetic. The URL policy is the real wall.
enum Injected {

    /// Name of the message handler the page posts to.
    static let handlerName = "antisocial"

    // MARK: - Navigation hook (document start, main frame only)

    static let navigationHook = #"""
    (function () {
        if (window.__antiSocialHooked) { return; }
        window.__antiSocialHooked = true;

        function post(payload) {
            try {
                window.webkit.messageHandlers.antisocial.postMessage(payload);
            } catch (e) {}
        }

        function report(why) {
            post({ type: "url", url: location.href, why: why });
        }

        function wrap(name) {
            var original = history[name];
            if (typeof original !== "function") { return; }
            history[name] = function () {
                var result = original.apply(this, arguments);
                setTimeout(function () { report(name); }, 0);
                return result;
            };
        }

        wrap("pushState");
        wrap("replaceState");
        window.addEventListener("popstate", function () { report("popstate"); });
        window.addEventListener("hashchange", function () { report("hashchange"); });

        var last = location.href;
        setInterval(function () {
            if (location.href !== last) {
                last = location.href;
                report("poll");
            }
        }, 400);

        // Work out whose account is signed in, so the app knows which profile
        // is "yours" without you typing it into Settings. Reported once.
        function ownUsername() {
            var host = (location.hostname || "").toLowerCase();
            if (host.indexOf("instagram") === -1) { return null; }
            var candidates = document.querySelectorAll('a[href^="/"]');
            for (var i = 0; i < candidates.length; i++) {
                var a = candidates[i];
                var label = (a.getAttribute("aria-label") || "").trim();
                var text = (a.innerText || "").trim();
                var isProfile = label === "Profile" || text === "Profile";
                if (!isProfile) {
                    // The nav avatar's alt text names its own owner.
                    var img = a.querySelector("img[alt]");
                    if (img && /'s profile picture$/i.test(img.getAttribute("alt") || "")) {
                        isProfile = a.closest("nav") !== null || a.getAttribute("role") === "link";
                    }
                }
                if (!isProfile) { continue; }
                var href = a.getAttribute("href") || "";
                var m = href.match(/^\/([A-Za-z0-9._]{1,30})\/?$/);
                if (m) { return m[1]; }
            }
            return null;
        }

        var reportedName = null;
        function reportOwner() {
            if (reportedName) { return; }
            var name = ownUsername();
            if (name) {
                reportedName = name;
                post({ type: "owner", site: "instagram", username: name });
            }
        }
        setTimeout(reportOwner, 1500);
        setTimeout(reportOwner, 5000);
        setInterval(reportOwner, 15000);

        window.__as_hide = function () {
            document.documentElement.style.setProperty("visibility", "hidden", "important");
        };
        window.__as_show = function () {
            document.documentElement.style.removeProperty("visibility");
        };
    })();
    """#

    // MARK: - Element hiding

    private static let facebookCSS = """
    a[href="/"], a[href^="/?"], a[href="/home.php"], a[href^="/home.php?"],
    a[href="https://www.facebook.com/"], a[href^="https://www.facebook.com/?"],
    a[href^="https://www.facebook.com/home.php"], a[href="https://m.facebook.com/"],
    a[href^="https://m.facebook.com/?"], a[href^="https://m.facebook.com/home.php"],
    a[href^="/reel"]:not([href^="/reel/create"]), a[href^="/watch"], a[href^="/video"],
    a[href^="/stories"]:not([href^="/stories/create"]),
    a[href^="/gaming"], a[href^="/games"], a[href^="/memories"], a[href^="/feeds"],
    a[href^="/saved"], a[href^="/bookmarks"], a[href^="/menu"], a[href^="/dating"],
    a[href="/groups/"], a[href="/groups"], a[href^="/groups/?"], a[href^="/groups/feed"],
    a[href^="/groups/discover"], a[href="/friends/"], a[href="/friends"], a[href^="/friends/?"],
    a[href^="https://www.facebook.com/reel"], a[href^="https://www.facebook.com/watch"],
    a[href^="https://www.facebook.com/video"],
    a[href^="https://www.facebook.com/stories"]:not([href^="https://www.facebook.com/stories/create"]),
    a[href^="https://www.facebook.com/gaming"], a[href^="https://www.facebook.com/memories"],
    a[href^="https://www.facebook.com/feeds"], a[href^="https://www.facebook.com/saved"],
    a[href^="https://www.facebook.com/bookmarks"], a[href^="https://www.facebook.com/menu"],
    a[href="https://www.facebook.com/groups/"], a[href^="https://www.facebook.com/groups/?"],
    a[href="https://www.facebook.com/friends/"], a[href^="https://www.facebook.com/friends/?"],
    a[href^="https://m.facebook.com/reel"], a[href^="https://m.facebook.com/watch"],
    a[href^="https://m.facebook.com/video"],
    a[href^="https://m.facebook.com/stories"]:not([href^="https://m.facebook.com/stories/create"]),
    a[href^="https://m.facebook.com/menu"], a[href^="https://m.facebook.com/bookmarks"],
    [aria-label="Home"], [aria-label="Video"], [aria-label="Reels"], [aria-label="Watch"],
    [aria-label="Stories"], [aria-label="Gaming"], [aria-label="Feeds"],
    [data-pagelet^="FeedUnit"], [data-pagelet="Stories"], [data-pagelet="VideoChatHomeRoot"],
    [data-pagelet="MegaphoneUnit"],
    a[href^="fb://"], a[href^="itms-apps://"], a[href*="apps.apple.com"] {
        display: none !important;
    }
    """

    private static let instagramCSS = """
    a[href="/"], a[href^="/?"], a[href="/explore/"], a[href^="/explore"],
    a[href="/reels/"], a[href^="/reels"], a[href^="/stories"],
    a[href="https://www.instagram.com/"], a[href^="https://www.instagram.com/?"],
    a[href^="https://www.instagram.com/explore"], a[href^="https://www.instagram.com/reels"],
    a[href^="https://www.instagram.com/stories"],
    [aria-label="Home"], [aria-label="Explore"], [aria-label="Reels"],
    a[href^="instagram://"], a[href^="itms-apps://"], a[href*="apps.apple.com"] {
        display: none !important;
    }
    """

    /// Adds the CSS as early as possible and keeps it there. Also hides
    /// "open the app" buttons, which have no stable selector, by their text.
    /// One web view can move between facebook.com and instagram.com (account
    /// center, login with Facebook), so the script picks the CSS by hostname.
    static func hidingScript() -> String {
        return #"""
        (function () {
            if (window.__asHiding) { return; }
            window.__asHiding = true;
            var host = (location.hostname || "").toLowerCase();
            var css = "";
            if (host.indexOf("instagram") !== -1) {
                css = `\#(escapeForTemplate(instagramCSS))`;
            } else if (host.indexOf("facebook") !== -1 || host.indexOf("messenger") !== -1) {
                css = `\#(escapeForTemplate(facebookCSS))`;
            }
            if (!css) { return; }

            function ensureStyle() {
                var existing = document.getElementById("__as_style");
                if (existing) { return; }
                var style = document.createElement("style");
                style.id = "__as_style";
                style.textContent = css;
                (document.head || document.documentElement).appendChild(style);
            }

            var nagPattern = /^(use the app|open app|open in app|open the app|get app|get the app|switch to the app|open messenger|get messenger|open facebook|open instagram|download messenger|download the app)$/i;

            function hideNags() {
                var nodes = document.querySelectorAll("button, a, [role='button']");
                for (var i = 0; i < nodes.length; i++) {
                    var node = nodes[i];
                    if (node.__asChecked) { continue; }
                    node.__asChecked = true;
                    var text = (node.innerText || node.textContent || "").trim();
                    if (text.length > 0 && text.length < 30 && nagPattern.test(text)) {
                        node.style.setProperty("display", "none", "important");
                    }
                }
            }

            ensureStyle();
            hideNags();

            var pending = false;
            var observer = new MutationObserver(function () {
                if (pending) { return; }
                pending = true;
                setTimeout(function () {
                    pending = false;
                    ensureStyle();
                    hideNags();
                }, 250);
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """#
    }

    // MARK: - Viewport (desktop mode)

    /// The desktop site has no viewport meta tag, so WebKit lays it out at
    /// 980 px and shrinks it to fit, which is unreadable on a phone. This pins
    /// the layout width to something narrower so the page scales up. Facebook
    /// keeps a workable layout down to roughly 600 px.
    static func viewportScript(width: Int) -> String {
        return #"""
        (function () {
            var width = \#(width);
            if (!width) { return; }
            if (window.__asViewport) { return; }
            window.__asViewport = true;

            function apply() {
                var metas = document.querySelectorAll('meta[name="viewport"]');
                for (var i = 0; i < metas.length; i++) {
                    if (metas[i].id !== "__as_viewport") {
                        metas[i].parentNode.removeChild(metas[i]);
                    }
                }
                if (!document.getElementById("__as_viewport")) {
                    var meta = document.createElement("meta");
                    meta.id = "__as_viewport";
                    meta.name = "viewport";
                    meta.content = "width=" + width + ", minimum-scale=0.25, maximum-scale=5";
                    (document.head || document.documentElement).appendChild(meta);
                }
            }

            apply();
            var observer = new MutationObserver(function (mutations) {
                for (var m = 0; m < mutations.length; m++) {
                    var added = mutations[m].addedNodes;
                    for (var n = 0; n < added.length; n++) {
                        var node = added[n];
                        if (node.nodeType === 1 && node.tagName === "META" && node.getAttribute("name") === "viewport" && node.id !== "__as_viewport") {
                            apply();
                            return;
                        }
                    }
                }
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """#
    }

    private static func escapeForTemplate(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }

    // MARK: - Diagnostics

    /// Returns a JSON string describing the links and labels on the page. Used
    /// by the Diagnostics screen so you can copy it and send it over when
    /// something slips through.
    static let pageMap = #"""
    (function () {
        var out = { url: location.href, title: document.title, links: [], labels: [] };
        var seen = {};
        var anchors = document.querySelectorAll("a[href]");
        for (var i = 0; i < anchors.length; i++) {
            var a = anchors[i];
            var href = a.getAttribute("href") || "";
            href = href.split("?")[0].slice(0, 80);
            var label = a.getAttribute("aria-label") || "";
            var key = href + (label ? " [" + label + "]" : "");
            if (seen[key]) { continue; }
            seen[key] = true;
            out.links.push(key);
        }
        var labelled = document.querySelectorAll("[role='navigation'] [aria-label], [role='tablist'] [aria-label], nav [aria-label], [role='banner'] [aria-label]");
        for (var j = 0; j < labelled.length; j++) {
            var l = labelled[j].getAttribute("aria-label");
            if (l && out.labels.indexOf(l) === -1) { out.labels.push(l); }
        }
        out.links = out.links.slice(0, 200);
        out.labels = out.labels.slice(0, 100);
        return JSON.stringify(out, null, 2);
    })();
    """#
}
