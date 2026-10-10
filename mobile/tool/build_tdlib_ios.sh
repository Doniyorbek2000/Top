#!/usr/bin/env bash
# Builds TDLib (libtdjson) for iOS devices and simulators on macOS and packages it as
# ios/TDLib/tdjson.xcframework (dynamic tdjson.framework per slice), consumed by ios/TDLib/TDLib.podspec.
#
# Requirements: macOS with Xcode, Homebrew packages: gperf cmake coreutils (for grealpath).
# Usage: tool/build_tdlib_ios.sh [work_dir]
set -euo pipefail

TDLIB_COMMIT="c15d3f5a5"   # 1.8.68 — must match the tdlib_ex version in pubspec.yaml
MIN_IOS="15.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${1:-${APP_DIR}/.tdlib-build-ios}"
OUT="${APP_DIR}/ios/TDLib/tdjson.xcframework"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: iOS builds require macOS with Xcode" >&2
  exit 1
fi
for tool in git cmake gperf grealpath xcodebuild; do
  command -v "${tool}" >/dev/null || { echo "error: '${tool}' is missing (brew install gperf cmake coreutils)" >&2; exit 1; }
done

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
[[ -d td ]] || git clone --quiet https://github.com/tdlib/td.git td
git -C td fetch --quiet origin
git -C td checkout --quiet "${TDLIB_COMMIT}"
TD="${WORK_DIR}/td"

echo "==> Generating TDLib sources"
mkdir -p "${TD}/native-build"
(cd "${TD}/native-build" && cmake -DTD_GENERATE_SOURCE_FILES=ON .. >/dev/null && cmake --build . >/dev/null)

echo "==> Building OpenSSL for iOS and iOS simulator"
EXAMPLE="${TD}/example/ios"
if [[ ! -f "${EXAMPLE}/third_party/openssl/iOS/lib/libssl.a" ]]; then
  (
    cd "${EXAMPLE}"
    [[ -d Python-Apple-support ]] || git clone --quiet https://github.com/beeware/Python-Apple-support
    cd Python-Apple-support
    git checkout --quiet 6f43aba0ddd5a9f52f39775d0141bd4363614020
    git reset --quiet --hard
    git apply ../Python-Apple-support.patch
    for platform in iOS iOS-simulator; do
      SOURCE_DATE_EPOCH=1 ZERO_AR_DATE=1 make "OpenSSL-${platform}"
      rm -rf "../third_party/openssl/${platform}"
      mkdir -p "../third_party/openssl/${platform}/lib"
      cp "merge/${platform}/openssl/lib/libcrypto.a" "merge/${platform}/openssl/lib/libssl.a" "../third_party/openssl/${platform}/lib/"
      cp -r "merge/${platform}/openssl/include/" "../third_party/openssl/${platform}/include"
    done
  )
fi

FRAMEWORKS=()
for slice in iOS iOS-simulator; do
  echo "==> Building TDLib for ${slice}"
  if [[ "${slice}" == "iOS" ]]; then ios_platform="OS"; else ios_platform="SIMULATOR"; fi
  ssl="${EXAMPLE}/third_party/openssl/${slice}"
  build="${WORK_DIR}/build-${slice}"
  install="${WORK_DIR}/install-${slice}"
  rm -rf "${build}" "${install}"
  mkdir -p "${build}"
  (
    cd "${build}"
    cmake "${TD}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="${TD}/CMake/iOS.cmake" \
      -DIOS_PLATFORM="${ios_platform}" \
      -DIOS_DEPLOYMENT_TARGET="${MIN_IOS}" \
      -DOPENSSL_FOUND=1 \
      -DOPENSSL_CRYPTO_LIBRARY="${ssl}/lib/libcrypto.a" \
      -DOPENSSL_SSL_LIBRARY="${ssl}/lib/libssl.a" \
      -DOPENSSL_INCLUDE_DIR="${ssl}/include" \
      -DOPENSSL_LIBRARIES="${ssl}/lib/libcrypto.a;${ssl}/lib/libssl.a" \
      -DCMAKE_INSTALL_PREFIX="${install}" >/dev/null
    ZERO_AR_DATE=1 cmake --build . --target tdjson -j"$(sysctl -n hw.ncpu)"
  )
  dylib="$(find "${build}" -name 'libtdjson.*.dylib' -o -name 'libtdjson.dylib' | head -n1)"

  # Wrap the dylib in a framework bundle: App Store builds only accept frameworks, not loose dylibs.
  fw="${WORK_DIR}/frameworks-${slice}/tdjson.framework"
  rm -rf "${fw}"
  mkdir -p "${fw}"
  cp "${dylib}" "${fw}/tdjson"
  install_name_tool -id "@rpath/tdjson.framework/tdjson" "${fw}/tdjson"
  cat > "${fw}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>tdjson</string>
  <key>CFBundleIdentifier</key><string>org.tdlib.tdjson</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>tdjson</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.8.68</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>${MIN_IOS}</string>
</dict>
</plist>
PLIST
  FRAMEWORKS+=(-framework "${fw}")
done

echo "==> Creating ${OUT}"
rm -rf "${OUT}"
xcodebuild -create-xcframework "${FRAMEWORKS[@]}" -output "${OUT}"
echo "Done."
