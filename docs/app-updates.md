# 앱 업데이트 운영

## 구성과 정책

Release 앱은 매 프로세스 시작과 수동 확인 때 `GET /v1/releases/latest`로 현재 표시 버전과 빌드 번호만 보낸다.
이 단계에서는 기기 ID·앱 키·Keychain을 사용하지 않는다. 최신 버전이면 종료하고,
새 버전이면 변경사항을 스크롤 가능한 안내 창에 표시한다.

- 업데이트: 이때 처음 Keychain에서 기기 ID/앱 키를 읽고 `POST /v1/check`로 라이선스를 확인한 뒤 Sparkle 설치 절차로 진행한다.
- 이 버전 건너뛰기: 해당 빌드 번호를 로컬 설정에 저장하고 다음 시작 알림을 생략한다. 더 높은 빌드는 다시 안내한다.
- 나중에: 이번 안내만 닫고 다음 시작 때 다시 확인한다.
- 수동 확인: 건너뛴 버전도 다시 표시한다.

사용자가 본 빌드 번호를 인증 요청과 Sparkle 피드에 고정하여, 안내 후 새 릴리스가 게시되어도
다른 빌드로 교체하지 않는다. 선택한 릴리스가 철회되면 설치를 진행하지 않는다.
기존 구버전의 `/v1/check` 요청도 계속 지원한다.

**Debug에서는 시작 확인, 수동 확인, 키 저장, Sparkle 초기화를 모두 비활성화한다.**
앱 메뉴의 업데이트 항목을 숨기고 설정에는 비활성화 안내만 표시한다.
Release에서도 서버/라이선스 오류로 원고 편집을 차단하지 않는다.

기기 ID는 하드웨어 일련번호가 아닌 UUID이며 앱 키와 함께 로컬 Keychain에 보관한다.
iCloud로 동기화하지 않으며 재설치 후에도 Keychain이 남아 있으면 같은 UUID를 유지한다.
설정에서 앱 키를 명시적으로 저장할 수 있다. 저장 자체는 인증/다운로드를 시작하지 않는다.
macOS가 Keychain 접근 권한을 요구하는 경우는 업데이트 수락 후 또는 명시적인 키 저장 때로 제한된다.

서버는 앱 키와 UUID를 SHA-256 해시로 저장한다. 키는 충분히 긴 난수로 발급한다.
정상 라이선스의 기기를 최초 연결 시 등록하고 재연결 시 버전과 마지막 접속 시각을 갱신한다.
기기 수 제한은 SQLite 쓰기 트랜잭션으로 동시 등록에도 적용한다. 기본 발급 한도는 2대이며
`--devices`로 변경한다. 만료 정책/결제/계정 가입은 아직 없다.
클라이언트가 보낸 식별자만으로 바이너리 위변조까지 증명할 수는 없다.
복제된 앱 키/설치 ID에 대한 하드웨어 증명 또는 별도 활성화 프로토콜은 별도 범위다.

서버는 정수 `CFBundleVersion`을 비교한다. 표시 버전 `CFBundleShortVersionString`과
빌드 번호는 별개이며 릴리스마다 빌드 번호를 증가시켜야 한다. 정당한 새 버전이 있으면
24시간 유효한 임의 토큰을 발급한다. DB에는 토큰 해시만 저장한다.
Sparkle는 Authorization 헤더로 피드와 다운로드에 접근한다. 키 폐기는 매 요청에 반영된다.
만료된 다운로드는 앱에서 다시 업데이트를 확인해 새 토큰을 받아 재시도한다.

`AppUpdateManager`는 Sparkle 2.10.0의 안내/다운로드/검증/교체/재실행을 사용한다.
자동 다운로드·자동 설치는 꺼져 있다. 사용자가 설치를 선택할 때만 진행한다.
업데이트 재실행 전에 기존 `EditorTabManager.prepareToClose` 저장/취소 경로를 호출한다.
앱의 최소 OS와 아키텍처 적합성은 Sparkle가 판정한다.
새 메뉴는 원고 편집 도구가 아니라 앱 관리 명령이므로 EditorToolRegistry와 분리한다.

`Config/Info.plist`는 생성 Info.plist에 병합할 Sparkle 설정의 원본이다.
임의 `INFOPLIST_KEY_SU...` 빌드 설정만으로는 실제 번들에 포함되지 않아 사용하지 않는다.
Ed25519 개인키는 이 Mac의 로그인 Keychain, Sparkle account `textlinkeditor`에 있다.
공개키만 앱과 서버에 포함한다. 개인키는 서버나 Git에 복사하지 않는다.

## 서브컴 배포

경로: `/home/sub/textlinkeditor-updates`

