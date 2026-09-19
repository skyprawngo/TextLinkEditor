# 전역 상태와 AppKit 연동

- `UserSettings.swift`: UserDefaults 기반 전역 설정과 CLI 경로 문자열. 에디터의 프로젝트별 설정은 `EditorTabManager`에도 있으므로 저장 범위를 구별한다.
- `PermissionManager.swift`: 디렉토리 접근 권한. 프로젝트 접근 수명은 `ProjectManager`의 bookmark 처리와 함께 확인한다.
- `KeyboardShortcutManager.swift`와 `AppCommands.swift`: 사용자 단축키 정의·저장 및 메뉴 동작 연결. 사용자 변경이 가능한 액션은 뷰의 고정 키로 우회하지 않는다. 저장 파일은 `~/Library/Application Support/TextlinkEditor/shortcuts.json`이다.
- `ThemeManager.swift`, `WindowStateManager.swift`: 테마 적용과 창 상태. 색상 계약은 [Theme](../../Theme/claude.md)에 있다.
- `AlertHelper.swift`: `beginSheetModalWithArrowNavigation`으로 시트의 화살표 탐색을 제공한다. 기존 파일 작업 다이얼로그와 일관된 키보드 동작을 유지한다.

## 에디터 도구 등록

새 에디터 도구는 `EditorToolRegistry.swift`의 `tool(id, titleKey, category, impact, key, modifiers, operation)`으로 정의한다. 안정적인 ID, 번역 키, 영향 범위와 실행 처리가 한 선언에 속한다. 기본 키를 생략해도 `KeyboardShortcutManager`가 설정 행을 생성한다. 설정 화면의 별도 목록·액션 enum·기본 바인딩 배열에 새 도구를 중복 추가하지 않는다. 확장 등록은 `register`로 가능하며 중복 ID를 거부한다.

툴바와 메뉴는 `.tool(id)`를 전달하고, 키보드는 같은 등록부를 조회한다. 실제 원고 실행은 `EditorToolTarget.runTool`과 `EditorToolBridge`를 거쳐 IME·읽기 전용·시작/종료 처리를 공유한다. 매개변수가 필요한 글꼴·크기·줄간격·자간 도구는 해당 컨트롤을 열고, 값 변경의 배치는 기존 `applyDisplayStyle` 트랜잭션이 담당한다. 툴의 새로운 능력이 필요하면 target 인터페이스를 확장하되 설정 행 생성 로직은 변경하지 않는다.

단축키 JSON의 액션은 기존 문자열 ID 형식을 유지한다. 알 수 없는 ID도 보존하며, 새 기본 키가 기존 사용자 키와 충돌하면 새 도구를 미지정 상태로 병합한다. 미지정·단축키 비활성화는 툴바 실행을 금지하지 않는다. `tests/shortcut_regression.py`와 `tests/tool_registry_regression.py`는 임시 설정 파일로 등록·병합·키 변경·실제 원고 실행을 함께 검증한다.

## Undo 소유권

현재 네이티브 원고는 `NativeManuscriptTextView`의 AppKit UndoManager를 사용한다. 비교용 이전 엔진의 `EditorState` 이력은 별도 경로다. AI 입력은 `MultiLineInputView`의 `NSTextView` 기본 UndoManager를 사용하며, 외부에서 입력 내용을 바꿀 때 이력을 초기화한다. 남아 있는 `UndoSystem.swift`를 현재 AI 입력의 실행 경로로 가정하지 않는다.

Edit 메뉴의 `undo:`/`redo:`가 실제 first responder에 도달해야 한다. 조합 중 IME 처리와 편집 알림을 통해 화면·binding·전송 문자열이 함께 갱신되는지도 확인한다. 원고 Undo의 액션 표현은 [Editor](../Editor/claude.md)와 텍스트 엔진에 있다.

설정 값 모델과 표시 기본값은 `Preferences/`, 단축키 값 모델은 `Shortcuts/ShortcutModels.swift`에 둔다. `UserSettings`와 `KeyboardShortcutManager`가 기존 저장 도메인과 마이그레이션을 계속 소유한다. 호환 Undo의 값 모델·텍스트 이력·일반 상태 이력은 `Undo/`에, 영역별 이력 선택은 `UndoSystem.swift`에 있다.

내장 도구의 문자열 ID는 `EditorToolID`가 정의한다. 선택이 필요한 도구는 definition의 `requiresSelection`에 선언하고, 메뉴 요청은 `EditorToolRegistry.requestExecution`을 사용한다. 실행 수명은 began → validated → applied → 배치 완료(필요 시) → ended이며, 전달 성공과 실행 결과를 구분한다. 전체 호출 경계는 `docs/tool-execution.md`를 참고한다.
