# VimText — Architecture & Code Map

A guide to the codebase for humans and LLM agents. Read this first to navigate
quickly to the right file instead of grepping the whole tree.

## What it is

A native macOS notes app with first-class Vim keybindings ("Apple Notes, but
with Vim"). SwiftUI + AppKit (TextKit 1 / `NSLayoutManager`), Swift 5.9,
macOS 14+, **no external dependencies** (keep it that way).

## Build / run / test

- **`./build.sh`** — compile (release) → bundle `.app` → install to
  `/Applications` → relaunch. This is the standard run loop.
- Compile only: **`swift build -c release --product VimText`**.
  > ⚠️ Plain `swift build` fails: it also builds the `VimTextSmokeTests` target,
  > which uses `@testable import` and won't compile in release. Always pass
  > `--product VimText` (build.sh already does).
- Tests: **`swift run -Xswiftc -enable-testing VimTextSmokeTests`**
  (the `-enable-testing` flag is required for `@testable import VimTextCore`).
- Release: tag `vX.Y.Z` and push (feature = minor bump, fix = patch).
- The SPM `VimTextCore` target globs `VimText/`, so **new files are picked up
  automatically** — but incremental builds occasionally miss a brand-new file;
  if a new type "isn't found," `rm -rf .build` once.

## Directory layout (`VimText/`)

| Path | Responsibility |
| --- | --- |
| `VimTextApp.swift` | `@main` App, menu commands, global keyboard shortcuts. |
| `Models/` | `Note`, `NoteFolder` — plain value types. |
| `Storage/StorageManager.swift` | Disk persistence (JSON + `.txt`/`.rtf` sidecars), image assets, backups/recovery. Singleton. |
| `ViewModels/NotesViewModel.swift` | `@MainActor` store: notes/folders state, filtering pipeline, debounced saves. |
| `Views/` | SwiftUI views (sidebar, editor chrome, command palette, content split). |
| `Vim/` | The editor core: Vim engine + the AppKit text view and its bridge. |
| `Theme/` | Themes, design tokens (`DS`), cached date formatters. |
| `Support/` | Small cross-cutting helpers (notification names, prefs, image Markdown). |

## The editor core (`Vim/`) — most of the complexity lives here

The editor is a SwiftUI `NSViewRepresentable` wrapping a custom `NSTextView`.
It was one 4000-line file; it is now split by responsibility:

| File | Type | What it does |
| --- | --- | --- |
| `VimMode.swift` | `VimMode`, `VimAction`, `Motion`, `TextObject` enums + `VimWordUnderCursor` | The vocabulary of the engine (pure, testable). |
| `VimEngine.swift` | `VimEngine` | **Key → action state machine.** `processKey` parses normal/visual/operator-pending input into `[VimAction]`. No view knowledge. This is where you add a new keybinding's *parsing*. |
| `VimTextView.swift` | `VimTextView` (struct) | The `NSViewRepresentable`: builds the `NSScrollView`/text view and loads the note's content **once** in `makeNSView`; `updateNSView` only syncs presentation (font/theme/paper/rulers). Edits flow out through `onContentChange`. |
| `VimTextView+Coordinator.swift` | `VimTextView.Coordinator` | The `NSTextViewDelegate` bridge: **resolves motions against live text** (`resolveMotion`), **executes `VimAction`s** (the big `executeActions` switch), debounced serialization reported via `onContentChange`, find, marks. This is where you *resolve* a new motion/action. |
| `VimNSTextView.swift` | `VimNSTextView` (NSTextView subclass) | Low-level view behavior: `keyDown` routing, block-cursor drawing, paste (incl. images), image selection/resize, rich-text formatting, code-block restyle, paper styles. |
| `FindController.swift` | `FindController` | In-note find bar state + the local key monitor (Enter/Shift-Enter/⌘G; ⌘K navigation mode). |
| `ImageAttachment.swift` | `ImageTextAttachment`, `ImageAttachments` | Inline image attachment + attributed-string ↔ Markdown conversion. |
| `LineNumberRulerView.swift` | `LineNumberRulerView` | Gutter / line numbers. |
| `PremiumScroller.swift` | `PremiumScroller` | Thin overlay scrollbar. |

### Data flow for a keystroke (normal mode)
`VimNSTextView.keyDown` → `Coordinator` calls `VimEngine.processKey` → gets
`[VimAction]` → `Coordinator.executeActions` resolves each against the live
`NSTextStorage` (motions via `resolveMotion`) and mutates the text view.

### Adding a Vim motion (touches ~4 places)
1. `Motion` enum in `VimMode.swift` (+`isLinewise`/`isInclusive`).
2. `VimEngine` normal-mode `switch` and `motionForKey` (for operators like `dX`).
3. Visual-mode parsing in `VimEngine`.
4. `Coordinator.resolveMotion(_:in:)` in `VimTextView+Coordinator.swift`.

## Persistence model (`StorageManager`)

- One note = `<slug>-<createdAt>.json` (metadata) + `.txt` (plain content) +
  optional `.rtf` (rich formatting). `urlsByID` maps note id → file so a title
  edit renames rather than orphans.
- Content is the source of truth for text; RTF is a formatting cache.
- **Images**: stored as files in `notes/assets/<uuid>.<ext>`, referenced in the
  `.txt` as portable Markdown `![|<width>](assets/…)`. The editor renders these
  as inline attachments and serializes them back to Markdown on save. See
  `Support/ImageMarkdown.swift` (pure parser) and `Vim/ImageAttachment.swift`.
  Orphan assets are pruned at launch (`pruneOrphanAssets`).
- Reads are split: `readNotesSnapshot()` (off-main, pure) + `apply()` (main) to
  avoid racing `urlsByID`.

## Saving (debounced)

`NotesViewModel.updateNoteContent` updates memory immediately and schedules a
~0.5s disk write; `flushPendingSavesSynchronously()` runs on ⌘S, note switch,
window close, and app quit/resign-active. The editor (`Coordinator`) separately
debounces the expensive per-keystroke work (full-string sync, RTF
serialization, code-block restyle) and flushes via the `commitEditorPendingWork`
notification.

## Editor data flow (NSTextStorage is the source of truth)

`NSTextStorage` owns the note content. `VimTextView` takes `initialText` /
`initialRTFData` and loads them once in `makeNSView`; SwiftUI never pushes
content back into the view. Edits are serialized (Markdown text + RTF) when
typing pauses (~0.5s) or on flush (`commitEditorPendingWork`), and reported
upward via the `onContentChange` callback, which feeds `NoteEditorView`'s save
pipeline. There is no per-keystroke full-document copy and no
`updateNSView` content diffing. `.id(noteId)` recreates the editor per note on
purpose (isolates undo stack, Vim mode, and marks) — which is what makes the
initial-content-only model safe.

## Cross-cutting gotchas

- **UTF-16 vs grapheme**: `NSRange`/`selectedRange` are UTF-16 offsets — clamp
  with `(string as NSString).length`, not `String.count`.
- **Event bus**: `Support/NotificationNames.swift` lists the app's
  `Notification.Name`s (createNewNote, findInNote, openCommandPalette,
  commitEditorPendingWork, revealNoteInSidebar, …).
- **Refactor safety**: types in `Vim/` are split across files in one module;
  most cross-file calls are `internal`. When moving code, only access widening
  (`private` → `internal`) should ever be needed — never change logic.

## Biggest remaining cleanup target

`VimTextView+Coordinator.swift` (~2200 lines) is the largest file: the
`executeActions` action dispatch dominates it. It's the next candidate to split
(e.g. by action category into `Coordinator` extensions), but doing so requires
relaxing some `private` helpers to `internal`/`fileprivate`.
