import SwiftUI
import UniformTypeIdentifiers

struct InsightsSharePayload: Identifiable {
    let id = UUID()
    let snapshot: InsightsSnapshot
    let rangeLabel: String
}

struct InsightsShareImage: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName("Muesli activity.png")
    }
}

struct InsightsShareSheet: View {
    let payload: InsightsSharePayload
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var export: InsightsShareImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let image, let export {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("\(payload.rangeLabel): \(payload.snapshot.words) words dictated, \(payload.snapshot.notes) voice notes, \(payload.snapshot.meetings) meetings. Current streak \(payload.snapshot.currentStreak) days; longest streak \(payload.snapshot.longestStreak) days.")
                        ShareLink(item: export, preview: SharePreview("My Muesli activity", image: Image(uiImage: image))) {
                            Label("Share Card", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("insights.shareCard")
                    } else if failed {
                        ContentUnavailableView {
                            Label("Couldn’t create card", systemImage: "photo")
                        } actions: {
                            Button("Try Again", action: render)
                        }
                    } else {
                        ProgressView("Creating card…")
                    }
                    Text("Only your stats are shared. No transcripts or account details.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .background(MuesliTheme.backgroundBase)
            .navigationTitle("Share your activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { render() }
        }
    }

    @MainActor
    private func render() {
        failed = false
        guard let rendered = InsightsShareRenderer.render(snapshot: payload.snapshot, rangeLabel: payload.rangeLabel),
              let png = rendered.pngData() else {
            failed = true
            return
        }
        image = rendered
        export = InsightsShareImage(data: png)
    }
}

@MainActor
enum InsightsShareRenderer {
    static let size = CGSize(width: 1200, height: 630)

    static func render(snapshot: InsightsSnapshot, rangeLabel: String) -> UIImage? {
        let renderer = ImageRenderer(content:
            InsightsShareCard(snapshot: snapshot, rangeLabel: rangeLabel)
                .frame(width: size.width, height: size.height)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// Adapted from the macOS InsightsShareCard, using iOS's filtered snapshot.
private struct InsightsShareCard: View {
    let snapshot: InsightsSnapshot
    let rangeLabel: String

    private let pale = Color(red: 0.91, green: 0.95, blue: 0.98)
    private let muted = Color(red: 0.61, green: 0.68, blue: 0.74)
    private let cyan = Color(red: 0.20, green: 0.78, blue: 0.91)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.071, blue: 0.090)

            Group {
                Image("InsightsShareBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1200, height: 630)
                    .clipped()
            }

            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.050, blue: 0.068).opacity(0.08),
                    Color(red: 0.045, green: 0.062, blue: 0.080).opacity(0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(rangeLabel.uppercased())
                        .font(MuesliTheme.font(size: 14, weight: .semibold))
                        .tracking(1.9)
                        .foregroundStyle(pale.opacity(0.82))
                    Spacer()
                    MuesliShareMark(color: pale)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(red: 0.035, green: 0.050, blue: 0.068).opacity(0.44))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
                }

                Spacer(minLength: 34)

                Text(snapshot.words.formatted())
                    .font(MuesliTheme.font(size: 108, weight: .bold))
                    .tracking(-5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .monospacedDigit()
                    .foregroundStyle(pale)
                Text("WORDS DICTATED")
                    .font(MuesliTheme.font(size: 18, weight: .bold))
                    .tracking(2.8)
                    .foregroundStyle(muted)

                Text("\(snapshot.notes.formatted()) \(snapshot.notes == 1 ? "voice note" : "voice notes")")
                    .font(MuesliTheme.font(size: 18, weight: .medium))
                    .foregroundStyle(muted)

                Spacer(minLength: 36)

                HStack(spacing: 0) {
                    shareDatum(value: snapshot.meetings.formatted(), label: "MEETINGS")
                    shareDivider
                    shareDatum(value: snapshot.averageWPM.map { "\(Int($0.rounded()))" } ?? "—", label: "DICTATION WPM")
                    shareDivider
                    shareDatum(value: dayCount(snapshot.currentStreak), label: "CURRENT STREAK")
                    shareDivider
                    shareDatum(value: dayCount(snapshot.longestStreak), label: "LONGEST STREAK")
                }
                .padding(.vertical, 24)
                .background(Color(red: 0.035, green: 0.050, blue: 0.068).opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.16)))

                Spacer(minLength: 30)

                HStack {
                    Text("Private by design. Made on this iPhone.")
                        .font(MuesliTheme.font(size: 15, weight: .medium))
                        .foregroundStyle(pale.opacity(0.88))
                        .shadow(color: Color.black.opacity(0.48), radius: 3, y: 1)
                    Spacer()
                    Text("muesli.works")
                        .font(MuesliTheme.font(size: 15, weight: .semibold))
                        .foregroundStyle(cyan)
                        .shadow(color: Color.black.opacity(0.48), radius: 3, y: 1)
                }
            }
            .padding(54)
        }
    }

    private func shareDatum(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(MuesliTheme.font(size: 30, weight: .semibold))
                .tracking(-0.8)
                .monospacedDigit()
                .foregroundStyle(pale)
            Text(label)
                .font(MuesliTheme.font(size: 12, weight: .bold))
                .tracking(1.7)
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private var shareDivider: some View {
        Rectangle().fill(Color.white.opacity(0.11)).frame(width: 1, height: 58)
    }

    private func dayCount(_ value: Int) -> String {
        "\(value) \(value == 1 ? "DAY" : "DAYS")"
    }
}

private struct MuesliShareMark: View {
    let color: Color

    var body: some View {
        HStack(spacing: 11) {
            Group {
                Image("MuesliAppIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("muesli")
                .font(MuesliTheme.font(size: 30, weight: .bold))
                .tracking(-1.1)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("muesli")
    }
}

