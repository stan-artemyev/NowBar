import AppKit
import NowBarCore
import SwiftUI

/// What the panel shows, derived from a player snapshot.
enum PanelContent {
    case track(Track)
    /// The music app isn't running.
    case notRunning
    /// macOS denied NowBar permission to control the music app.
    case notAuthorized
    /// The music app is running with nothing loaded.
    case nothingPlaying

    init(_ snapshot: PlayerSnapshot) {
        switch snapshot.availability {
        case .notRunning:
            self = .notRunning
        case .notAuthorized:
            self = .notAuthorized
        case .running:
            if let track = snapshot.track {
                self = .track(track)
            } else {
                self = .nothingPlaying
            }
        }
    }

    var title: String {
        switch self {
        case .track(let track): track.title
        case .notRunning, .nothingPlaying: "Not Playing"
        case .notAuthorized: "Can't Control Apple Music"
        }
    }

    /// The line under the title. Large layout: "Artist — Album"; compact layout: the artist.
    func detail(compact: Bool) -> String {
        switch self {
        case .track(let track):
            if compact { return track.artist }
            return [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        case .notRunning:
            return "Apple Music isn't open"
        case .notAuthorized:
            return "Turn on Music under NowBar in System Settings → Privacy & Security → Automation."
        case .nothingPlaying:
            return "Choose something to play in Apple Music"
        }
    }

    var hasTrack: Bool {
        if case .track = self { return true }
        return false
    }
}

/// The 300 pt wide panel shown in the menu bar window.
///
/// It draws no background of its own: the MenuBarExtra window supplies the system material
/// (Liquid Glass on macOS 26 and later).
public struct PlayerPanel: View {
    private let store: PlayerStore

    @FocusState private var isFocused: Bool
    @Environment(\.panelRenderContext) private var renderContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: PlayerStore) {
        self.store = store
    }

    public var body: some View {
        let snapshot = store.snapshot
        let content = PanelContent(snapshot)
        let compact = store.layout == .compact

        VStack(spacing: 0) {
            PanelHeader(store: store)
                .frame(height: 22)
                .padding(.bottom, 12)

            nowPlaying(content, snapshot: snapshot, compact: compact)

            actionBlock(content, snapshot: snapshot)

            TransportRow(store: store, snapshot: snapshot)
                .padding(.top, 8)

            VolumeRow(store: store)
                .padding(.top, 8)
        }
        .padding(14)
        .frame(width: 300)
        .background {
            if !renderContext.isSnapshot {
                WindowKeyObserver { store.isPanelVisible = $0 }
                // The layout switch resizes the window; this keeps its top edge under the menu bar.
                WindowTopAnchor()
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space, phases: .down) { _ in handleKey { store.playPause() } }
        .onKeyPress(.leftArrow, phases: .down) { _ in handleKey { store.previous() } }
        .onKeyPress(.rightArrow, phases: .down) { _ in handleKey { store.next() } }
        .onAppear { isFocused = true }
        .onChange(of: store.isPanelVisible) { _, visible in
            if visible { isFocused = true }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func nowPlaying(_ content: PanelContent, snapshot: PlayerSnapshot, compact: Bool) -> some View {
        let isPlaying = content.hasTrack && snapshot.state == .playing
        let image = content.hasTrack ? store.artwork : nil

        if compact {
            HStack(spacing: 12) {
                ArtworkTile(
                    image: image,
                    side: 56,
                    cornerRadius: 8,
                    shadow: .init(radius: 6, y: 4, opacity: 0.22)
                )
                MetaBlock(store: store, content: content, compact: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkTile(
                    image: image,
                    side: 272,
                    cornerRadius: 10,
                    shadow: .init(radius: 12, y: 8, opacity: 0.25)
                )
                .scaleEffect(isPlaying ? 1 : 0.92)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.62), value: isPlaying)

                MetaBlock(store: store, content: content, compact: false)
                    .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func actionBlock(_ content: PanelContent, snapshot: PlayerSnapshot) -> some View {
        switch content {
        case .track(let track):
            ProgressSection(store: store, snapshot: snapshot, track: track)
        case .notRunning, .nothingPlaying:
            CallToAction(title: "Open Apple Music") { store.openMusic() }
        case .notAuthorized:
            CallToAction(title: "Open System Settings") { store.openAutomationSettings() }
        }
    }

    private func handleKey(_ action: () -> Void) -> KeyPress.Result {
        guard store.snapshot.availability == .running else { return .ignored }
        action()
        return .handled
    }
}

// MARK: - Title, artist and favorite

struct MetaBlock: View {
    let store: PlayerStore
    let content: PanelContent
    let compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(content.title)
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .tracking(compact ? -0.14 : -0.15)
                    .lineLimit(1)
                    .frame(height: compact ? 18 : 20)
                Text(content.detail(compact: compact))
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(content.hasTrack ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: !content.hasTrack)
                    .frame(minHeight: compact ? 16 : 18, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .track(let track) = content {
                FavoriteButton(isFavorited: track.isFavorited) {
                    store.toggleFavorite()
                }
                .padding(.trailing, -4)
            }
        }
    }
}

// MARK: - Header

struct PanelHeader: View {
    let store: PlayerStore

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                BrandGlyph()
                Text("Apple Music")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            MoreMenu(store: store)
                .padding(.trailing, -4)
        }
    }
}

/// The 16 pt rounded square with a white note, in Apple Music's red gradient.
struct BrandGlyph: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Palette.brandTop, Palette.brandBottom], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// The ⋯ menu: Open Apple Music, layout, menu bar title, media keys, launch at login and Quit.
struct MoreMenu: View {
    let store: PlayerStore
    @Environment(\.panelRenderContext) private var renderContext

    var body: some View {
        @Bindable var store = store

        if renderContext.isSnapshot {
            // ImageRenderer can't draw an AppKit-backed Menu, so snapshots get the closed state.
            label
                .frame(width: 24, height: 24)
        } else {
            Menu {
                Button("Open Apple Music") { store.openMusic() }

                Divider()

                Picker("Layout", selection: $store.layout) {
                    Text("Large Artwork").tag(PanelLayout.large)
                    Text("Compact").tag(PanelLayout.compact)
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Toggle("Show Title in Menu Bar", isOn: $store.showTitleInMenuBar)

                Divider()

                if store.hasMediaKeyTap {
                    Toggle("Media Keys Control Apple Music", isOn: $store.mediaKeysEnabled)
                    if store.mediaKeysEnabled && !store.mediaKeysTrusted {
                        Button("Allow Media Key Access…") { store.requestMediaKeyAccess() }
                    }
                }
                Toggle("Launch at Login", isOn: $store.launchAtLogin)

                Divider()

                Button("Quit NowBar") { store.quit() }
                    .keyboardShortcut("q")
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(HoverCircleButtonStyle(diameter: 24, foreground: Color.secondary, hoverForeground: Color.primary))
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More Options")
        }
    }

    private var label: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.secondary)
    }
}
