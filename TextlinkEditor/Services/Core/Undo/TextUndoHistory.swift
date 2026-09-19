import Foundation

// MARK: - Text Undo History (텍스트 Undo 히스토리)

/// 텍스트 입력 영역의 Undo/Redo 히스토리 관리
/// 연속 타이핑 그룹화, 문자 타입 경계 감지 포함
final class TextUndoHistory {
    /// 작업 영역 식별자
    let workArea: WorkArea

    /// Undo 스택
    private var undoStack: [TextUndoAction] = []

    /// Redo 스택
    private var redoStack: [TextUndoAction] = []

    /// 최대 히스토리 크기
    private let maxHistorySize: Int

    /// 현재 그룹화 중인 텍스트 입력
    private var pendingTextGroup: TextPendingGroup?

    /// 텍스트 적용 클로저
    private let applyText: (String, NSRange, NSRange) -> Void

    /// Undo 가능 여부
    var canUndo: Bool { !undoStack.isEmpty || pendingTextGroup != nil }

    /// Redo 가능 여부
    var canRedo: Bool { !redoStack.isEmpty }

    /// 현재 Undo 스택 크기
    var undoCount: Int { undoStack.count }

    /// 현재 Redo 스택 크기
    var redoCount: Int { redoStack.count }

    /// 초기화
    /// - Parameters:
    ///   - workArea: 작업 영역 식별자
    ///   - maxHistorySize: 최대 히스토리 크기 (기본 1000)
    ///   - applyText: 텍스트 적용 클로저 (text, range, newSelectedRange)
    init(
        workArea: WorkArea,
        maxHistorySize: Int = 1000,
        applyText: @escaping (String, NSRange, NSRange) -> Void
    ) {
        self.workArea = workArea
        self.maxHistorySize = maxHistorySize
        self.applyText = applyText
    }

    // MARK: - Text Input Grouping

    /// 텍스트 입력을 그룹에 추가 (연속 타이핑 그룹화)
    /// - Parameters:
    ///   - text: 입력된 텍스트
    ///   - location: 입력 위치
    ///   - originalSelectedRange: 입력 전 선택 범위
    func addTextInput(_ text: String, at location: Int, originalSelectedRange: NSRange) {
        guard let firstChar = text.first else { return }
        let charType = TextCharType.from(firstChar)

        // 기존 그룹이 있고, 같은 타입이며, 연속된 위치라면 그룹에 추가
        if var group = pendingTextGroup,
           group.lastCharacterType.canGroupWith(charType),
           group.endLocation == location {
            group.insertedText += text
            group.endLocation = location + text.count
            group.lastCharacterType = TextCharType.from(text.last ?? firstChar)
            pendingTextGroup = group
        } else {
            // 기존 그룹 커밋 후 새 그룹 시작
            commitPendingTextGroup()

            pendingTextGroup = TextPendingGroup(
                startLocation: location,
                endLocation: location + text.count,
                insertedText: text,
                lastCharacterType: TextCharType.from(text.last ?? firstChar),
                originalSelectedRange: originalSelectedRange
            )
        }

        redoStack.removeAll()
    }

    /// 삭제 작업 기록
    /// - Parameters:
    ///   - range: 삭제된 범위
    ///   - deletedText: 삭제된 텍스트
    ///   - newSelectedRange: 삭제 후 선택 범위
    func recordDeletion(range: NSRange, deletedText: String, newSelectedRange: NSRange) {
        // 대기 중인 그룹 커밋
        commitPendingTextGroup()

        let action = TextUndoAction.replaceText(
            range: NSRange(location: range.location, length: 0),  // 삭제 후 범위
            oldText: deletedText,
            newText: "",
            oldSelectedRange: range,
            newSelectedRange: newSelectedRange
        )
        pushAction(action)
    }

    /// 대체 작업 기록
    /// - Parameters:
    ///   - range: 대체된 범위
    ///   - oldText: 이전 텍스트
    ///   - newText: 새 텍스트
    ///   - newSelectedRange: 대체 후 선택 범위
    func recordReplacement(range: NSRange, oldText: String, newText: String, newSelectedRange: NSRange) {
        // 대기 중인 그룹 커밋
        commitPendingTextGroup()

        let action = TextUndoAction.replaceText(
            range: NSRange(location: range.location, length: newText.count),
            oldText: oldText,
            newText: newText,
            oldSelectedRange: range,
            newSelectedRange: newSelectedRange
        )
        pushAction(action)
    }

