# Rill

A lightweight, native macOS RSS reader that shows every article as its original web page.

Many readers re-render articles in their own reader view, which breaks code blocks and layouts on sites such as Zenn and Qiita. Rill loads the page itself in WebKit, so it looks exactly as it does in Safari.

- Three panes: feeds, articles, and the article's web page
- RSS 2.0, RSS 1.0 (RDF) and Atom
- Paste a page URL (e.g. `https://zenn.dev/topics/swift`) and Rill finds its feed
- Import subscriptions from OPML (e.g. exported from NetNewsWire)
- Refreshes on launch and every 30 minutes; unread count in the Dock
- Written in Swift with AppKit and WebKit only — no Electron, no dependencies

## Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools (Swift 5.9+)

## Build

```sh
./build.sh
```

This produces `build/Rill.app`. Move it to `/Applications` if you like.

## Usage

- ⌘N adds a feed. ⌘R refreshes all feeds.
- In the article list: `j` / `k` next / previous article, `Space` / `Shift-Space` scroll the page, `o` or `Return` open in the browser, `m` toggle read.
- ⌘K marks all articles in the current feed as read. ⇧⌘U shows unread articles only.
- ⌘-click a link in the page to open it in your default browser. ⌘+ / ⌘- zoom the page.

Subscriptions and articles are stored in `~/Library/Application Support/Rill/state.json`.

## License

[MIT](LICENSE)