```sh
ssh sub-ubuntu 'mkdir -p /home/sub/textlinkeditor-updates'
scp server/update_service/{app.py,manage.py,requirements.txt,Dockerfile,compose.yml,nginx.conf,.dockerignore} sub-ubuntu:/home/sub/textlinkeditor-updates/
ssh sub-ubuntu 'cd /home/sub/textlinkeditor-updates && docker compose up -d --build --force-recreate'
ssh sub-ubuntu 'curl -fsS http://127.0.0.1:8788/healthz'
```

컨테이너 `updates`는 Gunicorn/Flask, `origin`은 Nginx다. 호스트에는 loopback 포트
8787/8788만 연다. `origin`만 기존 `hometrader_default` 터널 네트워크에 추가된다.
다른 프로젝트로 옮기면 compose의 외부 네트워크명을 해당 터널 네트워크로 바꾼다.
기존 HomeTrader/TeslaMate 서비스와 호스트 Nginx 설정은 수정하지 않는다.

Cloudflare의 기존 `hometrader` 터널에 Published application을 추가한다.

- Hostname: `textlinkeditor.skyprawngo.com`
- Service URL: `http://textlinkeditor-origin:8080`
- Path: 비워 둠
- DNS: Cloudflare의 Add route가 생성하는 터널 CNAME

관리 명령은 SSH에서만 실행한다. 공개 관리 API는 없다. Cloudflare Access의 브라우저 로그인
챌린지를 이 호스트에 적용하면 네이티브 앱 통신이 실패한다. API 경로에 캐시 강제 규칙을
추가하지 않는다. Nginx는 체크 요청을 전체 origin 기준 5회/초, burst 20으로 제한한다.
사용자가 늘면 Cloudflare에서 신뢰할 수 있는 클라이언트 IP별 제한을 구성한다.
본문·Authorization 헤더를 로그에 넣지 않는다.

```sh
curl -fsS https://textlinkeditor.skyprawngo.com/healthz
# 인증 없는 피드 요청은 401이어야 한다.
curl -I https://textlinkeditor.skyprawngo.com/v1/appcast.xml
```

## 키 발급·폐기·기기 초기화

```sh
ssh -t sub-ubuntu 'cd /home/sub/textlinkeditor-updates && docker compose exec updates python manage.py issue --label customer-reference --devices 2'
ssh -t sub-ubuntu 'cd /home/sub/textlinkeditor-updates && docker compose exec updates python manage.py revoke'
ssh -t sub-ubuntu 'cd /home/sub/textlinkeditor-updates && docker compose exec updates python manage.py reset-devices'
ssh sub-ubuntu 'cd /home/sub/textlinkeditor-updates && docker compose exec -T updates python manage.py list'
```

`issue`는 새 키를 한 번 출력한다. 기록되는 채팅/로그에 붙이지 말고 수령자에게 안전하게 전달한다.
`revoke`와 `reset-devices`는 키를 echo 없는 프롬프트에서 입력받는다.
기기 초기화는 기존 세션 토큰을 모두 무효화한다. 키를 분실하면 새 키를 발급한다.
발급 시 label에는 불필요한 개인정보 대신 주문/고객 참조값을 사용한다.

## 버전·변경사항 자동화

공개 API는 `GET /v1/releases/latest`다. 인증이나 기기 정보 없이 최신 등록 버전, 빌드,
최소 OS, 변경사항을 제공한다. `?build=현재빌드`를 붙이면 `update_available`도 비교한다.
동일 버전이어도 최신 릴리스의 메타데이터는 제공한다. 등록된 릴리스가 없을 때만 `release: null`이다.
비교 빌드를 생략하면 `update_available`은 false이며 메타데이터 조회만 수행한다.

버전의 원본은 Xcode의 `MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION`이다.
배포 도구는 이 설정이 반영된 **실제 export 앱**의 `CFBundleShortVersionString`과
`CFBundleVersion`을 읽는다. 설정 파일의 문자열을 따로 복제하거나 서버 버전을 수동 수정하지 않는다.
`archive_release.py`를 실행하는 셸에 두 환경변수를 지정하면 Xcode archive에도 그대로 전달된다.
빌드 번호는 운영자가 증가시켜야 하며 자동으로 임의 증가시키지는 않는다.

변경사항은 직전 서버 등록 릴리스의 `source_commit`부터 이번 archive 커밋까지의
비-merge 커밋 제목을 시간순으로 `• 항목` 형태로 변환한다. 커밋 본문은 공개하지 않는다.
첫 릴리스는 해당 커밋까지의 이력을 사용한다. 범위를 줄이거나 기존 수동 릴리스를 마이그레이션할 때는
`--since <커밋 또는 태그>`로 기준을 명시할 수 있다. 기준이 현재 커밋의 조상이 아니거나
새 커밋 제목이 없으면 자동 생성은 실패한다.

### 1. Archive → export → 서명·변경사항 생성

