import Foundation

// Checks the rules in AntiSocial/Policy/AccessPolicy.swift. The update script
// builds and runs this on the Mac before it builds the app:
//
//   xcrun swiftc AntiSocial/Policy/AccessPolicy.swift Checks/main.swift -o policy-check
//   ./policy-check
//
// The same checks run against the Android app's AccessPolicy.kt, so the two
// apps follow one set of rules. This file is not part of the app itself.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    if ok {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

func u(_ text: String) -> URL {
    guard let url = URL(string: text) else {
        print("FAIL not a URL: \(text)")
        failures += 1
        return URL(string: "about:blank")!
    }
    return url
}

func with(_ options: PolicyOptions, _ change: (inout PolicyOptions) -> Void) -> PolicyOptions {
    var copy = options
    change(&copy)
    return copy
}

func reasonOf(_ decision: PolicyDecision) -> String? {
    if case .block(let reason) = decision { return reason }
    return nil
}

func refOf(_ decision: PolicyDecision) -> PostRef? {
    if case .verify(let ref) = decision { return ref }
    return nil
}

func isAllowDecision(_ decision: PolicyDecision) -> Bool {
    if case .allow = decision { return true }
    return false
}

func isBlockDecision(_ decision: PolicyDecision) -> Bool {
    if case .block = decision { return true }
    return false
}

func isExternalDecision(_ decision: PolicyDecision) -> Bool {
    if case .external = decision { return true }
    return false
}

let me = PolicyOptions(
    facebookUsername: "magictrickguy", instagramUsername: "magictrickguy",
    facebookUserID: "500029620", instagramUserID: "1234567890"
)
let p = AccessPolicy(options: me)
func d(_ text: String, inPage: Bool = false) -> PolicyDecision { p.decide(u(text), inPage: inPage) }
func isAllow(_ text: String) -> Bool { isAllowDecision(d(text)) }
func blockReason(_ text: String) -> String? { reasonOf(d(text)) }
func verify(_ text: String) -> PostRef? { refOf(d(text)) }

