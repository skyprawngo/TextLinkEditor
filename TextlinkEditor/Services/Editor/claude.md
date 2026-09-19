# 탭과 원고 저장

`EditorTabManager.swift`는 URL별 `TabEditState`에 편집 텍스트, 저장본(`originalContent`), 0-based 커서를 보관한다. 수정 여부는 두 텍스트의 비교로 계산하며 저장 성공 시 저장본을 갱신한다. 화면의 저장 상태도 이 결과를 사용한다.

`Scroll/EditorViewportStore.swift`는 원고 바이트와 분리된 파일별 읽기 위치를 앱 설정에 보관한다. 첫 화면 행 번호·행 텍스트·행 안 오프셋, 커서 행 번호·행 텍스트·열과 커서 앞뒤 최대 24글자를 저장한다. 닫기/탭 전환에서는 즉시 수집하고 스크롤/선택 변경은 0.2초 지연 저장한다. 파일 이동 이벤트에는 위치 기록도 함께 이동한다. 구형 레코드의 커서 필드는 선택 사항이며 손상된 저장 데이터는 새 빈 기록으로 덮어쓰지 않는다.

`Scroll/EditorViewportResolver.swift`는 화면과 저장소에 의존하지 않는 위치 판정기다. 첫 행의 정확한 텍스트를 우선하고, 일치 항목이 여러 개이거나 사라졌으면 커서 행 텍스트 또는 커서 주변 문맥의 이동량을 보조 기준으로 쓴다. 두 기준 모두 찾지 못하면 기존 행을 문서 범위로 제한한다. 빈 행은 고유한 식별 근거로 쓰지 않는다. 동일한 문구가 반복되면 보조 기준과의 거리로 결정하므로 모든 외부 수정에서 원래 위치를 식별할 수 있는 계약은 아니다. 기준 행이 그대로인 경우 두 행만 확인하며, 이동을 찾을 때만 원문 행을 순회한다.

`TextlinkEditorRepresentable.Coordinator`는 네이티브 화면에서 기준점을 수집하고 판정 결과를 배치하는 역할을 맡는다. 일치하는 커서 위치도 복원하되 화면을 커서로 스크롤하지 않는다. `tests/editor_binding_regression.py`는 행 삽입, 첫 행 삭제/중복, 커서 문맥, 구형/손상 기록과 실제 네이티브 창에서 100행→120행 재열기를 검증한다.

## 저장·복구 경계

원고 쓰기는 `FileSystem/DocumentFileStore.swift`의 신규 생성/기준본 비교 저장을 거친다. 닫기·전환·삭제는 먼저 에디터를 flush하고 저장/버리기/취소를 결정한다. 버리기 승인만으로 캐시를 지우지 않으며, 후속 파일 작업 실패 시 초안을 유지한다.

앱의 Application Support/TextlinkEditor/Recovery에 프로젝트 경로별 복구 사본을 먼저 저장하고, `.{projectName}.weavedata/editor-session.json`에도 프로젝트 내부 탭을 저장한다. 탭·커서와 수정 중 `draftContent`·`baseContent`를 포함한다. 프로젝트 밖으로 다른 이름 저장한 탭의 `externalURL`은 앱 소유 복구 사본에서만 복원하며 프로젝트가 제공하는 절대 경로는 신뢰하지 않는다. 변경 후 0.5초 지연 저장이므로 갑작스러운 종료 직전 입력까지 보장하는 저널은 아니다. 복원 실패 시 원본 세션의 별도 사본 보존을 시도하고 오류를 알린다. 이것은 편집 초안 복구이며 전체 프로젝트의 장기 버전 백업은 아니다. 구형 프로젝트 공통 글꼴 설정은 `editor-settings.json`에 남아 있지만 현재 표시 설정은 아래의 전체 기본값/파일별 재정의 규칙을 사용한다.

