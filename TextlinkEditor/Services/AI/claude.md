# AI 연결과 대화 기록

## 호출 경로

`Views/MainEditor/AIAssistant/AIAssistantViewModel.swift`가 연결 상태, 프로젝트 문맥, 전송·취소를 조율한다. `AIAssistantContainerView`는 상태에 맞는 화면을 선택하고, `Chat/AIChatView.swift`는 단일 대화 화면과 IME를 지원하는 하단 입력을 소유한다. 이전 대화는 패널 안에서 수평 전환하는 검색 가능한 기록 화면, 원고·참조 대화 선택은 입력창의 첨부 popover에 둔다. 연결·제공자·계정·사용량은 앱 설정의 AI 페이지에 둔다. `AIAssistantViewModel.shared`가 단일 에디터 창과 설정 창의 계정·요청 소유권을 공유한다. 패널 내부의 별도 설정 sheet는 없다. 화면별로 별도 인증 서비스나 실행기를 만들지 않는다.

- `Models/AICLIType.swift`: Claude와 Codex 실행 파일 및 설치 정보. 기존 저장값 호환을 위해 Codex의 enum raw value는 `chatgpt`를 유지한다. 이 선언은 외부 CLI 호환성이 검증되었다는 뜻이 아니다.
- `CLI/CLIDetector.swift`, `CLIInstaller.swift`: 설치 감지·수동 경로·설치 안내.
- `CLI/CLIProcessManager.swift`: Claude stream-json / Codex exec JSONL의 명시적 완료 이벤트와 종료 코드를 처리한다. 각 ViewModel은 자체 실행기를 가지며, 요청별 POSIX 프로세스 그룹을 취소한다. 지속 터미널 모드는 지원하지 않는다.
- `Prompt/AIPromptTemplateManager.swift`와 `Resources/AIPromptTemplates.json`: 문맥 조립만 담당한다. CLI 인자와 출력 계약은 CLIProcessManager에 둔다.

## 저장 형식

일반 채팅은 프로젝트 루트의 텍스트 문서를 격리 사본에 복사해 작업 디렉토리로 사용하고, 프로젝트를 다시 열면 현재 제공자의 최근 일반 대화를 기본으로 선택한다. 후속 요청은 대화별 저장된 제공자 세션 ID로 재개한다(Codex `exec resume`, Claude `--resume`). 매번 현재 사본의 경로와 최신 문서를 우선하도록 안내한다. 새 대화는 새 세션이며 인라인 편집은 항상 독립 요청이다. 세션은 마지막 완료 응답의 제공자가 일치할 때만 사용한다. 실패·취소 후에는 세션 연결을 해제하고 사용자가 재시도하면 저장된 완료 대화로 문맥을 구성한다. 앱 기록은 프로젝트에, 제공자의 원본 세션은 해당 CLI 저장소에 있으므로 프로젝트 복사만으로 외부 세션까지 이동되지는 않는다.

프로젝트 파일은 지속 참조 자료다. 일반 요청은 현재 루트의 관련 파일을 검색·읽고 최신 내용으로 답변하도록 안내한다. 전체 파일 자동 첨부나 무제한 모델 기억을 뜻하지 않는다. Claude 일반 채팅은 safe-mode 안에서 Read/Glob/Grep만 허용하며 인라인은 빈 tools를 유지한다.

`Chat/AIHistoryRepository.swift`의 `AIHistoryRepository`가 프로젝트별 저장 계약이다. 기본 구현은 `.{프로젝트명}.weavedata/ai-sessions/history-store.json`에 메시지 카드와 대화/요청 인덱스를 하나의 원자적 snapshot으로 저장한다. `ChatHistoryManager`는 기존 호출자용 호환 facade다. 화면 모델은 repository를 주입받고 파일명이나 직렬화 방식에 의존하지 않는다.

