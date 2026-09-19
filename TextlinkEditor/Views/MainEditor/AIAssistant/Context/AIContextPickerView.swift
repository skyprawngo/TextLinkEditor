import SwiftUI

struct AIContextPickerView: View {
    let projectURL: URL
    var onReviewRequested: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var selection = AIContextSelection.shared
    @State private var files: [URL] = []
    @State private var search = ""
    @State private var preview: AIContextManifest?
    @State private var error: String?
    @State private var reviewKind = "consistency"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: L10n.get("ai.context.title")) { dismiss() }
            Text(L10n.get("ai.context.explanation"))
                .font(.callout).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { selection.scene(projectURL: projectURL) }, set: { selection.setScene($0, projectURL: projectURL); refresh() }), in: 0...100000) {
                Text(selection.scene(projectURL: projectURL) == 0 ? L10n.get("ai.context.scene.none") : String(format: L10n.get("ai.context.scene"), selection.scene(projectURL: projectURL)))
            }
            Text(L10n.get("ai.context.loreExplanation"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(L10n.get("ai.context.review.kind"), selection: $reviewKind) {
                    Text(L10n.get("ai.context.review.consistency")).tag("consistency")
                    Text(L10n.get("ai.context.review.dialogue")).tag("dialogue")
                    Text(L10n.get("ai.context.review.title")).tag("title")
                }.frame(maxWidth: 290)
                Button(L10n.get("ai.context.review.prepare")) {
                    refresh()
                    guard error == nil else { return }
                    let kind = L10n.get("ai.context.review." + reviewKind)
                    let scene = selection.scene(projectURL: projectURL)
                    onReviewRequested(String(format: L10n.get("ai.context.review.prompt"), kind, scene))
                    dismiss()
                }.disabled(preview?.entries.isEmpty != false)
            }
            HSplitView {
                VStack(alignment: .leading) {
                    TextField(L10n.get("ai.context.fileSearch"), text: $search).textFieldStyle(.roundedBorder)
                    List(files.filter { search.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(search) }, id: \.self) { file in
                        Toggle(isOn: Binding(get: {
                            selection.items(projectURL: projectURL).contains { $0.kind == .file && $0.source == relative(file) }
                        }, set: { enabled in
                            do {
                                if enabled { try selection.addFile(file, projectURL: projectURL) }
                                else if let item = selection.items(projectURL: projectURL).first(where: { $0.kind == .file && $0.source == relative(file) }) { selection.remove(item.id, projectURL: projectURL) }
                                refresh()
                            } catch { self.error = error.localizedDescription }
                        })) { Text(relative(file)).lineLimit(2) }
                    }
                }.frame(minWidth: 220)
                VStack(alignment: .leading) {
                    Text(L10n.get("ai.context.attachments")).font(.headline)
                    List(selection.items(projectURL: projectURL)) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.source).lineLimit(1)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { selection.remove(item.id, projectURL: projectURL); refresh() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help(L10n.get("ai.context.remove"))
                        }
                    }
                    HStack {
                        Text(L10n.get("ai.context.preview")).font(.headline)
                        Spacer()
                        Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .help(L10n.get("ai.context.refresh"))
                    }
                    ScrollView {
                        Text(preview?.text.isEmpty == false ? preview!.text : L10n.get("ai.context.empty"))
                            .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 150)
                    if let preview { Text(String(format: L10n.get("ai.context.count"), preview.entries.count, preview.text.count)).font(.caption).foregroundStyle(.secondary) }
                }.frame(minWidth: 300)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }.padding(20).frame(minWidth: 660, idealWidth: 760, minHeight: 500, idealHeight: 620)
            .onAppear { files = selection.availableFiles(projectURL: projectURL); refresh() }
    }

    private func relative(_ url: URL) -> String { String(url.path.dropFirst(projectURL.path.count + 1)) }
    private func refresh() {
        do { preview = try selection.manifest(projectURL: projectURL); error = nil }
        catch { preview = nil; self.error = error.localizedDescription }
    }
}
