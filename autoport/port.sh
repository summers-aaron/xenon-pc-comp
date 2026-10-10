#!/usr/bin/env bash
# autoport: Xbox 360 ISO -> native Linux build (ReXGlue SDK), no manual config.
#
#   autoport/port.sh <game.iso> <workdir> <project_name>
#
# Steps:
#   1. extract ISO (extract-xiso)
#   2. rexglue init (+ DLL modules), fix host path case for DLLs
#   3. codegen loop: tail-merge chunks, flagged targets   (fix_unresolved.py)
#   4. static passes: orphan entries, XAPI fibers          (scan_orphans.py, detect_xapi.py)
#   5. cross-DLL import thunks                             (gen_xdll_imports.py)
#   6. build in Fedora container (clang + gtk3)
#   7. headless runtime loop: missed indirect targets      (runtime_loop.py)
#
# AUTOPORT_TARGET=windows cross-compiles step 6 for Windows instead (container
# xenon-build-win-<arch>, autoport/windows/clang-msvc.cmake) against the Windows SDK
# install in AUTOPORT_WIN_SDK. WIN_ARCH is aarch64 (default) or x86_64.
# AUTOPORT_REXGLUE overrides the rexglue binary (autoport/rexglue-container.sh
# runs it in the build container when the host glibc is too old).
set -euo pipefail

ISO=$(realpath "$1"); WORK=$(realpath -m "$2"); NAME=$3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AP=$ROOT/autoport
# Patched ReXGlue v0.10.0 built from ref/rexglue-sdk (fixes rexglue-sdk#456 and friends).
SDK=${AUTOPORT_SDK:-$ROOT/tools/rexglue-src}
SDK_LIB=$SDK/lib64
REXGLUE=${AUTOPORT_REXGLUE:-$SDK/bin/rexglue}
TARGET=${AUTOPORT_TARGET:-linux}
JOBS=${AUTOPORT_JOBS:-$(nproc)}
XISO=$ROOT/tools/extract-xiso/build/extract-xiso
PORT=$WORK/port
BUILD="podman run --rm --userns=keep-id -v $ROOT:$ROOT:Z -w $PORT xenon-build"

mkdir -p "$WORK"
[ -f "$WORK/game/default.xex" ] || "$XISO" -x "$ISO" -d "$WORK/game"

if [ ! -f "$PORT/${NAME}_manifest.toml" ]; then
  "$REXGLUE" init --project-name "$NAME" --xex-path "$WORK/game/default.xex" \
    --game-root "$WORK/game" --scan-dll --project-root "$PORT"
  # `init --scan-dll` lowercases DLL paths; restore on-disk case (Linux is case-sensitive).
  python3 - "$PORT/${NAME}_manifest.toml" "$WORK/game" <<'EOF'
import re, sys, os
manifest, game = sys.argv[1], sys.argv[2]
real = {os.path.relpath(os.path.join(d, f), game).lower(): os.path.relpath(os.path.join(d, f), game)
        for d, _, fs in os.walk(game) for f in fs}
text = open(manifest).read()
def fix(m):
    rel = os.path.relpath(os.path.normpath(os.path.join(os.path.dirname(manifest), m.group(1))), game)
    fixed = real.get(rel.lower(), rel)
    return f'file_path = "{os.path.relpath(os.path.join(game, fixed), os.path.dirname(manifest))}"'
open(manifest, "w").write(re.sub(r'file_path = "([^"]+)"', fix, text))
EOF
  cat >> "$PORT/CMakeLists.txt" <<EOF

# autoport: cross-DLL import thunks
include(generated/autoport_xdll.cmake OPTIONAL)

