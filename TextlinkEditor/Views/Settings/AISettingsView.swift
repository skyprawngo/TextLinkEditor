import SwiftUI

// MARK: - AI Settings

struct AISettingsView: View {
    @State private var viewModel = AIAssistantViewModel.shared
    var body: some View {
        AIConnectionSettingsContent(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.chatGPTAccount.account) { _, account in
                guard viewModel.selectedCLIType == .chatgpt else { return }
                if account != nil {
                    if case .connected(.chatgpt) = viewModel.connectionState {} else { viewModel.completeConnection(.chatgpt) }
                } else {
                    viewModel.cancelSend()
                    viewModel.connectionState = .ready(.chatgpt)
                }
            }
    }
}