파일 이동·이름 변경은 탭 ID를 유지하면서 URL·편집 캐시·저장 상태를 함께 옮긴다. `EditorContainerView`와 `TextlinkEditorRepresentable`은 문서 ID·URL·내용 revision으로 지연된 binding 갱신의 귀속을 확인한다. IME 확정 결과를 이전 URL로 돌려주는 연결을 유지해야 한다.

## 외부 파일 동기화

`EditorTabManager`가 열린 URL 집합을 전달하고 `FileSystem/Workspace/DocumentObservationController`가 감시·읽기 수명을 소유한다. 파일과 부모 디렉터리의 vnode 감시, `NSFilePresenter`, 앱 활성화·잠자기 복귀 및 5초 보완 검사를 함께 사용한다. 이벤트 후 백그라운드에서 완전한 본문을 읽고 탭 ID·요청 ID·기준본을 재검증한다. 원자적 파일 교체 후 감시는 다시 연결한다. `EditorContainerView`는 확인된 본문 갱신 알림만 화면에 적용한다.

깨끗한 문서는 외부본을 반영한다. 양쪽이 수정되면 기준본과 앱 초안을 그대로 유지하고 조용히 충돌 상태로 둔다. 삭제되면 사이드바에서는 사라지지만 열린 본문은 유지하고 탭 제목에는 취소선을 표시한다. 자동 저장은 충돌·삭제 파일을 쓰지 않는다. 명시적 저장에서만 다른 이름 저장을 제안하며, 복사 저장은 기존 경로를 덮어쓰지 않는 배타적 생성이다. 충돌·삭제 탭을 닫으면 질문 없이 버리되 실제 닫기가 완료된 뒤 복구 세션을 동기 저장한다. 종료의 승인된 버리기 항목도 복원 목록에서 제외한다. 읽기 실패는 삭제로 간주하지 않는다.

`tests/storage_regression.py`는 실제 임시 파일의 원자적 교체·직접 쓰기·비활성 탭·삭제·충돌·복사 저장·닫기 후 복구를 검증한다. 외부 쓰기는 강제 잠그지 않으며 비협조 writer와 최종 비교/교체 사이의 경쟁을 완전히 제거하는 계약은 아니다.

## 텍스트 엔진과 Undo

구조는 [TextEngine](TextEngine/claude.md)에 있다. `TextlinkEditorRepresentable.Coordinator`가 문서 ID별 `NativeManuscriptTextView`를 보관한다. 각 NSTextView는 독립 UndoManager를 사용하며 탭 전환에서 이력을 유지하고, 닫힌 탭의 캐시는 해제한다. 디스크 새 버전이나 외부 본문 교체는 네이티브 본문을 다시 로드하고 이력을 초기화한다. Undo 스택 자체를 세션에 영속 저장하는 것은 아니다.

찾기·바꾸기와 서식 명령은 `EditorCommand`를 통해 텍스트·선택·Undo를 함께 바꾼다. 커서·선택 표시의 행 번호와 엔진의 0-based 위치를 혼동하지 않는다.

현재 원고 화면은 `NativeManuscriptView.swift`의 NSTextView와 NSScrollView를 사용한다. AppKit이 단어/행/문서 이동·선택, IME, 클립보드, Undo를 처리한다. `NSTextContentStorage` → `NSTextLayoutManager` → `NSTextContainer`의 TextKit 2 구성을 사용한다. 줄 번호·현재 행 강조는 표시 중인 문단/행 fragment에서 계산한다. 이 경로에서 `NSTextView.layoutManager`에 접근하면 TextKit 1 호환 모드가 켜지므로 사용하지 않는다. 전체 원고의 행 시작 UTF-16 인덱스는 본문 변경 때 갱신하며, 저장 형식은 기존 문자열/원고 파일 계약을 유지한다. `tests/native_editor_regression.py`는 네이티브 명령과 합성 대용량 문서 비용을, `tests/editor_binding_regression.py`는 문서 귀속을 검증한다. 기존 Core Text 뷰는 비교·회귀용 소스로 남아 있으며 원고 화면에는 연결되지 않는다.

