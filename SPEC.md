# Pemeria — Spec

A focused Mac app for drafting fiction. Version 1 runs on the Mac only, and files live on the Mac only.

Items marked **(assumed)** are choices Claude made that the author hasn't confirmed yet. Review and override them freely.

---

## 1. Scope

**In v1**
- One novel = one project file.
- A sidebar of files that can be nested, reordered, folded and renamed.
- Select one or many files; the editor shows them together as one continuous document.
- Fiction typography: curly quotes, em dashes and first-line indents. Italics and bold.
- Every draft file has an attached outline.
- `//` comments, named bookmarks, and one Working File.
- File icons, defaulting to story beats.
- Notes vs. drafts.
- Word count.
- ⌘K search across everything.
- Split view, Read mode, and a one-click copy button on every file.
- Always saved, with automatic snapshots and a trash.

**Not now (but planned eventually)**
- iCloud sync and the iPhone app. The file format is designed so these can be added later.
- Export (Word, PDF, ePub).
- Headings, and bulleted lists. Lists are likely later, for notes.

---

## 2. The project on disk

A project is a **package**: a folder that Finder shows and handles as a single file, `My Novel.pemeria`. You double-click it, move it, back it up and email it like one file. Inside is plain readable text, so your words are never locked into the app.

```
My Novel.pemeria/
  project.json      project settings: name, icon definitions, Working File
  files/
    k3f9a2.md       one file per sidebar item (drafts and notes)
    p81xq0.md
    …
  state.json        window state: what's selected, panes, cursor positions. Safe to lose.
  snapshots/        automatic history (see §11)
  trash/            deleted files, restorable (see §11)
```

**Each file describes itself.** It records its own ID, title, parent and position, so the sidebar can always be rebuilt from `files/` alone. That makes a corrupted or missing index impossible, and it prepares the format for sync later.

Files are named by their ID, not their title, so renaming a file only changes a line inside it.

### File format

```
---
id: k3f9a2
title: The Lighthouse
parent: p81xq0
order: V
kind: draft
icons: inciting-incident, crisis
---
The lamp had been dark for *eleven* years.
She climbed anyway. // Too abrupt? Maybe add a beat here.
<!-- bookmark b7c1: The storm starts -->
Rain came sideways off the water — **hard**.
<!-- outline -->
Mara reaches the lighthouse. Finds the logbook. Storm hits.
```

