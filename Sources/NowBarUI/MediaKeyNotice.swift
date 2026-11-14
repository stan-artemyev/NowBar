import SwiftUI

/// Shown at the top of the panel while media keys are switched on but NowBar doesn't have the Accessibility
/// permission they need. Without it the keys silently go to whatever played last (a browser video, say), so
/// the panel says so and offers the way to fix it.
struct MediaKeyNotice: View {
    let store: PlayerStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text("Media keys need access")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Allow…") { store.requestMediaKeyAccess() }
                .buttonStyle(PillButtonStyle(isCompact: true))
                .help("Open the Accessibility settings and switch NowBar on")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.warningTile))
    }
}
