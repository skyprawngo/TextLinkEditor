"""Run via SSH/docker exec. Keys are emitted once; never put them in command arguments."""
import argparse
import base64
import getpass
import hashlib
import plistlib
import zipfile
import json
import os
import re
import secrets
import shutil
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from app import initialize, connect, digest


PUBLIC_KEY = base64.b64decode("8PoDq94aYfjuGKxU/MnIm99Y78pEFYj9xRCTjUmup2Y=")


def verify_archive(archive, signature, public_key=PUBLIC_KEY):
    Ed25519PublicKey.from_public_bytes(public_key).verify(
        base64.b64decode(signature, validate=True), archive.read_bytes())


def load_release_manifest(path):
    if path.stat().st_size > 256_000:
        raise ValueError("manifest too large")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    filename = manifest.get("filename", "")
    if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip", filename):
        raise ValueError("manifest requires a local ZIP filename")
    archive = path.parent / filename
    if archive.resolve().parent != path.parent.resolve():
        raise ValueError("archive must be beside manifest")
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != manifest.get("sha256"):
            raise ValueError("archive checksum mismatch")
    for key in ("source_commit", "previous_commit"):
        value = manifest.get(key)
        if key == "previous_commit" and value is None:
            continue
        if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", value):
            raise ValueError("invalid Git commit in manifest")
    if not isinstance(manifest.get("notes"), str) or not manifest["notes"].strip() or len(manifest["notes"]) > 100_000:
        raise ValueError("manifest must contain nonempty release notes")
    if not isinstance(manifest.get("build"), str) or not re.fullmatch(r"[1-9][0-9]{0,8}", manifest["build"]):
        raise ValueError("invalid build")
    if not isinstance(manifest.get("signature"), str):
        raise ValueError("missing signature")
    # Verify metadata against the actual app inside the signed archive, not a mutable label.
    with zipfile.ZipFile(archive) as package:
        entries = [i for i in package.infolist() if len(i.filename.split("/")) == 3
                   and i.filename.endswith(".app/Contents/Info.plist")]
        if len(entries) != 1 or entries[0].file_size > 1_048_576:
            raise ValueError("expected one app Info.plist")
        info = plistlib.loads(package.read(entries[0]))
    if info.get("CFBundleIdentifier") != "com.textlinkeditor.app":
        raise ValueError("wrong app bundle")
    for field, plist_key in (("version", "CFBundleShortVersionString"), ("build", "CFBundleVersion"),
                             ("minimum_os", "LSMinimumSystemVersion")):
        if manifest.get(field) != info.get(plist_key):
            raise ValueError("manifest does not match Xcode bundle: " + field)
    return manifest, archive


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.environ.get("UPDATE_DATA", "/data"))
    commands = parser.add_subparsers(dest="command", required=True)
    issue = commands.add_parser("issue")
    issue.add_argument("--label", required=True)
    issue.add_argument("--devices", type=int, default=2)
    commands.add_parser("revoke")
    commands.add_parser("reset-devices")
    commands.add_parser("list")
    commands.add_parser("release-info")
    manifest_publish = commands.add_parser("publish-manifest")
    manifest_publish.add_argument("manifest", type=Path)
    publish = commands.add_parser("publish")
    publish.add_argument("archive")
    publish.add_argument("--build", type=int, required=True)
    publish.add_argument("--version", required=True)
    publish.add_argument("--signature", required=True)
    publish.add_argument("--minimum-os", default="26.0")
    publish.add_argument("--notes-file")
    withdraw = commands.add_parser("withdraw")
    withdraw.add_argument("build", type=int)
    args = parser.parse_args()
    manifest = None
    if args.command == "publish-manifest":
        try:
            manifest, archive = load_release_manifest(args.manifest)
        except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
            parser.error(str(error))
        args.archive = str(archive)
        args.build = int(manifest["build"])
        args.version = manifest["version"]
        args.signature = manifest["signature"]
        args.minimum_os = manifest["minimum_os"]
        args.notes_file = None
        args.command = "publish"
    root = Path(args.data)
    initialize(root)
    with connect(root) as db:
        if args.command == "issue":
            if args.devices < 1:
                parser.error("devices must be positive")
            key = "tle_" + secrets.token_urlsafe(32)
            db.execute("INSERT INTO licenses(key_hash,label,max_devices) VALUES (?,?,?)",
                       (digest(key), args.label, args.devices))
            print(key)
        elif args.command in ("revoke", "reset-devices"):
            key_hash = digest(getpass.getpass("App key: "))
            if not db.execute("SELECT 1 FROM licenses WHERE key_hash=?", (key_hash,)).fetchone():
                parser.error("unknown key")
            db.execute("DELETE FROM sessions WHERE key_hash=?", (key_hash,))
            if args.command == "revoke":
                db.execute("UPDATE licenses SET revoked=1 WHERE key_hash=?", (key_hash,))
            else:
                db.execute("DELETE FROM devices WHERE key_hash=?", (key_hash,))
        elif args.command == "release-info":
            record = db.execute("""SELECT r.build,r.version,p.source_commit,p.previous_commit
                FROM releases r LEFT JOIN release_provenance p ON p.build=r.build
                ORDER BY r.build DESC LIMIT 1""").fetchone()
            print(json.dumps(dict(record) if record else None))
        elif args.command == "list":
            print(json.dumps([dict(r) for r in db.execute('''SELECT label,max_devices,revoked,
                (SELECT COUNT(*) FROM devices d WHERE d.key_hash=l.key_hash) AS device_count
                FROM licenses l''')], ensure_ascii=False, indent=2))
        elif args.command == "withdraw":
            db.execute("UPDATE releases SET active=0 WHERE build=?", (args.build,))
        elif args.command == "publish":
            archive = Path(args.archive)
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.(zip|dmg)", archive.name):
                parser.error("use a simple .zip or .dmg filename")
            if not archive.is_file() or archive.stat().st_size == 0 or args.build < 1:
                parser.error("invalid archive/build")
            for value in (args.version, args.minimum_os):
                if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
                    parser.error("version must be numeric")
            try:
                if len(base64.b64decode(args.signature, validate=True)) != 64:
                    raise ValueError("signature length")
            except Exception:
                parser.error("invalid Ed25519 signature")
            # Independently verify the archive before making it visible to clients.
            try:
                verify_archive(archive, args.signature)
            except Exception:
                parser.error("archive signature verification failed")
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT COALESCE(MAX(build),0) FROM releases").fetchone()[0]
            if manifest:
                prior = db.execute("SELECT source_commit FROM release_provenance WHERE build=?", (previous,)).fetchone()
                if prior and manifest["previous_commit"] != prior["source_commit"]:
                    parser.error("release base changed; regenerate notes from the latest published commit")
            if args.build <= previous:
                parser.error("build must increase, including withdrawn releases")
            destination = root / "releases" / archive.name
            if destination.exists():
                parser.error("archive filename already exists; use a unique build filename")
            temporary = destination.with_suffix(destination.suffix + ".partial")
            try:
                shutil.copyfile(archive, temporary)
                temporary.replace(destination)
                notes = manifest["notes"] if manifest else (Path(args.notes_file).read_text() if args.notes_file else "")
                db.execute("INSERT INTO releases VALUES (?,?,?,?,?,?,?,1)",
                           (args.build, args.version, archive.name, args.signature,
                            destination.stat().st_size, args.minimum_os, notes))
                if manifest:
                    db.execute("INSERT INTO release_provenance VALUES (?,?,?)",
                               (args.build, manifest["source_commit"], manifest["previous_commit"]))
            except Exception:
                temporary.unlink(missing_ok=True)
                destination.unlink(missing_ok=True)
                raise
            print("Published build", args.build)


if __name__ == "__main__":
    main()
