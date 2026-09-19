import base64
import contextlib
import hashlib
import io
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/updates"))
sys.path.insert(0, str(ROOT / "server/update_service"))
from release_metadata import commit_notes, bundle_metadata
from manage import load_release_manifest, main, verify_archive
from app import create_app, connect


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Release Fixture")
        self.git("config", "user.email", "fixture@example.invalid")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def commit(self, message):
        self.git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def test_commit_range_is_bounded_and_uses_subjects_only(self):
        base = self.commit("Old public release")
        self.commit("Fix saving\n\nInternal body is not a release note")
        head = self.commit("한글 입력 개선")
        notes, resolved, previous = commit_notes(self.repo, head, base)
        self.assertEqual(notes, "• Fix saving\n• 한글 입력 개선")
        self.assertEqual((resolved, previous), (head, base))
        self.commit("Future unpublished change")
        self.assertEqual(commit_notes(self.repo, head, base)[0], notes)
        self.assertIn("Old public release", commit_notes(self.repo, base)[0])
        with self.assertRaises(ValueError):
            commit_notes(self.repo, head, head)
        self.git("checkout", "--orphan", "unrelated")
        unrelated = self.commit("Unrelated release")
        with self.assertRaises(ValueError):
            commit_notes(self.repo, unrelated, base)

    def artifact(self):
        app = self.root / "TextlinkEditor.app"
        (app / "Contents").mkdir(parents=True)
        info = dict(CFBundleIdentifier="com.textlinkeditor.app", CFBundleVersion="42",
                    CFBundleShortVersionString="1.2.3", LSMinimumSystemVersion="26.0")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        metadata, _ = bundle_metadata(app)
        commit = self.commit("Fix <save> & reopen")
        notes, _, _ = commit_notes(self.repo, commit)
        archive = self.root / "TextlinkEditor-1.2.3-42.zip"
        with zipfile.ZipFile(archive, "w") as package:
            package.write(app / "Contents/Info.plist", "TextlinkEditor.app/Contents/Info.plist")
        private = Ed25519PrivateKey.generate()
        manifest = dict(metadata, filename=archive.name, notes=notes, source_commit=commit, previous_commit=None,
                        sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                        signature=base64.b64encode(private.sign(archive.read_bytes())).decode())
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest))
        return path, archive, manifest, private.public_key().public_bytes_raw()

    def test_xcode_metadata_to_public_api_round_trip(self):
        path, archive, manifest, public_key = self.artifact()
        self.assertEqual(load_release_manifest(path)[0], manifest)
        data = self.root / "data"
        def publish():
            with patch.object(sys, "argv", ["manage", "--data", str(data), "publish-manifest", str(path)]), \
                 patch("manage.verify_archive", side_effect=lambda a, s: verify_archive(a, s, public_key)), \
                 contextlib.redirect_stdout(io.StringIO()):
                main()
        publish()
        client = create_app(data).test_client()
        release = client.get("/v1/releases/latest").json["release"]
        self.assertEqual(release, dict(build="42", version="1.2.3", minimum_os="26.0", notes="• Fix <save> & reopen"))
        self.assertTrue(client.get("/v1/releases/latest?build=41").json["update_available"])
        self.assertFalse(client.get("/v1/releases/latest?build=42").json["update_available"])
        output = io.StringIO()
        with patch.object(sys, "argv", ["manage", "--data", str(data), "release-info"]), contextlib.redirect_stdout(output):
            main()
        self.assertEqual(json.loads(output.getvalue())["source_commit"], manifest["source_commit"])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            publish()  # Duplicate or stale publication must not overwrite.
        with connect(data) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM releases").fetchone()[0], 1)

    def test_manifest_cannot_relabel_bundle_or_point_outside_directory(self):
        path, archive, manifest, _ = self.artifact()
        for changes in [dict(version="9.9.9"), dict(build="999"), dict(minimum_os="1.0"),
                        dict(filename="../elsewhere.zip"), dict(sha256="0"*64), dict(notes="")]:
            path.write_text(json.dumps({**manifest, **changes}))
            with self.assertRaises(ValueError):
                load_release_manifest(path)


if __name__ == "__main__":
    unittest.main()
