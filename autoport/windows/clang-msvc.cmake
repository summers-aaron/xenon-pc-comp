# Cross-compile for Windows (MSVC ABI) from Linux with clang + lld-link, against
# the MSVC CRT and Windows SDK that xwin splats into XWIN_ROOT (see
# docker/Containerfile.windows).
#
#   cmake -DCMAKE_TOOLCHAIN_FILE=autoport/windows/clang-msvc.cmake -DWIN_ARCH=aarch64 ...
#
# WIN_ARCH: aarch64 (Windows on ARM) or x86_64.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 10.0)

if(NOT WIN_ARCH)
  set(WIN_ARCH aarch64)
endif()
if(NOT XWIN_ROOT)
  set(XWIN_ROOT /opt/xwin)
endif()
# try_compile projects re-read this file; pass the settings through.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES WIN_ARCH XWIN_ROOT)

set(_arch_flags "")
if(WIN_ARCH STREQUAL "aarch64")
  set(CMAKE_SYSTEM_PROCESSOR ARM64)
elseif(WIN_ARCH STREQUAL "x86_64")
  set(CMAKE_SYSTEM_PROCESSOR AMD64)
  # Same baseline as ReXGlue's win-amd64 presets; Windows on ARM's x64
  # emulation runs it too.
  set(_arch_flags "-march=x86-64-v2")
else()
  message(FATAL_ERROR "WIN_ARCH must be aarch64 or x86_64, not '${WIN_ARCH}'")
endif()
set(_triple ${WIN_ARCH}-pc-windows-msvc)

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET ${_triple})
set(CMAKE_CXX_COMPILER_TARGET ${_triple})
set(CMAKE_ASM_COMPILER clang)
set(CMAKE_ASM_COMPILER_TARGET ${_triple})
set(CMAKE_RC_COMPILER llvm-rc)
set(CMAKE_MT llvm-mt)
# clang with the GNU-style driver archives ar-style (qc), so llvm-ar, not llvm-lib.
set(CMAKE_AR llvm-ar)
set(CMAKE_RANLIB llvm-ranlib)
set(CMAKE_LINKER lld-link)

set(_includes
  ${XWIN_ROOT}/crt/include
  ${XWIN_ROOT}/sdk/include/ucrt
  ${XWIN_ROOT}/sdk/include/um
  ${XWIN_ROOT}/sdk/include/shared
  ${XWIN_ROOT}/sdk/include/winrt)
# Case-fixed links for SDK headers the sources spell differently (<ObjBase.h>
# vs objbase.h); made once per build tree, outside try_compile projects.
set(_case_dir ${CMAKE_BINARY_DIR}/xwin-case)
get_property(_in_try_compile GLOBAL PROPERTY IN_TRY_COMPILE)
if(NOT _in_try_compile AND NOT EXISTS ${_case_dir})
  set(_scan ${CMAKE_SOURCE_DIR})
  foreach(prefix IN LISTS CMAKE_PREFIX_PATH)
    list(APPEND _scan ${prefix}/include)
  endforeach()
  set(_sdk_args "")
  foreach(dir IN LISTS _includes)
    list(APPEND _sdk_args --sdk-include ${dir})
  endforeach()
  execute_process(
    COMMAND python3 ${CMAKE_CURRENT_LIST_DIR}/header_case.py ${_sdk_args} --out ${_case_dir} ${_scan}
    COMMAND_ERROR_IS_FATAL ANY)
endif()

# -idirafter, not -isystem: the MSVC headers must come after clang's own
# (intrin.h, arm_neon.h, ...), which #include_next them, as with clang-cl.
set(_flags "${_arch_flags}")
foreach(dir IN LISTS _includes ITEMS ${_case_dir})
  string(APPEND _flags " -idirafter ${dir}")
endforeach()
set(CMAKE_C_FLAGS_INIT "${_flags}")
set(CMAKE_CXX_FLAGS_INIT "${_flags}")
set(CMAKE_RC_FLAGS_INIT "-I ${XWIN_ROOT}/sdk/include/um -I ${XWIN_ROOT}/sdk/include/shared")

set(_link "")
foreach(dir crt/lib/${WIN_ARCH} sdk/lib/um/${WIN_ARCH} sdk/lib/ucrt/${WIN_ARCH})
  string(APPEND _link " -L${XWIN_ROOT}/${dir}")
endforeach()
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_link}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_link}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_link}")

# xwin ships only the release CRT (no msvcrtd.lib), so every configuration,
# try_compile included, links the release DLL runtime.
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
set(CMAKE_TRY_COMPILE_CONFIGURATION Release)
cmake_policy(SET CMP0091 NEW)

# Find only Windows things: the xwin sysroot and the prefixes we were given
# (the cross-built SDK install), never the container's Linux packages.
set(CMAKE_FIND_ROOT_PATH ${XWIN_ROOT} ${CMAKE_PREFIX_PATH})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
