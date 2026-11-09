# Pemeria

A focused Mac app for drafting fiction.

Pemeria puts a novel's files in a sidebar and lets you write in them one at a time or several together, as one continuous document. Each draft file has its own outline. Your words are saved as plain text files, so they're never locked into the app.

## What it does

- **Files you can nest, reorder and fold**, each one either a draft or a note. Select several and the editor shows them together.
- **An outline attached to every draft file**, shown inline or pinned in its own pane.
- **Comments and bookmarks typed straight into the text.** `//` starts a comment and `#` a bookmark; both run to the end of the line, or end early with `\`. `//x` marks a comment done. The right panel lists them all.
- **Fiction typography:** curly quotes, em dashes, first-line indents, italics and bold.
- **Split view, Read mode, word counts, labels, a Working File, and ⌘F search across everything.**
- **One-click copy** of the manuscript, the outlines, or both.
- **Always saved**, with automatic snapshots and a trash you can restore from.

There's also a small iPhone app, **Pemeria Reader**, that opens a project for reading.

The full design, including the file format, is in [SPEC.md](SPEC.md).

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

Pemeria is a personal project with one maintainer, and it's kept deliberately small. You're welcome to open issues, but pull requests may not be merged, and what goes into the app is the maintainer's call. If you want it to work differently, fork it: the license lets you.

## License

The code is released under the [MIT License](LICENSE): anyone may use, change and share it, as long as the copyright notice stays with it.

The name "Pemeria" and the app icon aren't covered by the license. If you ship your own version, please give it a different name and icon.
