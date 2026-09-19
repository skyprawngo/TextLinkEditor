import base64
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "server/update_service"))
from manage import verify_archive
from app import connect, digest


class PublicationTests(unittest.TestCase):
    def test_signature_rejects_corruption_and_wrong_signer(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "test.zip"
            archive.write_bytes(b"fixture archive bytes")
            private = Ed25519PrivateKey.generate()
            public = private.public_key().public_bytes_raw()
            signature = base64.b64encode(private.sign(archive.read_bytes())).decode()
            verify_archive(archive, signature, public)
            with self.assertRaises(InvalidSignature):
                verify_archive(archive, signature)  # fixture is not signed by production signer
            archive.write_bytes(b"tampered archive bytes")
            with self.assertRaises(InvalidSignature):
                verify_archive(archive, signature, public)

    def test_issue_stores_hash_only_and_list_hides_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, str(Path(__file__).resolve().parents[2] /
                       "server/update_service/manage.py"), "--data", directory]
            key = subprocess.check_output(command + ["issue", "--label", "fixture", "--devices", "3"], text=True).strip()
            self.assertTrue(key.startswith("tle_"))
            with connect(Path(directory)) as db:
                license = db.execute("SELECT * FROM licenses").fetchone()
                self.assertEqual(license["key_hash"], digest(key))
                self.assertEqual(license["max_devices"], 3)
            listing = subprocess.check_output(command + ["list"], text=True)
            self.assertNotIn(key, listing)
            self.assertNotIn(digest(key), listing)


if __name__ == "__main__":
    unittest.main()
