#!/bin/bash
# Build the native iOS dependencies from a clean checkout. The Windows PE
# modules and prefix template are supplied by the pinned parent repository.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
JOBS=${MADEIRA_BUILD_JOBS:-3}
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$MINGW:$(brew --prefix bison)/bin:$PATH"
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
export ZERO_AR_DATE=1

case "${1:-}" in
  prepare)
    mkdir -p toolchains
    if [ ! -x "$MINGW/aarch64-w64-mingw32-clang" ]; then
      curl -fL --retry 3 \
        https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-macos-universal.tar.xz \
        -o toolchains/llvm-mingw.tar.xz
      tar -xf toolchains/llvm-mingw.tar.xz -C toolchains
      rm toolchains/llvm-mingw.tar.xz
    fi
    if [ ! -d research/freetype ]; then
      git clone --depth 1 --branch VER-2-13-3 \
        https://github.com/freetype/freetype.git research/freetype
    fi
    if [ ! -f toolchains/llvm-project/llvm/CMakeLists.txt ]; then
      curl -fL --retry 3 \
        https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.7/llvm-project-15.0.7.src.tar.xz \
        -o toolchains/llvm-source.tar.xz
      mkdir -p toolchains/llvm-project
      tar -xf toolchains/llvm-source.tar.xz -C toolchains/llvm-project --strip-components=1
      rm toolchains/llvm-source.tar.xz
    fi
    # LLVM 15 needs Apple's linker flags when targeting iOS (upstream recipe).
    python3 - <<'PY'
from pathlib import Path
p = Path('toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake')
p.write_text(p.read_text().replace('MATCHES "Darwin"', 'MATCHES "Darwin|iOS"'))
PY
    test -x "$MINGW/llvm-objcopy"
    "$MINGW/aarch64-w64-mingw32-clang" --version
    ;;
  fex)
    cmake -S FEX -B FEX/build-ios -G Ninja \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
      -DCMAKE_OSX_SYSROOT="$IOS_SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_THUNKS=OFF \
      -DENABLE_LTO=OFF -DENABLE_CCACHE=OFF -DENABLE_GDB_SYMBOLS=OFF
    cmake --build FEX/build-ios --parallel "$JOBS" \
      --target FEXCore FEXCore_Base JemallocLibs softfloat_3e
    ;;
  llvm)
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD= \
      -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
    cmake --build toolchains/llvm-host-build --parallel "$JOBS" --target llvm-tblgen
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build -G Ninja \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
      -DCMAKE_OSX_SYSROOT="$IOS_SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_TABLEGEN="$ROOT/toolchains/llvm-host-build/bin/llvm-tblgen" \
      -DLLVM_TARGETS_TO_BUILD= -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios18.0 \
      -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_TOOLS=OFF \
      -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
      -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
      -DLLVM_ENABLE_BACKTRACES=OFF -DLLVM_ENABLE_CRASH_OVERRIDES=OFF
    cmake --build toolchains/llvm-ios-build --parallel "$JOBS"
    ;;
  wine-headers)
    mkdir -p wine/build-macos
    (
      cd wine/build-macos
      if [ ! -f Makefile ]; then
        ../configure --enable-win64 --enable-archs=aarch64,arm64ec \
          --with-mingw=llvm-mingw --without-x --without-vulkan --disable-tests
      fi
      make -j"$JOBS" __tooldeps__ include/all
    )
    # Both PE architectures share the IDL headers generated above. The native
    # dwrite wrapper expects them at the developer's old second-build path.
    mkdir -p wine/build-arm64ec
    if [ ! -e wine/build-arm64ec/include ]; then
      ln -s ../build-macos/include wine/build-arm64ec/include
    fi
    test -f wine/build-macos/include/config.h
    test -f wine/build-arm64ec/include/dwrite_3.h
    ;;
  native)
    bash build/freetype-ios/build.sh
    bash build/gnutls-ios/build.sh
    cp toolchains/gnutls-ios/lib/libgnutls.a toolchains/gnutls-ios/lib/libhogweed.a \
      toolchains/gnutls-ios/lib/libnettle.a toolchains/gnutls-ios/lib/libgmp.a app/Madeira/
    MADEIRA_CLEAN_WINESERVER=1 bash build/wineserver/build.sh
    bash build/ntdll-unix/build.sh
    bash build/win32u-unix/build.sh
    ;;
  dxmt)
    if ! xcrun --sdk iphoneos --find metal >/dev/null 2>&1; then
      xcodebuild -downloadComponent MetalToolchain
    fi
    mkdir -p build/dxmt-ios/shader-headers
    for name in air_msad air_samplepos air_tessellation; do
      xcrun --sdk iphoneos metal -std=metal3.1 -c \
        "research/dxmt/src/airconv/shaders/$name.metal" \
        -o "build/dxmt-ios/shader-headers/$name.air"
      xxd -i -n "$name" "build/dxmt-ios/shader-headers/$name.air" \
        "build/dxmt-ios/shader-headers/$name.h"
    done
    bash build/dxmt-ios/build.sh
    xcrun --sdk iphoneos libtool -static \
      -o app/Madeira/libdxmt_combined.a \
      build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a
    ;;
  app)
    bash tools/check-prefix-template.sh
    # Microsoft runtimes are supplied by the device owner; keep the resource
    # directory present without adding unrequested third-party binaries.
    mkdir -p app/Madeira/x86_64-vcruntime
    xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
      -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
      -derivedDataPath "$ROOT/build/DerivedData" \
      IPHONEOS_DEPLOYMENT_TARGET=18.0 CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
    APP="$ROOT/build/DerivedData/Build/Products/Release-iphoneos/Madeira.app"
    test -f "$APP/Madeira"
    mkdir -p build/ipa/Payload
    rm -rf build/ipa/Payload/Madeira.app
    cp -R "$APP" build/ipa/Payload/Madeira.app
    cp app/Madeira/madeira-jit.js build/ipa/Payload/Madeira.app/
    (cd build/ipa && /usr/bin/zip -qry Madeira-unsigned.ipa Payload)
    ;;
  *) echo 'Usage: ci-build.sh prepare|fex|llvm|wine-headers|native|dxmt|app' >&2; exit 2 ;;
esac
