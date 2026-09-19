# 파일 트리와 원고 쓰기

`FileSystemManager.swift`는 `Models/FileSystemItem.swift`의 트리를 갱신하고 파일 작업·변경 감시를 수행한다. 화면은 `Views/MainEditor/Sidebar/ProjectExplorerView.swift`와 그 하위 뷰다.

초기화는 루트의 직접 자식을 로드하고, 폴더는 펼칠 때 자식을 갱신한다. 초기 전체 하위 개수 재귀 로드는 제거했다. 기존 항목 객체와 펼침 상태를 재사용하며 로드한 디렉터리에 watcher를 붙인다. 감시 결과는 해당 프로젝트에만 적용하고 전환 시 watcher를 정리한다. 이 감시가 미열람 하위 전체나 열린 원고의 본문 충돌 검사를 대신하지는 않는다. 열린 원고 감시의 수명은 `EditorTabManager`가 `DocumentObservationController`에 위임하며, 공통 파일 이벤트로 트리와 문서를 갱신한다.

`DocumentFileStore.swift`는 UTF-8 원고의 배타적 생성, 저장 직전 기준본 비교, 임시 파일 작성 후 재검증, atomic 쓰기를 담당한다. 충돌·읽기 실패를 조용한 덮어쓰기로 바꾸지 않는다. `NSFileCoordinator`를 사용하지만 이에 협조하지 않는 외부 writer와의 비교/쓰기 경쟁까지 완전히 차단하는 계약은 아니다.

이동·이름 변경은 편집기를 flush한 뒤 디스크 작업에 성공하면 열린 탭과 캐시 URL을 함께 갱신한다. 삭제는 dirty 결정을 먼저 받고 휴지통 이동 성공 후 탭을 닫는다. 작업 실패나 취소에서 미저장 초안을 유지해야 한다.

새 파일 위치는 선택 파일의 부모, 선택 폴더, 프로젝트 루트 순으로 결정된다.

`SidebarFileDrop`은 루트와 폴더 행의 공통 드롭 진입점이다. Finder의 file URL은 원본을 유지하며 기존 복사 명령으로 가져오고, 앱 내부 문자열 URL은 기존 이동 콜백에 전달한다. 여러 provider는 순서대로 읽으며 대상 프로젝트가 바뀌면 중단한다. 외부 URL 접근 권한은 복사 동안만 유지한다. 이름 충돌은 기존 복사 규칙으로 번호를 붙이며 자기 자신/하위 폴더로의 복사는 거부한다. 뷰는 완료 후 캐시만 갱신하고 직접 파일을 쓰지 않는다.

폴더 우클릭의 `FolderOptionsSheet`는 아이콘을 임시 선택하고 저장 시에만 `FileSystemManager.setFolderIcon`을 호출한다. `FolderAppearanceStore`는 프로젝트 숨김 데이터 폴더의 `folder-icons.json`에 프로젝트 상대 경로 → SF Symbol 이름을 저장한다. 기본값 복원은 해당 키를 제거하며, 기본 섹션 아이콘 규칙은 유지한다. 앱 내 이동·이름 변경·복사는 하위 폴더 설정도 함께 옮기고 삭제는 설정을 정리한다. Finder 등 외부에서 이동한 폴더의 경로 추적은 하지 않는다. 저장 실패 시 UI의 아이콘을 변경하지 않으며, 손상된 JSON을 빈 설정으로 덮어쓰지 않는다. `tests/folder_options_regression.py`가 디스크 저장과 이 경계를 검증한다.

## 파일 관리 모듈과 이벤트 계약

`Workspace/WorkspaceFileRepository.swift`의 `WorkspaceDocumentRepository`는 UTF-8 본문 읽기/기준본 비교 저장/배타적 생성을, `WorkspaceFileRepository`는 디렉터리 열람과 이동/복사/휴지통 작업을 정의한다. `LocalWorkspaceFileRepository`는 기존 `DocumentFileStore`의 파일 조정·UTF-8·atomic 교체 계약을 재사용한다. `WorkspaceFileCoordinator`에 저장소와 이벤트 버스를 주입할 수 있다. 뷰는 실제 파일을 이동한 뒤 다른 뷰를 직접 호출하지 않고 coordinator의 명령을 사용한다.

