import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Project-owned planning data stays separate from manuscript files. Explicit Save keeps failures visible.
struct WritingWorkspaceView: View {
    let projectURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var document = WritingWorkspaceDocument()
    @State private var savedDocument = WritingWorkspaceDocument()
    @State private var paths: [String] = []
    @State private var sceneID: UUID?
    @State private var loreID: UUID?
    @State private var page = 0
    @State private var error: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var format = "md"
    @State private var preview = ""
    @State private var metric: WritingMetrics?
    @State private var showDiscard = false
    @State private var removal: Removal?
    private enum Removal { case scene(UUID), lore(UUID) }
    private var store: WritingWorkspaceStore { WritingWorkspaceStore(projectURL: projectURL) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.get("writing.ui.1")).font(.headline)
                Spacer()
                LiquidGlassSegmentedControl(
                    title: L10n.get("writing.ui.2"), selection: $page,
                    options: [0, 1, 2],
                    label: { L10n.get("writing.ui.\($0 + 3)") }
                ).frame(width: 340)
                Spacer()
                Button(L10n.get("writing.ui.6")) { save() }.disabled(!loaded || busy || document == savedDocument)
                Button(L10n.get("writing.ui.7")) { if document != savedDocument { showDiscard = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
            }.padding()
            Divider()
            if loaded {
                if page == 0 { scenes }
                else if page == 1 { lore }
                else { exportPage }
            } else { ContentUnavailableView(L10n.get("writing.ui.8"), systemImage: "exclamationmark.triangle") }
        }
        .frame(minWidth: 780, minHeight: 560)
        .interactiveDismissDisabled(busy || document != savedDocument)
        .task { reload() }
        .alert(L10n.get("writing.ui.9"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.get("writing.ui.10")) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(L10n.get("writing.remove.confirm"), isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button(L10n.get("writing.remove.action"), role: .destructive) { confirmRemoval() }
            Button(L10n.get("writing.ui.14"), role: .cancel) { removal = nil }
        } message: { Text(L10n.get("writing.remove.description")) }
        .confirmationDialog(L10n.get("writing.ui.11"), isPresented: $showDiscard) {
            Button(L10n.get("writing.ui.12")) { if save() { dismiss() } }
            Button(L10n.get("writing.ui.13"), role: .destructive) { dismiss() }
            Button(L10n.get("writing.ui.14"), role: .cancel) {}
        }
    }

