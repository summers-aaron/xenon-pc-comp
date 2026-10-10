#!/usr/bin/env bash
# Build Halo 3 for Windows from your own disc image, cross-compiled in podman
# (from WSL or Linux), and install it into a Windows folder.
#
#   ./setup-halo3-windows.sh /path/to/Halo\ 3.iso [WINDOWS_DIR]
#
# WINDOWS_DIR is where halo3.exe, its DLLs, the launcher and the game data go,
# as a WSL path (default: %USERPROFILE%\Halo3). WIN_ARCH is the CPU to build
# for: x86_64 (default; also runs on Windows on ARM through its x64 emulation)
# or aarch64 (native Windows on ARM). The renderer is Direct3D 12 (Vulkan is
# built in too, but the runtime picks Direct3D 12).
#
# Steps (all re-run safe):
#   1. build containers: xenon-build (Linux, codegen) and xenon-build-win-<arch>
#      (clang + lld + the MSVC CRT / Windows SDK from xwin, which accepts
#      Microsoft's license for them)
#   2. build extract-xiso
#   3. clone ReXGlue v0.10.0 and apply our SDK/runtime patch
#   4. build the patched SDK for Linux       (tools/rexglue-resync: rexglue for codegen)
#   5. cross-build it for Windows            (tools/rexglue-win-<arch>; rebuilt
#                                             when the patch or its options change)
#   6. port the game: ISO -> codegen -> Windows build (games/halo3; relinked
#                                             against the SDK on later runs)
#   7. install into WINDOWS_DIR
# Then on Windows: WINDOWS_DIR\play-halo3.cmd -Name <gamertag> [-Live]
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ISO=${1:-}
WIN_ARCH=${WIN_ARCH:-x86_64}
SDK=$ROOT/tools/rexglue-resync
WIN_SDK=$ROOT/tools/rexglue-win-$WIN_ARCH
WIN_IMAGE=xenon-build-win-$WIN_ARCH
SRC=$ROOT/ref/rexglue-sdk
PATCH=$ROOT/autoport/sdk-patches/halo3-system-link.diff
GAME=$ROOT/games/halo3
BUILD=$GAME/port/out/build/win-$WIN_ARCH-release

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  echo "usage: $0 /path/to/Halo 3.iso [WINDOWS_DIR]" >&2
  exit 1
fi
ISO=$(realpath "$ISO")
case "$WIN_ARCH" in
  aarch64 | x86_64) ;;
  *) echo "WIN_ARCH must be aarch64 or x86_64" >&2; exit 1 ;;
esac

step() { printf '\n== %s\n' "$*"; }
run() {  # run <image> <workdir> <command...>
  local image=$1 work=$2
  shift 2
  podman run --rm --userns=keep-id -v "$ROOT:$ROOT:Z" -w "$work" "$image" bash -c "$*"
}

for tool in podman git python3; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done
python3 -c 'import capstone' 2>/dev/null || {
  echo "missing Python module capstone (pip install --user capstone)" >&2
  exit 1
}

if [ -n "${2:-}" ]; then
  DEST=$2
elif command -v cmd.exe >/dev/null; then
  DEST=$(wslpath "$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' | tr -d '\r')")/Halo3
else
  echo "not under WSL: pass WINDOWS_DIR (where to put the Windows build)" >&2
  exit 1
fi

step "build containers"
podman image exists xenon-build ||
  podman build -t xenon-build -f "$ROOT/docker/Containerfile" "$ROOT/docker"
podman image exists "$WIN_IMAGE" ||
  podman build -t "$WIN_IMAGE" --build-arg TARGET_ARCH="$WIN_ARCH" \
    -f "$ROOT/docker/Containerfile.windows" "$ROOT/docker"

step "extract-xiso"
if [ ! -x "$ROOT/tools/extract-xiso/build/extract-xiso" ]; then
  run xenon-build "$ROOT/tools/extract-xiso" 'cmake -S . -B build -G Ninja >/dev/null && cmake --build build'
fi