부가 표시의 fragment 순회는 좌표뿐 아니라 `viewportRange`의 텍스트 끝 위치로 제한한다. 미배치 fragment는 좌표가 0일 수 있으므로 건너뛰며 계속 순회하면 문서 끝까지 객체를 생성한다. 화면 밖 커서의 강조 좌표도 조회하지 않는다. 네이티브 회귀 검사는 10만 줄의 연속 스크롤·역방향 점프에서 부가 조회가 만드는 fragment 수를 제한해 이 경계를 검증한다.

너비 변경은 즉시 줄바꿈하되 기존 viewport의 텍스트 위치와 화면 내 오프셋을 유지한다. 이전 픽셀 좌표로 문서 뒤쪽을 재탐색하지 않도록 공개 `relocateViewport` API를 사용한다. SwiftUI의 크기·툴바 갱신에서는 마지막으로 받은 본문과 revision이 같으면 네이티브 전체 문자열을 읽지 않는다. `tests/native_resize_regression.py`는 10만 줄의 앞·중간·뒤에서 연속 너비 변경, 표시 문단·선택 유지, IME와 Undo를 검증한다.

## 에디터와 앱 UI의 작업 분리

표시 중인 NSTextView와 TextKit 배치는 메인 스레드가 소유한다. 별도 큐는 레이아웃 관리자가 없는 초기 저장소·행 인덱스 준비와 불변 세션 스냅샷의 JSON 인코딩·복구 파일 쓰기를 담당한다. 자동 복구는 직렬 큐에 제출하고, 명시적 세션 저장과 복원은 앞선 쓰기를 기다려 오래된 스냅샷의 역전 저장을 막는다. 종료 경로의 명시적 저장은 완료를 보장하기 위해 기다린다.

본문/커서 캐시는 SwiftUI 관찰에서 제외하고 탭의 수정 표시가 바뀔 때만 탭 배열을 갱신한다. 캐시는 저장·AI 요청 시 명시적으로 읽으며, 원고 binding과 선택 표시의 지연 알림은 최신 세대만 반영한다. 저장용 캐시 갱신은 지연하지 않는다.

행 인덱스는 NSTextStorage 문자 편집 알림에서 변경 문단과 인접 문단만 다시 읽는다. Undo·IME도 같은 경로를 거친다. 이후 행의 숫자 오프셋 이동은 여전히 행 수에 비례하지만 본문 전체를 문자열로 재스캔하지 않는다. `tests/editor_isolation_regression.py`는 유니코드 편집·Undo의 전체 인덱스 대조와 10만 줄에서의 스캔 범위를, `tests/storage_regression.py`는 관찰 분리·백그라운드 저장 중 메인 루프 진행·저장 순서를 검증한다. 이 검사는 실제 앱의 모든 패널 애니메이션이 프레임 손실 없이 동작한다는 증거는 아니다.

## 툴 실행 경계

`Scroll/EditorScrollCoordinator.swift`가 기준점 수집·TextKit 좌표 계산·복원·후속 배치 보정의 실제 구현을 소유한다. 기능별 기준은 모듈의 `Event` 매핑에서 설정한다. Markdown 표시 전환·외부 본문 교체는 화면 첫 표시 위치를 유지하고, 글꼴·줄간격 등 실제 배치 도구는 커서 기준을 사용한다. 파일 재열기는 `EditorViewportResolver`의 판정 결과를 같은 복원 경로에 전달한다. 원문 변경 시 기준점의 문자 위치 변환은 본문 변경 계층이 담당한다. 복원은 즉시 배치와 후속 첫 레이아웃에 적용하며 창 크기 변경은 기존 TextKit 위치를 사용해 대용량 문서 hit-test를 피한다. 단순 도구 UI 열기는 커서를 드러내거나 스크롤하지 않는다. 툴바·에디터·파일 열기는 모듈 메서드에 이벤트나 저장 위치를 전달할 뿐 자체 스크롤 계산을 구현하지 않는다.

