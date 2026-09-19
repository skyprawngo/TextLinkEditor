import SwiftUI
import AppKit

struct ManuscriptVersionsView: View {
    let projectURL: URL
    let documentURL: URL
    var draftContent: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [VersionHistoryStore.Snapshot] = []
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var selected: VersionHistoryStore.Snapshot? { snapshots.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.get("versions.title"), subtitle: documentURL.lastPathComponent, close: { dismiss() }) {
                if draftContent != nil {
                    Button(L10n.get("versions.capture"), systemImage: "plus") { captureDraft() }.disabled(isWorking)
                }
            }.padding()
            HSplitView {
                List(snapshots, selection: $selectedID) { snapshot in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.date.formatted(date: .abbreviated, time: .standard))
                        Text(L10n.get(snapshot.reason)).font(.caption).foregroundStyle(.secondary)
                    }.tag(snapshot.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                Group {
                    if let selected {
                        VersionPreview(content: selected.content, versionID: selected.id)
                    } else {
                        ContentUnavailableView(L10n.get("versions.empty"), systemImage: "clock.arrow.circlepath",
                                               description: Text(L10n.get("versions.emptyDescription")))
                    }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(L10n.get("versions.restoreDescription"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.get("versions.restore"), systemImage: "doc.badge.plus") { restoreCopy() }
                    .disabled(selected == nil || isWorking)
            }.padding()
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 420, idealHeight: 560)
        .task { await reload() }
        .alert(L10n.get("versions.failure"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.get("versions.ok"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() async {
        isWorking = true
        defer { isWorking = false }
        do {
            snapshots = try await Task.detached(priority: .userInitiated) {
                try VersionHistoryStore.snapshots(projectURL: projectURL, documentURL: documentURL)
            }.value
            if !snapshots.contains(where: { $0.id == selectedID }) { selectedID = snapshots.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func captureDraft() {
        guard let draftContent else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    try VersionHistoryStore.snapshot(projectURL: projectURL, documentURL: documentURL,
                                                     content: draftContent, reason: "versions.manualDraft")
                }.value
                selectedID = saved.id
                await reload()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func restoreCopy() {
        guard let selected else { return }
        let panel = NSSavePanel()
        panel.title = L10n.get("versions.restoreTitle")
        panel.directoryURL = documentURL.deletingLastPathComponent()
        let stem = documentURL.deletingPathExtension().lastPathComponent
        let suffix = documentURL.pathExtension.isEmpty ? "md" : documentURL.pathExtension
        panel.nameFieldStringValue = "\(stem)-\(L10n.get("versions.restoredSuffix")).\(suffix)"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do { try VersionHistoryStore.restoreCopy(selected, to: destination) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct VersionPreview: NSViewRepresentable {
    let content: String
    let versionID: UUID
    final class Coordinator { var versionID: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .textColor
        text.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.versionID != versionID, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.versionID = versionID
        text.string = content
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

struct ProjectBackupButton: View {
    let projectURL: URL
    @State private var resultMessage: String?
    @State private var isWorking = false
    var body: some View {
        Button(L10n.get("versions.backup"), systemImage: "externaldrive.badge.plus") {
            let panel = NSSavePanel()
            panel.title = L10n.get("versions.backupTitle")
            panel.message = L10n.get("versions.backupDescription")
            panel.directoryURL = projectURL.deletingLastPathComponent()
            let name = projectURL.lastPathComponent
            panel.nameFieldStringValue = name + "-" + L10n.get("versions.backupSuffix")
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let destination = panel.url else { return }
                isWorking = true
                Task {
                    let result = await Task.detached(priority: .userInitiated) { () -> String in
                        do {
                            try ProjectBackupStore.create(projectURL: projectURL, destinationURL: destination)
                            return String(format: L10n.get("versions.backupSuccess"), destination.lastPathComponent)
                        } catch { return String(format: L10n.get("versions.backupFailure"), error.localizedDescription) }
                    }.value
                    isWorking = false
                    resultMessage = result
                }
            }
        }.disabled(isWorking)
            .alert(L10n.get("versions.backupTitle"), isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button(L10n.get("versions.ok"), role: .cancel) { resultMessage = nil }
            } message: { Text(resultMessage ?? "") }
    }
}
