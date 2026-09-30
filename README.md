# Reddit Menu Bar

A private-use macOS 14+ menu bar app written in Swift, AppKit, and SwiftUI, intended for an owner's personal and business accounts. Browse Home, Popular, and the selected account’s subscribed communities in Safari. All connected accounts are monitored for unread inbox replies, mentions, and private messages.

## Build and run

Open `RedditMenuBar.xcodeproj`, select the **RedditMenuBar** scheme and **My Mac**, then Run. The app appears as a speech-bubble icon in the menu bar, without a Dock icon. Open **Settings…** from its menu.

Command-line build and tests:

```sh
xcodebuild -project RedditMenuBar.xcodeproj -scheme RedditMenuBar -derivedDataPath build build
xcodebuild -project RedditMenuBar.xcodeproj -scheme RedditMenuBar -derivedDataPath build test
open build/Build/Products/Debug/RedditMenuBar.app
```

The project defaults to local ad-hoc signing. For a stable installed copy and launch-at-login testing, configure your signing team in Xcode and copy the app into `/Applications`. No third-party packages or server are required.

## Try without Reddit credentials

In Settings, enable **Demo mode**. Select either demo account in the menu to see its subscriptions. Click **Request notification permission**, then **Simulate reply for selected account**. Demo data is stored separately from live accounts; demo mode never accesses Reddit or real tokens. Turning demo mode off restores the live account list.

## Connect real accounts

1. Obtain explicit API access approval under Reddit’s [Responsible Builder Policy](https://support.reddithelp.com/hc/en-us/articles/42728983564564-Responsible-Builder-Policy). Do not use mock mode as evidence that API approval has been granted.
   Disclose any business use in the request and obtain the applicable written approval for commercial use. Devvit's [private user data documentation](https://developers.reddit.com/docs/capabilities/server/reddit-api#private-user-data) excludes subscribed subreddit lists, a required feature of this utility.
2. Register an **installed app**, with the exact redirect URI `redditmenubar://oauth/callback`. Registration availability depends on Reddit approval. Use the assigned client ID; an installed app does not have a client secret.
3. Save the client ID in Settings, disable demo mode, and click **Add / Reconnect account**. Approve the requested identity, subscription-list, and private-message scopes in the browser. The callback returns to the app.
4. To add another account, change the Reddit account in the authorization browser first, then repeat. Authorizing an existing username replaces its credentials while preserving its notification history.
5. Allow macOS notifications when requested. If previously denied, enable the app in System Settings → Notifications.

References: [Reddit OAuth](https://github.com/reddit-archive/reddit/wiki/OAuth2), [Reddit API endpoints](https://www.reddit.com/dev/api/).

Tokens are stored in macOS Keychain. Account names, subscriptions, preferences, and notified message IDs are stored in UserDefaults; message bodies are not persisted by the app. Removing an account deletes its local tokens and cached data. You can also revoke authorization through Reddit’s account settings. Remove live accounts before changing the client ID.

## Behavior

- The app checks unread inbox items every 60 seconds while running and awake. Existing unread items form a silent baseline when connecting an account. Subsequent items notify once per account, including across relaunches. It does not mark messages read.
- Every connected account is monitored. The account selected in the menu determines the subreddit list. Subscriptions refresh at launch, selection, manually, and every 15 minutes. Cached subscriptions remain available offline.
- Rate limits and transient errors delay subsequent attempts. Account failures are isolated; reconnect errors appear in Settings and the menu. Manual Refresh also respects an active retry delay.
- Notification clicks and menu browsing open Safari explicitly. Safari uses its current Reddit login; the app does not switch Safari accounts or profiles.
- Chat, new-post alerts, and embedded browsing are excluded. Private-message alerts without a comment context open the Reddit inbox.
- Launch at login is optional and off by default. macOS may require approval in Login Items.

## Manual acceptance checklist

These checks require an interactive macOS session; live checks additionally require approved credentials:

- Enable demo mode, switch accounts, and verify Home/Popular and the corresponding alphabetical subscription list.
- Request notifications, simulate a reply, and click its banner to open Safari. Deny permission and confirm browsing and polling still work.
- Quit/relaunch and confirm selection, cached subscriptions, and notification history survive.
- With a live account with many subscriptions, verify native menu scrolling and complete pagination.
- Connect two real accounts, verify their distinct subscriptions and notifications, then reconnect/remove one.
- Put the Mac to sleep and wake it; verify refresh resumes without repeating delivered alerts.
- Install a signed copy and verify enabling/disabling launch at login.

Automated tests use intercepted HTTP requests and temporary Keychain entries; they do not call Reddit. They cover OAuth callback validation, token refresh, pagination, rate limits, persisted alert deduplication, account isolation, and safe Safari links.

## Source privacy

This repository contains source, project configuration, documentation, and synthetic test fixtures only. It does not include account data, OAuth credentials, signing identities, build products, logs, screenshots, or Xcode user settings. Configure credentials locally in the app, and keep generated artifacts out of commits. Demo usernames and token strings in tests are fictional.

Validation: the macOS app and unit-test target built successfully, and all six tests passed. Interactive menu, notification, sleep/wake, and login-item acceptance checks remain pending. Live account integration has not been tested with approved credentials.
