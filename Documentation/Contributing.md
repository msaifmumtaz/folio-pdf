# Contributing

Bug reports, ideas, and pull requests are welcome.

## Reporting a bug

Open an issue that includes:

- iOS version and device or simulator
- Steps to reproduce
- What you expected and what happened
- If the problem is specific to one PDF, whether you can share it (or a similar file)

## Making a change

1. Fork the repository and create a branch from `main`.
2. Make your change. See [Getting started](Getting-Started.md) to build and run.
3. If you added or removed files, run `python3 Scripts/generate_project.py`.
4. Add or update tests for behavior you changed.
5. Run the full test suite.
6. Open a pull request describing what changed and why. Include screenshots for UI changes.

## Conventions

- **No third-party dependencies.** Folio uses only Apple frameworks. Discuss any exception in an issue first.
- **Offline and private.** No analytics, tracking, or network calls.
- **Never modify the original PDF.** Markup lives in the JSON sidecar until export.
- **Keep the main actor responsive.** File I/O and rendering belong in the existing actors. See [Architecture](Architecture.md#concurrency-rules).
- **Accessibility.** Check new UI with VoiceOver, Reduce Motion, and the largest Dynamic Type size.
- Match the style of the surrounding code: SwiftUI views stay small, and design tokens come from `DesignSystem.swift` (`Palette`, `Layout`).

## Pull request checklist

- [ ] No new compiler warnings
- [ ] `FolioTests` and `FolioUITests` pass
- [ ] Xcode project regenerated if files were added or removed
- [ ] No signing team, bundle identifier, or personal data committed
- [ ] Documentation updated if behavior changed

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](../LICENSE).