`EditorToolBridge.swift`는 도구를 본문 편집·표시 설정·탐색·AI 요청으로 분류하고 텍스트/레이아웃/선택에 대한 영향을 선언받는다. 툴바 서식과 찾기·바꾸기는 `execute(EditorCommand)`로, 글꼴·크기·줄간격·자간은 `applyDisplayStyle`로 들어와 같은 브릿지를 거친다. AI 툴바 요청도 명령으로 전달하지만 종료는 요청 전달 완료를 뜻하며 외부 모델의 응답 완료를 뜻하지 않는다. Bold 등의 기존 저장 계약은 마크다운 표기 삽입이다.

브릿지는 식별자별 시작·적용·뷰포트 배치 완료·종료 이벤트를 제공한다. 실제 배치 완료는 `layout()` 이후에만 알리고, 변경 없음은 배치를 생략하며 문서 교체/뷰 분리는 대기 중 종료를 취소한다. 본문 편집의 읽기 전용 검사와 편집/탐색 전 IME 확정도 공통 처리다. 표시 설정은 조합을 유지하고 변경된 속성만 한 저장소 트랜잭션으로 적용해 대체 글꼴을 불필요하게 지우지 않는다. 표시 설정 변경의 스크롤 기준은 커서 줄이다. 화면 안의 커서는 기존 화면 Y 위치를 유지하고, 화면 밖이면 속성 적용 전에 커서 줄을 맨 위로 이동한다. 속성 적용 직후와 첫 후속 레이아웃에서 기준점을 복원하며 문서 교체·뷰 분리 때 폐기한다. 창 너비 변경은 기존 viewport 기준을 유지한다.

새 사용자 도구는 `../Core/EditorToolRegistry.swift`의 `tool(...)`로 ID·이름·분류·영향·실행 처리를 함께 등록한다. 기본 키가 없어도 설정 단축키 목록에 자동 반영된다. 툴바/메뉴는 `.tool(id)`를 사용하며 네이티브 target이 `toolBridge.perform`으로 실행을 감싼다. 버튼에 별도 시작/종료 알림이나 강제 전체 레이아웃을 넣지 않는다. `onEvent`는 관찰용이며 재진입 도구 실행은 취소된다. `tests/editor_tool_regression.py`는 실제 TextKit 2와 10만 줄 fixture에서 이벤트 순서·속성 편집 횟수·Undo·IME·취소를 검증한다. 본문 수정 후 문자열 스냅샷 발행과 저장본 비교는 여전히 문서 크기에 영향을 받는다.

## Markdown 표시 모드

SwiftUI가 전달한 도구 명령은 `updateNSView` 안에서 실행하지 않고 메인 큐의 다음 실행으로 넘긴다. 실행 직전에 문서 ID·URL·revision과 활성 문서를 확인한다. 표시 전환 콜백과 포커스 변경이 화면 갱신 중 SwiftUI 상태를 재진입해 수정하지 않도록 이 경계를 유지한다.

`display.markdownPreview`는 호환성을 위해 유지한 표시 전환 도구 ID이며 기본 키는 지정하지 않는다. 서식 모드도 동일한 `NativeManuscriptTextView`를 사용하므로 줄번호·줄간격·입력·저장·Undo·AI 요청의 소유권이 갈라지지 않는다. Markdown 원문은 저장소에 그대로 두고 `MarkdownSourceStyling`이 글꼴과 장식 속성만 적용한다. 커서가 있는 문단의 구문 기호는 옅게 표시하고 다른 문단의 기호는 축소·투명 처리한다. 따라서 클릭/방향키의 위치는 계속 원문 오프셋이며 별도의 리치 텍스트 직렬화는 없다.

