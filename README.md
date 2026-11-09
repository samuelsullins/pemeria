# Pemeria

The final Mac app for fiction writing.

Pemeria does away with the heaps of buttons and confusing options that other apps are loaded with. My main design philosophy creating Pemeria was "can I delete that?" And most of the time the answer was yes. I started with a screenshot of Scrivener and scribbled out all the piles of confusing controls and went from there.

Pemeria is wholly ai-developed, but under my exacting and continuous design command.

In Pemeria you have drafts and notes. Notes don't count against the project word count which is nice. Just keeps them a little separate. Drafts are where you write. Every draft has a special note section attached for that file's outline. 

It works really well to use one draft file for each scene or chapter. You can nest them within each other in the sidebar to organize into acts or quadrants.

You can't have different text sizes in files, or headings, or any of that. Those are distractions and have been taken away.

It comes with a view-only mobile app that works when your files are in iCloud. Why view only? Because I will not risk iCloud diffs wiping my writing (this has happened to me with Obsidian and other apps.)

Pemeria is currently in development and might have some issues still being worked on.

Why is it called that? It's the name of a nasty land in a fantasy world I have. It sounded cool so I used it for this.

## General features

- **Files you can nest, reorder and fold**. Each one is either a draft or a note. Select multiple to view together as one chunk.
- **An outline attached to every draft file**, shown inline but you can pin it to its own pane.
- **Code comments typed straight into the text.** `//` starts a comment and `#` a bookmark. They end on newlines or with `\`. Putting an x, `//x`, marks a comment done. The right hand sidebar lists out all the comments and bookmarks.
- **Fiction typography by default:** curly quotes, em dashes, first-line indents, italics and bold.
- **Split view, Read mode, word counts, color-coded labels/tags, a Working File marker, and ⌘F search across everything.**
- **One-click copy to clipboard** of the manuscript, the outline, or both.
- **Always saved**, with automatic snapshots and a trash can to restore from.

The full design, including the file format, is in [SPEC.md](SPEC.md). This is an in progress project currently evolving faster than the spiders in _Children of Time_ so watch out.

## Building

You need macOS 27 and Xcode 27.

1. Open `Pemeria.xcodeproj`.
2. In each target's **Signing & Capabilities**, choose your own team.
3. Run the **Pemeria** scheme.

The file format and project logic live in `PemeriaCore`, a Swift package with its own tests:

```bash
cd PemeriaCore && swift test
```

## Project layout

| Folder | What's in it |
| --- | --- |
| `Pemeria/` | The Mac app: SwiftUI for the window and panels, AppKit (TextKit 2) for the editor |
| `PemeriaCore/` | The file format, the project package, comments, search and word counts, with tests |
| `PemeriaReader/` | The iPhone reader |
| `Config/` | Info.plists and entitlements |

## A project on disk

A project is a `.pemeria` package: a folder that Finder treats as one file. Inside, every sidebar item is its own Markdown-like text file, readable in any text editor. See [SPEC.md §2](SPEC.md#2-the-project-on-disk).

## Contributing

Pemeria is a personal project with one maintainer (me), and it's kept deliberately small. You're welcome to open issues, but pull requests may not be merged, and what goes into the app is the maintainer's call. If you want it to work differently, fork it and go to town.

## License

The code is released under the [MIT License](LICENSE): anyone may use, change and share it, as long as the copyright notice stays with it.

The name "Pemeria" and the app icon aren't covered by the license. If you ship your own version, please give it a different name and icon.
