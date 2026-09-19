import SwiftUI

/// Shared chrome for dismissible review sheets. Editing sheets keep their explicit Save/Cancel actions.
struct SheetHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var isCloseDisabled = false
    let close: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            actions()
            Button(L10n.get("common.close"), action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(isCloseDisabled)
        }
        .controlSize(.regular)
    }
}

extension SheetHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, isCloseDisabled: Bool = false, close: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.isCloseDisabled = isCloseDisabled
        self.close = close
        self.actions = { EmptyView() }
    }
}