# autoport: portable runtime fixes shared by every game (kernel export overrides)
file(GLOB AUTOPORT_RUNTIME_SOURCES CONFIGURE_DEPENDS $AP/runtime/*.cpp)
target_sources($NAME PRIVATE \${AUTOPORT_RUNTIME_SOURCES})
EOF
  sed -i "s|#include <rex/rex_app.h>|#include <rex/rex_app.h>\n\n#include \"$AP/runtime/frame_capture.h\"\n#include \"$AP/runtime/cache_mounts.h\"\n#include \"$AP/runtime/disc_mount.h\"\n#include \"$AP/runtime/scripted_input.h\"|; \
          s|  // void OnPostSetup() override {}|  void OnPostSetup() override {\n    autoport::MountDiscImage(runtime());\n    autoport::MountCachePartitions(runtime());\n    autoport::StartFrameCapture(runtime());\n    autoport::StartScriptedInput(runtime());\n  }|" \
    "$PORT/src/${NAME}_app.h"
fi

# Cross builds can't run the target's rexglue for the build-time codegen step;
# REXGLUE_HOST_TOOL names a host one. Added separately so older ports get it too.
if ! grep -q REXGLUE_HOST_TOOL "$PORT/CMakeLists.txt"; then
  cat >> "$PORT/CMakeLists.txt" <<'EOF2'

# autoport: cross builds run codegen with a host rexglue (-DREXGLUE_HOST_TOOL=...)
if(REXGLUE_HOST_TOOL)
  set_target_properties(rex::rexglue PROPERTIES
    IMPORTED_LOCATION "${REXGLUE_HOST_TOOL}" IMPORTED_LOCATION_RELEASE "${REXGLUE_HOST_TOOL}")
endif()
EOF2
fi

cd "$PORT"
M=${NAME}_manifest.toml
python3 "$AP/fix_unresolved.py" "$M" --rexglue "$REXGLUE"
python3 "$AP/scan_orphans.py" "$M"
python3 "$AP/detect_xapi.py" "$M"
python3 "$AP/fix_unresolved.py" "$M" --rexglue "$REXGLUE"
# Jump tables sized too small by the generator (then regenerate).
if python3 "$AP/fix_switch_tables.py" "$M" | grep -q " -> "; then
  python3 "$AP/fix_unresolved.py" "$M" --rexglue "$REXGLUE"
fi
python3 "$AP/gen_xdll_imports.py" "$M" --log codegen_auto.log
python3 "$AP/patch_spin_hints.py" "$M"

if [ "$TARGET" = windows ]; then
  WIN_ARCH=${WIN_ARCH:-aarch64}
  WIN_SDK=${AUTOPORT_WIN_SDK:-$ROOT/tools/rexglue-win-$WIN_ARCH}
  WIN_BUILD="podman run --rm --userns=keep-id -v $ROOT:$ROOT:Z -w $PORT xenon-build-win-$WIN_ARCH"
  B=$PORT/out/build/win-$WIN_ARCH-release
  [ -f "$B/build.ninja" ] || $WIN_BUILD cmake -S . -B "$B" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$AP/windows/clang-msvc.cmake" -DWIN_ARCH="$WIN_ARCH" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$WIN_SDK" -DREXGLUE_HOST_TOOL="$SDK/bin/rexglue"
  $WIN_BUILD cmake --build "$B" -j"$JOBS"
  # The SDK's DLLs (runtime, GPU plugins, SDL) sit next to the executable.
  cp -f "$WIN_SDK"/bin/*.dll "$B/"
  echo "Built: $B/$NAME.exe"
  exit 0
fi

[ -f out/build/linux-release/build.ninja ] || $BUILD cmake -S . -B out/build/linux-release -G Ninja \
  -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$SDK"
$BUILD cmake --build out/build/linux-release -j"$(nproc)"

B=$PORT/out/build/linux-release
ln -sf "$SDK_LIB/librexgpu-xenos.so" "$B/"
# SDK dlopen()s guest-DLL modules by bare target name on Linux.
(cd "$B" && for f in lib${NAME}_*.so; do n=${f#lib}; ln -sf "$f" "${n%.so}"; done)

python3 -u "$AP/runtime_loop.py" "$M" --rexglue "$REXGLUE" --sdk-lib "$SDK_LIB" \
  --build-dir "$B" --exe "$NAME" --seconds 90 \
  --run-args "--game_data_root=$WORK/game --gpu_plugin=xenos" \
  --build-cmd "$BUILD cmake --build out/build/linux-release -j$(nproc)"

echo "Built: $B/$NAME"
echo "Run:   LD_LIBRARY_PATH=$B:$SDK_LIB $B/$NAME --game_data_root=$WORK/game --gpu_plugin=xenos --fullscreen=false --window_width=1280 --window_height=800"
