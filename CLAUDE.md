# CLAUDE.md

Rill is a lightweight, native macOS RSS reader (Swift + AppKit + WebKit, no dependencies, no Xcode project). Articles are shown as their original web pages in a `WKWebView`, so sites like Zenn and Qiita render exactly as in Safari, code blocks included.

## Build and run

- `./build.sh` builds a release binary, then assembles `build/Rill.app`, adds the icon and ad-hoc signs it.
- `swift build -c release` alone is enough to check that the code compiles.
- The app icon is drawn by `scripts/make-icon.swift`; `build.sh` regenerates it on every build. Don't commit image files for it.
- Swift language mode is 5 (`swift-tools-version:5.9`). `main.swift` wraps app startup in `MainActor.assumeIsolated`.

## Workflow

- The initial code went in through a one-off `develop` branch. After that is merged, cut one branch per issue from `main`. Open a PR to `main`; merge with **squash only** (the repo only allows squash, and deletes the head branch on merge).
- PRs get AI review from Codex (`@codex review`) and Copilot. For each finding: check it against the code, reproduce it when possible, fix it, then reply in the thread with the fixing commit hash and how it was verified. Say so when a finding is wrong instead of changing code.
- Each re-review tends to surface narrower edge cases. Once real issues are fixed, merge and track further findings as issues rather than looping.
- Commits, PRs, README and code comments are in English. UI strings are written in English with `String(localized:)`, and their Japanese translations live in `Localization/ja.lproj/Localizable.strings` (`build.sh` copies it into the app). Add every new UI string to that file.

## Conventions in the code

- **Show articles as web pages; don't parse article bodies.** That is the point of the app. `FeedParser` keeps only the title, link, ID and date of each item.
- **Never fetch on the main thread.** `Fetcher` is nonisolated and called from `Task`s; results come back to the `@MainActor` `Store`.
- **Change data only through `Store`.** Every change goes through `changed()`, which recounts unread articles, notifies the window and schedules a save one second later. `applicationWillTerminate` saves immediately.
- **Never drop an article the feed still lists.** `merge` keeps up to 200 older articles per feed, plus everything in the latest fetch; dropping a listed one would bring it back as unread on the next refresh.
- **Articles are identified by `Article.key`** (feed URL + item ID, falling back to the link). Table reloads restore the selection by key, inside the `reloading` flag so that restoring it doesn't count as a user selection.
- With "Unread" on, the open article stays listed after it turns read, until the selection or filter changes.
- Links meant for a new window, and ⌘-clicked links, open in the default browser rather than inside the app.

## Verifying changes

- Screen capture is usually unavailable to the agent. To check the UI, temporarily add a hook that renders the window with `cacheDisplay(in:to:)` and the page with `WKWebView.takeSnapshot` to PNGs and quits, run the binary, inspect the images, then remove the hook before committing. `cacheDisplay` doesn't draw the web view's content, hence the separate snapshot.
- To test parsing without the UI, compile `Sources/Rill/FeedParser.swift` together with a throwaway `main.swift` outside the repo using `swiftc`, and run it against real feeds: Zenn (RSS 2.0), Qiita (Atom) and Hatena Bookmark (RSS 1.0) cover the three formats.
- A test run writes to the real `~/Library/Application Support/Rill/state.json`; leave it as you found it.

## Background

- Built to replace Reeder Classic (paid) and NetNewsWire, whose reader view didn't show Zenn and Qiita code blocks properly.
- Features deliberately left out so far: folders, sync, full-text search, content blocking, and a reader view.
