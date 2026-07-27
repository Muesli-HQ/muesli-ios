import SwiftUI

struct AboutSettingsContent: View {
    private let sourceURL = URL(string: "https://github.com/Muesli-HQ/muesli-ios")!
    private let libraries = OpenSourceLibrary.all

    @State private var copiedDiagnostics = false

    /// The keyboard transition log, preceded by a count of audio files against
    /// the notes that own them. Filenames are never included -- only totals.
    private func diagnosticsReport() -> String {
        var header = ""
        if let audit = try? SharedStore().audioFileAudit() {
            header = "audio: \(audit.onDisk) files, \(audit.owned) owned, \(audit.orphaned) orphaned\n\n"
        }
        return header + KeyboardDiagnosticsLog.exportText()
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    AboutValueRow(icon: "app.badge", title: "Version", value: "\(version) (\(build))")
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    AboutValueRow(icon: "lock.shield", title: "Processing", value: "On device")
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    AboutValueRow(icon: "externaldrive", title: "App data", value: "Local SQLite")
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    Button {
                        // Keyboard state transitions only -- phases, short
                        // request IDs, timings. Never dictated text.
                        UIPasteboard.general.string = diagnosticsReport()
                        copiedDiagnostics = true
                    } label: {
                        HStack(spacing: MuesliTheme.spacing12) {
                            Image(systemName: "stethoscope")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MuesliTheme.accent)
                                .frame(width: 22)
                            Text("Copy keyboard diagnostics")
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Spacer()
                            Text(copiedDiagnostics ? "Copied" : "Last \(KeyboardDiagnosticsLog.entryLimit)")
                                .font(MuesliTheme.callout())
                                .foregroundStyle(MuesliTheme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    Link(destination: sourceURL) {
                        HStack(spacing: MuesliTheme.spacing12) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MuesliTheme.accent)
                                .frame(width: 22)
                            Text("Source code")
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Spacer()
                            Text("GitHub")
                                .font(MuesliTheme.callout())
                                .foregroundStyle(MuesliTheme.accent)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MuesliTheme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .padding(MuesliTheme.spacing16)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("OPEN SOURCE LIBRARIES")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .tracking(0.8)
                    .padding(.leading, MuesliTheme.spacing4)

                MuesliSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                            OpenSourceLibraryRow(library: library)
                            if index < libraries.count - 1 {
                                Divider().overlay(MuesliTheme.surfaceBorder)
                            }
                        }
                    }
                    .padding(.horizontal, MuesliTheme.spacing16)
                }
            }

            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Label("Local-first by design", systemImage: "hand.raised.fill")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Voice recordings and downloaded speech models stay on this iPhone. Only text is eligible for private iCloud sync when you enable it.")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }
}

private struct AboutValueRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct OpenSourceLibraryRow: View {
    let library: OpenSourceLibrary

    var body: some View {
        Link(destination: library.url) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: library.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(library.name)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(library.license)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    Text(library.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, MuesliTheme.spacing4)
            }
            .padding(.vertical, MuesliTheme.spacing12)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(library.name), \(library.license), open project website")
    }
}

struct OpenSourceLibrary: Identifiable, Equatable {
    let id: String
    let name: String
    let license: String
    let detail: String
    let icon: String
    let url: URL

    static let all: [OpenSourceLibrary] = [
        OpenSourceLibrary(
            id: "fluidaudio",
            name: "FluidAudio",
            license: "Apache 2.0",
            detail: "CoreML speech inference, streaming recognition, VAD, and speaker diarization.",
            icon: "waveform",
            url: URL(string: "https://github.com/FluidInference/FluidAudio")!
        ),
        OpenSourceLibrary(
            id: "whisperkit",
            name: "WhisperKit",
            license: "MIT",
            detail: "Argmax's Swift runtime for OpenAI Whisper models on CoreML and the Apple Neural Engine.",
            icon: "quote.bubble",
            url: URL(string: "https://github.com/argmaxinc/WhisperKit")!
        ),
        OpenSourceLibrary(
            id: "telemetrydeck",
            name: "TelemetryDeck Swift SDK",
            license: "MIT",
            detail: "Privacy-conscious product telemetry used to understand reliability and failures.",
            icon: "chart.bar",
            url: URL(string: "https://github.com/TelemetryDeck/SwiftSDK")!
        ),
        OpenSourceLibrary(
            id: "sqlite",
            name: "SQLite",
            license: "Public domain",
            detail: "Durable local storage for voice notes, meeting sessions, transcripts, and app state.",
            icon: "cylinder",
            url: URL(string: "https://sqlite.org")!
        ),
    ]
}
