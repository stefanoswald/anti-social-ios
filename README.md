# Anti-Social

A locked-down browser for Facebook and Instagram. It loads only the parts you need and refuses everything else before it loads, so there is nothing to scroll.

Five tabs:

| Tab | What it opens |
|---|---|
| Messages | facebook.com/messages (Messenger inbox and conversations) |
| Marketplace | facebook.com/marketplace (browse, search, your listings, buyer chats) |
| Alerts | facebook.com/notifications (comments, mentions, tags, and the posts they point to) |
| IG Inbox | instagram.com/direct/inbox (Instagram DMs) |
| IG Alerts | instagram.com/notifications (comments and mentions on your posts) |

Tap the tab you are already on to jump back to its home page.

## What is blocked

Home feed, Reels, Watch, Video, Stories, Friends, Groups feed, Gaming, Events, Memories, Saved, Search, Explore, hashtags, and every profile except your own. Links to install or open the real apps are blocked too. Video never autoplays.

Blocking happens in two places:

1. Every real page load runs through the allowlist in `Policy/AccessPolicy.swift`. If the URL is not on the list, it is cancelled.
2. Facebook and Instagram change the URL without a real page load most of the time. A small script (`Web/Injected.swift`) reports every in-page URL change to the app, which checks the same list and steps back if the page is not allowed.

On top of that, feed links, Reels tabs, and "open the app" nags are hidden inside the pages. That part is cosmetic. The URL rules are the wall.

## What is allowed

Messages, Marketplace, notifications, login and security pages, settings, your professional dashboard, single posts (`/username/posts/...`, `/permalink.php`, `/story.php`, `/photo...`, single videos), single group posts (can be turned off), and your own profile once you enter your username in Settings. On Instagram: DMs, notifications, single posts (`/p/...`), and your own profile.

Single Reels are off by default because a Reel page can swipe into the next one. Turn it on in Settings if you need to answer comments on your Reels.

## Install on your iPhone

Needs Xcode 16 or newer on the Mac mini.

1. Open `AntiSocial.xcodeproj` in Xcode.
2. Click the `AntiSocial` project in the sidebar, pick the `AntiSocial` target, open **Signing & Capabilities**, and choose your Team. If Xcode complains about the bundle identifier, change `com.stefanoswald.antisocial` to anything unique.
3. Plug in the iPhone 15 Pro Max. Pick it as the run destination at the top of the window.
4. Press Run (Cmd+R). The first time, the phone will ask you to trust the developer under **Settings > General > VPN & Device Management**.

With the paid developer account the install stays valid for a year.

## First run

1. Delete the Facebook, Messenger, and Instagram apps from the phone. Links inside the web pages can open installed apps, and there is no reason to keep the doors open.
2. Log in to Facebook in the Messages tab. Log in to Instagram in the IG Inbox tab. Logins persist across all tabs and relaunches.
3. Open Settings (the circle menu, top right) and enter your Facebook and Instagram usernames so you can open your own profile.
4. Facebook uses the desktop site by default, because Facebook's mobile site refuses to show Messenger and bounces to the feed. If the text is too small, pick a narrower **Desktop page width** in Settings, or pinch to zoom. Rotating the phone sideways also helps.

## When something slips through

Open the circle menu, pick **Diagnostics**, tap **Capture page map**, then **Share page map**. Send that over together with what you saw and the rule can be tightened. The Diagnostics screen also keeps a log of everything that was blocked, in case something you needed got caught.

## Files

```
AntiSocial/
  AntiSocialApp.swift        App entry. Builds settings and the web view pool.
  ContentView.swift          Tab bar, per-tab top bar, error card.
  Models/WebTab.swift        The five tabs and their home URLs.
  Policy/AccessPolicy.swift  The allowlist. Change rules here.
  Settings/AppSettings.swift User settings, saved in UserDefaults.
  Web/WebController.swift    One WKWebView per tab, navigation and policy enforcement.
  Web/WebViewPool.swift      Keeps web views alive across tab switches, applies settings.
  Web/Injected.swift         The in-page URL hook, hiding CSS, diagnostics script.
  Web/GuardedWebView.swift   SwiftUI wrapper.
  Views/                     Settings, Diagnostics, blocked banner.
```
