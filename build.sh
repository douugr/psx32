#!/bin/bash
# PSX32: PlayStation emulator for iPad on iOS 8 (armv7).
# Core: PCSX ReARMed (libretro) with its ARM dynamic recompiler, built into the app. Bluetooth controllers via BTstack.
#
# Usage:  ./build.sh            -> build (build/PSX32.app)
#         ./build.sh install    -> build and install to /Applications on the iPad (outside the sandbox, for BTstack)
#
# Variables: IPAD=192.168.1.105, X13=.../Xcode-13.4.1.app/Contents/Developer
set -euo pipefail
cd "$(dirname "$0")"

APP=PSX32
IPAD="${IPAD:-192.168.1.105}"
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
          -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1)
ROOT="$(cd .. && pwd)"
CORE_REPO=https://github.com/libretro/pcsx_rearmed.git
CORE_COMMIT=7b0e8f8fadfbce3d170d195b9d9eecaabfa08c8e

X13="${X13:-$ROOT/Xcode-13.4.1.app/Contents/Developer}"
TC="$X13/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SDK="$(ls -d "$X13"/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | head -1 || true)"
[ -x "$TC/clang" ] && [ -n "$SDK" ] || { echo "Xcode 13 toolchain not found at: $X13" >&2; exit 1; }
export DEVELOPER_DIR="$X13"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# --- BTstack (the iPad's own library) ---
if [ ! -s vendor/libBTstack.dylib ]; then
    echo "==> Fetching /usr/lib/libBTstack.dylib from the iPad ($IPAD)"
    ssh "${SSH_OPTS[@]}" "root@$IPAD" 'cat /usr/lib/libBTstack.dylib' > vendor/libBTstack.dylib.tmp || true
    [ -s vendor/libBTstack.dylib.tmp ] || { echo "Could not copy libBTstack.dylib from the iPad." >&2; exit 1; }
    mv -f vendor/libBTstack.dylib.tmp vendor/libBTstack.dylib
fi
python3 tools/make_link_stub.py vendor/libBTstack.dylib vendor/libBTstackLink.dylib >/dev/null

# --- Core: PCSX ReARMed ---
if [ ! -d core/pcsx/.git ]; then
    echo "==> Downloading PCSX ReARMed ($CORE_COMMIT)"
    mkdir -p core
    git clone -q "$CORE_REPO" core/pcsx
    git -C core/pcsx checkout -q "$CORE_COMMIT"
