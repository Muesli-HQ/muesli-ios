import SwiftUI

struct KeyboardRootView: View {
    static let preferredHeight: CGFloat = 245

    private static let recorderBodyHeight: CGFloat = 84
    private static let activeStatusWidth: CGFloat = 84
    private static let activeControlButtonWidth: CGFloat = 120
    private static let activeWaveformBarCount = 34

    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: 5) {
            keyboardDeck
            helperKeys
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.top, 4)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity)
        .frame(height: Self.preferredHeight, alignment: .bottom)
        .transaction { transaction in
            if !controller.isLaunchSettled {
                transaction.animation = nil
            }
        }
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
        // iOS temporarily hosts third-party keyboards at full-screen and at
        // an intermediate height. Keep those extra host regions transparent;
        // only the final keyboard envelope should paint Muesli's surface.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var keyboardDeck: some View {
        VStack(spacing: 7) {
            Capsule()
                .fill(MuesliTheme.textSecondary.opacity(0.7))
                .frame(width: 40, height: 4)

            header

            if controller.showsActiveWaveform {
                activeRecorder
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                readyRecorder
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .muesliKeyboardDeckSurface()
        .animation(.snappy(duration: 0.22), value: controller.showsActiveWaveform)
        .animation(.snappy(duration: 0.22), value: controller.primaryButtonRole)
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image("MuesliAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)

            Text("muesli")
                .font(.system(size: 20, weight: .bold))
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
        VStack(spacing: MuesliTheme.spacing8) {
            primaryActionButton(isProminent: true)

            if controller.canInsertLatest {
                Button {
                    controller.insertLatestDictation()
                } label: {
                    Label("Insert latest", systemImage: "text.insert")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.recording)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(MuesliTheme.recording.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(height: 32)
            }
        }
        .frame(height: Self.recorderBodyHeight)
    }

    private var activeRecorder: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            activeWaveformStrip
            HStack(spacing: MuesliTheme.spacing8) {
                Group {
                    if controller.canCancelActiveDictation {
                        KeyboardControlButton(
                            title: "Cancel",
                            tint: MuesliTheme.destructive,
                            action: controller.cancelActiveDictation
                        )
                    } else {
                        Color.clear
                            .frame(height: 40)
                    }
                }
                .frame(width: Self.activeControlButtonWidth)

                primaryActionButton(isProminent: false)
                    .frame(width: Self.activeControlButtonWidth)
            }
        }
        .frame(height: Self.recorderBodyHeight)
    }

    private var activeWaveformStrip: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(activeStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: activeStatusColor.opacity(0.75), radius: 5)

                Text(activeStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activeStatusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: Self.activeStatusWidth, alignment: .leading)

            ZStack {
                MuesliInlineWaveformView(
                    mode: controller.waveformMode,
                    color: activeStatusColor,
                    level: controller.waveformLevel,
                    barCount: Self.activeWaveformBarCount,
                    spacing: 2.2,
                    framesPerSecond: 18,
                    refreshDriver: .timeline
                )
                .frame(height: 24)
                .shadow(color: activeStatusColor.opacity(0.28), radius: 8)

                if controller.dictationPhase == .transcribing {
                    ProgressView()
                        .tint(activeStatusColor)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 36)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MuesliTheme.surfacePrimary.opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(activeStatusColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var helperKeys: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                KeyboardTextKey(".") { controller.insertTextKey(".") }
                KeyboardTextKey(",") { controller.insertTextKey(",") }
                KeyboardTextKey("?") { controller.insertTextKey("?") }
                KeyboardTextKey("!") { controller.insertTextKey("!") }
                KeyboardTextKey("'") { controller.insertTextKey("'") }
                KeyboardRepeatingTextKey(systemImage: "delete.left", accessibilityLabel: "Delete") {
                    controller.deleteBackward()
                }
            }

            HStack(spacing: 5) {
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
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(primaryForeground)
        .frame(maxWidth: .infinity)
        .frame(height: isProminent ? 44 : 36)
        .background(primaryBackground, in: RoundedRectangle(cornerRadius: isProminent ? 15 : 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isProminent ? 15 : 12, style: .continuous)
                .strokeBorder(primaryBorder, lineWidth: 1)
        )
        .shadow(color: primaryShadow, radius: isProminent ? 12 : 8, x: 0, y: 5)
        .opacity(controller.isPrimaryButtonDisabled ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: isProminent ? 15 : 12, style: .continuous))
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

        return .white
    }

    private var primaryBackground: LinearGradient {
        let colors: [Color]
        if controller.isPrimaryButtonDisabled {
            colors = [MuesliTheme.surfacePrimary, MuesliTheme.surfacePrimary.opacity(0.78)]
        } else if controller.stylesPrimaryButtonAsStop {
            colors = [MuesliTheme.destructive.opacity(0.82), MuesliTheme.destructive.opacity(0.62)]
        } else {
            colors = [Color(hex: 0x4F88FF), MuesliTheme.recording]
        }

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var primaryBorder: Color {
        if controller.stylesPrimaryButtonAsStop {
            return MuesliTheme.destructive.opacity(0.55)
        }

        return Color.white.opacity(0.18)
    }

    private var primaryShadow: Color {
        if controller.stylesPrimaryButtonAsStop {
            return MuesliTheme.destructive.opacity(0.22)
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
                .frame(height: 36)
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
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MuesliTheme.surfacePrimary.opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

private struct KeyboardRepeatingTextKey: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        KeyboardTextKeyLabel(title: nil, systemImage: systemImage)
            .muesliKeyboardKeySurface()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startRepeatingIfNeeded() }
                    .onEnded { _ in stopRepeating() }
            )
            .onDisappear {
                stopRepeating()
            }
    }

    private func startRepeatingIfNeeded() {
        guard repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(65))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
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
        .frame(minHeight: 38)
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
