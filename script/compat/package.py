#!/usr/bin/env python3
"""Package the verified app together with complete corresponding source."""
import hashlib
import importlib.util
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('gate', root/'script/compat/verify.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
app = root/'build/compat/NTFSWriteFlowCompat.app'
report = gate.verify(app)
output = root/'dist/NTFSWriteFlowCompat-0.1.2-compat.1'
output.mkdir(parents=True, exist_ok=True)
(output/'产物验证.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
(output/'使用与构建说明.md').write_bytes((root/'兼容版说明.md').read_bytes())
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(output/'NTFS畅写兼容版-Intel与Apple芯片-macOS13以上.zip')], check=True)
with tempfile.TemporaryDirectory(prefix='writeflow-source-') as temporary:
    bundle = Path(temporary)/'ntfs-3g-pinned.bundle'
    subprocess.run(['git','-C',str(root/'ThirdParty/ntfs-3g'),'bundle','create',str(bundle),'HEAD'], check=True)
    files = subprocess.check_output(['git','ls-files','-co','--exclude-standard','-z'],cwd=root).decode().split('\0')
    dependency = subprocess.check_output(['git','ls-files','-z'],cwd=root/'ThirdParty/ntfs-3g').decode().split('\0')
    files = sorted(set(f for f in files if f and f != 'ThirdParty/ntfs-3g'))
    files += ['ThirdParty/ntfs-3g/'+f for f in dependency if f]
    prefix='NTFSWriteFlowCompat-Source'
    with tarfile.open(output/'完整对应源码.tar.gz','w:gz') as archive:
        for relative in files:
            path=root/relative
            if path.is_file() or path.is_symlink(): archive.add(path,arcname=prefix+'/'+relative,recursive=False)
        archive.add(bundle,arcname=prefix+'/ThirdParty/ntfs-3g-pinned.bundle')
checksums=[]
for path in sorted(output.iterdir()):
    if path.is_file() and path.name != 'SHA256SUMS.txt':
        checksums.append(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name)
(output/'SHA256SUMS.txt').write_text('\n'.join(checksums)+'\n')
print(output)
