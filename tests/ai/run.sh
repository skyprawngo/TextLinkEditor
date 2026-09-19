#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/textlinkeditor-ai-test.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
xcrun swiftc -parse-as-library \
  TextlinkEditor/Services/AI/Models/AICLIType.swift \
  TextlinkEditor/Services/AI/Models/AIMessage.swift \
  TextlinkEditor/Services/AI/Models/AIConnectionState.swift \
  TextlinkEditor/Services/AI/CLI/CLIDetector.swift \
  TextlinkEditor/Services/AI/Auth/ChatGPTAccountService.swift \
  TextlinkEditor/Services/AI/CLI/CodexRPCConnection.swift \
  TextlinkEditor/Services/AI/CLI/CLIProcessManager.swift \
  TextlinkEditor/Services/AI/CLI/CLIJSONStream.swift \
  TextlinkEditor/Services/AI/CLI/CodexContextMeter.swift \
  TextlinkEditor/Services/AI/CLI/CLIRequestRunner.swift \
  TextlinkEditor/Services/AI/Chat/*.swift \
  TextlinkEditor/Services/AI/Preferences/*.swift \
  TextlinkEditor/Services/AI/Requests/*.swift \
  TextlinkEditor/Services/AI/Collaboration/*.swift \
  TextlinkEditor/Services/AI/Prompt/AIPromptTemplateManager.swift \
  TextlinkEditor/Services/AI/Context/AIContextSelection.swift \
  TextlinkEditor/Services/AI/Revision/ManuscriptRevision.swift \
  TextlinkEditor/Services/Writing/WritingWorkspaceStore.swift \
  TextlinkEditor/Services/Versions/VersionHistoryStore.swift \
  TextlinkEditor/Services/FileSystem/DocumentFileStore.swift \
  TextlinkEditor/Services/FileSystem/Workspace/DocumentReconciliation.swift \
  TextlinkEditor/Services/FileSystem/Workspace/WorkspaceFileEvents.swift \
  TextlinkEditor/Views/MainEditor/AIAssistant/AIAssistantViewModel.swift \
  tests/ai/HistoryRepositoryRegression.swift \
  tests/ai/CollaborationRegression.swift \
  tests/ai/QueueRegression.swift \
  tests/ai/Regression.swift -o "$task_dir/regression"
"$task_dir/regression" "$@"
