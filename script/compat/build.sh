#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
IDENTITY=1DDCB3B175991894FC207A24F0B13D5C41F502B6
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -q "$IDENTITY"; then
    echo '缺少固定签名身份 TutorialQuickSend Local Signing，停止交付；请恢复原证书及钥匙串私钥。' >&2
    exit 1
fi
mkdir -p build/compat/logs
BUILD_NUMBER="${WRITEFLOW_BUILD_NUMBER:-$(python3 - <<'PY'
from pathlib import Path
import plistlib
values=[1]
for p in [Path('build/compat/NTFSWriteFlowCompat.app/Contents/Info.plist'),Path.home()/'Applications/NTFSWriteFlowCompat.app/Contents/Info.plist']:
    if p.exists():
        value=plistlib.loads(p.read_bytes()).get('CFBundleVersion','1')
        if value.isdigit(): values.append(int(value))
print(max(values)+1)
PY
)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo '构建号必须是递增的正整数。' >&2; exit 1; }
bash script/compat/prepare_fuse_sdk.sh
export WRITEFLOW_FUSE_INSTALLER="${WRITEFLOW_FUSE_INSTALLER:-$HOME/Downloads/fuse-t-macos-installer-1.2.9.pkg}"
export WRITEFLOW_FUSE_SDK="${WRITEFLOW_FUSE_SDK:-$ROOT/build/compat-fuse-sdk/fuse-t-core.pkg/Payload/Library/Application Support/fuse-t}"
bash script/compat/build_engine.sh > build/compat/logs/engine.log 2>&1
COMMON=(Sources/Core/VolumeRecord.swift Sources/Compatibility/Protocol.swift Sources/Compatibility/Command.swift
    Sources/App/Services/MountedFileSystemReader.swift
    Sources/HelperShared/DiskEject.swift)
APP_SOURCES=(Sources/Compatibility/App.swift Sources/Compatibility/AppModel.swift Sources/Compatibility/Inventory.swift
    Sources/App/Services/PrivilegedMountClient.swift Sources/App/Services/RetainedDiskBinding.swift Sources/App/Services/AuthorizedDeviceHandle.swift)
HELPER_SOURCES=(Sources/Compatibility/MountEngine.swift Sources/Compatibility/Listener.swift
    Sources/PrivilegedHelper/HelperNamespace.swift Sources/PrivilegedHelper/HelperMedia.swift Sources/PrivilegedHelper/PrivilegedHelperMain.swift)
for ARCH in x86_64 arm64; do
    mkdir -p "build/compat/$ARCH"
    xcrun swiftc -O -swift-version 5 -D WRITEFLOW_COMPAT -target "$ARCH-apple-macos13.0" \
        -import-objc-header Configuration/Compatibility/Bridging-Header.h \
        "${COMMON[@]}" "${APP_SOURCES[@]}" -framework SwiftUI -framework ServiceManagement \
        -framework DiskArbitration -framework IOKit -framework Security \
        -o "build/compat/$ARCH/WriteFlowCompat" > "build/compat/logs/app-$ARCH.log" 2>&1 || { cat "build/compat/logs/app-$ARCH.log" >&2; exit 1; }
    xcrun swiftc -O -swift-version 5 -D WRITEFLOW_COMPAT -target "$ARCH-apple-macos13.0" \
        -import-objc-header Configuration/Compatibility/Bridging-Header.h \
        "${COMMON[@]}" "${HELPER_SOURCES[@]}" -framework DiskArbitration -framework IOKit -framework Security \
        -o "build/compat/$ARCH/WriteFlowCompatHelper" > "build/compat/logs/helper-$ARCH.log" 2>&1 || { cat "build/compat/logs/helper-$ARCH.log" >&2; exit 1; }
done
APP="$ROOT/build/compat/NTFSWriteFlowCompat.app"
STAGE="$(mktemp -d "$ROOT/build/compat/stage.XXXXXX")/NTFSWriteFlowCompat.app"
mkdir -p "$STAGE/Contents/"{MacOS,Resources,Library/HelperTools,Library/LaunchDaemons}
xcrun lipo -create build/compat/{x86_64,arm64}/WriteFlowCompat -output "$STAGE/Contents/MacOS/WriteFlowCompat"
xcrun lipo -create build/compat/{x86_64,arm64}/WriteFlowCompatHelper -output "$STAGE/Contents/Library/HelperTools/WriteFlowCompatHelper"
cp build/compat-engine/products/WriteFlowNTFS "$STAGE/Contents/Library/HelperTools/WriteFlowNTFS"
cp Configuration/Compatibility/local.ntfswriteflow.compat.mount-helper.plist "$STAGE/Contents/Library/LaunchDaemons/"
cp Sources/App/Resources/WriteFlow.icns "$STAGE/Contents/Resources/"
cp "$WRITEFLOW_FUSE_INSTALLER" "$STAGE/Contents/Resources/fuse-t-macos-installer-1.2.9.pkg"
cp Configuration/Compatibility/FUSE-T-License.txt "$STAGE/Contents/Resources/"
cp LICENSE 第三方组件说明.md "$STAGE/Contents/Resources/"
cp ThirdParty/ntfs-3g/{COPYING,COPYING.LIB,AUTHORS,CREDITS} "$STAGE/Contents/Resources/"
python3 - "$STAGE" "$BUILD_NUMBER" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='local.ntfswriteflow.compat',
    CFBundleName='NTFS 畅写兼容版',CFBundleDisplayName='NTFS 畅写兼容版',CFBundleExecutable='WriteFlowCompat',
    CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.2-compat.1',CFBundleVersion=sys.argv[2],
    CFBundleIconFile='WriteFlow',LSMinimumSystemVersion='13.0',NSHighResolutionCapable=True,
    NSRemovableVolumesUsageDescription='用于管理您选择的外接 NTFS 卷并安全推出。',
    NSNetworkVolumesUsageDescription='FUSE-T 通过本机网络卷提供 NTFS 文件访问。',
    NSHumanReadableCopyright='基于 dososo/ntfs-writeflow，GPL-2.0。兼容预览版。')))
PY
for ITEM in "$STAGE/Contents/Library/HelperTools/WriteFlowNTFS" "$STAGE/Contents/Library/HelperTools/WriteFlowCompatHelper" "$STAGE"; do
    case "$ITEM" in
        */WriteFlowNTFS) ID=local.ntfswriteflow.compat.engine ;;
        */WriteFlowCompatHelper) ID=local.ntfswriteflow.compat.mount-helper ;;
        *) ID=local.ntfswriteflow.compat ;;
    esac
    REQUIREMENT="designated => identifier \"$ID\" and certificate leaf = H\"$IDENTITY\""
    if [[ "$ID" == local.ntfswriteflow.compat ]]; then
        bash script/compat/build_service_packages.sh "$STAGE" "$BUILD_NUMBER"
    fi
    SIGN_ARGS=(--force --options runtime --timestamp=none --sign "$IDENTITY" --identifier "$ID" --requirements "=$REQUIREMENT")
    if [[ "$ID" == local.ntfswriteflow.compat.engine ]]; then SIGN_ARGS+=(--entitlements Configuration/Compatibility/Engine.entitlements); fi
    codesign "${SIGN_ARGS[@]}" "$ITEM"
done
python3 script/compat/verify.py "$STAGE"
# Replace only the reproducible build product; installing/updating uses install.sh.
if [[ -d "$APP" ]]; then mv "$APP" "$APP.previous"; fi
mv "$STAGE" "$APP"
if [[ -d "$APP.previous" ]]; then rm -rf "$APP.previous"; fi
echo "已生成固定签名的通用兼容版：$APP"
