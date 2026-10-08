# CLAUDE.md

Rill is a lightweight, native macOS RSS reader (Swift + AppKit + WebKit, no dependencies, no Xcode project). Articles are shown as their original web pages in a `WKWebView`, so sites like Zenn and Qiita render exactly as in Safari, code blocks included.

## Build and run

- `./build.sh` builds a release binary, then assembles `build/Rill.app`, adds the icon and ad-hoc signs it.
- `swift build -c release` alone is enough to check that the code compiles.
- The app icon is drawn by `scripts/make-icon.swift`; don't commit image files for it.
- Swift language mode is 5 (`swift-tools-version:5.9`). `main.swift` wraps app startup in `MainActor.assumeIsolated`.

## Code

- `FeedParser.swift`: RSS 2.0 / RSS 1.0 (RDF) / Atom parsing, OPML import, feed discovery from `<link rel="alternate">` in HTML pages. Article bodies are deliberately not parsed.
- `Store.swift`: feeds and articles in `~/Library/Application Support/Rill/state.json`, saved one second after the last change. Up to 200 old articles are kept per feed, plus whatever the feed still lists (dropping those would bring them back as unread).
- `MainWindowController.swift`: three-pane window (feeds / articles / web view). Table reloads restore the selection by article key; the `reloading` flag keeps that from counting as a user selection.
- UI strings are English with `String(localized:)`; Japanese lives in `Localization/ja.lproj/Localizable.strings`. Add every new UI string there.

## Verifying changes

- To test parsing without the UI, compile `Sources/Rill/FeedParser.swift` with a throwaway `main.swift` outside the repo using `swiftc`.
- To check the UI, temporarily add a hook that renders the window with `cacheDisplay(in:to:)` and the page with `WKWebView.takeSnapshot`, then quits. Remove it before committing.
