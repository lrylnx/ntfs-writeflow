#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/build/compat-engine"
PIN=7f0f841fc52cf719106c5c93bafe465004e36816
SOURCE="$ROOT/ThirdParty/ntfs-3g"
SDK_ROOT="${WRITEFLOW_FUSE_SDK:-/Library/Application Support/fuse-t}"
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$PIN" ]] || { echo 'NTFS-3G 固定提交不符。' >&2; exit 1; }
git -C "$SOURCE" diff --quiet
git -C "$SOURCE" diff --cached --quiet
[[ -f "$SDK_ROOT/include/fuse/fuse.h" ]] || { echo '缺少 FUSE-T SDK。' >&2; exit 1; }
LIBTOOLIZE="${LIBTOOLIZE:-$(command -v glibtoolize || command -v libtoolize || true)}"
[[ -x "$LIBTOOLIZE" ]] || { echo '请安装 GNU Libtool、Autoconf、Automake 和 pkg-config。' >&2; exit 1; }
mkdir -p "$WORK/source" "$WORK/products"
if [[ -L "$WORK/sdk" && "$(readlink "$WORK/sdk")" != "$SDK_ROOT" ]]; then
    echo 'FUSE-T SDK 路径已变化，请移走 build/compat-engine 后重新构建。' >&2; exit 1
fi
if [[ ! -e "$WORK/sdk" ]]; then ln -s "$SDK_ROOT" "$WORK/sdk"; fi
SDK_ROOT="$WORK/sdk"
FINGERPRINT="$(cat "$ROOT/script/compat/patch_engine.py" "$ROOT/script/compat/build_engine.sh" | shasum -a 256 | awk '{print $1}')"
if [[ -f "$WORK/source/configure" && "$(cat "$WORK/source/.writeflow-fingerprint" 2>/dev/null || true)" != "$FINGERPRINT" ]]; then
    echo '引擎构建脚本或补丁已变化，请移走 build/compat-engine 后重新构建，禁止复用过期对象。' >&2; exit 1
fi
if [[ ! -f "$WORK/source/configure" ]]; then
    git -C "$SOURCE" archive "$PIN" | tar -xf - -C "$WORK/source"
    cp "$ROOT/ThirdParty/NTFSBridge/libgcrypt.m4" "$WORK/source/m4/libgcrypt.m4"
    python3 "$ROOT/script/compat/patch_engine.py" "$WORK/source"
    (cd "$WORK/source"; "$LIBTOOLIZE" --force --copy --install; LIBTOOLIZE="$LIBTOOLIZE" autoreconf -fi -I m4)
    printf '%s\n' "$FINGERPRINT" > "$WORK/source/.writeflow-fingerprint"
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in x86_64 arm64; do
    BUILD="$WORK/$ARCH"
    mkdir -p "$BUILD"
    if [[ ! -f "$BUILD/Makefile" ]]; then
        (cd "$BUILD"
         PKG_CONFIG="${PKG_CONFIG:-/usr/bin/true}" \
         FUSE_MODULE_CFLAGS="-I\"$SDK_ROOT/include/fuse\" -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26" \
         FUSE_MODULE_LIBS="-L\"$SDK_ROOT/lib\" -lfuse-t-1.2.9 -framework IOKit -framework CoreFoundation -Wl,-rpath,/usr/local/lib" \
         CC="$(xcrun -f clang)" CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=13.0 -O2" \
         LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=13.0" \
         ../source/configure --host="$ARCH-apple-darwin" --disable-shared --enable-static \
            --with-fuse=external --disable-crypto --disable-nls --disable-plugins --enable-ntfsprogs)
    fi
    make -C "$BUILD/libntfs-3g" -j4
    make -C "$BUILD/src" -j4 ntfs-3g
    cp "$BUILD/src/ntfs-3g" "$WORK/products/WriteFlowNTFS-$ARCH"
done
xcrun lipo -create "$WORK/products/WriteFlowNTFS-x86_64" "$WORK/products/WriteFlowNTFS-arm64" -output "$WORK/products/WriteFlowNTFS"
# Use only the official, separately installed runtime; no build-machine rpath.
/usr/bin/install_name_tool -change @rpath/libfuse-t.dylib /usr/local/lib/libfuse-t.dylib "$WORK/products/WriteFlowNTFS"