`Markdown/MarkdownSyntaxDocument`는 버전 고정한 `swift-markdown` 0.8.0의 CommonMark/GFM AST를 원문 UTF-16 범위로 변환한다. 파서의 열 위치는 UTF-8 바이트이므로 한글·이모지·CRLF 변환을 거친다. `Markdown/MarkdownPresentationController`는 표시 모드·갱신과 문서 세대별 파싱 캐시를 소유한다. 커서나 글꼴만 바뀌면 다시 파싱하지 않는다. `Markdown/MarkdownSourceStyling`은 범위에 대응하는 속성만 적용한다. 네이티브 뷰는 입력·Undo와 모듈 호출을 담당하며 툴바/단축키는 공통 `display.markdownPreview` 도구를 통한다. 문서 저장이나 SwiftUI 상태를 서식 모듈에서 변경하지 않는다.

ATX/Setext 제목, 중첩 강조·취소선, 인용문·목록·체크리스트, 들여쓰기/펜스/인라인 코드, GFM 표, 인라인/참조/자동 링크, 이미지·HTML·구분선·줄바꿈의 해석을 표준 파서에 위임한다. 기존 `<u>` 도구는 제한된 밑줄 확장으로 유지한다. CJK 대체 글꼴에 기울임체가 없으면 obliqueness로 표시한다. IME 조합 중에는 서식 재적용을 보류하며 보기 전환은 원문과 Undo 이력을 바꾸지 않는다.

이 화면은 원문 보존형 편집기이지 HTML 미리보기가 아니다. 표는 고정폭/헤더 서식으로, 목록·체크박스·구분선은 원문 기호로 표시한다. 이미지의 실제 삽입·외부 다운로드, HTML 실행, 엔티티 치환, 표 셀 격자 재배치는 하지 않는다. 링크는 http/https/mailto만 활성화하고 다른 목적지는 텍스트로 유지한다. 수식·Mermaid·위키링크·각주 등 GFM 밖의 확장은 아직 렌더링하지 않는다. 따라서 모든 Markdown 방언의 완전한 시각적 렌더링을 보장하지 않는다.

`tests/markdown_regression.py`는 AST 범주·유니코드 위치·중첩 서식·코드 격리·안전한 링크를, `tests/editor_binding_regression.py`는 원문 보존·Undo·원문 모드 복원을 검증한다. 네이티브 회귀 실행기는 `tests/markdown_test_support.py`로 앱과 같은 파서를 빌드·링크한다. 표준 파서 업데이트 시 앱과 테스트의 고정 버전을 함께 변경한다.

## 버전과 프로젝트 바꾸기

`../Versions/VersionHistoryStore.swift`는 저장 전 본문과 수동 스냅샷을 프로젝트 메타데이터에 보관한다(문서당 최근 30개). 버전 복원은 새 파일 생성으로 원본 덮어쓰기를 피한다. 탭 경로 이동은 버전 기록과 집필 자료 링크도 함께 이동시킨다.

`ProjectReplacementStore.swift`는 디스크 원고의 문자 그대로 바꾸기를 미리보고, 선택한 모든 파일의 기준본을 확인한 후 버전과 작업 저널을 남긴다. 중간 실패의 롤백은 후속 외부 편집을 덮어쓰지 않는다. UI는 미저장 열린 원고를 거부하며, 마지막 작업 되돌리기도 현재 본문 일치를 요구한다. 앱 재실행 후 자동 일괄 Undo를 제공하는 것은 아니다.

## 인라인 AI 공간

원고 우클릭 또는 ⌘I는 `editorInlineAI` 알림으로 `InlineAIChatView`를 설치한다. `NativeManuscriptTextView`의 TextKit 2 delegate가 `ManuscriptLayoutFragment.bottomMargin`으로 선택 문단 아래에 공간을 예약한다. 패널을 열고 닫을 때 해당 fragment의 여백과 레이아웃을 함께 무효화한다. 빈 문서와 마지막 빈 줄의 extra line fragment도 처리한다. 원고 문자열·저장 형식에는 패널 마커를 넣지 않는다. 패널과 미전송 입력은 탭의 네이티브 뷰 수명에만 속하며 외부 본문 교체 시 제거한다. 전송 즉시 패널을 닫고, 지시와 실행 결과는 인라인 편집 기록에 남는다.

