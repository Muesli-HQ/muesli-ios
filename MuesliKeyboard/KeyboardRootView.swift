import SwiftUI

struct KeyboardRootView: View {
    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    controller.beginDictation()
                } label: {
                    Image(systemName: controller.isWaitingForResult ? "waveform" : "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Muesli")
                        .font(.headline)
                    Text(controller.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                KeyboardKey(title: "space") {}
                KeyboardKey(title: "return") {}
            }
        }
        .padding(12)
        .background(.background)
    }
}

private struct KeyboardKey: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
    }
}

