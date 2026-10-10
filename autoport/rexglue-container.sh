#!/usr/bin/env bash
# Runs the SDK's rexglue inside the build container (it links against the
# container's glibc/libstdc++, which may be newer than the host's).
# AUTOPORT_SDK: the installed SDK (default tools/rexglue-resync).
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SDK=${AUTOPORT_SDK:-$ROOT/tools/rexglue-resync}
exec podman run --rm --userns=keep-id -v "$ROOT:$ROOT:Z" -w "$PWD" xenon-build "$SDK/bin/rexglue" "$@"