fi
# Patches for jailbroken iOS 8: the recompiler's translation cache becomes a 16 MB zero-fill rwx
# segment of the app itself (ARM branches only reach +-32MB). Re-applied whenever core-patches/ changes.
PATCH_SUM="$(cat core-patches/*.patch | shasum | cut -d' ' -f1)"
if [ "$(cat core/pcsx/.psx32-patches 2>/dev/null)" != "$PATCH_SUM" ]; then
    echo "==> Applying core patches"
    git -C core/pcsx checkout -q -- .
    for p in core-patches/*.patch; do git -C core/pcsx apply "$PWD/$p"; done
    echo "$PATCH_SUM" > core/pcsx/.psx32-patches
    make -C core/pcsx -f Makefile.libretro platform=ios9 DYNAREC=ari64 STATIC_LINKING=1 clean >/dev/null 2>&1 || true
    rm -rf build-core
fi

CORE_LIB="$PWD/build-core/libpcsx.a"
if [ ! -f "$CORE_LIB" ]; then
    echo "==> Building the core (the first time takes a few minutes)"
    mkdir -p build-core
    CC_CMD="$TC/clang -arch armv7 -isysroot $SDK -DPSX32_JIT"
    make -C core/pcsx -f Makefile.libretro -j"$JOBS" platform=ios9 DYNAREC=ari64 STATIC_LINKING=1 \
        IOSSDK="$SDK" CC="$CC_CMD" CXX="$TC/clang++ -arch armv7 -isysroot $SDK -DPSX32_JIT" AR="$TC/ar" >build-core/make.log 2>&1 \
        || { tail -30 build-core/make.log; echo "Core build failed (see build-core/make.log)" >&2; exit 1; }
    cp core/pcsx/pcsx_rearmed_libretro_ios.dylib "$CORE_LIB"   # (static archive despite the name)
    echo "==> Core: $("$TC/ar" t "$CORE_LIB" | wc -l | tr -d ' ') object files"
fi

# --- rcheevos (RetroAchievements), MIT ---
RC_REPO=https://github.com/RetroAchievements/rcheevos.git
RC_TAG=v12.5.0
if [ ! -d core/rcheevos/.git ]; then
    echo "==> Downloading rcheevos ($RC_TAG)"
    mkdir -p core
    git clone -q --depth 1 --branch "$RC_TAG" "$RC_REPO" core/rcheevos
fi
RC_LIB="$PWD/build-ra/librcheevos.a"
if [ ! -f "$RC_LIB" ]; then
    echo "==> Building rcheevos"
    mkdir -p build-ra
    for f in core/rcheevos/src/*.c core/rcheevos/src/rapi/*.c core/rcheevos/src/rcheevos/*.c core/rcheevos/src/rhash/*.c; do
        case "$f" in *hash_encrypted.c) continue;; esac
        "$TC/clang" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=8.0 -O2 -w \
            -DRC_CLIENT_SUPPORTS_HASH -DRC_HASH_NO_ENCRYPTED -DRC_HASH_NO_ZIP \
            -Icore/rcheevos/include -Icore/pcsx/deps/libretro-common/include \
            -c "$f" -o "build-ra/$(echo "$f" | tr / _).o"
    done
    "$TC/libtool" -static -o "$RC_LIB" build-ra/*.o 2>/dev/null
fi

# --- App ---
OUT="build/$APP.app"
rm -rf build && mkdir -p "$OUT"
echo "==> Building the app (armv7, iOS 8.0)"
"$TC/clang" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=8.0 -B "$TC" \
    -fobjc-arc -O2 -Wall -Wno-unused-parameter -Wunguarded-availability \
    -I src -I vendor/btstack -I core/pcsx/deps/libretro-common/include \
    -I core/rcheevos/include -I core/rcheevos/src -DRC_CLIENT_SUPPORTS_HASH \
    src/*.m "$CORE_LIB" "$RC_LIB" -o "$OUT/$APP" \
    -L vendor -lBTstackLink -Wl,-segprot,__JIT,rwx,rwx \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
    -framework GLKit -framework OpenGLES -framework AudioToolbox -framework AVFoundation -framework CoreImage -framework Security

cp Info.plist "$OUT/"
cp resources/Icon-*.png resources/*.html "$OUT/"
cp resources/*.der "$OUT/" 2>/dev/null || true   # extra root certificates for RetroAchievements HTTPS
if command -v ldid >/dev/null 2>&1; then ldid -S "$OUT/$APP"; else codesign -f -s - "$OUT/$APP"; fi
lipo -info "$OUT/$APP"
echo "==> OK: $OUT ($(du -sh "$OUT" | cut -f1))"

if [ "${1:-}" = "install" ]; then
    echo "==> Installing to /Applications/$APP.app"
    COPYFILE_DISABLE=1 tar -C build -cf - "$APP.app" | ssh "${SSH_OPTS[@]}" "root@$IPAD" \
        "rm -rf /Applications/$APP.app && tar -C /Applications -xf - && chown -R root:wheel /Applications/$APP.app && chmod -R 755 /Applications/$APP.app && mkdir -p /var/mobile/Documents/PSX32/games /var/mobile/Documents/PSX32/bios && chown -R mobile:mobile /var/mobile/Documents/PSX32 && (su mobile -c uicache || uicache)"
    echo "==> Installed."
fi
