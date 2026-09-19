# UI 명령과 실행 경계 점검

## 에디터 도구

등록된 문서 도구는 `EditorToolRegistry`가 ID·표시 이름·분류·단축키·선택 요구조건·실행 처리를 함께 소유한다. 내장 ID는 `EditorToolID`로 고정하며 저장되는 문자열 값은 유지한다. 확장 도구는 기존 문자열 등록 API를 사용한다.

| 진입점 | 실행 경로 |
|---|---|
| 서식 툴바 | `EditorToolID.rawValue` → `onToolAction` → `EditorCommand.tool` |
| AI 도구 메뉴 | 등록부의 definition ID → `EditorCommand.tool` |
| 앱 서식 메뉴 | `requestExecution`의 ID 검증 → 활성 `EditorContainerView` → `EditorCommand.tool` |
| 사용자 단축키 | `KeyboardShortcutManager`의 저장된 action ID → 등록부 조회 → native target |
| 네이티브 원고 | `EditorToolRegistry.perform` → `NativeManuscriptTextView.runTool` → `EditorToolBridge` |

공통 수명은 **began → validated → applied → viewportLaidOut(배치 변경 시) → ended**다. 검증에서 거부되면 began → ended(cancelled), 변화가 없으면 applied → ended(unchanged)로 끝난다. 이벤트는 같은 UUID로 연결되고 원고 내용은 포함하지 않는다. 옵저버는 관찰용이며 그 안에서 재진입한 작업은 취소된다. 문서 교체·뷰 분리 시 대기하던 배치 완료는 취소된다.

서식 변경·선택 첨부·선택 코멘트는 선택 요구조건을 등록부에서 선언한다. 표시 컨트롤을 받을 UI가 없거나 읽기 전용 상태에서 인라인 편집을 열려고 하면 실행을 취소한다. `perform`의 Bool은 ID 인식 여부이며 작업 성공 여부는 이벤트 outcome으로 구별한다.

## AI 요청 전달

`aiDraftAction`은 메인 화면이 한 번 수신하여 프로젝트 문맥을 맞추고 `prepareDraftAction`을 호출한 뒤 AI 패널을 표시한다. 패널 생성 후 같은 알림을 재전송하거나 AI 컨테이너가 중복 수신하지 않는다. 초안 준비와 실제 요청 전송은 별도 사용자 동작이다.

전송은 `AIAssistantViewModel` → 요청 준비 → 주입된 `AIRequestExecuting`으로 이어진다. 스트림·완료는 요청 ID와 프로젝트를 확인하고, 취소는 ID를 무효화한 뒤 실행기를 취소한다. 협업 적용은 `CollaborationCoordinator`와 적용 저장소가 기준본·변경 제안·승인 및 실패를 관리한다. UI 도구의 전달 완료를 외부 AI 실행 완료로 간주하지 않는다.

## 다른 기능의 명령 경계

| 기능 | 진입·중간 검증·종료 소유자 |
|---|---|
| 파일 생성·이동·이름 변경·삭제 | Sidebar/Tab UI → FileSystemManager → WorkspaceFileCoordinator의 문서 참여자 → repository I/O → 성공 이벤트와 트리/탭 갱신. 오류는 operationError로 전달한다. |
| 프로젝트 전환 | ProjectManager가 목적지 검증, 기존 문서 닫기 합의, 세션 저장, 접근 권한 전환, 새 세션 복원을 조율한다. |
| 저장·복구 | EditorTabManager가 초안/기준본을 소유하고 repository가 충돌을 확인한다. EditorRecoveryWriter는 순서와 오래된 완료 콜백 무효화를 소유한다. |
| 찾기·바꾸기 | 입력값을 포함한 EditorCommand가 원고로 전달되며 동일한 EditorToolBridge 검증·배치·종료 경로를 사용한다. |
| 글꼴 등 값 변경 | 도구 ID는 컨트롤을 열고, 선택된 값은 EditorAppearanceStore를 거쳐 applyDisplayStyle의 배치 트랜잭션으로 전달된다. |
| Undo·복사·붙여넣기 | AppKit responder chain이 현재 포커스의 입력 객체를 호출한다. 원고·AI 입력·이름 입력의 대상을 전역 도구로 고정하지 않는다. |
| 버전·집필 자료·설정 | 각 도메인의 값/저장 API를 호출한다. 원고 실행 대상이 필요 없는 동작을 EditorToolRegistry에 등록하지 않는다. |

툴 ID는 원고 도구의 공통 주소이며 앱의 모든 함수에 강제하는 서비스 로케이터가 아니다. 파라미터가 있는 도메인 명령과 responder 동작은 각자의 타입·상태 소유권을 유지한다.

## 이번 수정과 검증 범위

문자열 조합으로 만들던 툴바 ID를 고정 ID로 교체하고, 메뉴 요청의 등록 여부 검증을 공통화했다. 선택이 없거나 표시 수신자가 없는 도구를 적용 성공으로 기록하던 경로를 차단했다. 검증 완료 이벤트를 추가하고 AI 요청의 수신자를 단일화했다.

`tool_registry_regression.py`는 모든 내장 ID의 등록 및 단일 전달, 알 수 없는 ID 거부, 필수 선택/수신자 부재, 사용자 단축키와 실제 원고 실행을 검증한다. `editor_tool_regression.py`는 동일 작업 ID의 수명, 읽기 전용·재진입·문서 전환·뷰 분리 취소를 검증한다. 이 검사는 실제 사용자 프로젝트에서 모든 메뉴를 수동 조작한 증거는 아니다.
