import concurrent.futures
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from xml.etree import ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "server/update_service"))
from app import create_app, connect, digest, SPARKLE


class UpdateServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = create_app(self.root)
        self.client = self.app.test_client()
        self.key = "test-only-license-key"
        self.device = str(uuid.uuid4())
        with connect(self.root) as db:
            db.execute("INSERT INTO licenses VALUES (?,?,?,0)", (digest(self.key), "fixture", 1))

    def check(self, **changes):
        payload = dict(device_id=self.device, app_key=self.key, version="0.1.0", build="1")
        payload.update(changes)
        return self.client.post("/v1/check", json=payload)

    def release(self, build=2):
        (self.root / "releases/test.zip").write_bytes(b"test-only-archive")
        with connect(self.root) as db:
            db.execute("INSERT INTO releases VALUES (?,?,?,?,?,?,?,1)",
                       (build, "0.2.0", "test.zip", "test-signature", 17, "26.0", "Fix <save> & reopen"))

    def test_public_metadata_does_not_activate_or_expose_credentials(self):
        self.assertFalse(self.client.get("/v1/releases/latest?build=1").json["update_available"])
        self.release()
        response = self.client.get("/v1/releases/latest?build=1&version=0.1.0")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["release"], dict(build="2", version="0.2.0",
            notes="Fix <save> & reopen", minimum_os="26.0"))
        self.assertNotIn("token", response.json)
        # Public latest version/notes are readable even without a comparison build.
        self.assertEqual(self.client.get("/v1/releases/latest").json["release"], response.json["release"])
        self.assertEqual(self.client.get("/v1/releases/latest?build=2").json["release"], response.json["release"])
        for build in ["2", "10"]:
            self.assertFalse(self.client.get("/v1/releases/latest?build=" + build).json["update_available"])
        for build in ["bad", "0", "-1"]:
            self.assertEqual(self.client.get("/v1/releases/latest?build=" + build).status_code, 400)
        with connect(self.root) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0], 0)

    def test_accepted_build_is_pinned_and_withdrawal_does_not_substitute(self):
        self.release()
        with connect(self.root) as db:
            db.execute("INSERT INTO releases VALUES (3,'0.3.0','new.zip','signature',1,'26.0','new',1)")
        result = self.check(target_build="2").json
        self.assertEqual(result["latest_version"], "0.2.0")
        feed = self.client.get("/v1/appcast.xml?build=2", headers={"Authorization": "Bearer " + result["token"]})
        items = ET.fromstring(feed.data).findall("channel/item/enclosure")
        self.assertEqual([i.attrib["{" + SPARKLE + "}version"] for i in items], ["2"])
        with connect(self.root) as db:
            db.execute("UPDATE releases SET active=0 WHERE build=2")
        self.assertFalse(self.check(target_build="2").json["update_available"])
        self.assertEqual(self.check(target_build="bad").status_code, 400)

    def test_no_release_and_equal_or_older_build(self):
        self.assertEqual(self.check().json, dict(license_status="valid", update_available=False))
        self.release()
        for build in ["2", "3", "10"]:
            self.assertFalse(self.check(build=build).json["update_available"])

    def test_authenticated_feed_download_range_and_no_cache(self):
        self.release()
        response = self.check()
        self.assertTrue(response.json["update_available"])
        headers = {"Authorization": "Bearer " + response.json["token"]}
        feed = self.client.get("/v1/appcast.xml", headers=headers)
        item = ET.fromstring(feed.data).find("channel/item/enclosure")
        self.assertEqual(item.attrib["{" + SPARKLE + "}version"], "2")
        self.assertTrue(item.attrib["url"].startswith("https://textlinkeditor.skyprawngo.com/"))
        self.assertEqual(feed.headers["Cache-Control"], "no-store")
        with self.client.get("/v1/download/test.zip", headers={**headers, "Range": "bytes=0-3"}) as download:
            self.assertEqual(download.status_code, 206)
            self.assertEqual(download.data, b"test")
        for path in ["/v1/appcast.xml", "/v1/download/test.zip"]:
            self.assertEqual(self.client.get(path).status_code, 401)
        with connect(self.root) as db:
            db.execute("UPDATE licenses SET revoked=1")
        self.assertEqual(self.client.get("/v1/download/test.zip", headers=headers).status_code, 401)
        self.assertEqual(self.check().json["license_status"], "revoked")

    def test_missing_invalid_and_device_limit(self):
        self.assertEqual(self.check(app_key="").json["license_status"], "unlicensed")
        self.assertEqual(self.check(app_key="wrong").json["license_status"], "invalid")
        self.check()
        self.assertEqual(self.check(device_id=str(uuid.uuid4())).json["license_status"], "device_limit")
        self.assertEqual(self.check().json["license_status"], "valid")
        with connect(self.root) as db:
            row = db.execute("SELECT * FROM devices").fetchone()
            self.assertEqual(row["device_hash"], digest(self.device))
            self.assertNotEqual(row["key_hash"], self.key)

    def test_parallel_activation_cannot_overbook(self):
        def activate(_):
            with self.app.test_client() as client:
                return client.post("/v1/check", json=dict(device_id=str(uuid.uuid4()),
                    app_key=self.key, version="0.1.0", build="1")).json["license_status"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(activate, range(8)))
        self.assertEqual(results.count("valid"), 1)
        self.assertEqual(results.count("device_limit"), 7)

    def test_bad_input_is_not_server_error(self):
        for changes in [dict(device_id="bad"), dict(app_key=[]), dict(build="-1"),
                        dict(build=1), dict(version={}), dict(version="x"), dict(build="1.0")]:
            self.assertEqual(self.check(**changes).status_code, 400)
        self.assertEqual(self.client.post("/v1/check", json=[]).status_code, 400)
        self.assertEqual(self.check(app_key="x" * 5000).status_code, 413)

    def test_expired_token_and_withdrawn_release(self):
        self.release()
        token = self.check().json["token"]
        headers = {"Authorization": "Bearer " + token}
        with connect(self.root) as db:
            db.execute("UPDATE releases SET active=0")
        self.assertFalse(self.check().json["update_available"])
        self.assertEqual(self.client.get("/v1/download/test.zip", headers=headers).status_code, 404)
        with connect(self.root) as db:
            db.execute("UPDATE sessions SET expires=?", (int(time.time()) - 1,))
        self.assertEqual(self.client.get("/v1/appcast.xml", headers=headers).status_code, 401)


if __name__ == "__main__":
    unittest.main()
