# 앱 구조와 책임 경계

앱은 프로젝트 단위로 원고와 창작 자료를 관리한다. 화면은 상태를 표시하고 의도를 전달하며, 서비스는 작업 순서와 상태 수명을 관리하고, 저장소와 AppKit 어댑터는 외부 시스템을 연결한다. 폴더는 이 책임을 기준으로 구분한다. 기존 저장 형식과 사용자 설정 키는 내부 코드 구조와 독립적으로 유지한다.

| 범주 | 책임과 진입점 |
|---|---|
| 앱 구성 | `TextlinkEditorApp`, `ContentView`가 시작과 창을 연결한다. `MainEditorView`는 패널 구성을, `MainEditor/AppCommandHandler`는 메뉴 명령 연결을 맡는다. |
| 프로젝트 | `Services/Project/ProjectManager`가 생성·전환·닫기를 조율한다. `ProjectPreferencesStore`는 최근 프로젝트와 bookmark 저장을 소유한다. |
| 파일 시스템 | `Services/FileSystem/FileSystemManager`는 탐색 트리의 상태를 소유한다. `WorkspaceFileCoordinator`는 디스크 작업과 문서 참여자를 조율하고 성공 이벤트를 발행한다. `DirectoryWatchRegistry`는 감시 descriptor와 취소 수명을 관리한다. |
| 문서 편집 | `Services/Editor/EditorTabManager`는 탭과 문서 초안의 상태 소유자다. `Session/EditorSessionStore`는 복구 형식을, `EditorRecoveryWriter`는 저장 순서와 완료 콜백 유효성을 담당한다. |
| 네이티브 에디터 | `Views/MainEditor/EditorPanel/TextlinkTextView/NativeManuscript*`가 입력·좌표·서식 배치·스크롤·포커스·인라인 UI를 나눈다. AppKit 입력과 서식 갱신 순서는 이 경계 안에서 유지한다. |
| AI | `Services/AI`는 인증·실행·요청 준비·대화 저장·협업 적용을 구분한다. 화면 모델은 전송 상태를 조율한다. `Chat/MultiLineInputView`는 IME와 입력을, `AIChatTranscript`는 대화 표시 경계를, `AIChatView`는 대화 화면 구성을 소유한다. |
| 설정과 명령 | `Services/Core/Preferences`는 설정 값과 표시 기본값, `Shortcuts`는 키 바인딩 모델, `Undo`는 호환 이력을 구분한다. 상태 저장은 기존 관리자, 도구 실행 등록은 `EditorToolRegistry`에 남는다. |
| 설정 화면 | `Views/SettingsView`는 탐색만 구성한다. `Views/Settings/`의 일반·에디터·AI·단축키·개발자 화면이 각 입력 상태를 소유한다. |
| 창작 자료와 버전 | `Services/Writing`, `Services/Versions`가 원고와 별도인 메타데이터·버전·Git 작업을 담당한다. `Views/Writing`, `Views/Versions`에서 표시한다. |
| 표시 자원 | `Theme`의 팔레트와 `Localization`의 키를 통해 테마·언어를 선택한다. 기능 뷰에 별도 색상 체계나 번역 저장소를 만들지 않는다. |

## 적용한 설계 원칙

- **단일 책임과 합성:** 입력 어댑터·화면 구성·저장·감시는 별도 객체로 조합한다. 관리자는 기존 호출자에게 동일한 인터페이스를 제공하는 facade로 유지한다. 파일을 나누기 위해 상태의 setter나 private 멤버를 공개하지 않는다.
- **저장소와 의존성 주입:** 문서 및 AI 저장은 기존 repository 계약으로 접근한다. 프로젝트 환경설정은 UserDefaults를 주입할 수 있어 사용자 설정을 건드리지 않고 검증한다. 구현체가 하나이고 변형 요구가 없는 모든 객체에 protocol을 추가하지 않는다.
- **명령과 이벤트:** UI 의도는 등록된 명령으로 전달한다. 파일 변경 이벤트는 성공 후 발행하며, 화면 갱신이 파일 명령을 다시 실행하지 않도록 한다. 실패를 성공 이벤트로 바꾸지 않는다.
- **자원 소유권:** 감시 객체가 descriptor와 cancel을 함께 소유한다. 복구 writer는 직렬 큐와 세대 번호를 함께 소유한다. 비동기 작업에는 불변 snapshot만 전달하고 observable 상태 변경은 메인 스레드에서 수행한다.

## 보존할 계약

원고·마지막 저장본·외부 변경을 구분한다. 프로젝트 전환 전 저장 및 취소 결정을 유지한다. 복구 저장은 명시적 저장이 이전 자동 저장보다 뒤에 완료되도록 직렬화한다. 오래된 완료 콜백은 새 프로젝트의 오류 상태를 덮어쓰지 않는다. 원고의 IME와 Undo는 실제 네이티브 입력 경로를 따른다. `UndoSystem`의 호환 구현을 현재 모든 입력의 실행 경로로 간주하지 않는다.

추가 기능은 먼저 상태 소유자와 입출력 경계를 정한다. 공통 등록부·저장소·이벤트 계약을 확장하고, 화면마다 같은 정책이나 저장 형식을 복제하지 않는다. 세부 기능 계약은 각 영역의 `claude.md`를 따른다.

## 컨테이너 수명과 레이아웃 계약

`MainEditorView`가 현재 프로젝트를 파일 트리·Git·AI에 연결하고 해제한다. 프로젝트 경로가 같으면 트리를 다시 만들지 않는다. 변경 시 이전 프로젝트의 문맥·검색·버전 sheet를 해제한다. AI 자식 화면의 생성/소멸은 프로젝트 전환이나 로그인 취소의 신호가 아니다.

`Layout/WorkspaceAIPanel`이 AI 패널 표시·드래그 수명을 소유하고, `WorkspacePanelLayout`의 같은 계산으로 표시 폭과 드래그 한계를 정한다. 사이드바·분리선·원고 최소 폭을 함께 계산한다. 창 크기 제약은 저장된 선호 폭을 덮어쓰지 않는다. 패널 숨김은 대화 컨테이너를 제거하지 않는다. 리사이즈 환경값도 이 상위 계층에서 정의해 대화 뷰가 소비한다.

`EditorFocusCoordinator`는 창별 사이드바 의도와 AppKit의 실제 first responder를 함께 검사한다. 비동기 문서 로딩은 AI 입력, 파일 이름 입력, 검색/툴바 입력의 포커스를 가져오지 않는다. 문서 선택 정보의 발행과 first responder 변경은 별개다.

버그 보정의 제거 여부는 그 보정이 지키는 계약으로 결정한다. SwiftUI 갱신 이후 네이티브 배치, 문서 ID/리비전 검사, 저장 debounce, 서식 배치 후 커서 갱신은 각각 필요한 경계이므로 유지한다. 검색 UI의 추가 main-queue 지연은 제거하고, 문서 ID를 검증하는 네이티브 command adapter의 지연 경계로 모았다. 툴바의 창 컨트롤 여백과 AI 입력창 겹침은 시각 계약으로 유지하며 임의로 삭제하지 않는다.

`workspace_container_regression.py`는 패널 폭 예산과 숨김/복원 시 콘텐츠 인스턴스 보존을 실제 SwiftUI 호스팅으로 검사한다. `native_cursor_regression.py`는 창별 포커스와 AI/field editor 포커스 보호를 검사한다. 실제 앱 전체의 수동 UI 검증과 구별한다.
