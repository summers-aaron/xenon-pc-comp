# Adds autoport/windows/d3d12_agility.cpp to the game executable (see there).
set(_autoport_agility_source "${CMAKE_CURRENT_LIST_DIR}/d3d12_agility.cpp")
cmake_language(EVAL CODE "cmake_language(DEFER CALL target_sources ${PROJECT_NAME} PRIVATE \"${_autoport_agility_source}\")")
