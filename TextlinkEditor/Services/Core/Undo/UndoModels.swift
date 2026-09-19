import Foundation

// MARK: - Work Area (작업 영역 식별)

/// 앱 내 작업 영역 식별자
/// 새로운 텍스트 입력 영역이 추가될 때 여기에 케이스 추가
enum WorkArea: String, Hashable {
    case editor = "editor"
    case aiChat = "aiChat"
    // 추후 확장 예시:
    // case settings = "settings"
    // case notepad = "notepad"
}

// MARK: - Text Character Type (문자 타입)

/// 문자 종류 (그룹화 경계 판단용)
///
/// 연속 타이핑 시 같은 타입의 문자는 하나의 Undo 단위로 그룹화됨.
/// 타입이 바뀌면 새 그룹이 시작됨.
enum TextCharType: Equatable {
    /// 영문/숫자
    case alphanumeric
    /// 한글
    case korean
    /// 일본어 히라가나
    case hiragana
    /// 일본어 카타카나
    case katakana
    /// 일본어 한자 (CJK 통합 한자)
    case kanji
    /// 중국어 간체/번체
    case chinese
    /// 공백
    case whitespace
    /// 줄바꿈
    case newline
    /// 특수문자/구두점
    case punctuation
    /// 기타
    case other

    /// 문자로부터 타입 결정
    static func from(_ char: Character) -> TextCharType {
        if char.isNewline {
            return .newline
        }
        if char.isWhitespace {
            return .whitespace
        }
        if char.isPunctuation || char.isSymbol {
            return .punctuation
        }

        // 유니코드 스칼라로 범위 확인
        guard let scalar = char.unicodeScalars.first else {
            return .other
        }

        let value = scalar.value

        // 한글 범위
        if (0xAC00...0xD7AF).contains(value) ||  // 한글 음절
           (0x1100...0x11FF).contains(value) ||  // 한글 자모
           (0x3130...0x318F).contains(value) {   // 호환용 한글 자모
            return .korean
        }

        // 일본어 히라가나
        if (0x3040...0x309F).contains(value) {
            return .hiragana
        }

        // 일본어 카타카나
        if (0x30A0...0x30FF).contains(value) ||
           (0x31F0...0x31FF).contains(value) {  // 카타카나 확장
            return .katakana
        }

        // CJK 통합 한자 (일본어 한자 + 중국어)
        if (0x4E00...0x9FFF).contains(value) ||   // CJK 통합 한자
           (0x3400...0x4DBF).contains(value) ||   // CJK 통합 한자 확장 A
           (0x20000...0x2A6DF).contains(value) {  // CJK 통합 한자 확장 B
            return .kanji
        }

        // 영문/숫자
        if char.isLetter || char.isNumber {
            return .alphanumeric
        }

        return .other
    }

    /// 같은 그룹으로 묶을 수 있는지 확인
    func canGroupWith(_ other: TextCharType) -> Bool {
        // 줄바꿈, 공백, 구두점은 항상 그룹 경계
        if self == .newline || other == .newline { return false }
        if self == .whitespace || other == .whitespace { return false }
        if self == .punctuation || other == .punctuation { return false }

        // 같은 타입끼리만 그룹화
        return self == other
    }
}

// MARK: - Text Undo Action (텍스트 Undo 액션)

/// 텍스트 편집 Undo 액션 타입
enum TextUndoAction {
    /// 텍스트 대체 (삽입, 삭제, 대체 모두 처리 가능)
    case replaceText(
        range: NSRange,
        oldText: String,
        newText: String,
        oldSelectedRange: NSRange,
        newSelectedRange: NSRange
    )
}

// MARK: - Text Pending Group (연속 타이핑 그룹)

/// 연속 타이핑 그룹화를 위한 대기 중인 텍스트 그룹
struct TextPendingGroup {
    /// 시작 위치
    let startLocation: Int
    /// 현재 끝 위치
    var endLocation: Int
    /// 누적된 텍스트
    var insertedText: String
    /// 마지막 문자 타입 (그룹화 판단용)
    var lastCharacterType: TextCharType
    /// 그룹 시작 전 선택 범위
    let originalSelectedRange: NSRange
}