    /// 대기 중인 텍스트 그룹을 Undo 스택에 커밋
    func commitPendingTextGroup() {
        guard let group = pendingTextGroup else { return }

        let action = TextUndoAction.replaceText(
            range: NSRange(location: group.startLocation, length: group.insertedText.count),
            oldText: "",
            newText: group.insertedText,
            oldSelectedRange: group.originalSelectedRange,
            newSelectedRange: NSRange(location: group.endLocation, length: 0)
        )

        undoStack.append(action)
        pendingTextGroup = nil

        trimStackIfNeeded()

        #if DEBUG
        print("[TextUndoHistory:\(workArea.rawValue)] 그룹 커밋: \(group.insertedText.count)자")
        #endif
    }

    // MARK: - Undo/Redo

    /// Undo 실행
    @discardableResult
    func undo() -> Bool {
        // 대기 중인 그룹이 있으면 먼저 커밋
        commitPendingTextGroup()

        guard let action = undoStack.popLast() else {
            #if DEBUG
            print("[TextUndoHistory:\(workArea.rawValue)] Undo 실패: 스택이 비어있음")
            #endif
            return false
        }

        applyUndoAction(action, isRedo: false)

        #if DEBUG
        print("[TextUndoHistory:\(workArea.rawValue)] Undo 실행")
        #endif

        return true
    }

    /// Redo 실행
    @discardableResult
    func redo() -> Bool {
        // 대기 중인 그룹이 있으면 먼저 커밋
        commitPendingTextGroup()

        guard let action = redoStack.popLast() else {
            #if DEBUG
            print("[TextUndoHistory:\(workArea.rawValue)] Redo 실패: 스택이 비어있음")
            #endif
            return false
        }

        applyUndoAction(action, isRedo: true)

        #if DEBUG
        print("[TextUndoHistory:\(workArea.rawValue)] Redo 실행")
        #endif

        return true
    }

    /// 히스토리 전체 클리어
    func clear() {
        pendingTextGroup = nil
        undoStack.removeAll()
        redoStack.removeAll()

        #if DEBUG
        print("[TextUndoHistory:\(workArea.rawValue)] 히스토리 클리어")
        #endif
    }

    // MARK: - Private

    private func pushAction(_ action: TextUndoAction) {
        undoStack.append(action)
        redoStack.removeAll()
        trimStackIfNeeded()
    }

    private func trimStackIfNeeded() {
        while undoStack.count > maxHistorySize {
            undoStack.removeFirst()
        }
    }

    private func applyUndoAction(_ action: TextUndoAction, isRedo: Bool) {
        switch action {
        case .replaceText(let range, let oldText, let newText, let oldSelectedRange, let newSelectedRange):
            #if DEBUG
            print("[TextUndoHistory] applyUndoAction isRedo=\(isRedo)")
            print("  range=\(range), oldText='\(oldText)', newText='\(newText)'")
            print("  oldSelectedRange=\(oldSelectedRange), newSelectedRange=\(newSelectedRange)")
            #endif

            if isRedo {
                // Redo: 원래 작업을 다시 실행
                // - 삽입 작업: oldText="" → newText="입력텍스트" (텍스트 삽입)
                // - 삭제 작업: oldText="삭제텍스트" → newText="" (텍스트 삭제)
                let deleteRange = NSRange(location: range.location, length: oldText.count)
                applyText(newText, deleteRange, newSelectedRange)

                #if DEBUG
                print("  [Redo] deleteRange=\(deleteRange), inserting '\(newText)'")
                #endif

                // 원래 액션을 Undo 스택에 다시 추가 (역액션 아님!)
                undoStack.append(action)
            } else {
                // Undo: newText를 삭제하고 oldText를 복원
                let deleteRange = NSRange(location: range.location, length: newText.count)
                applyText(oldText, deleteRange, oldSelectedRange)

                #if DEBUG
                print("  [Undo] deleteRange=\(deleteRange), inserting '\(oldText)'")
                #endif

                // 원래 액션을 Redo 스택에 추가 (역액션 아님!)
                redoStack.append(action)
            }
        }
    }
}
