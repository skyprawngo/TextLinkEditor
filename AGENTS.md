# TextlinkEditor 작업 맥락

TextlinkEditor는 `.weaveproj` 폴더 안에 원고와 창작 자료를 저장하는 macOS 앱이다. SwiftUI 화면과 AppKit 네이티브 원고 에디터를 사용한다. 이전 Core Text 엔진은 회귀 비교용으로 남아 있다. 앱 타깃의 최소 OS는 macOS 26.0이며, 실제 빌드 설정은 `TextlinkEditor.xcodeproj/project.pbxproj`가 기준이다.

앱 전체의 책임 분류와 의존성 경계는 [구조 문서](docs/architecture.md)에 있다.

## 기능별 진입점

필요한 영역의 맥락만 읽는다. 하위 `claude.md`는 도구와 무관한 영역별 참조 문서다.

| 작업 | 진입점과 맥락 |
|---|---|
| 앱 시작·프로젝트 전환 | `TextlinkEditor/TextlinkEditorApp.swift`, [Project](TextlinkEditor/Services/Project/claude.md) |
| 파일 탐색·이동·외부 변경 | [FileSystem](TextlinkEditor/Services/FileSystem/claude.md) |
| 탭·저장·원고 편집 | [Editor](TextlinkEditor/Services/Editor/claude.md), [TextEngine](TextlinkEditor/Services/Editor/TextEngine/claude.md) |
| CLI 연결·AI 대화·문맥 | [AI](TextlinkEditor/Services/AI/claude.md) |
| 권한·설정·단축키·Undo | [Core](TextlinkEditor/Services/Core/claude.md) |
| 화면 구조·AppKit 연동 | [Views](TextlinkEditor/Views/claude.md) |
| 테마·번역 | [Theme](TextlinkEditor/Theme/claude.md), [Localization](TextlinkEditor/Localization/claude.md) |

## 변경 시 중요한 경계

- 원고 파일과 `.{프로젝트명}.weavedata`의 메타데이터는 별도 저장 경로다. 프로젝트 이름·경로 변경은 설정, 탭 복원, AI 기록 경로까지 영향을 준다.
- 편집 중 텍스트, 마지막 저장본, 디스크의 외부 변경을 구별한다. 파일 이동·프로젝트 전환은 열린 탭과 저장되지 않은 텍스트의 소유 URL에도 영향을 준다.
- 한글·일본어 IME 조합은 일반 문자열 치환과 다르다. 입력·탭 전환·Undo 수정은 조합 상태와 AppKit responder chain을 함께 살핀다.
- AI의 앱 UI, 프롬프트 템플릿, 외부 CLI 실행은 별도 계층이다. UI에 제공자 이름이 있다는 사실은 설치·인증·응답 호환성의 증거가 아니다.

새 에디터 도구는 `TextlinkEditor/Services/Core/EditorToolRegistry.swift`의 공통 등록부에 실행 처리와 메타데이터를 함께 선언한다. 설정 단축키 목록이나 개별 뷰에 고정 키를 따로 추가하지 않는다. 등록과 실행 경계는 [Core](TextlinkEditor/Services/Core/claude.md)에 있다.

## 검증과 문서

2026-09-11의 검토보고서 두 개와 체크리스트는 해당 시점의 기록이며 현재 코드의 완료 증거가 아니다. 변경 영역에 맞는 검증을 선택하고 정적 확인, 빌드, 실제 앱 동작을 구분한다. 원고 저장·IME·외부 CLI의 동작은 소스 확인만으로 입증되지 않는다.

저장·복구는 `tests/storage_regression.py`, 텍스트 연산은 `tests/text_engine_regression.py`, 문서 전환과 binding은 `tests/editor_binding_regression.py`, 단축키는 `tests/shortcut_regression.py`, AI 실행·기록은 `tests/ai/run.sh`가 검증 진입점이다. 임시 원고와 fixture를 사용하며 실제 사용자 원고·CLI 계정에서의 성공과 구분한다.

문서는 의사결정에 필요한 저장 형식, 상태 소유권, 연동 경계와 코드 진입점을 유지한다. 코드에서 바로 읽을 수 있는 API 목록이나 모든 작업에 적용하는 고정 절차는 늘리지 않는다. 프로젝트 내부 전용 `SKILL.md`는 현재 없으며 사용자 전역 스킬과 `.claude/settings.local.json`의 실행 권한은 이 문서의 범위가 아니다.
