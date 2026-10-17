import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewTurned = false

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings").font(.folioDisplay).tracking(-0.8).padding(.bottom, 4)
                    appearanceCard
                    readingCard
                    NavigationLink { LibraryPrivacyView() } label: {
                        SettingsNavigationRow(title: "Library & privacy", symbol: "folder.fill", color: .teal)
                    }.buttonStyle(.plain)
                    NavigationLink { TipsAndGesturesView() } label: {
                        SettingsNavigationRow(title: "Tips & gestures", symbol: "lightbulb.fill", color: .yellow)
                    }.buttonStyle(.plain)
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "info.circle.fill", color: .indigo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("About Folio").font(.subheadline.weight(.medium))
                            Text("Version \(version) · Build \(build)").font(.caption).foregroundStyle(.secondary)
                            Link("Made by Muhammad Saif · saifcodes.com", destination: URL(string: "https://saifcodes.com")!)
                                .font(.caption).tint(Palette.accent)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16).background(Palette.card, in: .rect(cornerRadius: Layout.cardRadius))
                    .accessibilityElement(children: .contain)
                }
                .padding(.horizontal, Layout.pageInset).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Palette.paper).accessibilityIdentifier("settingsScrollView")
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
    }

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance", symbol: "circle.lefthalf.filled", color: Palette.accent) {
            Picker("Theme", selection: $preferences.appearance) {
                ForEach(AppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("appearancePicker")
            Text("PDF pages keep their original colors.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var readingCard: some View {
        SettingsCard(title: "Reading", symbol: "book.fill", color: .red) {
            HStack(spacing: 12) {
                ForEach(AppPreferences.ReadingMode.allCases) { mode in
                    Button {
                        preferences.readingMode = mode
                    } label: {
                        VStack(spacing: 8) {
                            ReadingStylePreview(mode: mode, turned: previewTurned && preferences.readingMode == mode)
                                .frame(height: 92).frame(maxWidth: .infinity)
                                .background(Palette.secondaryPaper, in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(preferences.readingMode == mode ? Palette.accent : .clear, lineWidth: 2))
                            Text(mode == .flip ? "Flip" : "Scroll").font(.subheadline)
                        }.contentShape(.rect)
                    }
                    .buttonStyle(ScaleButtonStyle()).foregroundStyle(.primary)
                    .accessibilityLabel(mode == .flip ? "Flip" : "Scroll")
                    .accessibilityIdentifier("readingMode-\(mode.rawValue)")
                    .accessibilityAddTraits(preferences.readingMode == mode ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("readingModePicker")
            .task(id: preferences.readingMode) {
                previewTurned = false
                guard !reduceMotion else { return }
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    withAnimation(.easeInOut(duration: 0.45)) { previewTurned = true }
                    try await Task.sleep(for: .milliseconds(600))
                    withAnimation(.easeInOut(duration: 0.45)) { previewTurned = false }
                } catch { }
            }
            if preferences.readingMode == .flip {
                Divider().padding(.top, 4)
                Toggle(isOn: $preferences.pageTurnSoundEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "speaker.wave.2.fill", color: .purple)
                        Text("Page-turn sound").font(.subheadline)
                    }
                }.accessibilityIdentifier("pageTurnSoundToggle")
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $preferences.pageTurnSoundVolume, in: 0...1, step: 0.05) {
                        Text("Page-turn sound volume")
                    }
                    .disabled(!preferences.pageTurnSoundEnabled)
                    .accessibilityValue("\(Int((preferences.pageTurnSoundVolume * 100).rounded())) percent")
                    .accessibilityIdentifier("pageTurnSoundVolume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color)
                Text(title).font(.subheadline.weight(.medium))
            }
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: Layout.cardRadius))
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16).frame(minHeight: 56)
        .background(Palette.card, in: .rect(cornerRadius: Layout.cardRadius))
        .foregroundStyle(.primary)
    }
}

private struct ReadingStylePreview: View {
    let mode: AppPreferences.ReadingMode
    let turned: Bool
    var body: some View {
        ZStack {
            if mode == .flip {
                page.offset(x: 5, y: 3)
            }
            page
                .rotationEffect(.degrees(mode == .flip && turned ? -9 : 0), anchor: .bottomTrailing)
                .offset(y: mode == .verticalScroll && turned ? -7 : 0)
            if mode == .verticalScroll {
                Image(systemName: "arrow.up").font(.caption).foregroundStyle(.secondary).offset(x: 33)
            } else {
                Image(systemName: "arrow.turn.down.left").font(.caption).foregroundStyle(.secondary).offset(x: 32, y: 26)
            }
        }.accessibilityHidden(true)
    }
    private var page: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<8) { index in
                Rectangle().fill(.gray.opacity(0.5)).frame(width: index == 0 || index == 7 ? 23 : 31, height: 1)
            }
        }
        .padding(9).frame(width: 48, height: 68)
        .background(.white, in: .rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.gray.opacity(0.5), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 2)
    }
}
