# Anti-Social

A locked-down browser for Facebook and Instagram, made for creating instead of consuming. Messages, Marketplace, alerts, groups, your own posts, and posting all work. Feeds do not load at all, and nothing ever moves on to the next post by itself, so there is nothing to scroll.

Five tabs:

| Tab | What it opens |
|---|---|
| Messages | facebook.com/messages (Messenger inbox and conversations) |
| Marketplace | facebook.com/marketplace (browse, search, your listings, buyer chats) |
| Alerts | Three pages, picked with the switch at the top. **Alerts** is facebook.com/notifications. **My Posts** is your own Facebook profile. **Groups** is the list of groups you are in. |
| IG Inbox | instagram.com/direct/inbox (Instagram DMs) |
| IG Alerts | Two pages again. **Alerts** is instagram.com/notifications. **My Posts** is your own Instagram grid. |

Tap the tab you are already on to jump back to its home page.

## Your posts, and posts and profiles you tap

Your own posts, Reels, videos, photos, and stories always open. That is how you read and answer comments: tap a comment alert, or open the post from My Posts, and reply right on the post.

With **Open posts and profiles I tap** on (the default), a post by someone else opens too, as long as you tapped it. What never happens is the next one. Swiping to the next Reel, a story moving on to the next person, or autoplay into another video is blocked, and you stay on the post you opened. Turn the switch off and only your own posts open.

Someone else's profile opens the same way: tap their name and you see who they are. Every tab of that profile (About, Photos, Reels) counts as the same tap. The page stops after about a screen and a half, with a note that says "Anti-Social stops here", so a profile never turns into a feed of their posts.

### One video at a time

A video opens when you tap it, and you can watch it all the way through. Then you go back to pick another one.

- Tapping another video from a video page is blocked. Tapping it from a chat, your alerts, or a profile works.
- If a player starts a second video by itself (the next video in a viewer, or the player moving on after the first one ends), the app stops it and says so.
- Someone else's video page stops after a short scroll, like a profile, so the list of suggested videos underneath never goes on and on.
- Back and Forward are never blocked, and your own videos always play.

The page side of this is the `video` part of `hook.template.js` (in `Web/Injected.swift`). The app side is `verify` in `Web/WebController.swift`.

What counts as a tap:

- A link you tap opens the post it points to.
- A tap that does not point at a post (a shared-post card in a chat, a share link that redirects) opens the first post it leads to, but only when you start from a page that is not a post, like a chat or your alerts. From inside a post, only a link to another post counts. So the player can never move you on.

How the app knows a post is yours:

1. The link names you. `facebook.com/<you>/videos/<id>`, `instagram.com/<you>/reel/<code>`, `permalink.php?...&id=<your number>`, and so on. Your username comes from facebook.com/me and from Instagram's own nav. Your account number comes from each site's login cookie.
2. The app has seen it before. Every post on your own Reels grid (Facebook) or your grid (Instagram) is remembered as yours, along with every post it has checked.
3. Anything else is looked up once. Bare links like `facebook.com/reel/<id>` or `instagram.com/p/<code>` do not say who made them, so the app fetches that post's page and reads the owner from its header (`og:url` and the canonical link, which carry the owner's username). It tries as a visitor first, then as you, for posts only your friends can see. The page stays covered while this happens, so someone else's post never shows.

The rules are in `Policy/AccessPolicy.swift` (which links are posts, and who they name), `Policy/OwnershipParser.swift` (reading the owner off a page), and `Web/OwnershipChecker.swift` (the memory and the lookups).

## Groups

The **Groups** page lists the groups you are in. Each group opens in full: its posts, comments, members, and the box to write a post. Posts inside a group always open. The mixed Groups feed (posts from all your groups at once) and group suggestions stay blocked.

## What is blocked

The home feed, the Reels feed, Watch, the Stories feed, Friends, the Groups feed and suggestions, Gaming, Events, Memories, Saved, Search, Explore, hashtags, and any post or profile by someone else that you did not tap. Links to install or open the real apps are blocked too. Video never autoplays.

Blocking happens in two places:

1. Every real page load runs through the allowlist in `Policy/AccessPolicy.swift`. If the URL is not on the list, it is cancelled.
2. Facebook and Instagram change the URL without a real page load most of the time. A small script (`Web/Injected.swift`) reports every in-page URL change to the app, which checks the same list and steps back if the page is not allowed.

On top of that, feed links, Reels tabs, and "open the app" nags are hidden inside the pages. That part is cosmetic. The URL rules are the wall.

## Posting

Tap the pencil in the top bar for the posting menu.

- **Facebook:** New post, New reel, New story, Go live, Sell something. New post and New reel open your profile, scroll down to its post box or Reel button, and open it for you. Pick your photo or video in the window that opens.
- **Instagram:** New post or reel, and New story. Both open your profile and make Instagram's own + button glow. Tap it, then pick a photo or video (a video becomes a reel), or choose Story. Instagram only opens the photo picker from a real tap, so the app points at the button instead of pressing it.

The script that does this is `composeTemplate` in `Web/Injected.swift`, built from `compose.template.js`.

## Marketplace

