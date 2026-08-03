cmake_minimum_required(VERSION 3.22)

# Native companion for the Palvolve Lua mod. The build output is copied to dlls/main.dll;
# the ModName set in dllmain.cpp (not this target name) is what makes UE4SS fire the
# same-name on_lua_start overload for the Palvolve Lua mod.
set(TARGET PalvolveNative)
project(${TARGET})

# UE4SS ships Zydis, Zycore and PolyHook2, but not safetyhook. The base camp decides work
# assignment through a C++ method that no reflected hook can reach, so the inline hook that
# fixes work behaviour after an evolution needs it. Pinned, like every other tool here.
include(FetchContent)
FetchContent_Declare(safetyhook
    GIT_REPOSITORY https://github.com/cursey/safetyhook.git
    GIT_TAG v0.6.2)
FetchContent_MakeAvailable(safetyhook)

add_library(${TARGET} SHARED "src/dllmain.cpp")
target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PRIVATE safetyhook)
target_link_libraries(${TARGET} PUBLIC UE4SS)
