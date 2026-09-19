import Foundation

// MARK: - Generic Undo Support (제네릭 Undo - 비텍스트 용)

/// Undo 가능한 작업 단위 (제네릭 버전 - 비텍스트 용)
/// 제네릭을 사용하여 다양한 타입의 상태를 저장 가능
struct GenericUndoAction<State> {
    /// 작업 설명 (디버깅/UI 표시용)
    let description: String

    /// 작업 시점의 타임스탬프
    let timestamp: Date

    /// Undo 시 복원할 상태
    let undoState: State

    /// Redo 시 복원할 상태
    let redoState: State

    init(description: String, undoState: State, redoState: State) {
        self.description = description
        self.timestamp = Date()
        self.undoState = undoState
        self.redoState = redoState
    }
}

/// 특정 작업 영역의 Undo/Redo 히스토리 관리 (제네릭 버전 - 비텍스트 용)
/// 제네릭 State를 사용하여 다양한 상태 타입 지원
final class GenericUndoHistory<State> {
    /// 작업 영역 식별자
    let workArea: WorkArea

    /// Undo 스택
    private var undoStack: [GenericUndoAction<State>] = []

    /// Redo 스택
    private var redoStack: [GenericUndoAction<State>] = []

    /// 최대 히스토리 크기 (메모리 관리)
    private let maxHistorySize: Int

    /// 상태 복원 클로저
    private let restoreState: (State) -> Void

    /// Undo 가능 여부
    var canUndo: Bool { !undoStack.isEmpty }

    /// Redo 가능 여부
    var canRedo: Bool { !redoStack.isEmpty }

    /// 현재 Undo 스택 크기
    var undoCount: Int { undoStack.count }

    /// 현재 Redo 스택 크기
    var redoCount: Int { redoStack.count }

    init(workArea: WorkArea, maxHistorySize: Int = 100, restoreState: @escaping (State) -> Void) {
        self.workArea = workArea
        self.maxHistorySize = maxHistorySize
        self.restoreState = restoreState
    }

    // MARK: - Public API

    /// 새로운 작업 등록
    func registerAction(description: String, undoState: State, redoState: State) {
        let action = GenericUndoAction(description: description, undoState: undoState, redoState: redoState)
        undoStack.append(action)
        redoStack.removeAll()

        if undoStack.count > maxHistorySize {
            undoStack.removeFirst(undoStack.count - maxHistorySize)
        }

        #if DEBUG
        print("[GenericUndoHistory:\(workArea.rawValue)] 작업 등록: \(description), 스택 크기: \(undoStack.count)")
        #endif
    }

    /// Undo 실행
    @discardableResult
    func undo() -> Bool {
        guard let action = undoStack.popLast() else {
            return false
        }
        restoreState(action.undoState)
        redoStack.append(action)
        return true
    }

    /// Redo 실행
    @discardableResult
    func redo() -> Bool {
        guard let action = redoStack.popLast() else {
            return false
        }
        restoreState(action.redoState)
        undoStack.append(action)
        return true
    }

    /// 히스토리 전체 클리어
    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// 마지막 Undo 작업 설명 가져오기
    var lastUndoDescription: String? {
        undoStack.last?.description
    }

    /// 마지막 Redo 작업 설명 가져오기
    var lastRedoDescription: String? {
        redoStack.last?.description
    }
}

/// GenericUndoHistory를 GenericUndoCapable로 확장
protocol GenericUndoCapable {
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func performUndo() -> Bool
    func performRedo() -> Bool
    func clearHistory()
}

extension GenericUndoHistory: GenericUndoCapable {
    func performUndo() -> Bool {
        undo()
    }

    func performRedo() -> Bool {
        redo()
    }

    func clearHistory() {
        clear()
    }
}
