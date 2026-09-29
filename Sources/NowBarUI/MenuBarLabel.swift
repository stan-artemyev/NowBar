import SwiftUI

/// The menu bar item: the note icon alone, or "Title · Artist" next to it when the setting is on.
///
/// MenuBarExtra labels only render Text, Image and Label reliably, so this deliberately avoids stacks.
public struct MenuBarLabel: View {
    private let store: PlayerStore

    public init(store: PlayerStore) {
        self.store = store
    }

    public var body: some View {
        if let title = store.menuBarTitle {
            Label(title, systemImage: "music.note")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "music.note")
        }
    }
}
