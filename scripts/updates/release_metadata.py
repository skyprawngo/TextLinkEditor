"""Release metadata from the exported Xcode bundle and a bounded Git history."""
import plistlib
import re
import subprocess
from pathlib import Path


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def source_commit(repo, reference):
    return git(repo, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}")


def commit_notes(repo, commit, previous=None):
    commit = source_commit(repo, commit)
    if previous:
        previous = source_commit(repo, previous)
        if subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", previous, commit],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            raise ValueError("Previous release is not an ancestor of this build; choose an explicit --since reference")
    revision_range = previous + ".." + commit if previous else commit
    # Commit subjects only: bodies often contain internal implementation details.
    messages = git(repo, "log", "--reverse", "--no-merges", "--format=%s", revision_range, "--").splitlines()
    notes = "\n".join("• " + " ".join(message.split()) for message in messages if message.strip())
    if not notes:
        raise ValueError("No new commit messages in the release range")
    return notes, commit, previous


def bundle_metadata(app):
    info = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.textlinkeditor.app":
        raise ValueError("Wrong bundle ID")
    version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version):
        raise ValueError("Invalid MARKETING_VERSION in the exported bundle")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]{0,8}", build):
        raise ValueError("CURRENT_PROJECT_VERSION must be a positive integer")
    minimum_os = info.get("LSMinimumSystemVersion")
    if not isinstance(minimum_os, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", minimum_os):
        raise ValueError("Invalid minimum OS in the exported bundle")
    return dict(version=version, build=build, minimum_os=minimum_os), info
