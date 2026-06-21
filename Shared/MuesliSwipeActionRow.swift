import SwiftUI

struct MuesliSwipeActionRow<Content: View>: View {
    struct Action {
        let title: String
        let systemImage: String
        let tint: Color
        let perform: () -> Void
    }

    private let leadingAction: Action?
    private let trailingAction: Action?
    private let content: Content

    init(
        leadingAction: Action? = nil,
        trailingAction: Action? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.leadingAction = leadingAction
        self.trailingAction = trailingAction
        self.content = content()
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .contextMenu {
                if let trailingAction {
                    contextMenuButton(for: trailingAction)
                }
                if let leadingAction {
                    contextMenuButton(for: leadingAction)
                }
            }
    }

    @ViewBuilder
    private func contextMenuButton(for action: Action) -> some View {
        if action.title.lowercased() == "delete" {
            Button(role: .destructive, action: action.perform) {
                Label(action.title, systemImage: action.systemImage)
            }
        } else {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}