변경사항에 포함할 소스를 먼저 커밋한 뒤 실행한다. 아래 명령은 활성 체크아웃을 변경하지 않고
정확한 커밋의 독립 worktree에서 Release archive를 만든다. 미커밋 변경이 있으면 시작하지 않는다.
출력 폴더는 저장소 밖의 새 폴더여야 한다. 생성한 worktree와 archive는 검토용으로 남겨 둔다.
Developer ID export 설정과 인증서·공증 환경은 먼저 준비되어 있어야 한다.

```sh
python3 scripts/updates/archive_release.py \
  --output /path/to/new-release-work \
  --export-options /path/to/ExportOptions.plist \
  --sparkle-bin /path/to/Sparkle/bin
```

`ExportOptions.plist`는 Xcode의 Developer ID 배포 설정을 사용한다. 자동 공증이 완료되지 않은
export는 `prepare_release.py`의 Gatekeeper 검사를 통과하지 못한다. 공증을 완료한 뒤 아래
명령으로 다시 패키징할 수 있다. 이것은 미공증 앱을 우회하여 배포하지 않기 위한 검사다.

이미 준비한 export 앱에는 실제 archive 때 기록한 커밋을 명시한다. 현재 HEAD를 자동 추정하지 않는다.

```sh
python3 scripts/updates/prepare_release.py /path/to/TextlinkEditor.app \
  --source-commit <archive에-사용한-커밋> \
  --sparkle-bin /path/to/Sparkle/bin --output /path/to/releases
```

서버의 SSH 전용 `manage.py release-info`에서 이전 배포 기준을 자동으로 읽는다.
통신이 실패하면 첫 배포라고 가정하지 않고 중단한다. 원본 앱 검증 후 ZIP, JSON manifest,
`.notes.txt` 미리보기를 생성한다. manifest에는 Xcode 버전·빌드·최소 OS, 서명, 체크섬,
커밋 범위와 공개 변경사항을 함께 담는다. **커밋 제목이 사용자에게 공개되므로 발행 전 notes를 검토한다.**

### 2. 한 명령으로 서버에 발행

```sh
python3 scripts/updates/publish_release.py /path/to/releases/TextlinkEditor-0.2.0-2.json
```

이 명령을 실행하면 ZIP과 manifest를 SSH로 서브컴에 전송하고 `publish-manifest`로 등록한다.
버전·빌드·서명·변경사항을 다시 타이핑하지 않는다. 서버는 다음을 확인한 뒤 DB에 원자적으로 등록한다.

- ZIP 체크섬과 Ed25519 서명
- ZIP 내부 앱의 버전·빌드·최소 OS가 manifest와 동일한지
- 더 높은 빌드 번호와 중복 없는 파일명인지
- 그 사이 다른 릴리스가 등록되어 변경사항 기준 커밋이 달라지지 않았는지

등록 직후 공개 API와 Sparkle 피드에서 같은 변경사항을 제공한다.
업로드한 임시 파일은 로그에 표시된 `/tmp/textlinkeditor-release.*` 경로에 검토용으로 남는다.
자동화는 **앱 빌드/실행마다 공개 배포하지 않는다**. 패키징과 발행 명령을 분리한다.
`publish --notes-file`의 기존 수동 등록 경로는 호환성을 위해 유지하지만 자동화 경로는 `publish-manifest`다.

### 3. 릴리스 철회

```sh
ssh sub-ubuntu 'cd /home/sub/textlinkeditor-updates && docker compose exec -T updates python manage.py withdraw 2'
```

철회한 빌드도 다시 사용하지 않는다. 구버전으로 강제 다운그레이드하지 않고 수정판을 더 높은 빌드로 발행한다.
서버에는 아직 실제 배포 릴리스를 등록하지 않았다. 서명된 앱 제작과 공개 릴리스 발행은 별도 실행 단계다.

## 백업·복구

Docker named volume `textlinkeditor-updates_update-data`의 DB와 releases를 함께 보관한다.
일관된 백업은 유지보수 시간에 `docker compose stop updates` 후 volume을 백업하고
`docker compose start updates`로 재개한다. DB만 복사할 때 실행 중인 WAL을 빠뜨리지 말고
SQLite backup API를 사용한다. 복구 시 파일 권한은 UID 10001, DB는 0600을 유지한다.
볼륨을 삭제하는 `docker compose down -v`는 라이선스/기기/릴리스를 모두 잃게 하므로 사용하지 않는다.
Mac의 Sparkle 서명 Keychain도 별도 안전한 백업 대상이다.

## 검증

```sh
python3 -m venv /tmp/textlinkeditor-update-venv
/tmp/textlinkeditor-update-venv/bin/pip install -r server/update_service/requirements.txt
/tmp/textlinkeditor-update-venv/bin/python -m unittest discover -s tests/updates -v
swiftc TextlinkEditor/Services/Updates/UpdateAPIClient.swift tests/updates/APIClientRegression.swift -o /tmp/textlinkeditor-update-api-test
/tmp/textlinkeditor-update-api-test
```

