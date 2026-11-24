# Fount

A lightweight, native macOS RSS reader that shows every article as its original web page.

Many readers re-render articles in their own reader view, which breaks code blocks and layouts on sites such as Zenn and Qiita. Fount loads the page itself in WebKit, so it looks exactly as it does in Safari.

- Three panes: feeds, articles, and the article's web page
- The article list shows each title with its feed, its time, a faint two-line excerpt from the feed, and the feed's thumbnail
- RSS 2.0, RSS 1.0 (RDF) and Atom
- Paste a page URL (e.g. `https://zenn.dev/topics/swift`) and Fount finds its feed
- Import subscriptions from OPML (e.g. exported from NetNewsWire)
- Refreshes on launch, every 30 minutes and on waking from sleep; unread count in the Dock and the menu bar
- Closing the window keeps Fount in the menu bar, still refreshing, so articles that busy feeds push out of their latest items aren't missed; clicking the menu bar item opens the window again, and right-clicking it shows Refresh, Open at Login (on by default) and Quit
- Written in Swift with AppKit and WebKit only — no Electron, no dependencies

## Requirements

- macOS 26 or later
- Xcode or the Xcode Command Line Tools (Swift 6.2+)

## Build

```sh
./build.sh
```

This produces `build/Fount.app`. `./build.sh --install` also copies it to `~/Applications`.

## Usage

- ⌘N adds a feed. ⌘R refreshes all feeds.
- In the article list: `j` / `k` next / previous article, `Space` / `Shift-Space` scroll the page, `o` or `Return` open in the browser, `m` toggle read.
- ⌘K marks all articles in the current feed as read. ⇧⌘U shows unread articles only; articles you read stay listed until the next ⌘R, so you can go back to them.
- Scrolling the article list marks the articles that scroll past its top as read, and clears the page so the article just read doesn't distract from picking the next.
- ⌘-click a link in the page to open it in your browser: the one picked in Article › Browser, or the system default. ⌘+ / ⌘- zoom the page; ⌥⌘+ / ⌥⌘- change the size of the article titles in the list.

Subscriptions and articles are stored in `~/Library/Application Support/Fount/state.json`.

## License

[MIT](LICENSE)
