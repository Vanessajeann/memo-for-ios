"""Package a real Xcode-built arm64 app; never manufacture a stub executable."""
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / 'build/Memo.xcarchive/Products/Applications/Memo.app'
if not app.is_dir():
    raise SystemExit('Missing Xcode archive application')
info = plistlib.loads((app / 'Info.plist').read_bytes())
binary = app / info['CFBundleExecutable']
subprocess.run(['xcrun', 'lipo', str(binary), '-verify_arch', 'arm64'], check=True)
if tuple(map(int, info['MinimumOSVersion'].split('.'))) > (18, 6, 2):
    raise SystemExit('MinimumOSVersion is newer than the target iOS 18.6.2')
payload = root / 'build/ipa/Payload'
if payload.exists():
    shutil.rmtree(payload)
payload.mkdir(parents=True)
shutil.copytree(app, payload / app.name, symlinks=True)
output = root / 'outputs/Memo-dev-bootstrap-unsigned.ipa'
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(output)], check=True)
print(json.dumps({'ipa': output.name, 'bundle': info['CFBundleIdentifier'], 'minimum_ios': info['MinimumOSVersion'], 'status': 'development-bootstrap'}, ensure_ascii=False))
