# Architecture

Folio is a single-target SwiftUI app. UIKit is used where PDFKit needs it: the PDF view, the page-curl controller, and gesture recognizers.

## Source layout

```
Folio/
├── App/          FolioApp (entry point, startup, migration), UI-test fixtures
├── Models/       SwiftData models (LibraryDocument, LibraryFolder) and Markup
├── Services/     Storage, files, thumbnails, preferences, sound, sync journal
├── Reader/       Reader screen, PDF hosting, Flip controller, page scrubber
├── Views/        Library, settings, and the shared design system
└── Resources/    Bundled audio
Scripts/          generate_project.py — regenerates Folio.xcodeproj
```

## Core types

| Type | Kind | Responsibility |
| --- | --- | --- |
| `FolioApp` | `App` | Creates the storage folder, runs migrations, opens the SwiftData container, and builds `LibraryStore` |
| `LibraryStore` | `@MainActor` class | Owns the SwiftData context: documents, folders, bookmarks, progress, and library operations |
| `DocumentFiles` | `actor` | Coordinated imports, SHA-256 fingerprints, atomic annotation sidecars, and PDF export |
| `DocumentSource` | `enum` | Where a PDF lives: `.managed` (copied into the app), `.external` (security-scoped bookmark), or `.unlinked` (needs locating) |
| `ThumbnailCache` | `actor` | Renders and caches covers and page tiles off the main actor |
| `ReaderSession` | class | The open document, markup history (undo/redo), search, and ordered save snapshots |
| `PDFHostController` | `UIViewController` | A stable `PDFView` for Vertical scroll, restoration after layout, and drawing gestures |
| `BookPDFController` | `UIViewController` | Flip mode, built on `UIPageViewController` with a page curl |
| `ReaderNavigating` | `protocol` | Lets jumps and search drive whichever reader is active |
| `AppPreferences` | `@Observable` class | Layout, appearance, reading mode, and sound settings in `UserDefaults` |
| `PageTurnSound` | class + `actor` | Serializes audio-session setup and playback for the Flip sound |
| `ReadingSyncService`, `SyncJournal` | classes | CloudKit reading-data sync. **Disabled** by `ReleaseFeatures.iCloudSync = false`; the journal still provides local recovery |

## Storage on disk

All data lives under `Application Support/Folio/` (`FolioUITests/` during UI tests).

| Path | Contents |
| --- | --- |
| `Documents/` | Imported originals, named `<uuid>.pdf`, never modified |
| `Annotations/` | One `<uuid>.json` per document: a versioned `MarkupEnvelope` |
| `Thumbnails/` | Disk thumbnail cache, capped at 24 MB |
| `Exports/` | Temporary shared PDFs, removed the next time the library appears |
| `Library.store` | SwiftData store for documents and folders |
| `Sync/Journal.json` | Reading-data journal used for recovery |
| `SchemaVersion` | Migration marker. Older stores are backed up to `BeforeReferenceMigration/` before upgrading |

Annotations are kept as a JSON sidecar instead of being written into the PDF. Originals stay byte-identical, and markup is only embedded when you export.

## Flow of a document

1. **Import.** `DocumentFiles` streams the file into `Documents/` through a `.partial` file while hashing it. A matching fingerprint reuses the existing library entry.
2. **Open.** The PDF is loaded on a worker and handed to the main actor as a `LoadedPDF`, a one-way ownership transfer. `ReaderSession` applies the sidecar markup as `PDFAnnotation`s.
3. **Read.** Page changes update metadata in memory. Progress is saved after one second of inactivity, and immediately on close, backgrounding, or the end of a scrub. A progress save updates only that document.
4. **Annotate.** Each completed edit creates a save snapshot. Snapshots are written in order and atomically. Closing waits for pending saves.
5. **Export.** If there is no Folio markup, the original bytes are shared unchanged. Otherwise a copy with embedded annotations is written to `Exports/`, keeping password protection and permission flags.

## Concurrency rules

- UI state, SwiftData, and the displayed `PDFDocument` stay on the main actor.
- File work and thumbnails run on separate actors, so rendering can't hold up reading or saving.
- Worker `PDFDocument`s are never accessed at the same time as the displayed document. The thumbnail worker document is released after eight idle seconds or when the reader closes.
- In Flip mode only the active page canvas owns the session's `PDFView`. Neighboring canvases share the main-actor document.

## Caching

| Cache | Size |
| --- | --- |
| Grid covers | 480 × 640 previews |
| Page tiles | 260 × 340 |
| Memory | 32 MB shared, decoded off the main actor |
| Disk | 24 MB, trimmed only when over budget |
| Search text | Per reading session |

Thumbnails of decrypted pages are never written to disk.
