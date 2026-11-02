#!/usr/bin/env python3
"""Release gate: architecture, deployment target, pinned identity and resources."""
import json
import hashlib
import plistlib
import re
import subprocess
import sys
from pathlib import Path

PIN = '1DDCB3B175991894FC207A24F0B13D5C41F502B6'

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True).strip()

def requirement(identifier):
    return f'identifier "{identifier}" and certificate leaf = H"{PIN}"'

def verify(app):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'local.ntfswriteflow.compat'
    assert info['LSMinimumSystemVersion'] == '13.0'
    installer = app / 'Contents/Resources/fuse-t-macos-installer-1.2.9.pkg'
    assert hashlib.sha256(installer.read_bytes()).hexdigest() == 'a1b893740ded8ea034f1acc522ded1144f4a567a1f416daef8c1441cf2662f7f', 'Bundled FUSE-T package must match the official package.'
    for name in ['WriteFlow-Install-Service', 'WriteFlow-Remove-Service']:
        package=app / ('Contents/Resources/'+name+'.pkg')
        expected=(app / ('Contents/Resources/'+name+'.sha256')).read_text().strip()
        assert hashlib.sha256(package.read_bytes()).hexdigest() == expected
    binaries = {
        app / 'Contents/MacOS/WriteFlowCompat': 'local.ntfswriteflow.compat',
        app / 'Contents/Library/HelperTools/WriteFlowCompatHelper': 'local.ntfswriteflow.compat.mount-helper',
        app / 'Contents/Library/HelperTools/WriteFlowNTFS': 'local.ntfswriteflow.compat.engine',
    }
    result = []
    for binary, identifier in binaries.items():
        archs = run('xcrun', 'lipo', '-archs', str(binary)).split()
        assert set(archs) == {'x86_64', 'arm64'}, (binary, archs)
        versions = []
        for arch in archs:
            load = run('otool', '-arch', arch, '-l', str(binary))
            match = re.search(r'\bminos\s+([\d.]+)', load) or re.search(r'LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', load)
            assert match, binary
            version = tuple(map(int, match[1].split('.')))
            assert version <= (13, 0), (binary, arch, version)
            versions.append({'architecture': arch, 'minimumOS': match[1]})
        links = run('otool', '-L', str(binary))
        assert 'FSKit.framework' not in links, binary
        run('codesign', '--verify', '--strict', '-R', '=' + requirement(identifier), str(app if identifier == 'local.ntfswriteflow.compat' else binary))
        dr = run('codesign', '-dr', '-', str(app if identifier == 'local.ntfswriteflow.compat' else binary))
        assert PIN.lower() in dr.lower(), dr
        result.append({'binary': binary.name, 'slices': versions, 'designatedRequirement': dr})
    run('codesign', '--verify', '--deep', '--strict', str(app))
    return {'bundleIdentifier': info['CFBundleIdentifier'], 'signatureVerified': True, 'bundledOfficialInstallerVerified': True, 'binaries': result,
            'runtimeValidation': 'This static gate does not test hardware or mounting. See 验证记录.md for runtime test results.'}

if __name__ == '__main__':
    print(json.dumps(verify(sys.argv[1]), ensure_ascii=False, indent=2))
