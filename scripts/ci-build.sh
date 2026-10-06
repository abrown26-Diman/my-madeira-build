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
    # The Madeira FEX fork contains a few ARM64EC/Windows-only diagnostics in
    # files that are also compiled into the native iOS FEXCore library. Patch
    # those diagnostics out only for this native build while keeping the real
    # iOS host code paths enabled via FEX_IOS_HOST.
    python3 - <<'PY'
from pathlib import Path

# Core.cpp: ARM64EC telemetry arrays are defined only in the Windows frontend.
p = Path('FEX/FEXCore/Source/Interface/Core/Core.cpp')
text = p.read_text()
start = '  /* iOS-Madeira ml304 (task #51): REPORT CallbackPtr ENTRY ON ITS OWN, not via the bogus-RIP path.'
end = '  /* iOS-Madeira: refuse to compile obviously-invalid guest RIPs.'
if '#if defined(FEX_IOS_HOST) && defined(_WIN32)\n' + start not in text:
    if start not in text or end not in text:
        raise SystemExit('Could not locate Madeira ARM64EC telemetry block in Core.cpp')
    text = text.replace(start, '#if defined(FEX_IOS_HOST) && defined(_WIN32)\n' + start, 1)
    text = text.replace(end, '#endif\n\n' + end, 1)
    p.write_text(text)

# Arm64.cpp: the CASPAL diagnostic uses Win32 VirtualQuery even when building
# the Mach/iOS host library. Keep that richer probe on Windows; on iOS log the
# address/misalignment without Win32 MEMORY_BASIC_INFORMATION.
p = Path('FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp')
text = p.read_text()
old = '''  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
'''
new = '''#if defined(_WIN32)
  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
#else
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} crosses16B={} (iOS host)",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no");
#endif
'''
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit('Could not locate Win32 VirtualQuery CASPAL diagnostic in Arm64.cpp')
p.write_text(text)
PY
    cmake -S FEX -B FEX/build-ios -G Ninja \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
      -DCMAKE_OSX_SYSROOT="$IOS_SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-DFEX_IOS_HOST=1" \
      -DCMAKE_CXX_FLAGS="-DFEX_IOS_HOST=1" \
      -DCMAKE_ASM_FLAGS="-DFEX_IOS_HOST=1" \
      -DTUNE_CPU=none -DTUNE_ARCH=generic \
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
    # The source uses iOS 26 SwiftUI Liquid Glass APIs. GitHub's current
    # macos-15 image here has Xcode 16.4 / iOS 18.5 SDK, so runtime
    # #available checks alone are insufficient: the old compiler cannot resolve
    # glassEffect at all. Wrap those paths in compiler checks so Xcode 16.4
    # builds the existing ultraThinMaterial fallback, while Xcode 26+ keeps the
    # Liquid Glass implementation.
    python3 - <<'PY'
from pathlib import Path
p = Path('app/Madeira/ContentView.swift')
text = p.read_text()
old1 = '''    @ViewBuilder private var interior: some View {
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }
'''
new1 = '''    @ViewBuilder private var interior: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
#else
        Circle().fill(.ultraThinMaterial)
#endif
    }
'''
old2 = '''    var body: some View {
        if #available(iOS 26.0, *) {
            if circle { Circle().fill(.clear).glassEffect(.regular, in: Circle()) }
            else { RoundedRectangle(cornerRadius: 18).fill(.clear)
                     .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18)) }
        } else {
            if circle { Circle().fill(.ultraThinMaterial) }
            else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
        }
    }
'''
new2 = '''    var body: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if circle { Circle().fill(.clear).glassEffect(.regular, in: Circle()) }
            else { RoundedRectangle(cornerRadius: 18).fill(.clear)
                     .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18)) }
        } else {
            if circle { Circle().fill(.ultraThinMaterial) }
            else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
        }
#else
        if circle { Circle().fill(.ultraThinMaterial) }
        else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
#endif
    }
'''
if old1 in text:
    text = text.replace(old1, new1, 1)
elif new1 not in text:
    raise SystemExit('Could not locate JoystickFace glassEffect block')
if old2 in text:
    text = text.replace(old2, new2, 1)
elif new2 not in text:
    raise SystemExit('Could not locate GlassShape glassEffect block')
p.write_text(text)
PY
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