## 대용량 원고 로딩

`DocumentFileStore.readInChunks`는 작업 스레드에서 64KB씩 읽고 완전한 UTF-8 본문만 전달한다. `PreparedManuscript`는 문단 경계의 청크마다 대체 글꼴을 미리 계산하고, 레이아웃 관리자가 없는 저장소를 화면에 한 번만 이전한다. 로딩 요청 ID와 문서 ID로 취소된 탭의 결과를 버리며 로딩 중에는 저장과 편집 캐시 갱신을 막는다. 전체 논리 문서는 네이티브 선택·Undo·저장을 위해 유지하며 디스크 페이지 편집기는 아니다. 준비된 저장소는 `NSTextContentStorage.textStorage`에 연결한다. 화면의 배치·캐시는 TextKit 2의 viewport controller가 담당하며 전체 문서 `ensureLayout`은 호출하지 않는다. `tests/chunked_loading_regression.py`는 취소·UTF-8 경계·백그라운드 준비·저장을 검증한다.


## 파일 관리 아키텍처 연결

`EditorTabManager`는 탭/초안/선택의 상태 소유자이며 `WorkspaceDocumentParticipant`로 이동 전 flush와 삭제 전 결정을 제공한다. 생성 시 주입된 `WorkspaceFileCoordinator`의 성공 이벤트를 구독한다. 이름 변경/이동은 같은 탭 UUID와 초안을 유지하고 소유 URL을 이동한다. 파일 작업이 실패하면 성공 이벤트가 없으므로 탭 경로도 바뀌지 않는다.

`DocumentObservationController`는 읽기 request UUID, 문서 UUID, 기준본을 고정하고 결과 전달 직전에 모두 확인한다. 저장으로 기준본이 바뀌었으면 다시 읽고, 새 요청/닫기/다른 문서로 바뀌었으면 폐기한다. 상태 판정은 `DocumentReconciliation`에 있고 UI 갱신은 관리자에 남는다. 최초 편집기 로딩도 관리자의 `readDocument`를 통해 동일 document repository를 사용하며, 뷰의 로딩 ID/문서 ID 검증을 추가로 유지한다.

`Session/EditorDocumentModels.swift`는 탭·초안·저장 세션의 자료형, `Session/EditorSessionStore.swift`는 복구 경로·인코딩·원자적 기록·구형 세션 읽기·손상본 보존을 담당한다. 관리자는 immutable snapshot 생성, 직렬 recovery queue와 현재 세대의 오류 표시를 조율한다. 로컬 복구본의 외부 URL 신뢰 경계와 명시 저장의 flush 순서는 유지한다. 전체 프로젝트 백업이나 OS 비협조 writer 잠금으로 확장해 해석하지 않는다.


## 전체 표시 기본값과 파일별 재정의

`UserSettings`의 글꼴·글자 크기·표시 줄간격 비율·자간은 전체 기본값이다. 설정 → 에디터에서 변경하면 `editorAppearanceDefaultsChanged`를 발행한다. `Appearance/EditorAppearanceStore.swift`는 optional 필드로 구성한 파일별 재정의를 기본값 위에 합성한다. 예를 들어 글꼴만 재정의한 문서는 나머지 세 항목의 전체 설정 변경을 계속 따른다. 표시 서식은 원고 바이트나 수정 여부에 영향을 주지 않는다.

