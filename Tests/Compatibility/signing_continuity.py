#!/usr/bin/env python3
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('gate', root / 'script/compat/verify.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
source = Path(sys.argv[1]).resolve()
before = gate.run('codesign', '-dr', '-', str(source)).split('designated =>', 1)[1].strip()
with tempfile.TemporaryDirectory(prefix='writeflow-signature-') as temp:
    app = Path(temp) / source.name
    subprocess.run(['ditto', str(source), str(app)], check=True)
    (app / 'Contents/Resources/continuity-test.txt').write_text('Changed resource for signature continuity verification.\n')
    rejected = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True).returncode != 0
    assert rejected, 'A changed sealed resource must fail before re-signing.'
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp=none', '--sign', gate.PIN,
        '--requirements', '=designated => ' + gate.requirement('local.ntfswriteflow.compat'), str(app)], check=True)
    after = gate.run('codesign', '-dr', '-', str(app)).split('designated =>', 1)[1].strip()
    assert before == after, (before, after)
    gate.verify(app)
print(json.dumps(dict(changedResourceRejected=True, resignedResourcesVerified=True,
    designatedRequirementUnchanged=True, privacyPermissionRetention='Not tested; no TCC changes made.'), indent=2))
