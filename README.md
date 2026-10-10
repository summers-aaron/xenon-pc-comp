# Halo 3, native on Linux — with ZeroTier system link

Recompiles your own Halo 3 (Xbox 360) disc image into a native Linux binary and
plays it with working **system link (LAN) multiplayer**, including between
machines that only share a **ZeroTier** network.

Built on [ReXGlue](https://github.com/rexglue/rexglue-sdk), the open-source
Xbox 360 static-recompilation toolchain. This repository is the whole recipe:
the ISO → native pipeline (`autoport/`), the ReXGlue changes that make Halo 3
(and specifically system link) work on Linux, and the launcher.

## Requirements

- Linux x86-64 (developed on Fedora 44), a Vulkan-capable GPU
- `podman`, `git`, `python3`
- ~40 GB free disk
- Your own Halo 3 disc image (ISO); it stays on your machine
- For internet play: both machines on the same ZeroTier network

## Build

```bash
git clone <this repo> xenon-pc-comp
cd xenon-pc-comp
./setup-halo3.sh "/path/to/Halo 3.iso"
```

The first run is long (the patched ReXGlue SDK is built from source, then the
game is recompiled). It is re-run safe: finished steps are skipped.

## Play

```bash
./play-halo3.sh --name YourName                  # system link on the LAN
./play-halo3.sh --zt --name YourName             # system link over ZeroTier
```

Every player needs a different `--name` (the XUID is derived from it). In game:
**Multiplayer → System Link**, one player hosts/creates the game, the others
join. While a game is running, `tools/zt-probe.py` lists every Halo 3 it can
see on the ZeroTier link (they all answer the probe on UDP 37023).

Useful launcher flags: `--instance N` (several instances on one PC),
`--ip ADDR` (pick the system-link interface), `--native` (experimental native
renderer), `--fps`, `--scale N`, `--help`.

## Windows

`setup-halo3-windows.sh` cross-compiles the same port for Windows in podman
(from WSL or Linux) and installs it into a Windows folder (default
`%USERPROFILE%\Halo3`):

```bash
./setup-halo3-windows.sh "/path/to/Halo 3.iso"
```

It builds x86_64 by default (Windows on ARM runs it through its x64
emulation); `WIN_ARCH=aarch64` builds for Windows on ARM natively. The
renderer is Direct3D 12. Building the cross-compile container accepts
Microsoft's license for the MSVC CRT and Windows SDK (fetched with xwin).
On Windows, from the install folder:

```
play-halo3.cmd -Name YourName              system link on the LAN
play-halo3.cmd -Name YourName -Zt          system link over ZeroTier
```

The other options (`-Instance N`, `-Ip`, `-Live`, `-Fullscreen`, `-Scale N`)
are listed at the top of `play-halo3.ps1`.

## ZeroTier notes

Both machines only need to join the same ZeroTier network — no port
forwarding. `--zt` advertises this machine's ZeroTier address and, thanks to the
runtime patch, sends system-link discovery broadcasts out the ZeroTier
interface instead of the default route. If a machine's ZeroTier address is
managed and reachable (`zerotier-cli listnetworks` says `OK`), the games find
each other.

## What's in here

| Path | What |
| --- | --- |
| `setup-halo3.sh` | One-command build: SDK patching + ISO port |
| `autoport/` | ISO → native pipeline (codegen fixups, runtime hooks, build) |
| `autoport/sdk-patches/halo3-system-link.diff` | Everything changed in ReXGlue: Canary GPU re-sync, Halo 3 fixes, system link |
| `play-halo3.sh` | Launcher |
| `setup-halo3-windows.sh`, `windows/` | Windows cross-build and its launcher |
| `autoport/windows/` | Windows cross-compile toolchain (clang + xwin) and helpers |
| `tools/zt-probe.py` | Find running Halo 3s on the ZeroTier/LAN link |
| `xenon-gpu/` | Experimental native renderer (`--native`); optional |
| `docker/Containerfile` | Build container (clang, GTK3, shader tools) |
| `docker/Containerfile.windows` | Windows cross-compile container |

Status: Halo 3 boots to the menu, campaign loads (Arrival → Sierra 117 and
beyond), and system link multiplayer works between instances/machines. The
`--native` renderer is experimental; the default emulated Xenos renderer is the
well-tested path.

## Notes

- Guest ports below 1024 are mapped up by `net_port_offset` (default 36000).
  Every machine in a system link must use the same offset.
- `--instance 1..16` gives each local instance its own `127.0.0.N`, saves and
  cache for system link on a single PC.
- Kernel/GPU details and the session history are in `autoport/` comments.

## Legal

No game code or data is included. `setup-halo3.sh` reads your own disc image;
the resulting binary is for your own use. ReXGlue and its dependencies are
BSD/MIT-licensed; `tools/extract-xiso` ships under its own license. Not
affiliated with Microsoft, Bungie or 343 Industries.