- **The header** (between the `---` lines) holds the file's details. `parent` is left empty for top-level files. `kind` is `draft` or `note`.
- **Paragraphs:** one line = one paragraph. An empty line is an empty paragraph and is kept exactly as written.
- **Italics and bold** are stored as `*italic*` and `**bold**`. That's the only Markdown used.
- **Comments** are stored exactly as typed (see §6).
- **Bookmarks and the outline divider** are stored as `<!-- … -->` lines. Markdown viewers hide those, so the file stays clean to read.
- **Escaping:** if the prose itself contains a literal `*`, `\`, or `<!--`, it's saved with a backslash in front (`\*`), so it's never mistaken for formatting.
- **Order** uses sortable keys (`V`, `k`, `kV`…). There's always room for a new key between two others, so moving a file only rewrites that one file.
- **Notes have no outline section.** If a draft is converted to a note, its outline stays saved in the file but hidden. It reappears if the file is switched back to a draft. Nothing is lost.

### project.json

```json
{
  "formatVersion": 1,
  "name": "My Novel",
  "workingFile": "k3f9a2",
  "icons": [
    { "id": "inciting-incident", "name": "Inciting Incident", "symbol": "bolt.fill",          "color": "#E5484D" },
    { "id": "turning-point",     "name": "Turning Point",     "symbol": "arrow.triangle.turn.up.right.diamond.fill", "color": "#F5A524" },
    { "id": "crisis",            "name": "Crisis",            "symbol": "exclamationmark.triangle.fill", "color": "#D6409F" },
    { "id": "climax",            "name": "Climax",            "symbol": "flame.fill",         "color": "#8E4EC6" },
    { "id": "resolution",        "name": "Resolution",        "symbol": "checkmark.seal.fill", "color": "#30A46C" }
  ]
}
```

---

## 3. Window layout

```
┌──────────┬───────────────────────────────────┬────────────┐
│ Sidebar  │  Header: file name(s)             │ Comments   │
│          │                                   │  [Sel|All] │
│ files…   │  Editor (one or two panes)        │            │
│          │                                   ├────────────┤
│          ├───────────────────────────────────┤ Bookmarks  │
│          │  Pinned outline pane (optional)   │            │
│          ├───────────────────────────────────┤            │
│          │  Word count                       │            │
└──────────┴───────────────────────────────────┴────────────┘
```

The sidebar and the right panel each toggle on and off. One project is open at a time **(assumed)**; File → Open Recent switches between projects, and the last project reopens on launch.

---

## 4. Sidebar

- **Tree of files.** Drag to reorder. Drop onto a file to nest it inside. Parents fold and unfold to hide their children.
- **Nesting is for organizing only.** Selecting a parent selects only the parent, not its children.
- **Selecting:** click selects one file. ⌘-click adds or removes a file. ⇧-click selects a range. The editor shows all selected files in sidebar order.
- **Rename:** double-click the name, type, then Return.
- **Notes vs. drafts:** right-click → "Make Note" / "Make Draft". Notes show a note icon and never count toward the draft word count.
- **File icons:** up to 3 per file. They're drawn slightly overlapping, fanned like playing cards, to save room. Assign them from the right-click menu. Icons are defined per project (name, color, symbol) and you can make as many as you like. The defaults are the five story beats in §2. *Where you create and edit icon definitions (assumed: a small sheet reached from the right-click menu → "Edit Icons…").*
- **Working File:** shown with a **fat arrow** glyph. Only one file per project can be the Working File (see §8).
- **New file:** ⌘N creates a draft below the current selection. ⌥⌘N creates a note **(assumed)**. The **+** button under the file list does the same: click for a draft, hold for a note.
- **Delete** (Delete key, or right-click → Move to Trash…): asks first, then moves the file to the project's trash (§11). Anything nested inside it goes too, and the confirmation says how many. It is never deleted permanently from here.
- **Right-click** acts on the whole selection if you click a selected file, or on just the clicked file otherwise (as in Finder).

---

## 5. Editor

### Showing files
- **One file selected:** you see its text, then an outline divider, then its outline.
- **Several files selected:** they appear in sidebar order, each followed by its outline, with a **dotted page-break line** between files. Each file has a small name label at the top.
- **Remembering your place:** the cursor and scroll position are remembered per file. Switching away and back returns you to the same spot.
- **On project open:** whatever was open last is restored: selection, panes and positions.

### Editing within files only
- Selecting across files is allowed, and so is **copying** that selection.
- **Any edit that crosses a boundary is blocked** with a gentle flash and no change. That includes typing, deleting, cutting, or pasting over a selection that spans a file break. It also covers backspace at the very start of a file and edits spanning the gap between a file's text and its outline.
- Pasting is always allowed inside a single file.
- Result: one keystroke can never damage more than one file.

### Formatting
- **What you see is what you edit.** The editor works on real italic and bold text, never on hidden Markdown symbols. The `*` markers exist only in the saved file, and you never see them.
- ⌘I toggles italic and ⌘B toggles bold, working like any Mac app. Typing right after italic text continues in italic.
- **Pasting from elsewhere:** italic and bold come through. Fonts, sizes and colors are dropped, so everything matches the global style. The characters themselves are pasted exactly as they were.

### Typography (display and typing only; nothing is rewritten after the fact)
- **Curly quotes and apostrophes** are converted as you type, like every Mac app, and stored as real curly characters. Getting these right in every situation (*'em*, *'til*) is later polish; working curly quotes come first.
- **Em dash:** `--` becomes — as you type.
- **First-line indent** on every paragraph of draft text. The first paragraph of each file is flush left, following book convention **(assumed)**. Outlines and notes are flush left throughout **(assumed)**. Indents are drawn by the editor; no tabs are stored.
- **No spacing between paragraphs** (book style). Spacing is a global setting.

### Global settings (Preferences, app-wide, never per document)
Font, size, alignment (justified by default, or left), line height, indent size, editor width, light/dark theme.

---

## 6. Comments

- **Typing `//` starts a comment.** It must be at the start of a line or after a space, so web addresses like `https://` are never caught.
- **A comment ends** at the end of the line, or at the first sentence-ending mark (`.` `?` `!` `…`), whichever comes first. The ending mark is part of the comment.
  - *Known quirk:* "Dr." or "e.g." ends a comment early. You'll see it right away because the rest won't be grayed out.
