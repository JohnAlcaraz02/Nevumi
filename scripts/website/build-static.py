#!/usr/bin/env python3
"""Package docs/ as static hosting output without app source or credentials."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[2]
source = root / "docs"
output = root / "dist"
marker = output / ".nevumi-static-output"
if not (source / "index.html").is_file():
    raise SystemExit("Missing docs/index.html")
if output.exists():
    if output.is_symlink() or not marker.is_file():
        raise SystemExit("Refusing to replace an unrecognized dist directory")
    shutil.rmtree(output)
shutil.copytree(source, output)
marker.write_text("Generated from docs/ by scripts/website/build-static.py\n")
print("Built static website from docs/ into dist/")
