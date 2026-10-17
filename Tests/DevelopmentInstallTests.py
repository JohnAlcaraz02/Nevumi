"""Run with python3 Tests/DevelopmentInstallTests.py /tmp/nevumi-development-installer."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile


installer = str(pathlib.Path(sys.argv[1]).resolve())


def app(path, bundle_id="com.johnalcaraz.SleepMusic", version="first"):
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Nevumi",
                      "CFBundlePackageType": "APPL"}, output)
    binary = contents / "MacOS/Nevumi"
    binary.write_text("#!/bin/sh\n# " + version + "\nexit 0\n")
    binary.chmod(0o755)
    return contents


def run(source, destination, success=True):
    result = subprocess.run([installer, str(source), str(destination)], capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix="nevumi-install-tests-") as root:
    root = pathlib.Path(root)
    source = root / "build/Nevumi.app"
    destination = root / "Applications/Nevumi.app"
    contents = app(source)
    (contents / "old-resource.txt").write_text("old")
    run(source, destination)
    assert (destination / "Contents/old-resource.txt").read_text() == "old"

    app(source, version="updated")
    (contents / "old-resource.txt").unlink()
    (contents / "new-resource.txt").write_text("new")
    run(source, destination)
    assert not (destination / "Contents/old-resource.txt").exists()
    assert (destination / "Contents/new-resource.txt").read_text() == "new"
    assert "updated" in (destination / "Contents/MacOS/Nevumi").read_text()
    run(destination, destination)

    invalid_source = root / "bad/Nevumi.app"
    app(invalid_source, bundle_id="example.unrelated")
    run(invalid_source, destination, success=False)
    assert (destination / "Contents/new-resource.txt").read_text() == "new"

    unrelated_destination = root / "other/Nevumi.app"
    app(unrelated_destination, bundle_id="example.unrelated", version="keep")
    run(source, unrelated_destination, success=False)
    assert "keep" in (unrelated_destination / "Contents/MacOS/Nevumi").read_text()
    run(source, root / "Applications/Another.app", success=False)
    assert not list((root / "Applications").glob(".nevumi-development-*"))

print("Development install tests passed: first install, replacement, resources, identity guards, and cleanup.")
