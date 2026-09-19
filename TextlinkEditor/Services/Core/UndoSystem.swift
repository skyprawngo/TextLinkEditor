//
//  UndoSystem.swift
//  TextlinkEditor
//
//  표준화된 Undo/Redo 시스템
//  모든 텍스트 입력 영역에서 동일한 인터페이스로 사용 가능
//
//  주요 기능:
//  - 연속 타이핑 그룹화 (동일 타입 문자를 하나의 Undo 단위로)
//  - 문자 타입 경계 감지 (한글, 영문, 일본어 등 구분)
//  - 작업 영역별 독립 히스토리
//

import Foundation

// MARK: - Text Undo History Manager (중앙 관리자)

/// 앱 전체의 텍스트 Undo 히스토리를 중앙에서 관리
final class TextUndoHistoryManager {
    static let shared = TextUndoHistoryManager()

    /// 작업 영역별 히스토리 저장소
    private var histories: [WorkArea: TextUndoHistory] = [:]

    /// 현재 포커스된 작업 영역
    private(set) var focusedArea: WorkArea?

    private init() {}

    // MARK: - History Management

    /// 작업 영역에 대한 TextUndoHistory 생성 및 등록
    /// - Parameters:
    ///   - workArea: 작업 영역
    ///   - maxHistorySize: 최대 히스토리 크기
    ///   - applyText: 텍스트 적용 클로저
    /// - Returns: 생성된 TextUndoHistory
    @discardableResult
    func createHistory(
        for workArea: WorkArea,
        maxHistorySize: Int = 1000,
        applyText: @escaping (String, NSRange, NSRange) -> Void
    ) -> TextUndoHistory {
        let history = TextUndoHistory(
            workArea: workArea,
            maxHistorySize: maxHistorySize,
            applyText: applyText
        )
        histories[workArea] = history

        #if DEBUG
        print("[TextUndoHistoryManager] 히스토리 생성: \(workArea.rawValue)")
        #endif

        return history
    }

    /// 작업 영역의 TextUndoHistory 가져오기
    func getHistory(for workArea: WorkArea) -> TextUndoHistory? {
        histories[workArea]
    }

    /// 작업 영역의 히스토리 제거
    func removeHistory(for workArea: WorkArea) {
        histories.removeValue(forKey: workArea)

        #if DEBUG
        print("[TextUndoHistoryManager] 히스토리 제거: \(workArea.rawValue)")
        #endif
    }

    // MARK: - Focus Management

    /// 포커스된 작업 영역 설정
    func setFocusedArea(_ area: WorkArea?) {
        // 이전 영역의 대기 그룹 커밋
        if let previousArea = focusedArea, previousArea != area {
            histories[previousArea]?.commitPendingTextGroup()
        }

        focusedArea = area

        #if DEBUG
        if let area = area {
            print("[TextUndoHistoryManager] 포커스 변경: \(area.rawValue)")
        } else {
            print("[TextUndoHistoryManager] 포커스 해제")
        }
        #endif
    }

    /// 현재 포커스된 영역의 히스토리
    var focusedHistory: TextUndoHistory? {
        guard let area = focusedArea else { return nil }
        return histories[area]
    }

    /// 현재 포커스된 영역에서 Undo 가능 여부
    var canUndo: Bool {
        focusedHistory?.canUndo ?? false
    }

    /// 현재 포커스된 영역에서 Redo 가능 여부
    var canRedo: Bool {
        focusedHistory?.canRedo ?? false
    }

    /// 현재 포커스된 영역에서 Undo 실행
    @discardableResult
    func undo() -> Bool {
        focusedHistory?.undo() ?? false
    }

    /// 현재 포커스된 영역에서 Redo 실행
    @discardableResult
    func redo() -> Bool {
        focusedHistory?.redo() ?? false
    }

    // MARK: - Convenience

    /// 모든 히스토리 클리어
    func clearAllHistories() {
        histories.values.forEach { $0.clear() }
        histories.removeAll()

        #if DEBUG
        print("[TextUndoHistoryManager] 모든 히스토리 클리어")
        #endif
    }

    /// 등록된 작업 영역 목록
    var registeredAreas: [WorkArea] {
        Array(histories.keys)
    }
}

// MARK: - Protocol for Undo Capable Views

/// Undo 기능을 지원하는 뷰 프로토콜
protocol TextUndoCapable: AnyObject {
    var textUndoHistory: TextUndoHistory? { get }
    func applyUndoText(_ text: String, in range: NSRange, selectRange: NSRange)
}