새 저장 파일이 없을 때만 `LegacyAIHistoryReader`가 `session-metadata.json` + `cards/{UUID}.json`, 더 오래된 `ai-chat-history.json`을 읽는다. 다음 성공한 저장에서 새 형식으로 이전하며 원본 파일은 복구용으로 그대로 둔다. 새 파일이 존재하면 항상 그것이 권위 있는 기록이다. 삭제된 대화가 구형 파일에서 다시 나타나도록 fallback하지 않는다. 새 파일 손상, 미래 schema, 누락/중복 카드, 다른 대화 소유의 응답은 오류로 중단하며 빈 기록으로 덮어쓰지 않는다. 과거 원본까지 지우는 영구 삭제/백업 정리는 별도 정책이다.

컨테이너 schemaVersion은 1, 내부 대화 메타데이터 schemaVersion은 2다. 카드 UUID는 사용자 메시지 ID, request ID는 assistant 메시지 ID, conversation ID는 대화 root다. 생성일은 다음 저장에도 유지한다. 인덱스는 메시지에서 재생성하고 함께 검증/커밋한다. 저장 실패 시 이전 snapshot이 남으며, 처음 읽는 것만으로 디스크를 이전하지 않는다. 현 앱의 단일 창/MainActor 저장 호출을 전제로 하며, 프로세스 간 동시 편집·대용량 부분 조회가 필요해지면 동일 repository 계약 아래 SQLite 등의 구현을 추가한다. 현재 전체 기록은 메모리에 로드한다.

AI 프롬프트에 포함할 원고/선택/카드의 범위는 ViewModel에서 추적한다. UI 문구나 프롬프트 지시문만으로 외부 프로세스의 파일 접근 권한이 제한되는 것은 아니다. 연결 감지, 인증, 응답 성공, 기록 저장은 각각 다른 검증 단계다.

기존 구현 기록과 미검증 시나리오는 루트 [AI_ASSISTANT_CHECKLIST.md](../../../AI_ASSISTANT_CHECKLIST.md)를 참고한다.

## 실행과 검증 경계

OAuth와 추론은 `LoreCodexEnvironment`의 동일한 계정 저장소를 사용한다. 현재 실제 경로는 제품명 변경 전 인증을 유지하는 `Application Support/Loreweave/OpenAI`다. Codex `exec`에는 keyring·로그인 방식·제공자 설정을 **exec 뒤의 `-c` 인자**로 전달한다. CLI 0.145.0에서 최상위 `-c`만 사용하면 계정 조회는 성공해도 추론에서 인증이 누락될 수 있음을 실제 요청으로 확인했다. 인증 오류를 터미널 신규 로그인 요구로 간주하지 않는다.

전송 시 프로젝트 URL, request ID, conversation ID를 고정한다. 프로젝트 전환과 취소는 콜백을 먼저 무효화한다. 원고 첨부는 선택 사항이며 전송 직전 에디터를 flush한 캐시 내용으로 만든다. Claude 인증은 외부 CLI가 소유한다. ChatGPT는 `Auth/ChatGPTAccountService.swift`가 공식 App Server의 브라우저 OAuth를 시작하고 완료 ID를 검증한다. 토큰 발급·갱신은 공식 런타임, 저장은 macOS Keychain이 담당한다. TextlinkEditor 전용 Application Support/TextlinkEditor/OpenAI와 keyring 설정을 인증·AI 호출 모두에 적용하며, 전역 Codex 계정이나 API 키 환경변수를 재사용하지 않는다. App Server 계약은 `tests/oauth/run.py`, 빈 AI 입력창의 클릭/크기는 `tests/ai_input_regression.py`에서 검증한다. Claude는 safe-mode를 사용하며 일반 채팅·협업은 읽기 도구, 인라인은 빈 tools로 실행한다. Codex 일반 채팅·협업·인라인 모두 read-only sandbox를 사용한다. 사용자 config/rules는 제외한다. 옵션을 지원하지 않는 버전은 명시적 호환성 오류로 처리한다.