`EditorAppearanceRepository`는 저장 계약, `JSONEditorAppearanceRepository`는 schema 1 JSON의 원자적 기록, `EditorAppearanceStore`는 파일 소유권·상속 계산·캐시·변경 이벤트를 담당한다. 앱 소유 `Application Support/TextlinkEditor/editor-appearance-overrides.json`에 정규화된 절대 경로별 재정의만 저장한다. 프로젝트 밖의 문서도 같은 규칙을 쓴다. 이 파일은 프로젝트의 이식 가능한 설정이 아니며 외부 Finder 이동/다른 기기로의 복사까지 추적하지 않는다. 앱 안 이동/폴더 이동은 기존 공통 파일 이벤트로 재정의를 옮기고 복사/다른 이름 저장은 원본을 남기면서 복사한다. 앱 시작 때 저장소가 이벤트 구독을 등록한다.

편집기는 파일 전환·전체 기본값 이벤트에서 합성한 값을 읽기만 한다. 툴바 전용 Binding의 setter에서 실제로 변경한 속성만 저장하며, 비동기 폰트 패널 콜백은 Binding 생성 시점의 파일 URL을 캡처한다. 따라서 다른 탭으로 바꾼 뒤 도착한 콜백이 새 탭에 재정의를 만들지 않는다. 툴바 우클릭의 전체 기본값 복원은 해당 파일의 모든 재정의를 제거한다.

구형 프로젝트 공통 설정에는 변경 대상 파일 정보가 없으므로 모든 파일의 개별 재정의로 복제하지 않는다. 기존 JSON은 삭제하지 않고 보존하며, 재정의가 없는 파일은 전체 설정을 따른다. 레코드는 최초 조회 때만 읽고 캐시하며 실제로 값이 달라진 경우에만 저장한다. 저장 실패 시 메모리 설정도 적용하지 않고 오류를 표시한다. 손상/미래 형식 파일은 빈 데이터로 덮어쓰지 않는다. `tests/editor_appearance_regression.py`는 항목별 상속, 파일 격리, 재로드, 이름/폴더 이동, 복사, 초기화, 손상/저장 실패를 검증한다.

## 네이티브 에디터의 책임 경계

`NativeManuscriptView.swift`는 AppKit 입력과 하위 모듈의 연결을 맡는다. 같은 폴더의 `NativeManuscriptLineIndex`는 UTF-16 행 인덱스, `NativeManuscriptGeometry`는 읽기 전용 TextKit 좌표 조회, `NativeManuscriptCommands`는 명령 실행을 담당한다. `NativeManuscriptInlinePanel`은 인라인 패널의 소스 위치와 문단 여백, `NativeManuscriptHost`는 스크롤 호스트와 꼬리 공간, `NativeManuscriptRuler`는 줄 번호 표시를 소유한다. `NativeManuscriptFocus`는 사이드바 선택 후 비동기 문서 로딩이 포커스를 다시 가져오지 못하게 한다.

서식 변경의 완료 순서는 `ManuscriptPresentationCoordinator` 하나가 소유한다: 속성 적용 → TextKit 재배치 → 화면 기준점 복원 → AppKit 선택/삽입 커서 갱신. `MarkdownPresentationController`는 구문 분석 캐시와 서식 속성만 결정한다. 커서를 먼저 갱신하고 이후 viewport를 이동하면 실제 `NSTextInsertionIndicator`가 이전 좌표에 남을 수 있으므로 이 순서를 분산시키지 않는다. 일반 도구의 기본 커서 보존과 별도로 표시 설정은 이 coordinator가 복원을 맡아 중복 복원을 피한다.

`tests/native_cursor_regression.py`는 클릭/화살표 이동과 116행의 화면 높이 60% 유지 조건을 검증한다. 실제 깜빡이는 커서는 `tests/native_caret_ui.py --output /tmp/TextlinkCaretValidation.app`로 별도 검증 앱을 빌드해 클릭·스크롤·서식 전환하며 확인한다. 활성 창의 실제 `NSTextInsertionIndicator` 프레임을 먼저 읽고 TextKit 선택 segment와 비교하며 `/tmp/textlink-caret-validation.log`에 결과를 기록한다. 비활성 테스트 창의 논리 좌표 검사만으로 실제 커서 표시 성공을 판정하지 않는다.
