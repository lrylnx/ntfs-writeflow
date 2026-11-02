#!/bin/bash
# Verify and extract the official package without installing it on the build machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${WRITEFLOW_FUSE_INSTALLER:-$HOME/Downloads/fuse-t-macos-installer-1.2.9.pkg}"
PIN=a1b893740ded8ea034f1acc522ded1144f4a567a1f416daef8c1441cf2662f7f
[[ -f "$INSTALLER" ]] || { echo '未找到 FUSE-T 官方安装包，请通过 WRITEFLOW_FUSE_INSTALLER 指定本地路径。' >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$INSTALLER" | awk '{print $1}')"
[[ "$ACTUAL" == "$PIN" ]] || { echo 'FUSE-T 安装包哈希不匹配，停止构建。' >&2; exit 1; }
mkdir -p "$ROOT/build/compat/logs"
LANG=C pkgutil --check-signature "$INSTALLER" > "$ROOT/build/compat/logs/fuse-installer-signature.txt"
grep -q 'Developer ID Installer: alex fishman (6DY7Z4SVDZ)' "$ROOT/build/compat/logs/fuse-installer-signature.txt" || { echo 'FUSE-T 安装包签名身份不符。' >&2; exit 1; }
SDK="$ROOT/build/compat-fuse-sdk"
if [[ ! -d "$SDK" ]]; then pkgutil --expand-full "$INSTALLER" "$SDK"; fi
echo "FUSE-T 官方安装包已核验；SDK 已解包到 ${SDK}。"