step "ReXGlue v0.10.0 + patch"
mkdir -p "$ROOT/ref"
if [ ! -d "$SRC/.git" ]; then
  git clone --branch v0.10.0 https://github.com/rexglue/rexglue-sdk.git "$SRC"
  git -C "$SRC" submodule update --init --recursive
fi
if git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "patch already applied"
else
  git -C "$SRC" apply "$PATCH"
  echo "patch applied"
fi

step "patched SDK for Linux (codegen)"
if [ ! -x "$SDK/bin/rexglue" ]; then
  march=
  [ "$(uname -m)" = x86_64 ] && march="-DCMAKE_C_FLAGS=-march=x86-64-v2 -DCMAKE_CXX_FLAGS=-march=x86-64-v2"
  run xenon-build "$SRC" "cmake -S . -B out/build/src-release -G Ninja \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ $march \
      -DCMAKE_CXX_STANDARD=23 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$SDK && \
    cmake --build out/build/src-release -j\$(nproc) && cmake --install out/build/src-release"
fi

step "patched SDK for Windows ($WIN_ARCH)"
WIN_SDK_OPTIONS="-DCMAKE_TOOLCHAIN_FILE=$ROOT/autoport/windows/clang-msvc.cmake -DWIN_ARCH=$WIN_ARCH \
  -DCMAKE_CXX_STANDARD=23 -DCMAKE_BUILD_TYPE=Release \
  -DREXGLUE_USE_D3D12=ON -DREXGLUE_USE_VULKAN=ON -DREXGLUE_ENABLE_TRACY=OFF \
  -DCMAKE_INSTALL_PREFIX=$WIN_SDK"
# Rebuilt (incrementally) whenever the patch or these options change.
WIN_SDK_STAMP=$( (sha256sum "$PATCH" | cut -d' ' -f1; echo "$WIN_SDK_OPTIONS") | sha256sum | cut -d' ' -f1)
if [ ! -f "$WIN_SDK/bin/rexruntime.dll" ] || [ "$(cat "$WIN_SDK/.autoport-stamp" 2>/dev/null)" != "$WIN_SDK_STAMP" ]; then
  run "$WIN_IMAGE" "$SRC" "cmake -S . -B out/build/win-$WIN_ARCH-release -G Ninja $WIN_SDK_OPTIONS && \
    cmake --build out/build/win-$WIN_ARCH-release -j\$(nproc) && \
    cmake --install out/build/win-$WIN_ARCH-release"
  echo "$WIN_SDK_STAMP" >"$WIN_SDK/.autoport-stamp"
fi

step "port Halo 3 from $ISO"
if [ ! -f "$BUILD/halo3.exe" ]; then
  AUTOPORT_TARGET=windows WIN_ARCH=$WIN_ARCH AUTOPORT_SDK=$SDK AUTOPORT_WIN_SDK=$WIN_SDK \
    AUTOPORT_REXGLUE=$ROOT/autoport/rexglue-container.sh \
    "$ROOT/autoport/port.sh" "$ISO" "$GAME" halo3
else
  # Already ported: relink against the (possibly rebuilt) SDK and take its DLLs.
  run "$WIN_IMAGE" "$GAME/port" "cmake --build $BUILD -j\$(nproc)"
  cp -f "$WIN_SDK"/bin/*.dll "$BUILD/"
fi

step "install into $DEST"
mkdir -p "$DEST"
cp -f "$BUILD"/halo3.exe "$BUILD"/*.dll "$ROOT"/windows/play-halo3.ps1 "$ROOT"/windows/play-halo3.cmd "$DEST/"
rsync -a --info=progress2 "$GAME/game/" "$DEST/game/"

step "done"
cat <<EOF
On Windows, from $(wslpath -w "$DEST" 2>/dev/null || echo "$DEST"):
  play-halo3.cmd -Name <gamertag>                   system link on the LAN
  play-halo3.cmd -Name <gamertag> -Live             matchmaking via slop-box-live
                 [-LiveServer http://<server>:36080]
Run the server (slop-box-live): bin/db.sh start && mix phx.server
EOF
