#!/usr/bin/env python3
"""Render real Nevumi views with isolated sample data; never starts app services.
Requires Xcode, XcodeGen, and the app's resolved packages in .build/Nevumi.
Production sources are copied to a temporary target; the app is not modified.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
output = root / 'docs' / 'screenshots'
output.mkdir(parents=True, exist_ok=True)
workspace = Path(tempfile.mkdtemp(prefix='nevumi-website-'))
source = workspace / 'Source'
shutil.copytree(root / 'Nevumi', source)
(source / 'App' / 'NevumiApp.swift').unlink()
for path in source.rglob('*.swift'):
    text = path.read_text()
    # Expose views and fixture state only in the disposable rendering target.
    text = re.sub(r'^private (struct|enum|final class|class) ', r'\1 ', text, flags=re.M)
    text = text.replace('@Published private(set)', '@Published')
    if path.name == 'SpotifyObserver.swift':
        text = text.replace('private var lastPosition:', 'var lastPosition:').replace('private var lastPositionDate', 'var lastPositionDate')
    path.write_text(text)
shutil.copy(root / 'scripts' / 'website' / 'ScreenshotMain.swift', source / 'ScreenshotMain.swift')
packages = {}
for name in ['DynamicNotchKit', 'SkyLightWindow']:
    checkout = root / '.build' / 'Nevumi' / 'SourcePackages' / 'checkouts' / name
    if not checkout.is_dir():
        raise SystemExit('Build Nevumi with -derivedDataPath .build/Nevumi to resolve packages first.')
    packages[name] = {'path': str(checkout)}
project = {
    'name': 'NevumiScreenshots',
    'packages': packages,
    'targets': {'NevumiScreenshots': {
        'type': 'application', 'platform': 'macOS', 'deploymentTarget': '26.0',
        'sources': ['Source'],
        'dependencies': [{'package': name} for name in packages],
        'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.nevumi.website-renderer',
            'SWIFT_VERSION': '5.0', 'GENERATE_INFOPLIST_FILE': 'YES',
            'CODE_SIGNING_ALLOWED': 'NO', 'ENABLE_APP_SANDBOX': 'NO'}},
    }},
}
(workspace / 'project.yml').write_text(json.dumps(project))
subprocess.run(['xcodegen', 'generate', '--spec', str(workspace / 'project.yml')], check=True, cwd=workspace)
log = workspace / 'build.log'
with log.open('w') as stream:
    build = subprocess.run(['xcodebuild', '-project', str(workspace / 'NevumiScreenshots.xcodeproj'),
        '-scheme', 'NevumiScreenshots', '-configuration', 'Debug', '-destination', 'platform=macOS',
        '-derivedDataPath', str(workspace / 'Build'), 'build'], stdout=stream, stderr=stream)
if build.returncode:
    print(log.read_text()[-14000:])
    raise SystemExit(f'Build failed. Full log: {log}')
app = workspace / 'Build' / 'Build' / 'Products' / 'Debug' / 'NevumiScreenshots.app'
subprocess.run([str(app / 'Contents' / 'MacOS' / 'NevumiScreenshots'), str(output)], check=True)
print(f'Rendered website images in {output}')
print(f'Temporary build: {workspace}')

# Render the native sample document windows used by the focus preview.
window_renderer = workspace / 'window-switching-images'
subprocess.run(['swiftc', '-parse-as-library', str(root / 'scripts' / 'website' / 'WindowSwitching.swift'), '-o', str(window_renderer)], check=True)
subprocess.run([str(window_renderer), str(output)], check=True)
