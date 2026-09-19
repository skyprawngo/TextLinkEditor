import Foundation

@MainActor private final class ProposalFixture: AIRequestExecuting {
    var proposal: CollaborationProposal
    var beforeReturn: (() throws -> Void)?
    var capturedPrompt = ""
    var directory: URL?
    init(_ proposal: CollaborationProposal) { self.proposal = proposal }
    func sendPrompt(_ prompt: String, cliType: AICLIType, workingDirectory: URL?, sessionId: String?,
                    allowsWorkspaceEdits: Bool, options: AIRequestOptions,
                    streamHandler: @escaping @MainActor @Sendable (String) -> Void) async throws -> CLIPromptResult {
        precondition(!allowsWorkspaceEdits && options.readsProjectFiles)
        capturedPrompt = prompt
        directory = workingDirectory
        try beforeReturn?()
        return .init(response: String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self), sessionId: "fixture")
    }
    func cancel() {}
}

@MainActor
func checkCollaboration(in folder: URL) async throws {
    var count = 0
    func check(_ value: Bool, _ message: String) {
        precondition(value, "Collaboration: " + message)
        count += 1
    }
    let root = folder.appendingPathComponent("협업 project")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("설정"), withIntermediateDirectories: true)
    let store = CollaborationStore(project: root)
    let emptyRoot = folder.appendingPathComponent("empty creative project")
    try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
    let emptyStore = CollaborationStore(project: emptyRoot)
    for path in ["설정".decomposedStringWithCanonicalMapping, "인물/조연", "자료/이미지", ".private/secret"] {
        try FileManager.default.createDirectory(at: emptyRoot.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try Data([0, 1, 2]).write(to: emptyRoot.appendingPathComponent("자료/이미지/photo.png"))
    try FileManager.default.createSymbolicLink(at: emptyRoot.appendingPathComponent("outside"), withDestinationURL: root)
    check(try emptyStore.snapshotDirectories() == ["설정", "인물", "인물/조연", "자료", "자료/이미지"],
          "directory inventory retains empty and nested Unicode folders but excludes hidden paths and symlinks")
    try emptyStore.enable()
    let createTask = try emptyStore.enqueue(origin: "conversation", instruction: "앞서 합의한 떠다니는 던전 설정을 첫 문서로 작성해 줘")
    let createFixture = ProposalFixture(.init(summary: "세계관 초안 작성", edits: [
        .init(path: "설정/세계관.md", content: "던전은 하늘에 떠 있다.", reason: "작가가 대화에서 확정하고 파일 작성을 요청함", evidence: [], dependsOn: [])
    ], questions: [.init(id: "origin", question: "던전이 떠 있는 이유는 무엇인가요?",
                        evidence: [.init(path: "설정/세계관.md", quote: "던전은 하늘에 떠 있다.")],
                        options: ["미정", "마법"])], facts: []))
    createFixture.beforeReturn = {
        let copy = createFixture.directory!
        check(FileManager.default.fileExists(atPath: copy.appendingPathComponent("인물/조연").path), "writing AI can browse existing empty subfolders")
        check(FileManager.default.fileExists(atPath: copy.appendingPathComponent("설정").path), "writing copy preserves Korean folder names")
        check(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("outside").path)
              && !FileManager.default.fileExists(atPath: copy.appendingPathComponent(".private").path)
              && !FileManager.default.fileExists(atPath: copy.appendingPathComponent("자료/이미지/photo.png").path),
              "copy excludes symlinks, metadata and binary contents")
        check(createFixture.capturedPrompt.contains("인물") && createFixture.capturedPrompt.contains("Existing project directories"),
              "prompt exposes current directory names")
    }
    let readFixture = ProposalFixture(.init(summary: "discussion", edits: [], questions: [], facts: []))
    readFixture.beforeReturn = {
        check(FileManager.default.fileExists(atPath: readFixture.directory!.appendingPathComponent("인물/조연").path),
              "conversation and planning share the directory-aware copy")
        check(readFixture.capturedPrompt.contains("Existing project directories"), "read-only modes receive current directory inventory")
    }
    var readOptions = AIRequestOptions()
    readOptions.readsProjectFiles = true
    _ = try await AIWorkspaceProposalExecutor(base: readFixture, requestID: UUID(), project: emptyRoot)
        .sendPrompt("프로젝트 구조 확인", cliType: .claude, workingDirectory: emptyRoot, sessionId: nil,
                    allowsWorkspaceEdits: false, options: readOptions, streamHandler: { _ in })
    _ = try await CollaborationEngine(store: emptyStore, executor: createFixture).execute(taskID: createTask, provider: .claude, options: .init())
    createFixture.beforeReturn = nil
    check(try emptyStore.snapshot()["설정/세계관.md"] == "던전은 하늘에 떠 있다.", "first document can be created from author conversation without fabricated source evidence")
    check(try emptyStore.load().tasks.first(where: { $0.id == createTask })?.phase == .waiting,
          "question can cite an independently created document without blocking its creation")
    let conversationID = UUID()
    let conversationRequest = try AIRequestPreparer().prepare(
        requestInput: "설정 내부에 길드 파일을 새로 생성해 줘", type: .claude,
        projectURL: emptyRoot, assistantId: conversationID, inlineRevision: nil,
        attachDocument: false, messages: [], taggedCardIds: [], existingSession: nil,
        continueFromCardId: nil, chatMode: .conversation)
    check(conversationRequest.allowsWorkspaceEdits, "conversation requests can use validated file edits")
    let conversationFixture = ProposalFixture(.init(summary: "길드 파일 생성", edits: [
        .init(path: "설정/길드.md", content: "길드는 경쟁으로 폐업했다.", reason: "사용자의 파일 생성 요청", evidence: [], dependsOn: [])
    ], questions: [], facts: []))
    _ = try await AIWorkspaceProposalExecutor(base: conversationFixture, requestID: conversationID, project: emptyRoot)
        .sendPrompt(conversationRequest.prompt, cliType: .claude, workingDirectory: emptyRoot, sessionId: nil,
                    allowsWorkspaceEdits: conversationRequest.allowsWorkspaceEdits, options: .init(), streamHandler: { _ in })
    check(try emptyStore.snapshot()["설정/길드.md"] == "길드는 경쟁으로 폐업했다.", "conversation creates requested file through the app transaction")
    let discussionID = UUID()
    conversationFixture.proposal = .init(summary: "대화 응답", edits: [], questions: [], facts: [])
    let discussionBefore = try emptyStore.snapshot()
    let discussion = try await AIWorkspaceProposalExecutor(base: conversationFixture, requestID: discussionID, project: emptyRoot)
        .sendPrompt("아이디어를 논의하자", cliType: .claude, workingDirectory: emptyRoot, sessionId: nil,
                    allowsWorkspaceEdits: true, options: .init(), streamHandler: { _ in })
    let discussionAfter = try emptyStore.snapshot()
    check(discussion.response == "대화 응답" && discussionAfter == discussionBefore,
          "discussion without edits preserves files and returns the answer")
    check(AIWorkspaceEdits.load(id: discussionID, project: emptyRoot) == nil,
          "discussion without edits does not create an empty comparison")
    let draftBefore = try emptyStore.snapshot()
    let draftTask = try emptyStore.enqueue(origin: "conversation", instruction: "질문 근거 검증")
    let draftFixture = ProposalFixture(.init(summary: "질문", edits: [
        .init(path: "인물/주인공.md", content: "주인공은 탐험가다.", reason: "작가 요청", evidence: [], dependsOn: ["role"])
    ], questions: [.init(id: "role", question: "직업을 확정할까요?",
                        evidence: [.init(path: "인물/주인공.md", quote: "주인공은 탐험가다.")], options: ["예", "아니오"])], facts: []))
    do {
        _ = try await CollaborationEngine(store: emptyStore, executor: draftFixture).execute(taskID: draftTask, provider: .claude, options: .init())
        preconditionFailure("question cited its own blocked edit")
    } catch {}
    check(try emptyStore.snapshot() == draftBefore, "blocked draft evidence cannot authorize publication")
    draftFixture.proposal.edits[0].dependsOn = []
    draftFixture.proposal.questions[0].evidence[0].quote = "없는 문장"
    do {
        _ = try await CollaborationEngine(store: emptyStore, executor: draftFixture).execute(taskID: draftTask, provider: .claude, options: .init())
        preconditionFailure("fabricated question evidence accepted")
    } catch {}
    check(try emptyStore.snapshot() == draftBefore, "fabricated question evidence still rejects all edits")
    let noEvidenceTask = try emptyStore.enqueue(origin: "conversation", instruction: "기존 설정 변경")
    createFixture.proposal.edits[0].content = "던전은 바다에 있다."
    do {
        _ = try await CollaborationEngine(store: emptyStore, executor: createFixture).execute(taskID: noEvidenceTask, provider: .claude, options: .init())
        preconditionFailure("existing document edit without evidence accepted")
    } catch {}
    check(try emptyStore.snapshot()["설정/세계관.md"] == "던전은 하늘에 떠 있다.", "existing documents still require actual evidence")
    let setting = try store.file("설정/인물.md")
    let manuscript = try store.file("원고.md")
    try "인물은 범인을 모른다.".write(to: setting, atomically: true, encoding: .utf8)
    try "나는 범인을 모른다.".write(to: manuscript, atomically: true, encoding: .utf8)
    try store.enable()
    check(try store.load().baseline == store.snapshot(), "initial activation establishes baseline")
    let task = try store.enqueue(origin: "comment", instruction: "처음부터 범인을 아는 인물로 바꿔")
    let evidence = [CollaborationEvidence(path: "설정/인물.md", quote: "인물은 범인을 모른다.")]
    let proposal = CollaborationProposal(summary: "설정과 대사 수정",
        edits: [
            .init(path: "설정/인물.md", content: "인물은 처음부터 범인을 안다.", reason: "사용자 결정", evidence: evidence, dependsOn: []),
            .init(path: "원고.md", content: "나는 처음부터 범인을 알았다.", reason: "인물 지식 반영", evidence: evidence, dependsOn: [])
        ], questions: [], facts: [
            .init(id: "knowledge", name: "범인 지식", path: "설정/인물.md", quote: "인물은 처음부터 범인을 안다.",
                  status: "confirmed", storyTime: "처음부터", knownBy: "주인공", decision: "사용자 요청")
        ])
    let fixture = ProposalFixture(proposal)
    _ = try await CollaborationEngine(store: store, executor: fixture).execute(taskID: task, provider: .claude, options: .init())
    check(try String(contentsOf: manuscript, encoding: .utf8) == "나는 처음부터 범인을 알았다.", "related manuscript updated")
    check(fixture.directory != root && !FileManager.default.fileExists(atPath: fixture.directory!.path), "isolated copy disposed")
    check(fixture.capturedPrompt.contains("Dialog, unreliable narration") && fixture.capturedPrompt.contains("reader revelation"), "canon distinctions included in model contract")
    let lore = try WritingWorkspaceStore(projectURL: root).load().lore
    check(lore.first?.body == "" && lore.first?.sourceQuote == "인물은 처음부터 범인을 안다." && lore.first?.canonStatus == "confirmed", "source-linked canon has no duplicate authoritative body")
    check(try store.load().tasks.first?.phase == .completed, "task completed after publication")
    check(try store.load().baseline == store.snapshot(), "AI edits advance baseline without feedback loop")
    try CollaborationApplier(store: store).undo(taskID: task)
    check(try String(contentsOf: manuscript, encoding: .utf8) == "나는 범인을 모른다.", "multi-file undo")
    check(try WritingWorkspaceStore(projectURL: root).load().lore.first?.canonStatus == "superseded", "undo invalidates changed canon evidence")

    let rollbackTask = try store.enqueue(origin: "comment", instruction: "rollback fixture")
    let rollbackBefore = try store.snapshot()
    var checks = 0
    do {
        _ = try CollaborationApplier(store: store, checkEditor: {
            checks += 1
            if checks == 3 { throw CollaborationFailure.conflict }
        }).apply(taskID: rollbackTask, before: rollbackBefore, changes: [
            .init(path: "설정/인물.md", before: rollbackBefore["설정/인물.md"], after: "first write"),
            .init(path: "원고.md", before: rollbackBefore["원고.md"], after: "second write")
        ])
        preconditionFailure("injected failure ignored")
    } catch {}
    check(try store.snapshot() == rollbackBefore, "partial publication failure rolls back all written files")
    check(try store.journals().last?.phase == "rolledBack", "rollback journal durable")

    let narrativeTask = try store.enqueue(origin: "comment", instruction: "대사 검토")
    let narrative = ProposalFixture(.init(summary: "가설 색인", edits: [], questions: [], facts: [
        .init(id: "belief", name: "인물의 주장", path: "원고.md", quote: "나는 범인을 모른다.",
              status: "confirmed", storyTime: "", knownBy: "화자", decision: "대사")
    ]))
    _ = try await CollaborationEngine(store: store, executor: narrative).execute(taskID: narrativeTask, provider: .claude, options: .init())
    check(try WritingWorkspaceStore(projectURL: root).load().lore.first(where: { $0.sourceKey == "belief" })?.canonStatus == "proposed", "manuscript statement cannot automatically become confirmed canon")
    let invalidFactTask = try store.enqueue(origin: "comment", instruction: "invalid evidence")
    narrative.proposal.facts[0].quote = "원문에 없는 추론"
    do {
        _ = try await CollaborationEngine(store: store, executor: narrative).execute(taskID: invalidFactTask, provider: .claude, options: .init())
        preconditionFailure("fabricated quote accepted")
    } catch {}
    check(try store.snapshot() == rollbackBefore, "fabricated evidence never modifies source")

    let blockedTask = try store.enqueue(origin: "comment", instruction: "blocked")
    try store.update { $0.protectedPaths.insert("원고.md") }
    do {
        _ = try await CollaborationEngine(store: store, executor: fixture).execute(taskID: blockedTask, provider: .claude, options: .init())
        preconditionFailure("protected edit accepted")
    } catch {}
    check(try String(contentsOf: setting, encoding: .utf8) == "인물은 범인을 모른다.", "protected edit rejects entire proposal")
    try store.update { $0.protectedPaths = [] }

    let conflictTask = try store.enqueue(origin: "comment", instruction: "concurrent edit")
    fixture.beforeReturn = { try "사용자가 새로 쓴 문장".write(to: manuscript, atomically: true, encoding: .utf8) }
    do {
        _ = try await CollaborationEngine(store: store, executor: fixture).execute(taskID: conflictTask, provider: .claude, options: .init())
        preconditionFailure("concurrent edit overwritten")
    } catch {}
    check(try String(contentsOf: manuscript, encoding: .utf8) == "사용자가 새로 쓴 문장", "concurrent edit preserved")
    fixture.beforeReturn = nil
    try "나는 범인을 모른다.".write(to: manuscript, atomically: true, encoding: .utf8)

    let qTask = try store.enqueue(origin: "comment", instruction: "반전도 유지하고 인물 지식도 바꿔")
    let question = CollaborationQuestion(id: "ending", question: "반전을 유지할까요?", evidence: evidence, options: ["유지", "변경"])
    var questionProposal = proposal
    questionProposal.questions = [question]
    questionProposal.edits[1].dependsOn = ["ending"]
    let questionFixture = ProposalFixture(questionProposal)
    _ = try await CollaborationEngine(store: store, executor: questionFixture).execute(taskID: qTask, provider: .claude, options: .init())
    check(try String(contentsOf: manuscript, encoding: .utf8) == "나는 범인을 모른다.", "dependent edit waits")
    check(try String(contentsOf: setting, encoding: .utf8) == "인물은 처음부터 범인을 안다.", "independent edit proceeds")
    check(try store.load().tasks.first(where: { $0.id == qTask })?.phase == .waiting, "question stored durably")
    try store.updateTask(qTask) { $0.questions[0].answer = "유지"; $0.phase = .queued }
    questionFixture.proposal = .init(summary: "답변 반영",
        edits: [.init(path: "원고.md", content: "나는 범인을 알지만 모른다고 말했다.", reason: "반전 유지",
                      evidence: [.init(path: "설정/인물.md", quote: "인물은 처음부터 범인을 안다.")], dependsOn: ["ending"])],
        questions: [], facts: [])
    _ = try await CollaborationEngine(store: store, executor: questionFixture).execute(taskID: qTask, provider: .claude, options: .init())
    check(try String(contentsOf: manuscript, encoding: .utf8) == "나는 범인을 알지만 모른다고 말했다.", "answer resumes dependent work")
    try "후속 사용자 편집".write(to: manuscript, atomically: true, encoding: .utf8)
    do { try CollaborationApplier(store: store).undo(taskID: qTask); preconditionFailure("undo overwrote user") } catch {}
    check(try String(contentsOf: manuscript, encoding: .utf8) == "후속 사용자 편집", "undo detects later user changes")

    let beforeRecovery = try store.snapshot()
    let recoveryTask = try store.enqueue(origin: "comment", instruction: "recover")
    let recoveryChange = CollaborationChange(path: "원고.md", before: beforeRecovery["원고.md"], after: "중단된 쓰기")
    let journal = CollaborationTransaction(taskID: recoveryTask, changes: [recoveryChange])
    try store.saveJournal(journal)
    try store.updateTask(recoveryTask) { $0.phase = .applying; $0.transactionIDs = [journal.id] }
    try "중단된 쓰기".write(to: manuscript, atomically: true, encoding: .utf8)
    try CollaborationApplier(store: store).recover()
    check(try store.snapshot() == beforeRecovery, "restart rolls back incomplete transaction")
    check(try store.load().tasks.first(where: { $0.id == recoveryTask })?.phase == .review, "interrupted task requires review")

    let changes = [CollaborationChange(path: "원고.md", before: "old", after: "new")]
    let first = try store.enqueue(origin: "documents", instruction: "batch", changes: changes)
    let second = try store.enqueue(origin: "git", instruction: "git", changes: changes)
    check(first == second, "app and Git batches deduplicate")
    let delayedGit = try store.enqueue(origin: "git", instruction: "late Git observation",
        changes: [.init(path: "원고.md", before: "AI has advanced baseline", after: "new")])
    check(first == delayedGit, "late Git observation deduplicates after baseline advances")
    let directed = try store.enqueue(origin: "gitInstruction", instruction: "keep the twist", changes: changes)
    let repeated = try store.enqueue(origin: "gitInstruction", instruction: "keep the twist", changes: changes)
    let different = try store.enqueue(origin: "gitInstruction", instruction: "reveal the twist", changes: changes)
    check(directed == repeated, "identical change instructions deduplicate")
    check(directed != different && directed != first, "distinct author decisions retain separate tasks")
    check(!CollaborationStore.validPath("../outside.md") && !CollaborationStore.validPath(".git/config.md")
          && !CollaborationStore.validPath("image.png"), "unsafe and nontext targets rejected")
    let outside = folder.appendingPathComponent("outside.md")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
    do { _ = try store.file("link.md"); preconditionFailure("symlink accepted") } catch {}
    check(try String(contentsOf: outside, encoding: .utf8) == "outside", "symlink target untouched")

    let gitRoot = folder.appendingPathComponent("git fixture")
    try FileManager.default.createDirectory(at: gitRoot, withIntermediateDirectories: true)
    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = gitRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
    try git(["init"])
    let gitFile = gitRoot.appendingPathComponent("draft.md")
    try "staged".write(to: gitFile, atomically: true, encoding: .utf8)
    try git(["add", "--", "draft.md"])
    try "working".write(to: gitFile, atomically: true, encoding: .utf8)
    let stage = try CollaborationGit.staged(project: gitRoot)
    check(stage["draft.md"]! == "staged", "partial staging reads index rather than working tree")
    let gitStore = CollaborationStore(project: gitRoot)
    try gitStore.enable()
    let stagedTask = try gitStore.enqueue(origin: "git", instruction: "staged",
        changes: [.init(path: "draft.md", before: nil, after: "staged")])
    do {
        _ = try await CollaborationEngine(store: gitStore, executor: fixture).execute(taskID: stagedTask, provider: .claude, options: .init())
        preconditionFailure("unstaged edit overwritten")
    } catch {}
    check(try String(contentsOf: gitFile, encoding: .utf8) == "working", "working tree divergence blocks application")
    let subfolder = gitRoot.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    do { _ = try CollaborationGit.staged(project: subfolder); preconditionFailure("parent repo accepted") } catch {}
    check(true, "Git root mismatch rejected")

    let mergeRoot = folder.appendingPathComponent("merge project")
    try FileManager.default.createDirectory(at: mergeRoot, withIntermediateDirectories: true)
    let mergeStore = CollaborationStore(project: mergeRoot)
    let mergeFile = mergeRoot.appendingPathComponent("draft.md")
    try Data("first\nsecond\nthird".utf8).write(to: mergeFile)
    try mergeStore.enable()
    let mergeTask = try mergeStore.enqueue(origin: "comment", instruction: "edit second")
    let mergeEdit = CollaborationEdit(path: "draft.md", content: nil, reason: "requested", evidence: [.init(path: "draft.md", quote: "second")], dependsOn: [], replacements: [.init(oldText: "second", newText: "AI")])
    let mergeFixture = ProposalFixture(.init(summary: "merged", edits: [mergeEdit], questions: [], facts: []))
    mergeFixture.beforeReturn = {
        try Data("prefix\nfirst\nsecond\nhuman".utf8).write(to: mergeFile)
        try Data("unrelated".utf8).write(to: mergeRoot.appendingPathComponent("other.md"))
    }
    _ = try await CollaborationEngine(store: mergeStore, executor: mergeFixture).execute(taskID: mergeTask, provider: .claude, options: .init())
    check(try String(contentsOf: mergeFile, encoding: .utf8) == "prefix\nfirst\nAI\nhuman", "exact-text proposal merges concurrent typing and shifted positions")
    let mergedJournal = try mergeStore.journals().first { $0.taskID == mergeTask }!
    check(mergedJournal.changes.first?.before == "prefix\nfirst\nsecond\nhuman", "journal captures actual human version")
    try Data("prefix\nfirst\nAI\nhuman\nlater".utf8).write(to: mergeFile)
    try CollaborationApplier(store: mergeStore).undo(taskID: mergeTask)
    check(try String(contentsOf: mergeFile, encoding: .utf8) == "prefix\nfirst\nsecond\nhuman\nlater", "undo preserves concurrent and later independent human changes")
    check(try String(contentsOf: mergeRoot.appendingPathComponent("other.md"), encoding: .utf8) == "unrelated", "unrelated new document does not block AI")
    do { _ = try mergeEdit.resolvedContent(base: "second second"); preconditionFailure("ambiguous old text accepted") } catch {}
    do { _ = try mergeEdit.resolvedContent(base: "missing"); preconditionFailure("missing old text accepted") } catch {}
    check(mergeFixture.capturedPrompt.contains("oldText") && mergeFixture.capturedPrompt.contains("not line numbers"), "provider contract requests exact text patches")
    let renamed = folder.appendingPathComponent("renamed project")
    try FileManager.default.moveItem(at: root, to: renamed)
    check(try CollaborationStore(project: renamed).load().tasks.count == storeCountAtRename(renamed), "project rename retains original collaboration metadata")
    print("Collaboration regression passed: \(count) assertions")
}

@MainActor private func storeCountAtRename(_ root: URL) throws -> Int {
    let data = try Data(contentsOf: root.appendingPathComponent(".협업 project.weavedata/collaboration/state.json"))
    return try JSONDecoder().decode(CollaborationDocument.self, from: data).tasks.count
}
