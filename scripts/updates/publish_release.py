#!/usr/bin/env python3
"""Explicit publication of a prepared manifest and archive over SSH."""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--host", default="sub-ubuntu")
    args = parser.parse_args()
    manifest = args.manifest.resolve()
    metadata = json.loads(manifest.read_text(encoding="utf-8"))
    filename = metadata.get("filename", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip", filename):
        parser.error("invalid archive filename")
    archive = manifest.parent / filename
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != metadata.get("sha256"):
            parser.error("archive checksum mismatch")
    host = args.host
    def ssh(command):
        return subprocess.check_output(["ssh", "-o", "BatchMode=yes", host, command], text=True).strip()
    remote = ssh("mktemp -d /tmp/textlinkeditor-release.XXXXXXXX")
    if not re.fullmatch(r"/tmp/textlinkeditor-release\.[A-Za-z0-9]+", remote):
        raise RuntimeError("Unexpected staging path")
    # Arguments sent to a remote shell are quoted; commit messages never enter commands.
    subprocess.run(["scp", str(manifest), host + ":" + remote + "/manifest.json"], check=True)
    subprocess.run(["scp", str(archive), host + ":" + remote + "/" + filename], check=True)
    prefix = "cd /home/sub/textlinkeditor-updates && "
    print(ssh(prefix + "docker compose cp " + shlex.quote(remote) + " updates:/tmp/"))
    container_manifest = "/tmp/" + Path(remote).name + "/manifest.json"
    print(ssh(prefix + "docker compose exec -T updates python manage.py publish-manifest " + shlex.quote(container_manifest)))
    print("Published metadata:", ssh(prefix + "docker compose exec -T updates python manage.py release-info"))
    print("Staged files retained for inspection:", remote, "(host and container)")


if __name__ == "__main__":
    main()
