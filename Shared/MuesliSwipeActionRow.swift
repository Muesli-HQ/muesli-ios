import SwiftUI
import UIKit

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

    @State private var offset: CGFloat = 0

    private let actionWidth: CGFloat = 96
    private let revealThreshold: CGFloat = 44

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
        ZStack {
            actionBackground

            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged(updateOffset)
                        .onEnded(resolveOffset)
                )
        }
        .contentShape(Rectangle())
    }

    private var actionBackground: some View {
        HStack(spacing: 0) {
            if let leadingAction {
                actionButton(leadingAction)
                    .frame(width: actionWidth)
            }

            Spacer(minLength: 0)

            if let trailingAction {
                actionButton(trailingAction)
                    .frame(width: actionWidth)
            }
        }
    }

    private func actionButton(_ action: Action) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                offset = 0
            }
            action.perform()
        } label: {
            VStack(spacing: MuesliTheme.spacing4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(action.title)
                    .font(MuesliTheme.captionMedium())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(action.tint)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }

    private func updateOffset(_ value: DragGesture.Value) {
        let translation = value.translation.width
        let allowsLeading = leadingAction != nil
        let allowsTrailing = trailingAction != nil

        let clamped: CGFloat
        if translation > 0, allowsLeading {
            clamped = min(translation, actionWidth)
        } else if translation < 0, allowsTrailing {
            clamped = max(translation, -actionWidth)
        } else {
            clamped = 0
        }

        offset = clamped
    }

    private func resolveOffset(_ value: DragGesture.Value) {
        let translation = value.translation.width
        let target: CGFloat
        if translation > revealThreshold, leadingAction != nil {
            target = actionWidth
        } else if translation < -revealThreshold, trailingAction != nil {
            target = -actionWidth
        } else {
            target = 0
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            offset = target
        }
    }
}
