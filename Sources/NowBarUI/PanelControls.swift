import AppKit
import NowBarCore
import SwiftUI

// MARK: - Artwork

/// The artwork tile, or the placeholder (a faint note on a tinted tile) when there is no image.
struct ArtworkTile: View {
    struct Shadow {
        var radius: CGFloat
        var y: CGFloat
        var opacity: Double
    }

    let image: NSImage?
    let side: CGFloat
    let cornerRadius: CGFloat
    let shadow: Shadow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Palette.tile)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipped()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.34))
                    .foregroundStyle(Palette.tileNote)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(image == nil ? Palette.tileLine : Palette.artLine, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(image == nil ? 0 : shadow.opacity), radius: shadow.radius, y: shadow.y)
        .animation(.easeOut(duration: 0.15), value: image.map(ObjectIdentifier.init))
        .accessibilityHidden(true)
    }
}

// MARK: - Favorite

struct FavoriteButton: View {
    let isFavorited: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .font(.system(size: 15, weight: .medium))
                .symbolEffect(.bounce, value: isFavorited)
        }
        .buttonStyle(HoverCircleButtonStyle(
            diameter: 28,
            foreground: isFavorited ? Palette.favorite : Color.secondary,
            hoverForeground: isFavorited ? Palette.favorite : Color.primary
        ))
        .help(isFavorited ? "Unfavorite" : "Favorite")
        .accessibilityLabel(isFavorited ? "Unfavorite" : "Favorite")
    }
}

// MARK: - Progress

/// The elapsed / remaining row and the seek bar (34 pt in total, like the prototype).
/// Duration 0 (a live stream) shows "Live" and no scrubber.
struct ProgressSection: View {
    let store: PlayerStore
    let snapshot: PlayerSnapshot
    let track: Track

    @LocalState private var scrub: Double?
    @Environment(\.panelRenderContext) private var renderContext

    var body: some View {
        Group {
            if track.duration > 0 {
                scrubber(duration: track.duration)
            } else {
                Text("Live")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 6)
        .frame(height: 34, alignment: .top)
    }

    private func scrubber(duration: TimeInterval) -> some View {
        let ticking = snapshot.state == .playing && store.isPanelVisible && scrub == nil
        return TimelineView(.animation(minimumInterval: 0.1, paused: !ticking)) { _ in
            // The timeline only paces the redraws; the position always comes from the current time,
            // so the first frame after the panel opens is never stale.
            let position = snapshot.position(at: renderContext.now ?? Date())
            let fraction = scrub ?? min(max(position / duration, 0), 1)
            let shown = scrub.map { $0 * duration } ?? position

            VStack(spacing: 0) {
                CapsuleSlider(fraction: fraction, scrub: $scrub, onScrub: nil) { target in
                    store.seek(to: target * duration)
                }
                .frame(height: 16)
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(TimeFormat.clock(shown)) of \(TimeFormat.clock(duration))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: store.seek(to: position + 5)
                    case .decrement: store.seek(to: position - 5)
                    @unknown default: break
                    }
                }

                HStack(spacing: 0) {
                    Text(TimeFormat.clock(shown))
                    Spacer(minLength: 0)
                    Text(TimeFormat.remaining(position: shown, duration: duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 14)
                .padding(.top, -2)
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Call to action

/// Replaces the progress block when there is nothing to scrub (same 34 pt).
struct CallToAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(title, action: action)
                .buttonStyle(PillButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(height: 34, alignment: .top)
    }
}

// MARK: - Transport

struct TransportRow: View {
    /// The prototype draws its glyphs in 22 and 30 pt boxes; SF Symbols of the same nominal size come out
    /// about 20% larger, so these sizes are what match the prototype's look.
    static let skipGlyphSize: CGFloat = 20
    static let playGlyphSize: CGFloat = 26

    let store: PlayerStore
    let snapshot: PlayerSnapshot

    var body: some View {
        let isPlaying = snapshot.state == .playing
        HStack(spacing: 20) {
            TransportButton(symbol: "backward.fill", glyphSize: TransportRow.skipGlyphSize, diameter: 36, label: "Previous Track") {
                store.previous()
            }
            TransportButton(
                symbol: isPlaying ? "pause.fill" : "play.fill",
                glyphSize: TransportRow.playGlyphSize,
                diameter: 44,
                label: isPlaying ? "Pause" : "Play",
                opticalOffset: isPlaying ? 0 : 1.5
            ) {
                store.playPause()
            }
            TransportButton(symbol: "forward.fill", glyphSize: TransportRow.skipGlyphSize, diameter: 36, label: "Next Track") {
                store.next()
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(snapshot.availability != .running)
    }
}

struct TransportButton: View {
    let symbol: String
    let glyphSize: CGFloat
    let diameter: CGFloat
    let label: String
    var opticalOffset: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize))
                .contentTransition(.symbolEffect(.replace))
                .offset(x: opticalOffset)
                .animation(.easeOut(duration: 0.16), value: symbol)
        }
        .buttonStyle(HoverCircleButtonStyle(diameter: diameter))
        .accessibilityLabel(label)
    }
}

// MARK: - Volume

/// Mute button, slider and a loud speaker: mirrors the Mac's output volume, so the keyboard
/// volume and mute keys move it too.
struct VolumeRow: View {
    let store: PlayerStore

    @LocalState private var scrub: Double?

    var body: some View {
        let volume = store.volume
        let level = volume.isMuted ? 0 : Double(volume.level)
        let shown = scrub ?? level
        let silent = volume.isMuted || shown <= 0.0001

        HStack(spacing: 2) {
            Button {
                store.toggleMute()
            } label: {
                Image(systemName: silent ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(HoverCircleButtonStyle(diameter: 24, foreground: Color.secondary, hoverForeground: Color.primary))
            .accessibilityLabel(volume.isMuted ? "Unmute" : "Mute")
            .padding(.leading, -6)

            CapsuleSlider(fraction: level, scrub: $scrub, onScrub: { fraction in
                store.setVolume(Float(fraction))
            }, onCommit: nil)
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((shown * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: store.setVolume(Float(min(shown + 0.0625, 1)))
                case .decrement: store.setVolume(Float(max(shown - 0.0625, 0)))
                @unknown default: break
                }
            }

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .padding(.trailing, -4)
                .accessibilityHidden(true)
        }
        .frame(height: 24)
        .disabled(!volume.isAdjustable)
        .help(volume.isAdjustable ? "" : "The current sound output doesn't have adjustable volume.")
    }
}
