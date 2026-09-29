import SwiftUI

/// `@State` under another name.
///
/// In the macOS 27 SDK `@State` is an attached macro (`SwiftUIMacros`), and that plugin ships only with Xcode,
/// so with Command Line Tools alone `@State` fails to compile. The `State` property wrapper it builds on still
/// exists; an alias with a different name reaches the wrapper without going through the macro.
typealias LocalState<Value> = State<Value>

/// Colors from the approved prototype. Neutral fills are the primary label color at a fixed opacity,
/// so they follow light and dark appearance (and the system material behind the panel).
enum Palette {
    static let brandTop = Color(red: 0xFB / 255, green: 0x5C / 255, blue: 0x74 / 255)      // #FB5C74
    static let brandBottom = Color(red: 0xFA / 255, green: 0x24 / 255, blue: 0x3C / 255)   // #FA243C
    static let favorite = Color(red: 0xFA / 255, green: 0x24 / 255, blue: 0x3C / 255)      // #FA243C

    static let hover = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.15)
    static let fill = Color.primary.opacity(0.75)
    static let tile = Color.primary.opacity(0.06)
    static let tileNote = Color.primary.opacity(0.16)
    static let tileLine = Color.primary.opacity(0.08)
    static let artLine = Color.primary.opacity(0.16)
    static let pill = Color.primary.opacity(0.10)
    static let pillHover = Color.primary.opacity(0.15)
}

/// How the panel is being drawn. The snapshot renderer pins the clock (so positions are stable)
/// and swaps out the views ImageRenderer can't draw (AppKit-backed ones).
struct PanelRenderContext: Equatable {
    var isSnapshot = false
    var now: Date?
}

private struct PanelRenderContextKey: EnvironmentKey {
    static let defaultValue = PanelRenderContext()
}

extension EnvironmentValues {
    var panelRenderContext: PanelRenderContext {
        get { self[PanelRenderContextKey.self] }
        set { self[PanelRenderContextKey.self] = newValue }
    }
}

/// A round hover target: transport buttons, favorite, mute and the ⋯ menu.
/// Hover shows a faint circle, pressing scales to 0.92, disabled dims to 35%.
struct HoverCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat
    /// Label color at rest. nil leaves the primary label color.
    var foreground: Color?
    /// Label color while hovered. nil leaves the primary label color.
    var hoverForeground: Color?

    init(diameter: CGFloat, foreground: Color? = nil, hoverForeground: Color? = nil) {
        self.diameter = diameter
        self.foreground = foreground
        self.hoverForeground = hoverForeground
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverCircleBody(configuration: configuration, diameter: diameter, foreground: foreground, hoverForeground: hoverForeground)
    }

    private struct HoverCircleBody: View {
        let configuration: ButtonStyleConfiguration
        let diameter: CGFloat
        let foreground: Color?
        let hoverForeground: Color?
        @LocalState private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hovering = isHovering && isEnabled
            let color = (hovering ? hoverForeground : foreground) ?? Color.primary
            configuration.label
                .foregroundStyle(color)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Palette.hover).opacity(hovering ? 1 : 0))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// The capsule call-to-action ("Open Apple Music", "Open System Settings").
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @LocalState private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(isHovering ? Palette.pillHover : Palette.pill))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
