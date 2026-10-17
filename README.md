# Folio PDF

A native, offline PDF reader for iPhone. Built with SwiftUI, PDFKit, and SwiftData, with no third-party dependencies and no backend.

## Features

- **Library** with folders, grid and list layouts, search, and a Continue reading card
- **Two reading modes:** vertical scroll, or Flip with a book-style page curl and an optional page-turn sound
- **Annotations:** highlight, underline, strikethrough, pen, and notes, with undo/redo and autosave
- **Export** a copy with annotations embedded. Your original PDF is never modified
- **Bookmarks, thumbnails, page jump, and full-text search**
- **Password-protected PDFs** supported. Passwords are never stored
- **Private by design:** everything stays on the device, with no accounts or analytics
- Light and dark themes, Dynamic Type, VoiceOver, and Reduce Motion support

## Quick start

Requires Xcode 26+ and iOS 26+.

1. Open `Folio.xcodeproj`.
2. Select the **Folio** scheme and an iPhone simulator.
3. Press **⌘R**.

To run on a device, set your own team and bundle identifier. See [Getting started](Documentation/Getting-Started.md).

## Documentation

- [Getting started](Documentation/Getting-Started.md): building, running, and testing
- [User guide](Documentation/User-Guide.md): how to use every feature
- [Architecture](Documentation/Architecture.md): how the code is organized
- [Contributing](Documentation/Contributing.md): how to propose changes

## Not yet supported

OCR for scanned PDFs, form filling, signatures, page reordering, and iPad layouts. Contributions are welcome.

## License

Folio PDF is released under the [MIT License](LICENSE).

## Author

Built by **Muhammad Saif** — [saifcodes.com](https://saifcodes.com)
