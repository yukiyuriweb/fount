# CLAUDE.md

Fount is a lightweight, native macOS RSS reader (Swift + AppKit + WebKit, no dependencies, no Xcode project). Articles are shown as their original web pages in a `WKWebView`, so sites like Zenn and Qiita render exactly as in Safari, code blocks included.

## Build and run

- `./build.sh` builds a release binary, then assembles `build/Fount.app`, adds the icon and ad-hoc signs it. `./build.sh --install` also copies it to `~/Applications`, replacing any copy there.
- `swift build -c release` alone is enough to check that the code compiles.
- The app icon is drawn by `scripts/make-icon.swift`; `build.sh` regenerates it on every build. Don't commit image files for it.
- The app requires macOS 26 (`swift-tools-version:6.2` for `.v26`), so the binary records SDK 26 and gets Liquid Glass; SwiftPM records the deployment target as the SDK version. The Swift language mode stays 5 (`swiftLanguageModes: [.v5]`). `main.swift` wraps app startup in `MainActor.assumeIsolated`.

## Workflow

- The initial code went in through a one-off `develop` branch. After that is merged, cut one branch per issue from `main`. Open a PR to `main`; merge with **squash only** (the repo only allows squash, and deletes the head branch on merge).
- PRs get AI review from Codex (`@codex review`) and Copilot. For each finding: check it against the code, reproduce it when possible, fix it, then reply in the thread with the fixing commit hash and how it was verified. Say so when a finding is wrong instead of changing code.
- Each re-review tends to surface narrower edge cases. Once real issues are fixed, merge and track further findings as issues rather than looping.
- Commits, PRs, README and code comments are in English. UI strings are written in English with `String(localized:)`, and their Japanese translations live in `Localization/ja.lproj/Localizable.strings` (`build.sh` copies it into the app). Add every new UI string to that file.

## Conventions in the code

- **Show articles as web pages; don't fetch or render article bodies.** That is the point of the app. `FeedParser` keeps the title, link, ID, date and thumbnail of each item, plus a plain-text excerpt (at most 300 characters) from the summary the feed itself carries, falling back to the start of its content. The excerpt is drawn faintly under the title to space the titles apart; it is not meant to be read.
- **Never fetch on the main thread.** `Fetcher` is nonisolated and called from `Task`s; results come back to the `@MainActor` `Store`.
- **Change data only through `Store`.** Every change goes through `changed()`, which recounts unread articles, notifies the window and schedules a save one second later. `applicationWillTerminate` saves immediately.
- **Never drop an article the feed still lists.** `merge` keeps up to 200 older articles per feed, plus everything in the latest fetch; dropping a listed one would bring it back as unread on the next refresh.
- **Articles are identified by `Article.key`** (feed URL + item ID, falling back to the link). Table reloads restore the selection by key, inside the `reloading` flag so that restoring it doesn't count as a user selection.
- With "Unread" on, articles read since the last manual Refresh (`keptRead`) stay listed, so the reader can go back to them; Refresh clears them out together, keeping only the open article. The 30-minute automatic refresh leaves them alone. Articles the user scrolls past the top of the list are marked read and kept the same way; only live scrolls (`NSScrollView.didLiveScrollNotification`) count, so reloads, feed switches and sorting never mark anything read. Starting a live scroll also clears the page and the selection (`closeArticle`).
- **Keep refreshing while the window is closed.** Feeds list only their latest items (Lifehacker Japan: 20, about 12 hours), so articles that scroll out while Fount isn't running are lost for good. Closing the window switches the app to the `.accessory` activation policy, leaving a menu bar item with the unread count; the window is not released, and the store and refresh timer keep running. Fount registers itself to open at login once (`SMAppService.mainApp`), starts in the menu bar when launched at login, and refreshes on wake.
- Links meant for a new window, and ⌘-clicked links, open in the browser rather than inside the app. `Browser.open` uses the one picked in Article > Browser, or the system default.

## Verifying changes

- Screen capture is usually unavailable to the agent. To check the UI, temporarily add a hook that renders the window with `cacheDisplay(in:to:)` and the page with `WKWebView.takeSnapshot` to PNGs and quits, run the binary, inspect the images, then remove the hook before committing. `cacheDisplay` doesn't draw the web view's content, hence the separate snapshot.
- To test parsing without the UI, compile `Sources/Fount/FeedParser.swift` together with a throwaway `main.swift` outside the repo using `swiftc`, and run it against real feeds: Zenn (RSS 2.0), Qiita (Atom) and Hatena Bookmark (RSS 1.0) cover the three formats.
- A test run writes to the real `~/Library/Application Support/Fount/state.json`; leave it as you found it.

## Background

- The name means a spring or source, as in "a fount of ideas". It replaced the working name Rill before the first merge. Its closeness to "font" was considered and accepted.
- Built to replace Reeder Classic (paid) and NetNewsWire, whose reader view didn't show Zenn and Qiita code blocks properly.
- Features deliberately left out so far: folders, sync, full-text search, content blocking, and a reader view.
