cmake_minimum_required(VERSION 3.22)

# Native companion for the Palvolve Lua mod. The build output is copied to dlls/main.dll;
# the ModName set in dllmain.cpp (not this target name) is what makes UE4SS fire the
# same-name on_lua_start overload for the Palvolve Lua mod.
set(TARGET PalvolveNative)
project(${TARGET})

add_library(${TARGET} SHARED "src/dllmain.cpp")
target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PUBLIC UE4SS)
