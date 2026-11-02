#!/bin/bash
# Restore only dependency Git metadata from the bundled public upstream history.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/ThirdParty/ntfs-3g"
PIN=7f0f841fc52cf719106c5c93bafe465004e36816
if [[ ! -e "$SOURCE/.git" ]]; then
    [[ -f "$ROOT/ThirdParty/ntfs-3g-pinned.bundle" ]] || { echo '缺少依赖 Git bundle；仓库克隆请运行 git submodule update --init --recursive。' >&2; exit 1; }
    git -C "$SOURCE" init
    git -C "$SOURCE" fetch "$ROOT/ThirdParty/ntfs-3g-pinned.bundle" HEAD
    git -C "$SOURCE" reset --mixed "$PIN"
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$PIN" ]] || { echo '依赖固定提交不符。' >&2; exit 1; }
git -C "$SOURCE" diff --quiet
echo '固定依赖元数据已就绪，未覆盖源文件。'
