import SwiftUI

struct KeyboardRootView: View {
    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: 10) {
            keyboardDeck
            helperKeys
        }
        .padding(.horizontal, 10)
        .padding(.top, MuesliTheme.spacing8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    MuesliTheme.backgroundRaised.opacity(0.98),
                    MuesliTheme.backgroundDeep.opacity(0.99)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            controller.prepareLaunchRequestIfNeeded()
        }
    }

    private var keyboardDeck: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(MuesliTheme.textSecondary.opacity(0.7))
                .frame(width: 44, height: 4)
                .padding(.top, 2)

            header

            if controller.showsActiveWaveform {
                activeRecorder
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                readyRecorder
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(MuesliTheme.spacing12)
        .muesliKeyboardDeckSurface()
        .animation(.snappy(duration: 0.22), value: controller.showsActiveWaveform)
        .animation(.snappy(duration: 0.22), value: controller.primaryButtonRole)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MuesliWaveformView(
                isActive: false,
                color: MuesliTheme.recording,
                barCount: 13,
                spacing: 1.4
            )
            .frame(width: 34, height: 24)

            Text("muesli")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(MuesliTheme.textPrimary)

            Spacer()

            if let settingsURL = controller.settingsURL {
                Link(destination: settingsURL) {
                    KeyboardIconLabel(systemImage: "gearshape.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Muesli settings")
            }

            KeyboardIconKey(systemImage: "chevron.down", accessibilityLabel: "Dismiss keyboard") {
                controller.dismissKeyboard()
            }
        }
    }

    private var readyRecorder: some View {
        VStack(spacing: 10) {
            primaryActionButton(isProminent: true)

            Text(readyHint)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if controller.canInsertLatest {
                Button {
                    controller.insertLatestDictation()
                } label: {
                    Label("Insert latest", systemImage: "text.insert")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.recording)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(MuesliTheme.recording.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var activeRecorder: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(activeStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: activeStatusColor.opacity(0.75), radius: 5)

                Text(activeStatusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(activeStatusColor)
                    .lineLimit(1)
            }

            ZStack {
                MuesliInlineWaveformView(
                    mode: controller.waveformMode,
                    color: activeStatusColor,
                    level: controller.waveformLevel,
                    barCount: 32,
                    spacing: 2.5
                )
                .frame(height: 68)
                .shadow(color: activeStatusColor.opacity(0.36), radius: 12)

                if controller.dictationPhase == .transcribing {
                    ProgressView()
                        .tint(activeStatusColor)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MuesliTheme.spacing4)

            if controller.showsLiveTranscript {
                Text(controller.liveTranscript)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MuesliTheme.spacing4)
            }

            HStack(spacing: MuesliTheme.spacing12) {
                Group {
                    if controller.canCancelActiveDictation {
                        KeyboardControlButton(
                            title: "Cancel",
                            tint: MuesliTheme.destructive,
                            action: controller.cancelActiveDictation
                        )
                    } else {
                        Color.clear
                            .frame(height: 44)
                    }
                }
                .frame(maxWidth: .infinity)

                primaryActionButton(isProminent: false)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var helperKeys: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                KeyboardTextKey(".") { controller.insertTextKey(".") }
                KeyboardTextKey(",") { controller.insertTextKey(",") }
                KeyboardTextKey("?") { controller.insertTextKey("?") }
                KeyboardTextKey("!") { controller.insertTextKey("!") }
                KeyboardTextKey("'") { controller.insertTextKey("'") }
                KeyboardTextKey(systemImage: "delete.left", accessibilityLabel: "Delete") {
                    controller.deleteBackward()
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                KeyboardTextKey(systemImage: "globe", accessibilityLabel: "Next keyboard") {
                    controller.switchInputMode()
                }
                    .frame(maxWidth: 58)

                KeyboardTextKey("ABC") { controller.switchInputMode() }
                    .frame(maxWidth: 66)

                KeyboardTextKey("space") { controller.insertSpace() }

                KeyboardTextKey("return") { controller.insertReturn() }
                    .frame(maxWidth: 96)

                KeyboardTextKey(":") { controller.insertTextKey(":") }
                    .frame(maxWidth: 58)
            }
        }
    }

    @ViewBuilder
    private func primaryActionButton(isProminent: Bool) -> some View {
        if controller.opensMuesliFromPrimaryButton, let launchURL = controller.launchURL {
            Link(destination: launchURL) {
                primaryActionLabel(isProminent: isProminent)
            }
            .simultaneousGesture(TapGesture().onEnded {
                controller.primaryLaunchAction()
            })
            .buttonStyle(.plain)
            .disabled(controller.isPrimaryButtonDisabled)
        } else {
            Button {
                controller.primaryAction()
            } label: {
                primaryActionLabel(isProminent: isProminent)
            }
            .buttonStyle(.plain)
            .disabled(controller.isPrimaryButtonDisabled)
        }
    }

    private func primaryActionLabel(isProminent: Bool) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: controller.primaryButtonIcon)
                .font(.system(size: isProminent ? 21 : 15, weight: .bold))
            Text(primaryActionTitle)
                .font(.system(size: isProminent ? 19 : 16, weight: .bold))
        }
        .foregroundStyle(primaryForeground)
        .frame(maxWidth: .infinity)
        .frame(height: isProminent ? 54 : 44)
        .background(primaryBackground, in: RoundedRectangle(cornerRadius: isProminent ? 15 : 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isProminent ? 15 : 12, style: .continuous)
                .strokeBorder(primaryBorder, lineWidth: 1)
        )
        .shadow(color: primaryShadow, radius: isProminent ? 12 : 8, x: 0, y: 5)
        .opacity(controller.isPrimaryButtonDisabled ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: isProminent ? 15 : 12, style: .continuous))
    }

    private var readyHint: String {
        if controller.isRecoveryRequested {
            return "Open Muesli to recover this voice note"
        }

        if controller.opensMuesliFromPrimaryButton {
            return "Tap Start, then return here to stop and insert"
        }

        return controller.canInsertLatest ? "Tap Start or insert your latest voice note" : "Tap Start to begin dictating"
    }

    private var activeStatusText: String {
        switch controller.dictationPhase {
        case .transcribing:
            "Transcribing"
        case .requested:
            "Starting"
        default:
            controller.statusText == "Stopping" ? "Stopping" : "Listening"
        }
    }

    private var activeStatusColor: Color {
        controller.dictationPhase == .transcribing ? MuesliTheme.transcribing : Color(hex: 0x39D7FF)
    }

    private var primaryActionTitle: String {
        switch controller.primaryButtonRole {
        case .record:
            "Start"
        case .stop:
            controller.statusText == "Stopping" ? "Stopping" : "Stop"
        case .openMuesliRequested:
            "Start"
        default:
            controller.primaryButtonTitle
        }
    }

    private var primaryForeground: Color {
        if controller.isPrimaryButtonDisabled {
            return MuesliTheme.textTertiary
        }

        return controller.stylesPrimaryButtonAsStop ? MuesliTheme.destructive : .white
    }

    private var primaryBackground: LinearGradient {
        let colors: [Color]
        if controller.isPrimaryButtonDisabled {
            colors = [MuesliTheme.surfacePrimary, MuesliTheme.surfacePrimary.opacity(0.78)]
        } else if controller.stylesPrimaryButtonAsStop {
            colors = [MuesliTheme.destructive.opacity(0.22), MuesliTheme.destructive.opacity(0.12)]
        } else {
            colors = [Color(hex: 0x4F88FF), MuesliTheme.recording]
        }

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var primaryBorder: Color {
        if controller.stylesPrimaryButtonAsStop {
            return MuesliTheme.destructive.opacity(0.42)
        }

        return Color.white.opacity(0.18)
    }

    private var primaryShadow: Color {
        if controller.stylesPrimaryButtonAsStop {
            return MuesliTheme.destructive.opacity(0.12)
        }

        return MuesliTheme.recording.opacity(0.22)
    }
}