Ads in the Marketplace results are hidden the moment they appear, and their videos never load. Each listing sits in a grid cell, and an ad's cell links out through `l.facebook.com` and holds no listing, which is how the app tells them apart (see `hidingScript` in `Web/Injected.swift`).

Marketplace sometimes jumped back to the top of the results while you scrolled. The page now guards against that:

- When the page moves up to the top by itself, it is put back where you were. A move you made is never undone: your finger pulling the page down, a tap, or a new search with new listings.
- Scrolling takes the focus off the search box, which also puts the keyboard away. Phones like to scroll back up to a box that has the focus, and Marketplace cannot make the page scroll to a box it focuses by itself.
- Every jump is written into Diagnostics as "Marketplace jumped to the top", with where it went from and to, how tall the page was, what had the focus, and which code moved the page if any did. Reloads the app did not start are written down too.

## What is allowed

Messages, Marketplace, notifications, groups, login and security pages, settings, your professional dashboard, your own profile (including your Reels and Videos tabs), your story archive, and your own posts, Reels, videos, photos, and stories. Other people's profiles open when you tap them, and stop after a short scroll. On Instagram: DMs, notifications, your own grid, and your own posts, Reels, stories, and highlights. Posting is allowed everywhere: a post, a story, Go Live, a Marketplace listing, and an Instagram post or story. Anything you tap opens as well (see above).

## Install on your iPhone

The quick way: plug in every iPhone you want it on, unlock them, and double-click `update-anti-social.command` in Documents. It builds the app, adds a new iPhone to your developer account, and installs it on each phone. A new phone needs two things first: tap **Trust** when it asks about this Mac, and turn on **Developer Mode** (Settings > Privacy & Security > Developer Mode, then restart and tap Turn On).

The manual way, in Xcode:

Needs Xcode 16 or newer on the Mac mini (Xcode 27 for an iPhone on iOS 27).

1. Open `AntiSocial.xcodeproj` in Xcode.
2. Click the `AntiSocial` project in the sidebar, pick the `AntiSocial` target, open **Signing & Capabilities**, and choose your Team. If Xcode complains about the bundle identifier, change `com.stefanoswald.antisocial` to anything unique.
3. Plug in the iPhone. Pick it as the run destination at the top of the window.
4. Press Run (Cmd+R). The first time, the phone will ask you to trust the developer under **Settings > General > VPN & Device Management**.

With the paid developer account the install stays valid for a year.

## First run

1. Delete the Facebook, Messenger, and Instagram apps from the phone. Links inside the web pages can open installed apps, and there is no reason to keep the doors open.
2. Log in to Facebook in the Messages tab. Log in to Instagram in the IG Inbox tab. Logins persist across all tabs and relaunches.
3. Open the Alerts tab, switch to **My Posts** once, and do the same in IG Alerts. That is how the app learns your usernames. You can also type them in Settings (the circle menu, top right).
4. Facebook uses the desktop site by default, because Facebook's mobile site refuses to show Messenger and bounces to the feed. If the text is too small, pick a narrower **Desktop page width** in Settings, or pinch to zoom. Rotating the phone sideways also helps.

## When something slips through

Open the circle menu, pick **Diagnostics**, tap **Capture page map**, then **Share page map**. Send that over together with what you saw and the rule can be tightened. The page map now also says where the page is scrolled to, what has the focus, how many ads were hidden, and the last 40 things the app noticed on the page (new pages, jumps, videos stopped).

The Diagnostics screen also keeps a log of everything that was blocked, in case something you needed got caught, plus Marketplace jumps and reloads the app did not start. **Share log** sends that list. It also shows which accounts the app thinks are yours and how many of your posts it knows.

## Checks

`Checks/main.swift` checks the rules in `Policy/AccessPolicy.swift` against more than a hundred links. The update script builds and runs it on the Mac before every build:

```
xcrun swiftc AntiSocial/Policy/AccessPolicy.swift Checks/main.swift -o /tmp/policy-check && /tmp/policy-check
```

The Android app's rules pass the same checks. The page scripts are tested separately, in the cloud, against the copies built into `Web/Injected.swift`.

## Files

```
AntiSocial/
  AntiSocialApp.swift        App entry. Builds settings and the web view pool.
  ContentView.swift          Tab bar, per-tab top bar, error card.
  Models/WebTab.swift        The pages, their home URLs, and the five tabs that hold them.
  Policy/AccessPolicy.swift  The allowlist. Change rules here.
  Policy/OwnershipParser.swift  Reads who made a post off the post's page.
  Settings/AppSettings.swift User settings, saved in UserDefaults.
  Web/WebController.swift    One WKWebView per tab, navigation and policy enforcement.
  Web/WebViewPool.swift      Keeps web views alive across tab switches, applies settings.
  Web/OwnershipChecker.swift Remembers your posts and looks up new ones.
  Web/Injected.swift         The in-page URL hook, hiding CSS, diagnostics script.
  Web/GuardedWebView.swift   SwiftUI wrapper.
  Views/                     Settings, Diagnostics, blocked banner.
Checks/
  main.swift                 Checks the rules. Not part of the app.
```
