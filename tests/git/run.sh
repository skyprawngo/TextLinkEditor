#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/textlinkeditor-git-test.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
xcrun swiftc -parse-as-library TextlinkEditor/Services/Versions/ProjectGitRepository.swift TextlinkEditor/Services/Versions/CommitDiffDocument.swift tests/git/Regression.swift -o "$task_dir/regression"
"$task_dir/regression"
xcrun swiftc -parse-as-library TextlinkEditor/Services/Versions/ProjectGitRepository.swift TextlinkEditor/Services/Versions/ProjectGitModel.swift tests/git/ModelRegression.swift -o "$task_dir/model-regression"
"$task_dir/model-regression"