- **Comments are drawn grayed out**, so they're quiet rather than shouting at you.
- They're ordinary text, so you edit them normally. They travel with the text they sit next to.
- **Never counted** in word counts. **Never included** in copy.
- **Comments panel:** lists comments with a snippet each. Click one to jump to it. A toggle switches between **Selected** (the default: only the files you have selected) and **All** (the whole project). The **+** button inserts `// ` at the cursor.

---

## 7. Bookmarks

- **⌘D** opens a small name popup at the cursor, Blender-style. Type a name, press Return, done. Esc cancels.
- **A bookmark marks a line.** It's drawn as a **labeled dotted line** above that line, styled clearly differently from the page-break line between files (accent color plus the bookmark's name).
- **One unit:** the bookmark behaves as a single piece in the text. Backspace removes the whole thing, and undo brings it back. The cursor hops over bookmark lines like it does over divider lines. Leaving the name empty names the bookmark after the first few words of its line **(assumed)**.
- **Right-click a bookmark** in the panel to rename or delete it.
- **Bookmarks panel:** lists all bookmarks in the project, in book order **(assumed: always project-wide, since bookmarks are for navigation)**. Click one to jump. Double-click to rename. The **+** button does the same as ⌘D.

---

## 8. Working File

- Exactly one file per project can be the Working File. It's marked with a fat arrow in the sidebar.
- **Set it:** right-click → "Set as Working File", or **⇧⌘J** **(assumed)**.
- **Jump to it:** **⌘J** **(assumed)** selects it and puts the cursor back where you left off.
- Opening a project does **not** jump to the Working File; it restores whatever was last open (§5).

---

## 9. Outlines

- Every **draft** has an outline: plain text, with the same formatting and comments as the draft. Notes have no outline.
- **By default** the outline appears inline after its file, below a divider.
- **Pin:** a pin icon on the divider (or View → Pin Outline, **⌥⌘O** **(assumed)**) moves outlines into the **pinned outline pane** at the bottom; its height is adjustable by dragging. When pinned, the main editor shows only the draft text. The pane shows the outlines of **all selected files**, stacked, each labeled with its file name. Unpinning puts them back inline.
- **Outline text never counts** toward the draft word count. It has its own count (§10).

---

## 10. Word count

- **The bar** at the bottom shows the word count of the **selected drafts' text**. It leaves out outlines, comments, bookmarks and notes.
- **Click it** to see:
  - Selected Draft
  - Selected Outline
  - Total Draft (whole project)
  - Total Outline (whole project)
- **Counting method:** match Microsoft Word, so numbers agree with what agents and publishers see. Check this against Word with a sample text, including em-dashed words, hyphens, ellipses and numbers.

---

## 11. Saving and safety

- **Always saved.** There is no ⌘S to remember. Changes are written when you pause typing (about 1 second), when you switch files, when the app goes to the background, and on quit.
- **Safe writes:** each save writes a new copy, then swaps it in. A crash mid-save leaves the previous version intact.
- **Snapshots:** each changed file gets an automatic copy in `snapshots/`, at most every ~10 minutes while you're editing it, plus before any risky operation such as delete or note/draft conversion. *A screen for browsing and restoring snapshots comes after the core editor; snapshots start being recorded from day one.*
- **Trash:** deleted files go to the project's `trash/`. They're restorable, and permanently deleted only by an explicit "Empty Trash".
- **Backups:** the package layout is plain files, so Time Machine backs it up cleanly.

