"""Prepare the original Memo vector icon as an iOS universal app icon catalog."""
from pathlib import Path
import json
import shutil
root = Path(__file__).resolve().parents[1]
catalog = root / 'build/MemoIcons.xcassets'
icon = catalog / 'AppIcon.appiconset'
icon.mkdir(parents=True, exist_ok=True)
info = {'info': {'author': 'xcode', 'version': 1}}
(catalog / 'Contents.json').write_text(json.dumps(info))
(icon / 'Contents.json').write_text(json.dumps(dict(info, images=[{
    'filename': 'MemoIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'
}])))
shutil.copyfile(root / 'App/MemoIcon.png', icon / 'MemoIcon.png')
