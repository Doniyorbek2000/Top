#!/usr/bin/env bash
# Builds TDLib (JSON interface, libtdjson.so) for all Android ABIs and copies the result into
# android/app/src/main/jniLibs. The TDLib commit must match the td_api schema used by the
# `tdlib_ex` Dart package pinned in pubspec.yaml (see TDLIB_COMMIT below).
#
# Requirements: bash, git, curl, java/jar/javadoc, perl, php, gperf, make, unzip.
# Usage: tool/build_tdlib_android.sh [work_dir]
set -euo pipefail

TDLIB_COMMIT="c15d3f5a5"          # "Update version to 1.8.68." — matches tdlib_ex 0.44.0
OPENSSL_TAG="OpenSSL_1_1_1w"
NDK_VERSION="23.2.8568313"
MIN_API_LEVEL="24"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${1:-${APP_DIR}/.tdlib-build}"
JNI_DIR="${APP_DIR}/android/app/src/main/jniLibs"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

for tool in git gperf php perl make java jar unzip curl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: required tool '${tool}' is not installed" >&2
    exit 1
  fi
done

SDK_DIR="${ANDROID_SDK_ROOT:-${WORK_DIR}/android-sdk}"
if [[ ! -d "${SDK_DIR}/ndk/${NDK_VERSION}" ]]; then
  echo "==> Installing Android SDK components (NDK ${NDK_VERSION}, CMake 3.22.1)"
  mkdir -p "${SDK_DIR}/cmdline-tools"
  if [[ ! -x "${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager" ]]; then
    curl -sSfL -o clt.zip "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
    unzip -qq -o clt.zip -d "${SDK_DIR}/cmdline-tools"
    rm -rf "${SDK_DIR}/cmdline-tools/latest"
    mv "${SDK_DIR}/cmdline-tools/cmdline-tools" "${SDK_DIR}/cmdline-tools/latest"
    rm clt.zip
  fi
  yes | "${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="${SDK_DIR}" --licenses >/dev/null || true
  "${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="${SDK_DIR}" --install \
    "ndk;${NDK_VERSION}" "cmake;3.22.1" "build-tools;34.0.0" "platforms;android-34" >/dev/null
fi

if [[ ! -d td ]]; then
  echo "==> Cloning TDLib"
  git clone --quiet https://github.com/tdlib/td.git td
fi
git -C td fetch --quiet origin
git -C td checkout --quiet "${TDLIB_COMMIT}"

ANDROID_EXAMPLE="${WORK_DIR}/td/example/android"
OPENSSL_DIR="${ANDROID_EXAMPLE}/third-party/openssl"
if [[ ! -d "${OPENSSL_DIR}/arm64-v8a" ]]; then
  echo "==> Building OpenSSL ${OPENSSL_TAG}"
  rm -rf "${OPENSSL_DIR}" "${WORK_DIR}/openssl-src"
  # Fetch with git: archive downloads are not always reachable from build machines.
  git clone --quiet --depth 1 --branch "${OPENSSL_TAG}" https://github.com/openssl/openssl.git "${WORK_DIR}/openssl-src"
  (
    cd "${WORK_DIR}/openssl-src"
    export ANDROID_NDK_ROOT="${SDK_DIR}/ndk/${NDK_VERSION}"
    export ANDROID_NDK_HOME="${ANDROID_NDK_ROOT}"
    export PATH="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"
    for abi in ${ABIS}; do
      case "${abi}" in
        arm64-v8a) LDFLAGS=-Wl,-z,max-page-size=16384 ./Configure android-arm64 no-shared -U__ANDROID_API__ -D__ANDROID_API__=21 ;;
        armeabi-v7a) ./Configure android-arm no-shared -U__ANDROID_API__ -D__ANDROID_API__=16 -D__ARM_MAX_ARCH__=8 ;;
        x86_64) LDFLAGS=-Wl,-z,max-page-size=16384 ./Configure android-x86_64 no-shared -U__ANDROID_API__ -D__ANDROID_API__=21 ;;
        x86) ./Configure android-x86 no-shared -U__ANDROID_API__ -D__ANDROID_API__=16 ;;
        *) echo "unknown ABI ${abi}" >&2; exit 1 ;;
      esac
      sed -i.bak 's/-O3/-O3 -ffunction-sections -fdata-sections/g' Makefile
      make depend -s
      make -j"$(nproc)" -s build_libs
      mkdir -p "${OPENSSL_DIR}/${abi}/lib"
      cp libcrypto.a libssl.a "${OPENSSL_DIR}/${abi}/lib/"
      cp -r include "${OPENSSL_DIR}/${abi}/"
      make distclean >/dev/null
    done
  )
fi

echo "==> Building TDLib (${ABIS})"
(
  cd "${ANDROID_EXAMPLE}"
  # build-tdlib.sh uses `make`-style parallelism through CMake/Ninja defaults; cap it to the machine.
  export CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)"
  ./build-tdlib.sh "${SDK_DIR}" "${NDK_VERSION}" "${OPENSSL_DIR}" "c++_static" "JSON" "${MIN_API_LEVEL}" "${ABIS}"
)

echo "==> Installing libraries into ${JNI_DIR}"
for abi in ${ABIS}; do
  mkdir -p "${JNI_DIR}/${abi}"
  cp "${ANDROID_EXAMPLE}/tdlib/libs/${abi}/libtdjson.so" "${JNI_DIR}/${abi}/libtdjson.so"
done
ls -la "${JNI_DIR}"/*/libtdjson.so
echo "Done."
