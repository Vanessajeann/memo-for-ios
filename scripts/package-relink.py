"""Distribute the patched LGPL source, static libs, headers and application objects."""
from pathlib import Path
import tarfile
root = Path(__file__).resolve().parents[1]
destination = root / 'outputs/Memo-relink-materials.tar.gz'
objects = root / 'build/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/Memo/IntermediateBuildFilesPath'
if not objects.is_dir() or not list(objects.rglob('*.o')):
    raise SystemExit('Relinking object files are missing')
def allowed(info):
    if any(p in {'.git', '.build', '__pycache__'} for p in Path(info.name).parts): return None
    if Path(info.name).suffix in {'.p12', '.mobileprovision'}: raise SystemExit('Unexpected signing material')
    return info
with tarfile.open(destination, 'w:gz') as archive:
    for name in ['App','Native','MemoCore','scripts','tests','project.yml','LICENSE','THIRD_PARTY_NOTICES.md']:
        archive.add(root/name, arcname='Memo-source/'+name, filter=allowed)
    # Read the actual checkout: includes the documented TLS/cookie modifications.
    archive.add(root/'build/ffmpeg-source', arcname='FFmpeg-source', recursive=True, filter=allowed)
    archive.add(root/'build/ffmpeg-ios', arcname='FFmpeg-ios', filter=allowed)
    archive.add(objects, arcname='Application-objects', filter=allowed)
print('LGPL source and application relinking materials:', destination.name)
