#!/usr/bin/env bash
# Boot the latest Halo 3 port (resync SDK build).
#
# Usage: ./play-halo3.sh [options] [-- extra runtime flags]
#   --fullscreen   fullscreen instead of a 1280x800 window
#   --fps          print the guest frame rate every 5 s
#   --novsync      allow immediate/mailbox present (old behaviour, uses more CPU)
#   --scale N      render at N x N internal resolution (Halo 3 is 1152x640)
#   --pad DIR      enable the scripted pad (drive it with autoport/pad.sh DIR ...)
#   --native       render with the xenon-gpu native renderer (rexgpu-xgpu plugin)
#   --instance N   system link on one PC: instance N (1..16) uses IP 127.0.0.<N+1>,
#                  gamertag PlayerN and its own saves/caches (games/halo3/instances/N);
#                  several instances may run at once
#   --live [URL]   sign in to the Xbox Live stand-in (halo3-live-phoenix), default
#                  http://127.0.0.1:36080; enables matchmaking
#   --name NAME    gamertag; across PCs each system link player needs its own
#                  (without --instance the game uses this PC's LAN address)
#   --zt           system link over ZeroTier: advertise this PC's ZeroTier IPv4
#                  address (one game per PC; the LAN address is not advertised)
#   --ip ADDR      system link using this IPv4 address instead of the default NIC
#   -h, --help     show this help
# Anything after `--` is passed to the game unchanged.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
BUILD=$ROOT/games/halo3/port/out/build/linux-release
SDK_LIB=$ROOT/tools/rexglue-resync/lib64
# Halo 3 runtime fixes built from the ref/rexglue-h3 worktree (branch halo3); only
# librexruntime.so is replaced, everything else comes from the resync SDK.
H3_LIB=$ROOT/tools/rexglue-h3/lib64
GAME=$ROOT/games/halo3/game

window=(--fullscreen=false --window_width=1280 --window_height=800)
extra=()
envs=()
plugin=xenos
instance=
explicit_ip=

while [ $# -gt 0 ]; do
  case "$1" in
    --fullscreen) window=(--fullscreen=true) ;;
    --fps) envs+=(AUTOPORT_FPS=1) ;;
    --native) plugin=xgpu ;;
    --instance)
      shift
      instance=$1
      ;;
    --live)
      url=http://127.0.0.1:36080
      if [ $# -gt 1 ] && [[ $2 == http://* ]]; then shift; url=$1; fi
      extra+=(--live_server="$url")
      ;;
    --name)
      shift
      extra+=(--user_name="$1")
      ;;
    --ip)
      shift
      explicit_ip=$1
      extra+=(--net_ip="$1")
      ;;
    --zt)
      explicit_ip=$(ip -4 -o addr show 2>/dev/null |
        awk '$2 ~ /^zt/ { sub(/\/.*/, "", $4); print $4; exit }')
      if [ -z "$explicit_ip" ]; then
        echo "--zt: no ZeroTier interface with an IPv4 address (is ZeroTier joined?)" >&2
        exit 1
      fi
      echo "ZeroTier system link address: $explicit_ip"
      extra+=(--net_ip="$explicit_ip")
      ;;
    --novsync) extra+=(--vulkan_allow_present_mode_immediate=true --vulkan_allow_present_mode_mailbox=true) ;;
    --scale)
      shift
      extra+=(--draw_resolution_scale_x="$1" --draw_resolution_scale_y="$1")
      ;;
    --pad)
      shift
      mkdir -p "$1"
      envs+=("AUTOPORT_INPUT_FILE=$(realpath "$1")/cmd.txt")
      ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; extra+=("$@"); break ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

if [ -n "$instance" ] && [ -n "$explicit_ip" ]; then
  echo "--instance cannot be combined with --zt/--ip" >&2
  exit 1
fi

if [ -n "$instance" ]; then
  if ! [[ $instance =~ ^([1-9]|1[0-6])$ ]]; then
    echo "--instance must be 1..16" >&2
    exit 1
  fi
  data=$ROOT/games/halo3/instances/$instance
  mkdir -p "$data"
  extra=(--net_ip=127.0.0.$((instance + 1)) --user_name=Player$instance
         --user_data_root="$data" --cache_root="$data/cache" --log_file="$data/halo3.log" --log_max_file_size_mb=200
         "${extra[@]}")
elif pgrep -x halo3 >/dev/null; then
  echo "halo3 is already running (pid $(pgrep -x halo3 | tr '\n' ' '))" >&2
  exit 1
fi

# Keep the host driver's compiled-pipeline cache from evicting the game's pipelines
# (the NVIDIA default is about 1 GB shared by every application).
export __GL_SHADER_DISK_CACHE_SIZE=${__GL_SHADER_DISK_CACHE_SIZE:-10737418240}
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP:-1}
export MESA_SHADER_CACHE_MAX_SIZE=${MESA_SHADER_CACHE_MAX_SIZE:-10G}

# Free guest-memory files leaked by earlier crashed runs (only ones no process has open).
"$ROOT/autoport/clean_shm.sh"

cd "$BUILD"
# The GPU plugins live in the SDK. Relink them if this tree was copied from
# another machine/path (the symlinks port.sh made are absolute).
for gpu_plugin in librexgpu-xenos.so librexgpu-xgpu.so; do
  [ -e "$SDK_LIB/$gpu_plugin" ] || continue
  [ -e "$gpu_plugin" ] || ln -sfn "$SDK_LIB/$gpu_plugin" "$gpu_plugin"
done
# The runtime rejects a flag given more than once, and that parse error also
# drops other flags (--gpu_plugin among them, leaving a black screen). Pass only
# the last value of each flag, so --name with --instance or a repeated extra
# flag just overrides the earlier one.
args=(--game_data_root="$GAME" --gpu_plugin=$plugin "${window[@]}" "${extra[@]}")
declare -A last
for i in "${!args[@]}"; do last[${args[i]%%=*}]=$i; done
final=()
for i in "${!args[@]}"; do [ "${last[${args[i]%%=*}]}" = "$i" ] && final+=("${args[i]}"); done
exec env "${envs[@]}" LD_LIBRARY_PATH="$BUILD:$H3_LIB:$SDK_LIB" ./halo3 "${final[@]}"