private struct KeyboardControlButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.16), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct KeyboardIconKey: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeyboardIconLabel(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct KeyboardIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(width: 44, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MuesliTheme.surfacePrimary.opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct KeyboardTextKey: View {
    let title: String?
    let systemImage: String?
    let accessibilityLabel: String?
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = nil
        self.accessibilityLabel = title
        self.action = action
    }

    init(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.title = nil
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            KeyboardTextKeyLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .muesliKeyboardKeySurface()
        .accessibilityLabel(accessibilityLabel ?? title ?? systemImage ?? "")
    }
}

private struct KeyboardTextKeyLabel: View {
    var title: String?
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 23, weight: .semibold))
            } else {
                Text(title ?? "")
                    .font(.system(size: textSize, weight: .medium))
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(MuesliTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var textSize: CGFloat {
        switch title {
        case "space", "return":
            15
        case "ABC":
            16
        default:
            22
        }
    }
}

private extension View {
    func muesliKeyboardDeckSurface() -> some View {
        modifier(MuesliKeyboardDeckSurfaceModifier())
    }

    func muesliKeyboardKeySurface(tint: Color? = nil) -> some View {
        modifier(MuesliKeyboardKeySurfaceModifier(tint: tint))
    }
}

private struct MuesliKeyboardDeckSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        content
            .background {
                shape.fill(.regularMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: Color(hex: 0x02060C).opacity(0.26), radius: 16, x: 0, y: 8)
    }
}

private struct MuesliKeyboardKeySurfaceModifier: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let keyTint = tint ?? Color.white

        content
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill(keyTint.opacity(tint == nil ? 0.035 : 0.10))
            }
            .overlay(shape.strokeBorder(keyTint.opacity(tint == nil ? 0.10 : 0.22), lineWidth: 1))
            .shadow(color: Color(hex: 0x02060C).opacity(0.28), radius: 4, x: 0, y: 2)
            .contentShape(shape)
    }
}
