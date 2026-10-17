# Getting started

## Requirements

- macOS with **Xcode 26** or newer
- An iPhone simulator or device running **iOS 26** or newer

Folio uses only Apple frameworks (SwiftUI, PDFKit, SwiftData, AVFAudio). There are no Swift packages to resolve and no backend to run.

## Run in the simulator

1. Open `Folio.xcodeproj`.
2. Select the **Folio** scheme and an iPhone simulator.
3. Press **⌘R**.
4. Tap **Explore a sample document**, or import a PDF from Files.

## Run on a physical iPhone

The project does not include a signing team.

1. Select the **Folio** target → **Signing & Capabilities**.
2. Choose your development team.
3. Change the bundle identifier (`com.folio.pdf`) to one your team owns.

Don't commit your team ID or bundle identifier in pull requests.

## Run the tests

Press **⌘U** in Xcode, or from the terminal:

```sh
xcodebuild test -project Folio.xcodeproj -scheme Folio \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -parallel-testing-enabled NO
```

Replace `iPhone 17e` with any installed iOS 26+ simulator (`xcrun simctl list devices available`).

| Target | Covers |
| --- | --- |
| `FolioTests` | Import and duplicate detection, progress, bookmarks, every annotation type, export, encrypted and restricted PDFs, save failure and retry, migrations, Flip mode, and 25/500-page loading benchmarks |
| `FolioUITests` | Reading, relaunch, rotation, pen/note/undo, search, thumbnails, Flip swipes, settings, library actions, and the largest accessibility text size in light, dark, and landscape |

### UI-test launch arguments

UI tests never touch your real library. These launch arguments control the test environment:

| Argument | Effect |
| --- | --- |
| `--ui-testing` | Uses a separate `FolioUITests` storage folder and defaults suite |
| `--reset-library` | Deletes the test library first (only honored with `--ui-testing`) |
| `--seed-library` | Fills the library with fixture documents (Debug builds only) |
| `--large-document` | Seeds a large document for performance tests |

## Adding or removing source files

The Xcode project is generated and committed. After adding, renaming, or deleting a file in `Folio/`, `FolioTests/`, or `FolioUITests/`, regenerate it:

```sh
python3 Scripts/generate_project.py
```

The script keeps your local signing team and bundle identifier. It also picks up `.mp3` resources.
