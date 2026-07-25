# PalvolveNative

The native part of Palvolve. It does exactly one thing: when a Pal evolves, it registers the
target species in the player's capture record so the game unlocks that species' saddle and Pal
Gear recipes. Everything else in Palvolve is Lua.

This lives in C++ because the capture record is stored in replicated fast arrays that UE4SS'
Lua API cannot reach. The build output ships as `dlls/main.dll` next to `scripts/`.

## What it exposes to the Lua side

UE4SS fires the same-name `on_lua_start` for a Lua mod that shares this mod's name, which is
how the bindings reach `scripts/evolution.lua`:

```lua
PalvolveNative_Version()                              -- string
PalvolveNative_GetCaptureRecord(characterId, uid?)    -- count, flagSet, message
PalvolveNative_UnlockCaptureRecord(characterId, uid?) -- ok, message
```

`uid` is the owning player's `OwnerPlayerUId` formatted as `%08X-%08X-%08X-%08X`. Leave it out
in single player. Calls are idempotent, refuse to run without world authority, and report
failure as `(false, message)` rather than throwing.

## Version lock

A UE4SS C++ mod is bound to the UE4SS build it was compiled against. Loading it into a
different build fails with `[0x7f] The specified procedure could not be found`.

This release is built against **UE4SS commit `c838a8ac`**, the build shipped by
[UE4SS Experimental (Palworld)](https://github.com/Okaetsu/RE-UE4SS/releases/tag/experimental-palworld)
and by the Steam Workshop item of the same name. Every UE4SS update means rebuilding and
re-releasing this component.

## Building

Requires Windows, Visual Studio 2022 **17.14 or newer** (MSVC toolset 14.44+), CMake 3.22+,
a Rust toolchain, and a GitHub account linked to Epic Games for the Unreal source submodule.

```bash
git config --global core.longpaths true
git config --global url."https://github.com/".insteadOf "git@github.com:"

# short path - MSVC does not honour core.longpaths
mkdir -p /c/pwcpp && cd /c/pwcpp
git clone --depth 1 --no-tags https://github.com/Okaetsu/RE-UE4SS.git RE-UE4SS
cd RE-UE4SS
git fetch --depth 1 origin c838a8acaade1a0f860bdf249f039e58f4e10088
git checkout FETCH_HEAD
git submodule update --init --recursive --depth 1
```

Point a root `CMakeLists.txt` at both projects:

```cmake
cmake_minimum_required(VERSION 3.22)
project(PalCppMods)
add_subdirectory(RE-UE4SS)
add_subdirectory("<path to>/Palvolve/cpp" PalvolveNative)
```

Then:

```powershell
cmake -B build -G "Visual Studio 17 2022" -A x64 .
cmake --build build --config Game__Shipping__Win64 --target PalvolveNative
```

Copy `build/PalvolveNative/Game__Shipping__Win64/PalvolveNative.dll` to `Palvolve/dlls/main.dll`.

Always build `Game__Shipping__Win64`. A Debug build links a different C runtime than the
shipped UE4SS and will not load.