---

## 12. Other features

- **Header:** shows the file name. Click and type to rename it when one file is selected. With several selected it shows "Name, Name, …" and can't be edited.
- **Split view:** two editor panes side by side, one of them active (clearly highlighted). Selecting in the sidebar changes what the **active** pane shows, and clicking into a pane makes the sidebar show that pane's selection. Toggle with **⌘\\** **(assumed)**.
- **Read mode** (eye icon, **⇧⌘R** **(assumed)**) hides comments, outlines and bookmarks, so you can just read the draft. Read mode is **read-only (assumed)**: editing while things are hidden risks deleting text you can't see. Exit Read mode to edit.
- **One-click copy:** a copy button in the top corner of every file. It copies the **draft text only**, with no comments, bookmarks or outline. The copy is formatted text (italics, bold, curly quotes), so it pastes cleanly into Word, Google Docs or email, and also includes a plain-text version.
- **⌘K search:** an overlay you type into, with results as you type. It searches **everything**: file names, drafts, outlines, notes, comments and bookmarks. Results are grouped by type, each with a preview snippet. Use the arrow keys to move and Return to jump.

---

## 13. Keyboard shortcuts

| Action | Keys |
|---|---|
| Italic / Bold | ⌘I / ⌘B |
| Add bookmark | ⌘D |
| Start a comment at the cursor | ⌘/ *(assumed)* |
| Search everything | ⌘K |
| Jump to Working File | ⌘J *(assumed)* |
| Set Working File | ⇧⌘J *(assumed)* |
| New draft / new note | ⌘N / ⌥⌘N *(assumed)* |
| Split view | ⌘\\ *(assumed)* |
| Read mode | ⇧⌘R *(assumed)* |
| Pin / unpin outline | ⌥⌘O *(assumed)* |
| Toggle sidebar | ⌃⌘S *(assumed, Mac standard)* |
| Toggle right panel | ⌥⌘0 *(assumed)* |

---

## 14. Technical approach

- **Code layout:** the file format, the project package and the tree live in `PemeriaCore/`, a Swift package with its own tests (`swift test`). The app target uses it.
- **Swift. SwiftUI for the window and panels. AppKit's text view (TextKit 2) for the editor.** SwiftUI's own text editor isn't capable enough for this.
- **Mac-only target.** The starter Xcode project currently also targets iOS and visionOS; turn those off for now.
- **One text view shows all selected files.** Behind it, a map records which part of the text belongs to which file (and which part is that file's outline). Each edit is checked against that map: edits inside one part go to that file's model, and edits that cross a boundary are refused (§5). Using a single text view is what makes selecting and copying across files work naturally. TextKit 2 only lays out what's on screen, so showing a whole novel stays fast.
- **Converting between screen and disk** (formatted text ↔ the file format in §2) is its own small, heavily tested piece. The core rule is that **opening and saving a file must reproduce it exactly**, checked against a set of sample files covering the tricky cases: asterisks in prose, italics inside a word, bold-italic, spaces at the edge of italics, comments with italics, bookmarks, empty paragraphs.
- **Saving** is handled by Pemeria itself, writing only the individual files that changed (§11), rather than by the standard Mac document system, which rewrites the whole package on every save **(assumed; to revisit if the standard system's version-browsing features turn out to be worth it)**.

---

## 15. Build order

1. **File format:** project package, file model, the converter, and round-trip tests. No interface yet.
2. **Sidebar:** create, rename, reorder, nest, fold, note/draft, delete to trash.
3. **Single-file editor:** italic and bold, typography, indents, autosave, remembering your place, global Preferences.
4. **Multi-file editor:** one view for several files, page breaks, cross-file edit blocking, inline outlines, the pinned outline pane.
5. **Comments, bookmarks, the right panel, Read mode.**
6. **Word count, file icons, Working File, header rename, one-click copy.**
7. **⌘K search, split view, the snapshot browser.**

**Later:** export, lists in notes, iCloud sync, the iPhone app.
