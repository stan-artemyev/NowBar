import SwiftUI

/// The prototype's slider: a 4 pt capsule that grows to 6 pt on hover, with a knob on hover or drag.
/// Used for playback position and for volume. A press seeks straight away; dragging scrubs.
struct CapsuleSlider: View {
    /// The value to show while the user isn't touching the slider, 0...1.
    var fraction: Double
    /// Non-nil while the user is pressing or dragging: the value under the pointer, 0...1.
    @Binding var scrub: Double?
    /// Called on every change while scrubbing.
    var onScrub: ((Double) -> Void)?
    /// Called once, when the pointer is released.
    var onCommit: ((Double) -> Void)?

    @LocalState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shown = min(max(scrub ?? fraction, 0), 1)
            let active = (isHovering || scrub != nil) && isEnabled
            let thickness: CGFloat = active ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.track)
                    .frame(height: thickness)
                Capsule()
                    .fill(Palette.fill)
                    .frame(width: max(shown * width, 0), height: thickness)
                Circle()
                    .fill(Color.primary)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 10, height: 10)
                    .shadow(color: Color.black.opacity(0.3), radius: 1.5, y: 1)
                    .offset(x: shown * width - 5)
                    .scaleEffect(active ? 1 : 0.5)
                    .opacity(active ? 1 : 0)
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let fraction = Self.fraction(at: value.location.x, width: width)
                        scrub = fraction
                        onScrub?(fraction)
                    }
                    .onEnded { value in
                        let fraction = Self.fraction(at: value.location.x, width: width)
                        onCommit?(fraction)
                        scrub = nil
                    },
                including: isEnabled ? .all : .none
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
        }
    }

    private static func fraction(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1))
    }
}
