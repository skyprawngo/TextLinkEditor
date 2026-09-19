#!/usr/bin/env python3
"""Package an exported/notarized app and generate commit-based metadata. Does not publish."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from release_metadata import bundle_metadata, commit_notes


def previous_release(host):
    command = "cd /home/sub/textlinkeditor-updates && docker compose exec -T updates python manage.py release-info"
    return json.loads(subprocess.check_output(["ssh", "-o", "BatchMode=yes", host, command], text=True))


def prepare(app, sparkle_bin, output, repo, commit, previous):
    metadata, info = bundle_metadata(app)
    notes, commit, previous = commit_notes(repo, commit, previous)
    public = subprocess.check_output([str(sparkle_bin / "generate_keys"), "--account", "textlinkeditor", "-p"], text=True).strip()
    if info.get("SUPublicEDKey") != public:
        raise ValueError("App's update key does not match this signing Mac")
    if info.get("SUFeedURL") != "https://textlinkeditor.skyprawngo.com/v1/appcast.xml":
        raise ValueError("Invalid release feed")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], check=True)
    identity = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
    if "Authority=Developer ID Application:" not in identity:
        raise ValueError("Export with Developer ID (not development/ad-hoc)")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"TextlinkEditor-{metadata['version']}-{metadata['build']}.zip"
    manifest_path = archive.with_suffix(".json")
    notes_path = archive.with_suffix(".notes.txt")
    if any(path.exists() for path in (archive, manifest_path, notes_path)):
        raise ValueError("Refusing to overwrite release artifacts")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    signature = subprocess.check_output([str(sparkle_bin / "sign_update"), "--account", "textlinkeditor", "-p", str(archive)], text=True).strip()
    subprocess.run([str(sparkle_bin / "sign_update"), "--account", "textlinkeditor", "--verify", str(archive), signature], check=True)
    with archive.open("rb") as stream:
        archive_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = dict(metadata, filename=archive.name, signature=signature, sha256=archive_hash,
                    notes=notes, source_commit=commit, previous_commit=previous)
    notes_path.write_text(notes + "\n", encoding="utf-8")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--sparkle-bin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--source-commit", required=True, help="Commit used to archive this app; never inferred from a later checkout")
    parser.add_argument("--since", help="Override the preceding release commit (legacy migration)")
    parser.add_argument("--host", default="sub-ubuntu")
    args = parser.parse_args()
    previous = previous_release(args.host)
    base = args.since or (previous or {}).get("source_commit")
    if previous and not base:
        parser.error("Previous release has no Git provenance; provide --since")
    metadata, _ = bundle_metadata(args.app)
    if previous and int(metadata["build"]) <= previous["build"]:
        parser.error("CURRENT_PROJECT_VERSION must exceed the last published build")
    print(prepare(args.app, args.sparkle_bin, args.output, args.repo, args.source_commit, base))


if __name__ == "__main__":
    main()
