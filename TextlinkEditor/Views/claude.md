# 화면과 입력 연결

`MainEditorView.swift`가 프로젝트 탐색, 탭, 에디터, AI 패널을 연결한다. 종속 뷰는 `MainEditor/`에 있으며 시작·설정·약관은 `WelcomeView`, `SettingsView`, `TermsOfServiceView`에서 찾는다.

원고 화면은 `EditorContainerView` → `EditorPanel/TextlinkTextView/TextlinkEditorRepresentable` → `NativeManuscriptHost`/`NativeManuscriptTextView`로 이어진다. NSTextView가 입력과 레이아웃을 담당하고 NSRulerView가 줄 번호를 표시한다.

AppKit 입력의 IME 조합 중 문자열 전체 교체는 조합을 깨뜨릴 수 있다. `hasMarkedText`, 조합 확정/취소, first responder와 SwiftUI binding의 갱신 순서를 함께 확인한다. 메뉴 키 동작은 [Core](../Services/Core/claude.md)의 단축키와 responder 경로를 따른다.

색상은 `AppColors`, 투명/불투명 배경은 `ThemeAwareBackground`의 기존 경로를 사용한다. Liquid Glass 사용 가능 여부는 앱 타깃 macOS 26.0 설정과 연결된다. 고정 UI 치수 목록보다 변경 주변 화면의 현재 컴포넌트를 기준으로 맞춘다.

집필 자료 메뉴는 `Writing/WritingWorkspaceView.swift`의 장면·설정 자료·내보내기와 `Versions/ManuscriptVersionsView.swift`의 버전 목록으로 연결된다. `Services/Writing/WritingWorkspaceStore.swift`가 원고와 별도인 장면 순서·시점·등장인물·목표·공개 시점 메타데이터를 소유한다. 삭제는 자료 항목만 제거하며 원고 파일은 유지한다. 집중 모드는 탐색·AI 패널과 서식 툴바를 숨긴다.

프로젝트 검색의 바꾸기 버튼은 `MainEditor/ProjectReplaceView.swift`를 연다. AI 첨부의 명시적 참조 화면과 응답의 수정 비교 화면은 각각 `AIAssistant/Context/`, `AIAssistant/Revision/`에 있다.

AI 대화의 스크롤 영역과 입력 프레임은 `AIChatView`의 별도 수직 영역이다. 두 영역 사이에는 -24pt 간격을 두어 입력창 상단 뒤로만 대화가 12pt 겹친다. 입력창은 위에 그리며, 대화 영역이 입력창 하단 여백까지 확장되지 않도록 한다. `AITranscriptScrollView.swift`는 읽기 전용 AppKit 대화 본문과 메시지 액션을 담당하며, 폭 변경 때 attributed text를 다시 생성하지 않는다. 원고의 TextKit 2 엔진과 달리 이 대화 뷰는 `NSLayoutManager`를 사용한다. `TranscriptScrollView`가 입력창 바로 위 문자의 UTF-16 위치와 하단 거리로 resize 앵커를 유지하고, 한 run-loop의 변경을 모아 SwiftUI 레이아웃 이후 복원한다. 패널 드래그 상태는 `aiPanelIsResizing` 환경값으로 전달한다. `tests/ai_transcript_regression.py`에서 재배치 중 동일 문자 위치, 입력 프레임과의 영역 분리, 선택·수정안 액션과 유휴 상태를 검증한다.