서버 테스트는 임시 DB/가짜 아카이브로 인증, 폐기, 토큰 만료, 기기 제한 경쟁,
빌드 비교, Range 다운로드, 잘못된 요청을 검증한다. 앱 통신 테스트는 URLProtocol로
요청 필드/HTTP 실패/잘못된 JSON을 검증한다. 이는 실사용 앱 교체 증거와 다르다.

실배포 전 별도 설치 경로에서 서명된 구/신 버전으로 다운로드 취소, 네트워크 단절,
서명 변조 거부, 업데이트 후 재실행, 수정 원고의 저장/버리기/취소를 확인한다.
현재 Mac에서 확인된 서명 ID는 Apple Development와 Apple Distribution이며
Developer ID Application 인증서는 없었다. 따라서 이번 작업의 빌드는 로컬 검증용이다.

## 이번 구성에서 확인한 상태 (2026-09-20 KST)

- 서브컴 Docker 서비스 healthy, 로컬 origin 상태 확인 200.
- 사용자가 Cloudflare 경로를 추가한 후 공개 DNS에서 호스트 확인.
- HTTPS 상태 확인 200 / 인증 없는 피드 401 / 키 없는 체크 unlicensed.
- 실제 도메인에 임시 라이선스로 정상 인증, 같은 기기 재인증, 기기 한도, 폐기를 확인했고 임시 레코드는 제거했다.
- Python 회귀 10개, Swift API 모의 통신, Xcode Debug 빌드 통과.
- 빌드된 Info.plist/내장 framework를 독립 테스트 번들에 넣어 Sparkle 초기화와 수동 업데이트 설정을 확인했다.
- Mac의 시스템 URLSession은 utun8 네트워크 경로에서 새 도메인 DNS 조회가 -1003으로 실패했다.
  일반 curl도 같은 DNS 실패이며, 공개 DNS에서 확인한 IP를 curl --resolve로 지정하면 정상 TLS/API 통신을 확인했다.
  DNS 캐시 갱신을 시도해도 계속되어 네이티브 실통신 테스트는 미통과로 남긴다. VPN/DNS 설정은 변경하지 않았다.
- 서브컴의 기본 Python-urllib User-Agent는 Cloudflare 1010(403)으로 거부되었다.
  앱 식별자 `TextlinkEditor/0.1.0`과 Sparkle User-Agent는 같은 경로에서 200이었다.
  앱 API에는 명시적인 TextlinkEditor User-Agent를 넣었고 Cloudflare 보안 정책은 변경하지 않았다.
- 실제 서명된 구/신 앱의 설치 교체, UI 클릭, 원고 저장/취소 후 재실행은 아직 검증하지 않았다.

추가 실행 진입점:

```sh
python3 tests/updates/run_sparkle_smoke.py /path/to/built/TextlinkEditor.app /path/to/unstripped/Sparkle.framework
swiftc TextlinkEditor/Services/Updates/UpdateAPIClient.swift tests/updates/LiveAPISmoke.swift -o /tmp/textlinkeditor-update-live-test
/tmp/textlinkeditor-update-live-test
```

### 변경된 확인 순서 검증

`UpdateWorkflowRegression.swift`는 실제 AppUpdateManager를 테스트용 API/Keychain 구현과 연결한다.
Debug에서 시작·수동확인·키저장이 모두 아무 작업도 하지 않는지, Release에서 최신 버전/건너뛰기/나중에는
Keychain을 읽지 않는지, 수락 후에만 지정한 빌드를 인증하는지 검증한다.

```sh
swiftc -D DEBUG -F /path/to/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker /path/to/Sparkle TextlinkEditor/Services/Updates/AppUpdateManager.swift tests/updates/UpdateWorkflowRegression.swift -o /tmp/update-workflow-debug
/tmp/update-workflow-debug
# -D DEBUG를 빼고 컴파일하면 Release 경로를 검증한다.
```

이번 순서 변경 후 Debug/Release 앱 빌드는 한 차례 통과했고, 최종 실제 manager의 Debug/Release 분기 테스트도 통과했다.
이후 최종 전체 Debug 재빌드는 동시 작업 파일 TypographySettingsView.swift:148의 Binding<Double>/Binding<CGFloat> 오류로 실패했다. 이 파일은 업데이트 작업에서 수정하지 않았다.
서브컴의 공개 버전 API도 HTTPS로 응답을 확인했다. 독립 테스트 앱으로 안내 창을 열어 클릭 검증하려 했지만
컴퓨터 제어 도구의 앱 실행이 시간 초과되어 실제 UI 클릭 검증은 완료하지 못했다.
