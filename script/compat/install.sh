#!/bin/bash
# Run after building. Keep the same path, identity and designated requirement on updates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/build/compat/NTFSWriteFlowCompat.app"
DEST="$HOME/Applications/NTFSWriteFlowCompat.app"
python3 "$ROOT/script/compat/verify.py" "$SOURCE" >/dev/null
if pgrep -f '/Contents/MacOS/WriteFlowCompat([[:space:]]|$)' >/dev/null; then
    echo '请先正常卸载受管卷并退出兼容版，再更新应用。' >&2; exit 1
fi
if pgrep -x WriteFlowNTFS >/dev/null; then
    echo 'NTFS 引擎仍在工作，请先正常卸载受管卷并等待收尾结束，再更新应用。' >&2; exit 1
fi
if pgrep -f '(^|/)Contents/Library/HelperTools/WriteFlowCompatHelper([[:space:]]|$)' >/dev/null && [[ ! -f /Library/PrivilegedHelperTools/local.ntfswriteflow.compat/version.json ]]; then
    echo '旧管理员服务仍在运行。请先在兼容版内正常卸载卷、移除管理员服务并退出，再更新应用。' >&2; exit 1
fi
if [[ -e "$DEST" ]]; then
    codesign --verify --deep --strict -R '=identifier "local.ntfswriteflow.compat" and certificate leaf = H"1DDCB3B175991894FC207A24F0B13D5C41F502B6"' "$DEST"
    for ITEM in '' '/Contents/Library/HelperTools/WriteFlowCompatHelper' '/Contents/Library/HelperTools/WriteFlowNTFS'; do
        OLD="$(codesign -dr - "$DEST$ITEM" 2>&1 | sed -n '/^designated =>/p')"
        NEW="$(codesign -dr - "$SOURCE$ITEM" 2>&1 | sed -n '/^designated =>/p')"
        [[ -n "$OLD" && "$OLD" == "$NEW" ]] || { echo '更新签名指定要求不连续，停止替换。' >&2; exit 1; }
    done
fi
mkdir -p "$HOME/Applications"
STAGE="$(mktemp -d "$HOME/Applications/.WriteFlowCompat.XXXXXX")"
ditto "$SOURCE" "$STAGE/NTFSWriteFlowCompat.app"
python3 "$ROOT/script/compat/verify.py" "$STAGE/NTFSWriteFlowCompat.app" >/dev/null
if [[ -d "$DEST" ]]; then mv "$DEST" "$STAGE/previous.app"; fi
mv "$STAGE/NTFSWriteFlowCompat.app" "$DEST"
python3 "$ROOT/script/compat/verify.py" "$DEST" >/dev/null
if [[ -d "$STAGE/previous.app" ]]; then rm -rf "$STAGE/previous.app"; fi
rmdir "$STAGE"
echo "已安装到固定位置：$DEST"
