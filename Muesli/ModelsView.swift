import SwiftUI

struct ModelsView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    Text("Models")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            TranscriptionModelSelector(
                                selection: $coordinator.selectedTranscriptionModel,
                                downloadedModels: coordinator.downloadedTranscriptionModels,
                                showsHeader: false,
                                compact: true,
                                preparation: coordinator.modelPreparation,
                                onSelect: coordinator.selectTranscriptionModel
                            )
                            ModelReadinessView(state: coordinator.modelPreparation,
                                modelName: coordinator.selectedTranscriptionModel.shortName,
                                retry: coordinator.prepareModel)
                        }
                        .padding(MuesliTheme.spacing16)
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing24)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
