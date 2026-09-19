"""License-gated Sparkle origin. Admin operations are SSH-only (manage.py)."""
from contextlib import contextmanager
import hashlib
import html
import os
import re
import secrets
import sqlite3
import time
import uuid
from pathlib import Path
from xml.etree import ElementTree as ET
from flask import Flask, abort, jsonify, request, send_file

ORIGIN = "https://textlinkeditor.skyprawngo.com"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


@contextmanager
def connect(root):
    db = sqlite3.connect(root / "licenses.sqlite3", timeout=15)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    try:
        with db:
            yield db
    finally:
        db.close()


def initialize(root):
    root.mkdir(parents=True, exist_ok=True)
    (root / "releases").mkdir(exist_ok=True)
    with connect(root) as db:
        db.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS licenses (
            key_hash TEXT PRIMARY KEY, label TEXT NOT NULL,
            max_devices INTEGER NOT NULL CHECK(max_devices > 0),
            revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS release_provenance (
            build INTEGER PRIMARY KEY REFERENCES releases(build),
            source_commit TEXT NOT NULL, previous_commit TEXT);
        CREATE TABLE IF NOT EXISTS devices (
            key_hash TEXT NOT NULL REFERENCES licenses(key_hash),
            device_hash TEXT NOT NULL, last_seen INTEGER NOT NULL,
            version TEXT NOT NULL, build INTEGER NOT NULL,
            PRIMARY KEY(key_hash, device_hash));
        CREATE TABLE IF NOT EXISTS sessions (
            token_hash TEXT PRIMARY KEY, key_hash TEXT NOT NULL REFERENCES licenses(key_hash),
            device_hash TEXT NOT NULL, expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS releases (
            build INTEGER PRIMARY KEY CHECK(build > 0), version TEXT NOT NULL,
            filename TEXT UNIQUE NOT NULL, signature TEXT NOT NULL,
            size INTEGER NOT NULL, minimum_os TEXT NOT NULL,
            notes TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1);
        ''')
    os.chmod(root / "licenses.sqlite3", 0o600)


def create_app(data_dir=None):
    root = Path(data_dir or os.environ.get("UPDATE_DATA", "/data"))
    initialize(root)
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 4096

    @app.after_request
    def private(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    def authorize():
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or len(auth) > 200:
            abort(401)
        with connect(root) as db:
            session = db.execute('''SELECT s.* FROM sessions s JOIN licenses l
                ON s.key_hash=l.key_hash WHERE s.token_hash=? AND s.expires>?
                AND l.revoked=0''', (digest(auth[7:]), int(time.time()))).fetchone()
        if session is None:
            abort(401)

    @app.get("/healthz")
    def health():
        with connect(root) as db:
            db.execute("SELECT 1").fetchone()
        return jsonify(status="ok")

    @app.get("/v1/releases/latest")
    def latest_release():
        build = request.args.get("build")
        if build is not None and not re.fullmatch(r"[1-9][0-9]{0,8}", build):
            abort(400)
        with connect(root) as db:
            latest = db.execute("SELECT * FROM releases WHERE active=1 ORDER BY build DESC LIMIT 1").fetchone()
        if latest is None:
            return jsonify(update_available=False, release=None)
        # Public metadata only: no identity access, activation, token or archive URL.
        return jsonify(update_available=bool(build is not None and latest["build"] > int(build)), release=dict(
            build=str(latest["build"]), version=latest["version"],
            notes=latest["notes"], minimum_os=latest["minimum_os"]))

    @app.post("/v1/check")
    def check():
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            abort(400)
        device, key, version, build = (payload.get(n) for n in
                                      ("device_id", "app_key", "version", "build"))
        if not isinstance(device, str) or not isinstance(key, str) or len(key) > 256:
            abort(400)
        try:
            device = str(uuid.UUID(device))
        except (ValueError, AttributeError):
            abort(400)
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version) or len(version) > 32:
            abort(400)
        if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]{0,8}", build):
            abort(400)
        target_build = payload.get("target_build")
        if target_build is not None and (not isinstance(target_build, str) or not re.fullmatch(r"[1-9][0-9]{0,8}", target_build)):
            abort(400)
        now = int(time.time())
        key_hash, device_hash = digest(key), digest(device)
        with connect(root) as db:
            # Serializes first activations so concurrent requests cannot exceed the seat limit.
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM sessions WHERE expires<=?", (now,))
            license = db.execute("SELECT * FROM licenses WHERE key_hash=?", (key_hash,)).fetchone()
            status = "unlicensed" if not key else "invalid"
            if license:
                status = "revoked" if license["revoked"] else "valid"
            if status != "valid":
                return jsonify(license_status=status, update_available=False)
            exists = db.execute("SELECT 1 FROM devices WHERE key_hash=? AND device_hash=?",
                                (key_hash, device_hash)).fetchone()
            count = db.execute("SELECT COUNT(*) FROM devices WHERE key_hash=?", (key_hash,)).fetchone()[0]
            if not exists and count >= license["max_devices"]:
                return jsonify(license_status="device_limit", update_available=False)
            db.execute('''INSERT INTO devices VALUES (?,?,?,?,?) ON CONFLICT(key_hash,device_hash)
                DO UPDATE SET last_seen=excluded.last_seen,version=excluded.version,build=excluded.build''',
                       (key_hash, device_hash, now, version, int(build)))
            if target_build is None:
                latest = db.execute("SELECT * FROM releases WHERE active=1 ORDER BY build DESC LIMIT 1").fetchone()
            else:
                latest = db.execute("SELECT * FROM releases WHERE active=1 AND build=?", (int(target_build),)).fetchone()
            result = dict(license_status="valid", update_available=bool(latest and latest["build"] > int(build)))
            if result["update_available"]:
                token = secrets.token_urlsafe(32)
                # A token permits retry/resume for 24h; revocation is checked on every request.
                db.execute("INSERT INTO sessions VALUES (?,?,?,?)", (digest(token), key_hash, device_hash, now + 86400))
                result.update(token=token, latest_version=latest["version"])
            return jsonify(result)

    @app.get("/v1/appcast.xml")
    def appcast():
        authorize()
        target_build = request.args.get("build")
        if target_build is not None and not re.fullmatch(r"[1-9][0-9]{0,8}", target_build):
            abort(400)
        rss = ET.Element("rss", version="2.0")
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "TextlinkEditor"
        with connect(root) as db:
            if target_build is None:
                releases = db.execute("SELECT * FROM releases WHERE active=1 ORDER BY build DESC LIMIT 20").fetchall()
            else:
                releases = db.execute("SELECT * FROM releases WHERE active=1 AND build=?", (int(target_build),)).fetchall()
        for release in releases:
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = release["version"]
            ET.SubElement(item, "description").text = html.escape(release["notes"]).replace("\n", "<br/>")
            ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = release["minimum_os"]
            ET.SubElement(item, "enclosure", {
                "url": ORIGIN + "/v1/download/" + release["filename"],
                "length": str(release["size"]), "type": "application/octet-stream",
                "{" + SPARKLE + "}version": str(release["build"]),
                "{" + SPARKLE + "}shortVersionString": release["version"],
                "{" + SPARKLE + "}edSignature": release["signature"],
            })
        return app.response_class(ET.tostring(rss, encoding="utf-8", xml_declaration=True), mimetype="application/xml")

    @app.get("/v1/download/<filename>")
    def download(filename):
        authorize()
        with connect(root) as db:
            release = db.execute("SELECT * FROM releases WHERE filename=? AND active=1", (filename,)).fetchone()
        if not release or Path(filename).name != filename:
            abort(404)
        return send_file(root / "releases" / filename, conditional=True, as_attachment=True)

    return app
