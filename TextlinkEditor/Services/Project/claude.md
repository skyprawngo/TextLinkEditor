# 프로젝트 형식과 접근 수명

`ProjectManager.swift`와 `Models/Project.swift`가 일반 프로젝트 폴더 및 메타데이터를 다룬다. 생성 시 확장자를 붙이지 않으며 입력한 이름 그대로 폴더를 만든다. 열기 패널은 확장자 대신 내부 project.json을 읽어 프로젝트 여부를 검증한다.

```text
MyProject/
├── .MyProject.weavedata/
│   ├── project.json
│   ├── editor-settings.json
│   ├── sidebar-layout.json
│   └── ai-sessions/
└── 원고와 섹션 폴더
```

프로젝트 생성 때 섹션 폴더 이름은 `folder.*` 번역으로 정해진다. 이후 언어 변경이 기존 폴더명을 바꾼다고 가정하지 않는다.

`ProjectCreationOptions.includesDefaultFolders`는 생성 시 기본 폴더 전체를 추가할지 정하는 옵션이다. `NewProjectSheet`의 더보기 안에 있는 체크박스로 선택하며, 시작 화면과 편집 화면 모두 같은 옵션을 `createProject`에 전달한다. 기본값은 체크 상태다. 해제하면 기본 폴더 없이 생성하되 숨김 메타데이터는 항상 생성한다. 기존 프로젝트에 옵션을 저장하거나 기존 폴더를 삭제하지 않는다. 실제 디스크 결과는 `tests/project_creation_regression.py`에서 검증한다.

숨김 데이터 폴더명은 프로젝트 파일명에서 계산되며 Editor와 AI 서비스에도 경로 계산이 있다. 이름 변경이나 저장 형식 수정은 이 참조들과 기존 데이터 호환성을 함께 살핀다.

`ProjectSidebarLayout`은 변경 사항·그래프의 펼친 본문 높이를 `sidebar-layout.json`에 저장한다. 드래그 종료 때 원자적으로 저장하고 프로젝트 전환 때 복원한다. 창 높이에 따른 일시적인 표시 제한과 접힘 상태는 저장된 높이를 덮어쓰지 않는다.

열기·닫기는 bookmark 접근, 최근/마지막 프로젝트와 연결된다. `openProjectFromFile`, `openProject`, `closeProject`와 메인 화면의 탭/AI 전환 호출을 함께 추적한다. `deleteProject`처럼 UI 이름과 다른 의미를 가질 수 있는 작업은 구현에서 실제 파일 삭제 여부를 확인한다.

최근 프로젝트와 bookmark의 UserDefaults 저장은 `ProjectPreferencesStore`에 분리되어 있다. `ProjectManager`는 목록의 표시 상태와 프로젝트 전환 순서를 소유한다. 기존 저장 키와 JSON 형식은 유지하며 테스트에서는 별도 UserDefaults를 주입한다.