- **명령:** 이동 전 `WorkspaceDocumentParticipant`가 편집기를 flush한다. 삭제 전 참여자가 저장/버리기/취소를 결정하며 취소하면 디스크 작업을 하지 않는다. 파일 I/O 실패는 throw하며 성공 이벤트를 내보내지 않는다.
- **커밋 이벤트:** `WorkspaceFileEvents`는 생성·저장·이동·복사·휴지통 성공과 외부 무효화 힌트를 구분한다. 이동 이벤트는 이전/새 URL을 함께 전달한다. 에디터가 탭 ID와 초안의 소유 경로를 갱신하고 트리는 프로젝트 범위 안의 이벤트만 반영한다. UI 수신은 메인 큐이며 트리 갱신은 현재 명령의 항목 변경이 끝난 뒤 실행한다.
- **쓰기 데코레이터:** `EventPublishingDocumentRepository`는 성공한 저장/생성에만 이벤트를 붙인다. 기존 AI·일괄 바꾸기·버전 복원 등의 `DocumentFileStore` 직접 호출도 기본 공유 버스로 발행한다. repository 구현에서는 이 기본 발행을 끄고 주입된 버스로 한 번만 발행한다.
- **관찰:** 디렉터리 vnode와 `OpenDocumentMonitor`는 변경의 힌트만 보낸다. 본문은 `DocumentObservationController`가 완전한 snapshot을 다시 읽어 검증한다. 감시 이벤트 자체로 원고 내용이나 삭제 상태를 확정하지 않는다.
- **합의 규칙:** `DocumentReconciliation`이 마지막 기준본/앱 초안/디스크 본문의 관계를 판정한다. 디스크가 기준본과 같으면 초안 유지, 초안이 깨끗하거나 디스크와 같으면 외부본 채택, 양쪽이 다르면 `ManuscriptTextMerge`로 원문 차이를 비교하여 독립적인 수정을 합치고 겹친 변경만 충돌로 처리한다. 저장 직전과 외부 갱신에 같은 규칙을 사용한다. 외부 갱신 시 기준본은 실제 디스크로, 초안은 병합본으로 갱신하여 미저장 소유권을 유지한다. IME 조합 중에는 갱신을 미루고 최신 디스크를 다시 읽는다. 병합 후 저장도 실제 읽은 디스크 본문을 기대값으로 검증하며 atomic 교체한다.
- **표시:** 수락된 본문·디스크 상태 이벤트만 기존 AppKit 알림으로 변환한다. 알림은 호환 adapter이며 본문을 소유하지 않는다. 탭 바는 `EditorTabManager.tabs`, 에디터는 해당 문서 ID와 캐시를 읽는다. 디스크 읽기 완료가 곧 네이티브 뷰에 적용됐다는 뜻은 아니다.
- **사용자 인터랙션:** 파일 생성/이름 변경/삭제 확인과 Finder 열기는 `FileSystemDialogs.swift`에 분리한다. 파일 트리의 표시 상태와 폴더 아이콘은 `FileSystemManager`/`FolderAppearanceStore`가 소유한다.

새 파일 명령은 coordinator에 추가하고 성공 후 typed event를 발행한다. 새 부가 모듈은 자신이 소유한 프로젝트/URL만 구독하고 토큰을 수명 종료 때 해제한다. 명령은 에디터 메인 큐에서 호출한다. 이벤트는 프로세스 내부 통지이며 영속 저널이나 프로세스 간 트랜잭션이 아니다. 원고 저장의 atomic 교체와 이동 후 부가 메타데이터 변경은 별개의 작업으로, 메타데이터 실패는 오류를 표시하고 이미 성공한 디스크 이동을 되돌리지 않는다. 프로젝트 설정·AI 기록·복구 데이터는 원고 덮어쓰기 규칙에 섞지 않고 각 저장 모듈이 소유한다.

`tests/storage_regression.py`는 실제 파일과 주입된 저장소/이벤트 버스로 명령 실패·삭제 veto·늦은 응답 역전·저장 중 기준본 변경을 검증한다. `tests/folder_options_regression.py`는 실제 트리와 탭 관리자를 함께 사용해 사이드바 이름 변경 → 탭 ID/초안 경로 → 후속 본문 갱신을 검증한다.


`WorkspaceFileIdentity`는 `/var`와 `/private/var` 등 표준화된 경로 표기 및 Unicode 정규화를 공통 비교 기준으로 사용한다. 대소문자를 강제로 접지 않는다. 트리 항목 조회, 탭 중복 판정, 경로 이동 suffix 계산이 같은 기준을 사용한다. 캐시 API는 다른 URL 표기가 들어와도 열린 탭이 소유한 URL로 조회한다. 일반 캐시 경로는 사전 조회를 먼저 하여 입력마다 탭 전체를 순회하지 않는다. 외부 이름 변경을 파일 inode로 추적해 새 URL로 자동 이동시키는 기능은 포함하지 않으며 기존 감시 정책대로 원래 경로의 삭제/변경으로 처리한다.

`Workspace/DirectoryWatchRegistry`가 폴더 감시 descriptor와 취소를 소유한다. `FileSystemManager`는 프로젝트/항목 유효성을 확인하고 이벤트 발행 및 트리 갱신만 결정한다. 감시 해제와 디스크 작업의 성공 여부를 섞지 않는다.