`tests/ai/run.sh`는 실제 서비스 대신 임시 fixture 실행 파일로 UTF-8/JSONL, 종료·인증 오류, 프로세스 그룹 취소, 프로젝트 귀속 및 대화 저장을 검증한다. 실제 CLI 로그인·서비스 응답·권한 적용은 별도 검증이다. 외부 CLI 계약 기준은 [Claude headless](https://code.claude.com/docs/en/headless), [Claude flags](https://code.claude.com/docs/en/cli-reference), [Codex non-interactive](https://developers.openai.com/codex/noninteractive/), [Codex CLI reference](https://developers.openai.com/codex/cli/reference/)다.

2026-09-12 실제 앱의 OAuth 로그인·재실행 복원·구독 응답·사용량 조회 근거는 루트 `OAUTH_AND_RUNTIME_VALIDATION_2026-09-12.md`에 있다. Codex 실행 엔진은 설치되어 있어야 하며 배포 번들 구성은 별도다.

## 명시적 문맥과 제안 적용

`Context/AIContextSelection.swift`는 프로젝트별 파일·고정 선택문·공개 시점이 허용된 설정 자료를 조립한다. 수정된 열린 원고는 초안, 그 외에는 디스크를 읽는다. 명시적 참조는 256 KiB, 최종 요청은 1 MB 제한이다. 토큰 수 추정치가 아니다. 요청별 `ai-context/{assistantID}.json`에는 실제 최종 프롬프트와 출처를 보관한다.

`Requests/AIChatMode.swift`가 일반 채팅의 `/대화`(`/chat`), `/계획`(`/plan`), `/작성`(`/write`) 태그와 모드 지침을 정의한다. 태그는 본문의 앞·중간·뒤에 붙일 수 있으며 여러 개이면 마지막 모드를 적용한다. 명령만 입력하면 추론 없이 현재 초안의 태그로 바뀐다. 입력창의 한글 조합이 확정된 후 명령 텍스트를 제거하며, 명령 선택기는 입력창 포커스를 가져가지 않는다. 태그는 요청을 준비하고 기록 저장에 성공했을 때 소비되며 다음 채팅과 기록 재열기에는 승계하지 않는다. 요청과 저장 본문에서는 태그를 제거하고 `chatMode`에 별도로 저장·표시한다. 파일명 확장자·URL 경로는 태그로 해석하지 않는다. 입력 끝의 `/` 또는 미완성 명령은 본문을 보존하는 태그 선택기를 연다. 기본은 대화이며 대화·작성은 모드 전환 없이 요청에 따라 검증된 수정안을 적용한다. 일반 질문은 수정 없는 응답으로 처리한다. 계획은 읽기 전용 사본에서 자유 형식 응답을 받는다. 문서가 없어도 구상할 수 있다. 대화·작성 모드는 협업 수정안·적용 경로를 공유하며 변경이 없는 답변에는 비교 기록을 만들지 않는다. 예전 기록은 대화로 취급한다. 현재 대화의 완료된 질답은 제공자 세션 재개 여부와 관계없이 다음 요청에 포함한다.

`Revision/ManuscriptRevision.swift`는 작성 실행 전 열린 초안을 충돌 검사 후 저장하고 프로젝트 원고(md/txt/markdown)의 기준본을 ai-revisions에 남긴다. 총 64 MiB를 넘거나 읽기/저장에 실패하면 실행하지 않는다. `AIWorkspaceProposalExecutor`는 작성 모드를 협업 엔진에 전달한다. 이때 CLI는 읽기 전용 사본에서 JSON 수정안을 반환하고 실제 문서는 앱이 적용한다. 새 문서에는 기존 인용을 요구하지 않지만 요청에 따른 생성 사유가 필요하며, 기존 문서 수정·삭제에는 원문 근거가 필수다. 비교 화면에는 해당 작업이 커밋한 변경만 기록한다. 완료 알림은 활성 편집기의 외부 변경 검사를 실행하며 수정 중인 초안과 IME 조합은 덮어쓰지 않는다. 인라인 편집은 기존 기준본 검증과 네이티브 Undo 경로를 유지한다.

## 문서 중심 협업

`Collaboration/CollaborationCoordinator`가 명시적 문서 의견, 선택한 변경 묶음, 선택적 Git 인덱스를 한 큐로 접수한다. 활성화 시 현재 파일을 기준본으로 등록한다. 저장 이벤트는 목록·설정 색인만 갱신하며 추론을 호출하지 않는다. Git은 프로젝트 루트와 저장소 루트가 같을 때만 읽고, 3초간 동일한 스테이지 내용을 접수한다. 작업 파일과 다르면 자동 덮어쓰기하지 않는다. 스테이징·커밋·저장소 생성은 하지 않는다.

`CollaborationEngine`은 최신 문서와 근거가 연결된 설정 색인·사용자 결정을 격리 사본에 전달한다. 질문에 의존하지 않는 수정만 적용하고 답변이 필요한 부분은 대기한다. 설정 사실은 `WritingLoreEntry`의 선택 필드로 원문 위치·인용·버전·상태·작품 시간·공개 장면·인지 인물과 연결한다. 원문 없는 독립 설정 본문을 복제하지 않는다. 출처가 바뀌면 색인을 갱신하거나 대체됨으로 표시한다. 서사 해석의 정확성은 모델 판단이며 앱의 보증이 아니다.

수정의 근거는 적용 전 원문에서 검증한다. 질문의 인용은 적용 전 원문뿐 아니라 검증을 통과하여 즉시 적용할 독립 수정의 결과도 참조할 수 있다. 아직 답변을 기다리는 수정 결과는 질문의 근거로 허용하지 않는다. 따라서 새 문서를 정리하면서 그 문장에 관한 후속 질문을 남겨도 독립적인 문서 생성이 거부되지 않는다.

일반 대화·계획·협업 작성의 읽기 사본은 `CollaborationStore.populateReadCopy`를 공유한다. 요청마다 빈 폴더와 텍스트가 없는 하위 폴더도 보존하고 현재 상대 경로 목록을 전달한다. 폴더 선택·이름 재사용을 강제하는 지침은 추가하지 않는다. 숨김 경로·패키지·심볼릭 링크는 제외하며 바이너리 내용은 복사하지 않는다. 파일 내용 기준본과 폴더 목록은 별개다.

`CollaborationApplier`만 실제 텍스트를 수정한다. 경로·보호 파일·전체 읽기 기준본·열린 초안·IME를 검증하고, 다중 파일 변경 전 `.{프로젝트명}.weavedata/collaboration`에 복구 저널을 저장한다. 중간 종료는 재진입 시 복구하며 후속 사용자 변경이 있으면 중단한다. 되돌리기도 같은 충돌 검사를 통과해야 한다. 작업 큐·설정 버전·기준본은 `state.json`, 변경 전후는 트랜잭션별 저널에 저장한다. 이미지·숨김 경로·심볼릭 링크·앱 데이터·Git 관리 파일은 사본과 수정 대상에서 제외한다. 패널을 닫아도 작업은 유지하며 프로젝트 전환은 취소한다. 협업 메타데이터와 일반 대화 기록의 생명주기는 별도다.

인라인 편집(`Views/MainEditor/AIAssistant/Inline/InlineAIChatView.swift`)은 전송 직후 닫히는 단일 지시 입력창이다. 선택한 범위가 있으면 치환하고 공백 선택 또는 커서만 있으면 해당 위치에 삽입한다. 문맥은 화면에 표시하지 않는다. `InlineEditRequest`가 JSON replacement 응답을 요구하며 앱만 기준본 비교·버전 기록·네이티브 Undo 경로를 통해 수정한다. 전송 전후 원고나 활성 문서가 바뀌면 덮어쓰지 않는다. 일반 답변이나 잘못된 JSON은 실패로 기록한다.

기록의 선택 필드 `AIMessage.kind == inlineEdit`로 일반 대화와 구분한다. 예전 기록의 필드 부재는 일반 대화로 해석한다. 인라인 기록은 조회·삭제할 수 있으며 이어서 대화하거나 이미 적용된 결과를 다시 수정 비교로 적용하지 않는다. 기존 계정·단일 실행기를 공유하되 사이드바 초안·선택 대화와 공통 첨부 설정은 해당 편집 요청에 섞지 않는다.

인라인 요청은 매번 새 conversation ID를 만들며 사이드 패널의 선택 대화·입력 초안·오류 표시를 바꾸지 않는다. 접수 전 오류만 인라인 입력창에 표시하고, 접수 후 응답과 실패는 해당 기록에서만 조회한다. 적용하지 못한 AI 응답도 실패 사유와 함께 보관하여 원인을 확인할 수 있게 한다.

## 요청 모델과 사용량

커밋 메시지 생성은 `AIConversationCategory.commitMessage`의 별도 모델·추론 설정을 사용한다. 설정 AI 탭에서 선택하며 현재 연결된 제공자와 기존 OAuth·단일 실행기를 공유한다. 메시지가 빈 커밋 요청은 스테이징 diff만 전달하고 독립 읽기 전용 요청에서 JSON 메시지를 받는다. 일반 채팅 세션·원고 수정 경로는 사용하지 않는다. 생성 실패·빈 응답·프로젝트 전환 시 커밋하지 않으며, Git 실행 직전에 인덱스와 HEAD/브랜치가 그대로인지 비교한다. 사용자가 입력한 메시지는 AI 없이 커밋한다. 자동 생성은 스테이징·푸시를 수행하지 않는다.

입력창 하단의 모델·추론 선택은 제공자별 앱 설정으로 보관하며 전송 시 고정한다. Codex 모델 목록과 지원 추론 단계는 계정 전용 App Server의 `model/list`에서 페이지별로 읽고, 선택값을 `--model`과 `model_reasoning_effort`로 전달한다. Claude는 CLI의 Sonnet/Opus/Haiku 별칭과 `--effort`를 사용한다. 모델 변경 시 이전 추론 선택이 지원되면 유지하고, 지원되지 않으면 새 모델의 권장 단계(없으면 medium 또는 첫 지원 단계)로 조정한다. 채팅 팝오버와 설정 AI 탭은 동일한 마지막 선택을 제공자별로 저장한다. 별도의 기본값 선택 단계는 없다. 제공 목록에 없는 저장 모델은 조용히 다른 모델로 실행하지 않는다. 공식 문서에 있는 `gpt-6-astra`는 구형 CLI 목록에서 빠져도 명시적으로 선택할 수 있으며, 서버 목록이 해당 모델을 제공하면 그 추론 단계 정보를 우선한다. 직접 선택 가능 여부는 계정 사용 권한 확인을 뜻하지 않는다. 선택 UI는 모델 이름 메뉴와 단계별 추론 슬라이더를 하나의 팝오버에 둔다.

완료 응답의 `usage`는 `AIMessage.usage`에 선택 필드로 저장한다. 컨텍스트 정보 팝오버는 최근 요청의 누적 입력·캐시·출력 토큰과 실행기가 보고한 한도만 표시한다. 도구 호출 누적량을 현재 컨텍스트 점유율로 환산하지 않으며 한도가 없으면 미제공으로 표시한다. 구형 기록은 사용량을 알 수 없는 상태로 유지한다.

컨텍스트 원형 바는 누적 usage가 아닌 앱 전용 Codex 세션 JSONL의 마지막 `token_count.info.last_token_usage.total_tokens`를 사용한다. `CodexContextMeter`가 응답 완료 후 백그라운드에서 해당 세션의 끝부분만 읽는다. 모델 캐시에서 유효 한도를 확인할 수 있으면 그 90%를 `model_auto_compact_token_limit`으로 실행기에 명시하고 동일한 기준을 usage에 보관한다. 이는 앱의 명시적 정책이며 Codex의 기본 압축 비율이라고 가정하지 않는다. 압축 이후 새 토큰 보고가 없거나 모델·세션 정보를 확인할 수 없으면 진행률은 미제공이다. Claude와 구형 기록의 누적 사용량도 진행률로 대체하지 않는다. 자동 압축은 실행기가 수행하며 앱에 저장된 대화 원문을 삭제하지 않는다.

사이드 채팅과 ⌘I는 `AIConversationCategory.chat` / `.inlineEdit`로 구분한다. 기본 모델·추론 수준은 제공자와 카테고리의 조합으로 저장하며, 기존 공통 설정은 최초 로드 때 인라인 설정으로 한 번 복사한다. 이후 서로의 선택을 변경하지 않는다. 설정 AI 탭은 두 영역을 각각 제공하고 인라인 전송은 `.inlineEdit` 설정을 스냅샷한다.

기록 메타데이터 schemaVersion 2의 `conversations`는 대화 UUID별 카테고리·순서 있는 카드 ID·완료/실패 응답 요청 ID와 최근 요청 설정을 인덱싱한다. 각 메시지도 요청 당시 provider/model/reasoningEffort를 보관한다. 기존 카드 파일 경로와 UUID는 유지하며, 구형 kind 부재는 일반 채팅으로 해석하고 다음 저장에 인덱스를 생성한다. 삭제·초기화 시 현재 메시지로 인덱스를 재생성한다. 기록 화면에서 범주 필터, 대화 ID/모델 검색, 대화 ID 복사를 지원한다.

## 확장 지점과 단일 책임

- `Preferences/AIModelPreferences`: 제공자·카테고리별 마지막 모델/추론 선택, 구형 설정 이전, 모델 capability에 맞는 옵션 결정. UI는 같은 observable 인스턴스를 읽는다. 새 범주는 `AIConversationCategory`에 추가하며 일반 채팅의 기존 설정 키를 유지한다.
- `Requests/AIRequestPreparer`: 원고 기준본 검증, 문맥/프롬프트 조립, 요청 artifact 준비. 화면의 메시지·초안·선택 대화는 수정하지 않는다. 준비 실패와 기록 커밋 실패 시 호출자가 해당 요청 artifact를 정리한다.
- `Requests/AIRequestExecuting`: 실행·스트리밍·취소 계약. 다른 실행기나 테스트 대역은 화면 모델 수정 없이 주입할 수 있다.
- `Requests/AIWorkspaceProposalExecutor`: 대화·계획에는 읽기 전용 사본과 일반 응답을, 작성에는 공통 협업 실행·적용 경로를 제공한다. 작성 작업의 변경 비교는 기존 대화 기록에 연결한다. 기존 TrackingExecutor는 이전 계약 회귀용이며 실제 채팅 실행에는 사용하지 않는다.
- `CLI/CLIProcessManager`: 제공자 인자 구성과 단일 요청 소유. `CLIRequestRunner`는 POSIX 프로세스·취소·파이프 I/O, `CLIJSONStream`은 UTF-8 JSONL framing과 제공자 이벤트 해석을 담당한다.
- `Chat/AIHistoryModels`와 `AIHistorySnapshot`: 저장 레코드, 메시지-대화 관계 및 인덱스 무결성. 파일 I/O는 repository, 구형 읽기만 legacy reader에 둔다.
- `AIAssistantViewModel`: 화면 상태, 연결 상태, 전송 시작/완료 조율과 프로젝트 전환 시 콜백 무효화. UI 변경과 저장 순서의 소유자는 이 객체다. 기존 sidebar/inline 분리, 단일 실행, 네이티브 원고 적용·Undo 계약은 유지한다.

`tests/ai/run.sh`는 기존 실행 fixture와 함께 저장 실패 주입, 구형 데이터 이전, 생성일/ID 유지, 미래 형식·손상 기록 덮어쓰기 차단, 실행 decorator의 실패·취소 후 파일 변경 기록을 검증한다. 실제 계정에서의 inference를 호출하지 않는다.
