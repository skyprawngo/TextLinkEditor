"""Load the built framework and Info.plist in an isolated, headless host bundle."""
import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("built_app", type=Path)
parser.add_argument("sparkle_framework", type=Path, help="Unstripped Sparkle.framework with Headers/Modules")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="textlinkeditor-update-smoke-") as directory:
    contents = Path(directory) / "UpdateSmoke.app/Contents"
    (contents / "MacOS").mkdir(parents=True)
    built = args.built_app / "Contents"
    info = plistlib.loads((built / "Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.textlinkeditor.update-smoke", CFBundleExecutable="UpdateSmoke")
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["ditto", str(built / "Frameworks/Sparkle.framework"),
                    str(contents / "Frameworks/Sparkle.framework")], check=True)
    executable = contents / "MacOS/UpdateSmoke"
    subprocess.run(["swiftc", "-parse-as-library", "-F", str(args.sparkle_framework.parent),
                    "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    str(Path(__file__).with_name("SparkleSmoke.swift")), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
