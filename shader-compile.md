# Halo 3 port: shader precompilation work

Handoff notes for the Halo 3 port in `~/xenon-pc-comp`, branch `windows-arm64`.
Scope: precompiling shaders and pipelines ahead of time so the game doesn't
stutter on first sight of a shader. Everything else (Live, README, branch
cleanup) is out of scope for now.

Halo 3's title ID is `4D5307E6`; Reach's is `4D53085B`.

## Where things live

- `xenon-gpu/`: native GPU library (Vulkan only) and the offline shader tools.
  - `tools/shader_scan.cpp` builds `xgpu-shader-scan`: it finds Xenos shader
    programs in arbitrary game files.
  - `tools/shader_aot.cpp` builds `xgpu-shader-aot`: it translates a shader corpus to
    SPIR-V.
  - `tools/extract_shaders.py`: the earlier Python extractor (parses D3D
    shader containers), replaced by the scanner. `tools/xsh.py` and `tools/xenos_cf.py` are helpers.
    `tools/stutter_report.py` summarizes a stutter log written when you set `AUTOPORT_STUTTER_LOG=<file>`.
  - `corpus/` holds the outputs (`.xsh`, `.csv`, `.spvpack`, AOT logs). It is
    gitignored, at about 2.3 GB.
  - `xenon-gpu/CMakeLists.txt` builds the scanner (`xenon-gpu/build/`).
    `xgpu-shader-aot` is built inside the ReXGlue SDK build instead, because it needs
    the runtime's translator. It's enabled with `-DXGPU_TOOLS_DIR=<repo>/xenon-gpu/tools`
    (see `src/graphics/CMakeLists.txt` in the patched SDK). The current binary is
    `ref/rexglue-resync/out/linux-amd64/xgpu-shader-aot`.
- The runtime is ReXGlue v0.10.0 plus `autoport/sdk-patches/halo3-system-link.diff`.
  The patch is generated, so don't hand-edit it: change a source tree, then regenerate
  the patch with `git diff <v0.10.0> HEAD`. `setup-halo3.sh` shows how the tree is cloned,
  patched and built. Relevant files in the patched tree:
  - `src/graphics/pipeline/shader/spirv_translator*.cpp`,
    `include/rex/graphics/pipeline/shader/spirv_translator.h`: the SPIR-V translator.
  - `src/graphics/vulkan/pipeline_cache.cpp`,
    `include/rex/graphics/vulkan/pipeline_cache.h`: the Vulkan pipeline cache and
    pipeline-library linking (cvar `vulkan_pipeline_library`, on by default).
  - `src/graphics/d3d12/pipeline_cache.cpp`: the D3D12 pipeline cache (Windows).
- Builds run in podman: `xenon-build` (`docker/Containerfile`, Fedora 44,
  clang 22, cmake, ninja, glslang, spirv-tools; C++23, `-march=x86-64-v2`) for
  Linux, and `xenon-build-win-<arch>` (`docker/Containerfile.windows`, clang +
  lld-link + xwin) for the Windows cross-build. Disc data is in
  `games/halo3/game/` (gitignored).

## What exists today

Offline, two steps:

1. Scan the disc files. Programs are hashed with XXH3-64 over the guest
   microcode, which matches the runtime's own hashes:
   ```bash
   xenon-gpu/build/xgpu-shader-scan --out xenon-gpu/corpus/4D5307E6.xsh --index xenon-gpu/corpus/4D5307E6.csv games/halo3/game/default.xex games/halo3/game/maps/*.map
   ```
2. Translate to SPIR-V with the runtime's translator, using the default vertex/pixel
   modification. A worker process isolates translator crashes; programs that fail are
   dropped, which also removes false hits from the scan:
   ```bash
   ref/rexglue-resync/out/linux-amd64/xgpu-shader-aot --in xenon-gpu/corpus/4D5307E6.xsh --out xenon-gpu/corpus/4D5307E6.spvpack
   ```
   `.spvpack` format: header `'XGSP'` u32, version u32, count u32. Each entry is
   hash u64, modification u64, stage u32, size u32, then the SPIR-V bytes.

Results (2026-09-26):
- Halo 3: 19,295 unique programs, 19,011 translated, 7 translator crashers
  (`corpus/aot-4D5307E6.log`). The corpus covers 584 of the 722 shaders seen at runtime (81%).
  The missing 19% exist in no game file because the game builds or patches them at runtime.
- Reach: similar coverage (1,524 of 1,804).

What the runtime does today (none of it uses the corpus):
- Linux/Vulkan:
  - Driver shader disk caches; `play-halo3.sh` raises the NVIDIA and Mesa limits to 10 GB.
  - Pipelines linked from VK_EXT_graphics_pipeline_library parts, with
    extended dynamic state 1/2/3 (replayed after each guest pipeline bind). A new
    state combo links in about 0.05 ms.
  - A warm boot prewarms about 2.8k pipelines in 0.5 s from the runtime's
    own shader/pipeline storage.
  - SPIR-V translation itself is cheap (about 0.24 ms). First-sight stutter is pipeline
    creation, about one dropped frame each.
- Windows/D3D12: renders with DXBC through the D3D12 pipeline cache. The SPIR-V corpus
  doesn't apply.

## TODO

### 1. Make the runtime load the AOT corpus (Linux/Vulkan)
Nothing in the SDK or runtime reads `.spvpack` yet. Remaining work, in order:
1. **Per-shader interpolator masks in AOT translation.** The runtime's translation
   depends on per-shader interpolator usage. The AOT output must match what the
   runtime would produce for the same shader, or it can't be used as-is.
2. **Independent-set, per-stage pipeline layouts.** Descriptor sets 2 and 3 are
   the VS and PS texture sets. They need layouts that don't depend on the other stage,
   so per-stage pipeline libraries can be built without knowing the pairing.
3. **Precompile pipeline libraries from the corpus** and load them at startup,
   alongside the existing warm-boot prewarm.
4. Measure with `AUTOPORT_STUTTER_LOG` + `xenon-gpu/tools/stutter_report.py`
   before and after: a cold boot into a multiplayer map and a campaign level.

Optional: look into the 7 translator crashers listed in `aot-4D5307E6.log`.

### 2. Halo 3 pipeline harvest
Fill the runtime's pipeline storage by playing every map, so the 19% of shaders
not on the disc and the real state combinations get recorded. Model it on
`autoport/reach_harvest.sh`, which plays a Slayer custom game on every map with
scripted input (`autoport/pad.sh`) and reports how much pipeline storage grew. Keep the
output out of git.

### 3. Windows/D3D12 equivalent (scope with the user first)
The Windows build gets nothing from the SPIR-V corpus. A D3D12 version would
translate the same `.xsh` corpus to DXBC and pre-build the D3D12 pipeline cache.
Ask the user before starting.

## How to work

- Change the runtime in a patched source tree, rebuild the SDK, regenerate
  `autoport/sdk-patches/halo3-system-link.diff`, and confirm the Linux build still works.
- Commit when it makes sense, but push only when asked. Don't open GitHub issues, PRs or
  comments without an explicit request.
- Test runs should be windowed. Use `pkill -x` with exact process names. Never `rm` with
  unguarded variables; use literal paths or narrow globs.
- For anything that needs a person to play (multiplayer, long sessions), boot the
  windows and hand them to the user rather than automating it.
