#!/bin/bash
# Conventional, system-authorized LaunchDaemon installation supports the fixed
# local signing identity without SMAppService's Developer ID launch constraints.
set -euo pipefail
APP="$1"
BUILD_NUMBER="$2"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "$ROOT/build/compat/service-package.XXXXXX")"
PAYLOAD="$WORK/payload"
SERVICE_ROOT=/Library/PrivilegedHelperTools/local.ntfswriteflow.compat
mkdir -p "$PAYLOAD$SERVICE_ROOT" "$PAYLOAD/Library/LaunchDaemons" "$WORK/install-scripts" "$WORK/remove-scripts" "$WORK/empty"
cp "$APP/Contents/Library/HelperTools/WriteFlowCompatHelper" "$APP/Contents/Library/HelperTools/WriteFlowNTFS" "$PAYLOAD$SERVICE_ROOT/"
python3 - "$PAYLOAD" "$BUILD_NUMBER" <<'PY'
import json,plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]); label='local.ntfswriteflow.compat.mount-helper'
helper='/Library/PrivilegedHelperTools/local.ntfswriteflow.compat'
(p/(helper+'/version.json').lstrip('/')).write_text(json.dumps({'build':sys.argv[2]}))
(p/'Library/LaunchDaemons'/f'{label}.plist').write_bytes(plistlib.dumps({
 'Label':label,'ProgramArguments':[helper+'/WriteFlowCompatHelper'],
 'MachServices':{label:True},'ProcessType':'Interactive',
 'StandardOutPath':'/dev/null','StandardErrorPath':'/dev/null'}))
PY
cat > "$WORK/install-scripts/preinstall" <<'SH'
#!/bin/bash
set -euo pipefail
if /sbin/mount | /usr/bin/grep -Fq ' on /private/var/db/local.ntfswriteflow.compat.mounts/'; then
    echo '仍有 NTFS 畅写受管挂载，请先正常卸载。' >&2; exit 1
fi
if /usr/bin/pgrep -x WriteFlowNTFS >/dev/null; then
    echo 'NTFS 引擎仍在工作，请等待正常卸载和收尾完成再安装或移除。' >&2; exit 1
fi
/bin/launchctl bootout system/local.ntfswriteflow.compat.mount-helper 2>/dev/null || true
SH
cat > "$WORK/install-scripts/postinstall" <<'SH'
#!/bin/bash
set -euo pipefail
ROOT=/Library/PrivilegedHelperTools/local.ntfswriteflow.compat
PLIST=/Library/LaunchDaemons/local.ntfswriteflow.compat.mount-helper.plist
for ITEM in WriteFlowCompatHelper WriteFlowNTFS; do
    if [[ "$ITEM" == WriteFlowCompatHelper ]]; then ID=local.ntfswriteflow.compat.mount-helper; else ID=local.ntfswriteflow.compat.engine; fi
    /usr/bin/codesign --verify --strict -R "=identifier \"$ID\" and certificate leaf = H\"1DDCB3B175991894FC207A24F0B13D5C41F502B6\"" "$ROOT/$ITEM"
done
/usr/sbin/chown -R root:wheel "$ROOT"
/bin/chmod 755 "$ROOT" "$ROOT/WriteFlowCompatHelper" "$ROOT/WriteFlowNTFS"
/bin/chmod 644 "$ROOT/version.json" "$PLIST"
/bin/launchctl enable system/local.ntfswriteflow.compat.mount-helper
/bin/launchctl bootstrap system "$PLIST"
SH
cp "$WORK/install-scripts/preinstall" "$WORK/remove-scripts/preinstall"
cat > "$WORK/remove-scripts/postinstall" <<'SH'
#!/bin/bash
set -euo pipefail
ROOT=/Library/PrivilegedHelperTools/local.ntfswriteflow.compat
# Only this application's fixed program/configuration files. Never touch volume data,
# user files, permission databases, or mount receipts.
/bin/rm -f "$ROOT/WriteFlowCompatHelper" "$ROOT/WriteFlowNTFS" "$ROOT/version.json" /Library/LaunchDaemons/local.ntfswriteflow.compat.mount-helper.plist
/bin/rmdir "$ROOT" 2>/dev/null || true
SH
chmod 755 "$WORK/"{install-scripts,remove-scripts}/*
chmod 755 "$PAYLOAD$SERVICE_ROOT/"{WriteFlowCompatHelper,WriteFlowNTFS}
RESOURCES="$APP/Contents/Resources"
pkgbuild --root "$PAYLOAD" --scripts "$WORK/install-scripts" --ownership recommended \
    --identifier local.ntfswriteflow.compat.service --version "$BUILD_NUMBER" --install-location / \
    "$RESOURCES/WriteFlow-Install-Service.pkg" >/dev/null
pkgbuild --root "$WORK/empty" --scripts "$WORK/remove-scripts" \
    --identifier local.ntfswriteflow.compat.remove-service --version "$BUILD_NUMBER" --install-location / \
    "$RESOURCES/WriteFlow-Remove-Service.pkg" >/dev/null
python3 - "$RESOURCES" <<'PY'
import hashlib,sys
from pathlib import Path
p=Path(sys.argv[1])
for name in ['WriteFlow-Install-Service','WriteFlow-Remove-Service']:
 (p/(name+'.sha256')).write_text(hashlib.sha256((p/(name+'.pkg')).read_bytes()).hexdigest()+'\n')
PY