    private var scenes: some View {
        HSplitView {
            VStack {
                List(selection: $sceneID) {
                    ForEach(document.scenes) { scene in
                        VStack(alignment: .leading) {
                            Text(scene.title)
                            Text(writingLabel(scene.status) + (scene.manuscriptPath.isEmpty ? L10n.get("writing.ui.56") : " · " + scene.manuscriptPath)).font(.caption).foregroundStyle(.secondary)
                        }.tag(scene.id)
                    }
                }
                HStack {
                    Button { var scene = WritingScene(); scene.title = L10n.get("writing.ui.58"); document.scenes.append(scene); sceneID = scene.id } label: { Label(L10n.get("writing.ui.15"), systemImage: "plus") }
                    Button { if let sceneID { removal = .scene(sceneID) } } label: { Image(systemName: "minus") }.help(L10n.get("writing.remove.scene")).disabled(sceneID == nil)
                    Button { moveScene(-1) } label: { Image(systemName: "arrow.up") }.help(L10n.get("writing.ui.16")).disabled(sceneIndex == nil || sceneIndex == 0)
                    Button { moveScene(1) } label: { Image(systemName: "arrow.down") }.help(L10n.get("writing.ui.17")).disabled(sceneIndex == nil || sceneIndex == document.scenes.count - 1)
                }.padding(8)
            }.frame(minWidth: 230, idealWidth: 260)
            Group {
                if let index = sceneIndex {
                    Form {
                        TextField(L10n.get("writing.ui.18"), text: $document.scenes[index].title)
                        manuscriptPicker(L10n.get("writing.ui.19"), selection: $document.scenes[index].manuscriptPath)
                        TextField(L10n.get("writing.ui.20"), text: $document.scenes[index].viewpoint)
                        TextField(L10n.get("writing.scene.characters"), text: Binding(get: { document.scenes[index].characters ?? "" }, set: { document.scenes[index].characters = $0 }))
                        TextField(L10n.get("writing.ui.21"), text: $document.scenes[index].place)
                        TextField(L10n.get("writing.ui.22"), text: $document.scenes[index].summary, axis: .vertical)
                        Picker(L10n.get("writing.ui.23"), selection: $document.scenes[index].status) { ForEach(["초고", "수정", "완료"], id: \.self) { Text(writingLabel($0)) } }
                        Toggle(L10n.get("writing.ui.24"), isOn: $document.scenes[index].includedInExport)
                        TextField(L10n.get("writing.ui.25"), value: $document.scenes[index].characterGoal, format: .number)
                        Button(L10n.get("writing.ui.26")) { measure(document.scenes[index]) }
                        if let metric {
                            LabeledContent(L10n.get("writing.ui.27"), value: String(format: L10n.get("writing.metrics.characters"), metric.characters))
                            LabeledContent(L10n.get("writing.ui.28"), value: String(format: L10n.get("writing.metrics.characters"), metric.nonWhitespaceCharacters))
                            LabeledContent(L10n.get("writing.ui.29"), value: "\(metric.words)")
                            if document.scenes[index].characterGoal > 0 {
                                ProgressView(value: Double(min(metric.characters, document.scenes[index].characterGoal)), total: Double(document.scenes[index].characterGoal))
                            }
                            Text(L10n.get("writing.ui.30")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L10n.get("writing.ui.31")).font(.caption).foregroundStyle(.secondary)
                    }.formStyle(.grouped)
                } else { ContentUnavailableView(L10n.get("writing.ui.32"), systemImage: "list.number") }
            }.frame(minWidth: 430)
        }.onChange(of: sceneID) { metric = nil }
    }

    private var lore: some View {
        HSplitView {
            VStack {
                List(selection: $loreID) { ForEach(document.lore) { entry in Text(entry.name).tag(entry.id) } }
                HStack {
                    Button { var entry = WritingLoreEntry(); entry.name = L10n.get("writing.ui.59"); document.lore.append(entry); loreID = entry.id } label: { Label(L10n.get("writing.ui.33"), systemImage: "plus") }
                    Button { if let loreID { removal = .lore(loreID) } } label: { Image(systemName: "minus") }.help(L10n.get("writing.remove.lore")).disabled(loreID == nil)
                }.padding(8)
            }.frame(minWidth: 230, idealWidth: 260)
            Group {
                if let index = document.lore.firstIndex(where: { $0.id == loreID }) {
                    Form {
                        TextField(L10n.get("writing.ui.34"), text: $document.lore[index].name)
                        Picker(L10n.get("writing.ui.35"), selection: $document.lore[index].kind) { ForEach(["인물", "장소", "규칙", "사건", "기타"], id: \.self) { Text(writingLabel($0)) } }
                        TextField(L10n.get("writing.ui.36"), text: $document.lore[index].aliases)
                        TextField(L10n.get("writing.ui.37"), text: $document.lore[index].knownBy)
                        manuscriptPicker(L10n.get("writing.ui.38"), selection: $document.lore[index].manuscriptPath)
                        Picker(L10n.get("writing.ui.39"), selection: $document.lore[index].revealedFromSceneID) {
                            Text(L10n.get("writing.ui.40")).tag(nil as UUID?)
                            ForEach(document.scenes) { Text($0.title).tag(Optional($0.id)) }
                        }
                        Text(L10n.get("writing.ui.41")).font(.headline)
                        if let quote = document.lore[index].sourceQuote {
                            Text(quote).textSelection(.enabled)
                            Text(L10n.get("collaboration.canon." + (document.lore[index].canonStatus ?? "proposed"))).font(.caption).foregroundStyle(.secondary)
                            Button(L10n.get("collaboration.openSource")) {
                                if let url = try? store.resolve(document.lore[index].manuscriptPath) {
                                    EditorTabManager.shared.openFile(FileSystemItem(url: url, isDirectory: false))
                                }
                            }
                        } else {
                            TextEditor(text: $document.lore[index].body).frame(minHeight: 140)
                        }
                        Toggle(L10n.get("writing.ui.42"), isOn: $document.lore[index].includeInAI)
                        Text(L10n.get("writing.ui.43")).font(.caption).foregroundStyle(.secondary)
                    }.formStyle(.grouped)
                } else { ContentUnavailableView(L10n.get("writing.ui.44"), systemImage: "books.vertical") }
            }.frame(minWidth: 430)
        }
    }

    private var exportPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.get("writing.ui.45")).foregroundStyle(.secondary)
            HStack {
                Picker(L10n.get("writing.ui.46"), selection: $format) { Text("Markdown").tag("md"); Text(L10n.get("writing.ui.47")).tag("txt"); Text("Word DOCX").tag("docx") }.frame(width: 230)
                Button(L10n.get("writing.ui.48")) { makePreview() }
                Button(L10n.get("writing.ui.49")) { exportSubmission() }.disabled(busy)
                Spacer()
            }
            ScrollView { Text(preview.isEmpty ? L10n.get("writing.ui.50") : preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.background(.background).clipShape(RoundedRectangle(cornerRadius: 8))
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text(L10n.get("writing.ui.51")).font(.headline)
                    Text(L10n.get("writing.ui.52")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L10n.get("writing.ui.53")) { archiveProject() }.disabled(busy)
            }
        }.padding()
    }

    private func writingLabel(_ value: String) -> String {
        let keys = ["초고": "writing.ui.64", "수정": "writing.ui.65", "완료": "writing.ui.66", "인물": "writing.ui.67", "장소": "writing.ui.21", "규칙": "writing.ui.68", "사건": "writing.ui.69", "기타": "writing.ui.70"]
        return keys[value].map { L10n.get($0) } ?? value
    }
    private var sceneIndex: Int? { document.scenes.firstIndex { $0.id == sceneID } }
    private func manuscriptPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(L10n.get("writing.ui.54")).tag("")
            if !selection.wrappedValue.isEmpty && !paths.contains(selection.wrappedValue) { Text(L10n.get("writing.ui.55") + selection.wrappedValue).tag(selection.wrappedValue) }
            ForEach(paths, id: \.self) { Text($0).tag($0) }
        }
    }
    private func reload() {
        do { document = try store.load(); savedDocument = document; paths = try store.manuscriptPaths(); loaded = true; sceneID = document.scenes.first?.id; loreID = document.lore.first?.id }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult private func save() -> Bool {
        do {
            guard try store.load() == savedDocument else { throw CollaborationFailure.conflict }
            try store.save(document); savedDocument = document; return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    private func confirmRemoval() {
        guard let target = removal else { return }
        removal = nil
        do {
            switch target {
            case .scene(let id):
                try document.removeScene(id: id)
                sceneID = document.scenes.first?.id
                metric = nil
            case .lore(let id):
                document.removeLore(id: id)
                loreID = document.lore.first?.id
            }
        } catch { self.error = error.localizedDescription }
    }
    private func moveScene(_ delta: Int) {
        guard let index = sceneIndex, document.scenes.indices.contains(index + delta) else { return }
        document.scenes.swapAt(index, index + delta)
    }
    private func drafts() -> [String: String] {
        let manager = EditorTabManager.shared; manager.flushEditor()
        var result: [String: String] = [:]
        for tab in manager.tabs where tab.url.path.hasPrefix(projectURL.path + "/") && manager.isModified(url: tab.url) {
            if let content = manager.getCachedContent(for: tab.url) { result[String(tab.url.path.dropFirst(projectURL.path.count + 1))] = content }
        }
        return result
    }
    private func measure(_ scene: WritingScene) {
        do { metric = WritingMetrics(try store.text(for: scene, drafts: drafts())) }
        catch { self.error = error.localizedDescription; metric = nil }
    }
    private func makePreview() {
        do { preview = try store.submission(document, drafts: drafts(), markdown: format == "md") }
        catch { self.error = error.localizedDescription }
    }
    private func exportSubmission() {
        do {
            let text = try store.submission(document, drafts: drafts(), markdown: format == "md")
            preview = text
            let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.get("writing.ui.57") + format
            panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            if format == "docx" { try store.exportDOCX(text, to: destination) }
            else { try Data(text.utf8).write(to: destination, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
    private func archiveProject() {
        guard save() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = projectURL.deletingPathExtension().lastPathComponent + ".zip"; panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let snapshot = drafts(), archiveStore = store
        busy = true
        Task {
            do { try await Task.detached { try archiveStore.archive(to: destination, drafts: snapshot) }.value }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