// ---------- Facebook, only own posts ----------
let reel = verify("https://www.facebook.com/reel/1299494788874394/?comment_id=937977179008213&__cft__[0]=AZgFs0Dy9&__tn__=R-R")
check("fb bare reel needs a check", reel != nil)
check("fb reel key", reel?.key == "fb:video:1299494788874394")
check("fb reel lookup drops tracking", reel?.lookupURL.absoluteString == "https://www.facebook.com/reel/1299494788874394/")
check("fb reel has no other owner", reel?.otherOwner == nil)
check("fb own video by name", isAllow("https://www.facebook.com/MagicTrickGuy/videos/1299494788874394/"))
check("fb own video key learned", p.ownedPostKey(in: u("https://www.facebook.com/MagicTrickGuy/videos/1299494788874394/")) == "fb:video:1299494788874394")
check("fb own video by number", isAllow("https://www.facebook.com/500029620/videos/1492050266276823/?__so__=permalink"))
let prof = verify("https://www.facebook.com/SpAzMoPiMp?comment_id=Y29tbWVudDox")
check("fb other profile opens on a tap", prof?.key == "fb:profile:spazmopimp" && prof?.otherOwner == "spazmopimp" && prof?.kind == .facebookProfile)
check("fb profile kind", prof?.kind.isProfile == true && prof?.kind.isVideo == false && prof?.kind.isStory == false)
check("fb profile with dots", verify("https://www.facebook.com/john.smith.5/")?.key == "fb:profile:john.smith.5")
check("fb old page name with dashes", verify("https://www.facebook.com/Some-Magic-Shop-123456789/")?.key == "fb:profile:some-magic-shop-123456789")
check("fb profile about tab is the same profile", verify("https://www.facebook.com/nasa/about")?.key == "fb:profile:nasa")
check("fb profile photos tab is the same profile", verify("https://www.facebook.com/nasa/photos")?.key == "fb:profile:nasa")
check("fb profile by number in the path", verify("https://www.facebook.com/100044201837698")?.key == "fb:profile:100044201837698")
check("fb name that cannot be a username", blockReason("https://www.facebook.com/foo_bar") == "Profile")
check("fb own profile still opens outright", isAllow("https://www.facebook.com/MagicTrickGuy/") && isAllow("https://www.facebook.com/magictrickguy/about"))
check("fb routes are not profiles", isAllow("https://www.facebook.com/settings") && blockReason("https://www.facebook.com/gaming/") == "Gaming" && blockReason("https://www.facebook.com/home.php") == "Home feed" && blockReason("https://www.facebook.com/friends/") == "Friends")
check("fb a post on a profile is still a post", verify("https://www.facebook.com/nasa/posts/pfbid0abc")?.key == "fb:post:pfbid0abc")
check("fb feature pages are never profiles", blockReason("https://www.facebook.com/media/set/?set=a.123") == "Profile" && blockReason("https://www.facebook.com/sharer/sharer.php?u=x") == "Profile" && blockReason("https://www.facebook.com/plugins/post.php") == "Profile")
let other = verify("https://www.facebook.com/someoneelse/posts/pfbid02abcXYZ")
check("fb other post names owner", other?.otherOwner == "someoneelse" && other?.key == "fb:post:pfbid02abcXYZ")
check("fb own permalink", isAllow("https://www.facebook.com/permalink.php?story_fbid=pfbid0xyz&id=500029620&comment_id=1"))
check("fb other permalink", verify("https://www.facebook.com/permalink.php?story_fbid=123&id=999")?.otherOwner == "999")
check("fb own photo by set", isAllow("https://www.facebook.com/photo/?fbid=10163360548974621&set=pb.500029620.-2207520000"))
let album = verify("https://www.facebook.com/photo/?fbid=10155952987339621&set=a.10150531284839621")
check("fb album photo needs check", album?.key == "fb:photo:10155952987339621" && album?.otherOwner == nil)
check("fb album lookup keeps fbid and set", album?.lookupURL.absoluteString == "https://www.facebook.com/photo/?fbid=10155952987339621&set=a.10150531284839621")
check("fb watch v needs check", verify("https://www.facebook.com/watch/?v=1299494788874394")?.key == "fb:video:1299494788874394")
check("fb watch feed", blockReason("https://www.facebook.com/watch/") == "Watch")
check("fb reel root", blockReason("https://www.facebook.com/reel/") == "Reels")
check("fb reels feed", blockReason("https://www.facebook.com/reels/") == "Reels")
check("fb reel composer", isAllow("https://www.facebook.com/reel/create"))
check("fb reels composer", isAllow("https://www.facebook.com/reels/create/?surface=PROFILE_PLUS"))
check("fb reels feed still blocked next to the composer", blockReason("https://www.facebook.com/reels/") == "Reels")
check("fb a reels page that is not the composer", blockReason("https://www.facebook.com/reels/trending/") == "Reels")
check("fb reels composer off without posting", isBlockDecision(AccessPolicy(options: with(me) { $0.allowPosting = false }).decide(u("https://www.facebook.com/reels/create/"))))
check("fb own reels tab", isAllow("https://www.facebook.com/MagicTrickGuy/reels/"))
check("fb own videos tab", isAllow("https://www.facebook.com/MagicTrickGuy/videos/"))
check("fb someone's reels tab is their profile", verify("https://www.facebook.com/NASA/reels/")?.key == "fb:profile:nasa")
check("fb group post key", AccessPolicy.postLink(in: u("https://www.facebook.com/groups/123/posts/456/"))?.ref.key == "fb:group:123:456")
check("fb messages", isAllow("https://www.facebook.com/messages/t/123"))
check("fb marketplace item", isAllow("https://www.facebook.com/marketplace/item/123/"))
check("fb notifications", isAllow("https://www.facebook.com/notifications/"))
check("fb home feed", blockReason("https://www.facebook.com/") == "Home feed")
check("fb me", isAllow("https://www.facebook.com/me"))
check("fb own profile.php", isAllow("https://www.facebook.com/profile.php?id=500029620&sk=reels_tab"))
let pp = verify("https://www.facebook.com/profile.php?id=999&sk=about")
check("fb other profile.php opens on a tap", pp?.key == "fb:profile:999" && pp?.otherOwner == "999" && pp?.kind == .facebookProfile)
check("fb profile.php without an id", blockReason("https://www.facebook.com/profile.php") == "Profile")
check("fb story composer no slash", isAllow("https://www.facebook.com/stories/create"))
check("fb stories root", blockReason("https://www.facebook.com/stories/") == "Stories")
check("fb mobile own story.php", isAllow("https://m.facebook.com/story.php?story_fbid=1&id=500029620"))
let mobile = verify("https://m.facebook.com/story.php?story_fbid=55")
check("fb mobile lookup goes to www", mobile?.lookupURL.absoluteString == "https://www.facebook.com/story.php?story_fbid=55")
check("fb videos id needs check", verify("https://www.facebook.com/videos/123456789/")?.key == "fb:video:123456789")
check("fb own photo path", isAllow("https://www.facebook.com/MagicTrickGuy/photos/the-magic-mansioncom/10163360548974621/"))
check("fb own photo key", p.ownedPostKey(in: u("https://www.facebook.com/MagicTrickGuy/photos/the-magic-mansioncom/10163360548974621/")) == "fb:photo:10163360548974621")
check("fb outbound link", isExternalDecision(d("https://www.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2F")))
check("fb share link", isAllow("https://www.facebook.com/share/r/1ABCdef/"))
check("fb live producer", isAllow("https://www.facebook.com/live/producer/v2/?target_id=1"))
check("fb live feed", blockReason("https://www.facebook.com/live/") == "Live")
check("fb pages", blockReason("https://www.facebook.com/pages/category/person/") == "Pages")
check("fb app link", blockReason("fb://profile/500029620") == "App link")
// Name not known yet, number known: a named owner cannot be ruled out.
let idOnly = AccessPolicy(options: PolicyOptions(facebookUserID: "500029620"))
let unsure = refOf(idOnly.decide(u("https://www.facebook.com/MagicTrickGuy/videos/1/")))
check("fb name unknown asks instead of blocking", unsure != nil && unsure?.otherOwner == nil)
check("fb id only still allows own number", isAllowDecision(idOnly.decide(u("https://www.facebook.com/500029620/videos/1/"))))
let nameOnly = AccessPolicy(options: PolicyOptions(facebookUsername: "magictrickguy"))
let unsure2 = refOf(nameOnly.decide(u("https://www.facebook.com/permalink.php?story_fbid=1&id=500029620")))
check("fb number unknown asks instead of blocking", unsure2 != nil && unsure2?.otherOwner == nil)
// ---------- Groups ----------
check("fb groups feed", blockReason("https://www.facebook.com/groups/") == "Groups feed")
check("fb groups feed path", blockReason("https://www.facebook.com/groups/feed/") == "Groups feed")
check("fb group suggestions", blockReason("https://www.facebook.com/groups/discover/") == "Group suggestions")
check("fb your groups list", isAllow("https://www.facebook.com/groups/joins/?nav_source=tab"))
check("fb create group", isAllow("https://www.facebook.com/groups/?category=create"))
check("fb one group by name", isAllow("https://www.facebook.com/groups/tradeshowperformers/"))
check("fb one group by number", isAllow("https://www.facebook.com/groups/2621763107839497/"))
check("fb group members tab", isAllow("https://www.facebook.com/groups/2621763107839497/members/"))
check("fb group member page", isAllow("https://www.facebook.com/groups/2621763107839497/user/100000000000001/"))
check("fb group post opens", isAllow("https://www.facebook.com/groups/tradeshowperformers/posts/1234567890/?comment_id=55"))
check("fb group permalink opens", isAllow("https://www.facebook.com/groups/123/permalink/456/"))
check("fb group photo opens", isAllow("https://www.facebook.com/photo/?fbid=10155952987339621&idorvanity=2621763107839497&set=g.2621763107839497"))
check("fb group post photo opens", isAllow("https://www.facebook.com/photo/?fbid=10155952987339621&set=gm.1234567890"))
// ---------- Stories ----------
check("fb story composer", isAllow("https://www.facebook.com/stories/create/"))
check("fb stories feed", blockReason("https://www.facebook.com/stories/") == "Stories")
check("fb own story", isAllow("https://www.facebook.com/stories/500029620/UzpfSVNDOjE1/?view_single=true"))
let otherStory = verify("https://www.facebook.com/stories/100044561550831/UzpfSVNDOjE2/")
check("fb other story needs a tap", otherStory?.otherOwner == "100044561550831" && otherStory?.kind == .facebookStory)
check("fb story archive", isAllow("https://www.facebook.com/stories/archive/"))
check("ig own story", isAllow("https://www.instagram.com/stories/magictrickguy/3456789012345678901/"))
let igOtherStory = verify("https://www.instagram.com/stories/nasa/3456789012345678901/")
check("ig other story needs a tap", igOtherStory?.otherOwner == "nasa" && igOtherStory?.key == "ig:story:nasa")
let highlight = verify("https://www.instagram.com/stories/highlights/17976890195128202/")
check("ig highlight needs a tap", highlight?.kind == .instagramHighlight && highlight?.otherOwner == nil)
check("ig stories feed", blockReason("https://www.instagram.com/stories/") == "Stories")
// ---------- Kinds ----------
check("fb reel kind", verify("https://www.facebook.com/reel/1/")?.kind.isVideo == true)
check("ig reels player kind", verify("https://www.instagram.com/reels/DefPxYVO9YH/")?.kind == .instagramReelsPlayer)
check("fb post kind", verify("https://www.facebook.com/someone/posts/9")?.kind == .facebookPost)
// ---------- Strict setting ----------
let strict = AccessPolicy(options: with(me) { $0.openTappedPosts = false })
check("strict blocks own tagged grid", reasonOf(strict.decide(u("https://www.instagram.com/magictrickguy/tagged/"))) == "Tagged posts")
check("tap mode opens own tagged grid", isAllowDecision(p.decide(u("https://www.instagram.com/magictrickguy/tagged/"))))
check("strict still opens groups", isAllowDecision(strict.decide(u("https://www.facebook.com/groups/123/posts/456/"))))
// ---------- Instagram ----------
let igReel = verify("https://www.instagram.com/reel/DefPxYVO9YH/")
check("ig bare reel needs check", igReel?.key == "ig:DefPxYVO9YH")
check("ig lookup is /p/", igReel?.lookupURL.absoluteString == "https://www.instagram.com/p/DefPxYVO9YH/")
check("ig own reel", isAllow("https://www.instagram.com/magictrickguy/reel/DefPxYVO9YH/"))
check("ig own reel key", p.ownedPostKey(in: u("https://www.instagram.com/magictrickguy/reel/DefPxYVO9YH/")) == "ig:DefPxYVO9YH")
check("ig own post", isAllow("https://www.instagram.com/magictrickguy/p/DeAYvsnn4la/"))
check("ig other reel", verify("https://www.instagram.com/nasa/reel/DeTUk4sDSp-/")?.otherOwner == "nasa")
check("ig comment link", verify("https://www.instagram.com/p/DeTUk4sDSp-/c/18000000000000000/")?.key == "ig:DeTUk4sDSp-")
check("ig reels player with code", verify("https://www.instagram.com/reels/DefPxYVO9YH/")?.key == "ig:DefPxYVO9YH")
check("ig reels feed", blockReason("https://www.instagram.com/reels/") == "Reels")
check("ig reels audio", blockReason("https://www.instagram.com/reels/audio/123456/") == "Reels")
check("ig own grid", isAllow("https://www.instagram.com/magictrickguy/"))
check("ig own reels tab", isAllow("https://www.instagram.com/magictrickguy/reels/"))
let igp = verify("https://www.instagram.com/nasa/")
check("ig other profile opens on a tap", igp?.key == "ig:profile:nasa" && igp?.otherOwner == "nasa" && igp?.kind == .instagramProfile)
check("ig other profile tabs are the same profile", verify("https://www.instagram.com/nasa/reels/")?.key == "ig:profile:nasa" && verify("https://www.instagram.com/nasa/tagged/")?.key == "ig:profile:nasa")
check("ig own profile still opens outright", isAllow("https://www.instagram.com/magictrickguy/"))
check("ig a post on a profile is still a post", verify("https://www.instagram.com/nasa/p/DeJ28eTxo4s/")?.key == "ig:DeJ28eTxo4s")
check("ig inbox", isAllow("https://www.instagram.com/direct/inbox/"))
check("ig home", blockReason("https://www.instagram.com/") == "Home feed")
check("ig explore", blockReason("https://www.instagram.com/explore/") == "Explore")
check("ig someone's stories need a tap", verify("https://www.instagram.com/stories/nasa/123/")?.otherOwner == "nasa")
check("ig create step", isAllow("https://www.instagram.com/create/select/"))
check("ig create alone is a person's profile, opened only by a tap", verify("https://www.instagram.com/create/")?.key == "ig:profile:create")
check("ig create unknown step in page", isAllowDecision(p.decide(u("https://www.instagram.com/create/newstep/"), inPage: true)))
check("ig create with posting off is blocked", reasonOf(AccessPolicy(options: with(me) { $0.allowPosting = false }).decide(u("https://www.instagram.com/create/select/"))) == "Posting is off")
check("ig unknown create step on a fresh load is blocked, not a profile", blockReason("https://www.instagram.com/create/newstep/") == "Create page")
check("ig bare p", blockReason("https://www.instagram.com/p/") == "Feed")
check("ig case kept in key", verify("https://www.instagram.com/p/AbCdEfGh123/")?.key == "ig:AbCdEfGh123")
// ---------- Grids ----------
check("grid fb reels", p.isOwnPostGrid(u("https://www.facebook.com/MagicTrickGuy/reels/")))
check("grid fb videos", p.isOwnPostGrid(u("https://www.facebook.com/MagicTrickGuy/videos")))
check("grid fb timeline is not", !p.isOwnPostGrid(u("https://www.facebook.com/MagicTrickGuy")))
check("grid fb profile.php reels", p.isOwnPostGrid(u("https://www.facebook.com/profile.php?id=500029620&sk=reels_tab")))
check("grid fb other is not", !p.isOwnPostGrid(u("https://www.facebook.com/NASA/reels/")))
check("grid ig own", p.isOwnPostGrid(u("https://www.instagram.com/magictrickguy/")))
check("grid ig own reels", p.isOwnPostGrid(u("https://www.instagram.com/magictrickguy/reels/")))
check("grid ig other is not", !p.isOwnPostGrid(u("https://www.instagram.com/nasa/")))
check("grid ig own post is not", !p.isOwnPostGrid(u("https://www.instagram.com/magictrickguy/reel/DefPxYVO9YH/")))
// ---------- Profile name from /me ----------
check("vanity from canonical", AccessPolicy.ownProfileName(from: u("https://www.facebook.com/MagicTrickGuy/")) == "magictrickguy")
check("vanity not from feed", AccessPolicy.ownProfileName(from: u("https://www.facebook.com/")) == nil)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
