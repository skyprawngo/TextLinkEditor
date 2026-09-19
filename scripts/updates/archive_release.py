#!/usr/bin/env python3
"""Archive/export/package from one clean Git commit; no publication or Git changes."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from release_metadata import git, source_commit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repository")
    parser.add_argument("--export-options", type=Path, required=True, help="Xcode Developer ID ExportOptions.plist")
    parser.add_argument("--sparkle-bin", type=Path, required=True)
    parser.add_argument("--host", default="sub-ubuntu")
    parser.add_argument("--since")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.is_relative_to(repo) or output.exists():
        parser.error("Use a new output directory outside the repository")
    if git(repo, "status", "--porcelain", "--untracked-files=all"):
        parser.error("Commit the intended release source first; the working tree is not clean")
    commit = source_commit(repo, "HEAD")
    output.mkdir(parents=True)
    # An isolated worktree prevents edits in the active checkout from entering this archive.
    checkout = output / "source"
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "--detach", str(checkout), commit], check=True)
    archive = output / "TextlinkEditor.xcarchive"
    export = output / "export"
    overrides = [f"{key}={os.environ[key]}" for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION") if key in os.environ]
    subprocess.run(["xcodebuild", "-project", str(checkout / "TextlinkEditor.xcodeproj"), "-scheme", "TextlinkEditor",
                    "-configuration", "Release", "-archivePath", str(archive), "archive", *overrides], check=True)
    if git(checkout, "status", "--porcelain", "--untracked-files=all"):
        raise SystemExit("Archive changed its source checkout; inspect before packaging")
    subprocess.run(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(export),
                    "-exportOptionsPlist", str(args.export_options.resolve())], check=True)
    (output / "source-context.json").write_text(json.dumps(dict(source_commit=commit), indent=2) + "\n")
    command = [sys.executable, str(Path(__file__).with_name("prepare_release.py")), str(export / "TextlinkEditor.app"),
               "--sparkle-bin", str(args.sparkle_bin.resolve()), "--output", str(output / "release"),
               "--repo", str(checkout), "--source-commit", commit, "--host", args.host]
    if args.since:
        command += ["--since", args.since]
    subprocess.run(command, check=True)
    print("Archive source retained for inspection:", checkout)


if __name__ == "__main__":
    main()
