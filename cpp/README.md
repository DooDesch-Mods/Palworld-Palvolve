# PalvolveNative

The native part of Palvolve. It handles the things an evolution has to change that UE4SS' Lua
API cannot reach: the capture record behind saddle and Pal Gear recipes, the work suitability
ranks a Pal carries into its new form, the moves it keeps, and the question of whether this
process is a dedicated server. Everything else in Palvolve is Lua.

Each of those lives in a replicated fast array, an engine-side cache or a native-only call, which
is what puts them out of Lua's reach. The build output ships as `dlls/main.dll` next to
`scripts/`.

## What it exposes to the Lua side

UE4SS fires the same-name `on_lua_start` for a Lua mod that shares this mod's name, which is
how the bindings reach `scripts/evolution.lua`:

```lua
PalvolveNative_Version()                                                -- string
PalvolveNative_GetCaptureRecord(characterId, uid?, playerStateName?)    -- count, flagSet, message
PalvolveNative_UnlockCaptureRecord(characterId, uid?, playerStateName?) -- ok, message
PalvolveNative_SetWorkSuitability(palAddress, workType, rank)           -- ok, message
PalvolveNative_ClearWorkSuitability(palAddress)                         -- ok, message
PalvolveNative_ScanWorkCache(palAddress)                                -- ok, message
PalvolveNative_TeachMasteredWaza(palAddress, wazaId)                    -- ok, message
PalvolveNative_IsDedicatedServer()                                      -- bool
PalvolveNative_Console(message)                                         -- writes to the server console
```

`PalvolveNative_IsDedicatedServer` reads the role from the executable name. Asking the engine is
just as certain but only answers once a world exists, and probing for one during startup killed
the server outright.

`uid` is the owning player's `OwnerPlayerUId` formatted as `%08X-%08X-%08X-%08X`.
`playerStateName` is the object name of that player's `PalPlayerState`. When both are given the
state wins, because the uid is then read from the authority's own object instead of from whatever
the calling process saw replicated. Pass empty strings in single player. An all-zero uid counts as
unresolved. Calls are idempotent, refuse to run without world authority, and report failure as
`(false, message)` rather than throwing.

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

**The Visual Studio generator picks the wrong toolset.** It takes the default,
14.38 on a machine that also has 14.44, and `-T version=14.44` does not change
that: UE4SS checks `MSVC_VERSION`, sees 1938 against its minimum of 1943, and
stops at configure time. Do not pass `-DUE4SS_VERSION_CHECK=OFF` to get around
it. The check guards the ABI this DLL is locked to, and a mismatch is exactly
the failure it exists to prevent.

Put the right compiler on PATH first and use a single-config generator:

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 -vcvars_ver=14.44
cmake -B build-nmake -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Game__Shipping__Win64 .
cmake --build build-nmake --target PalvolveNative
```

The DLL then lands in `build-nmake/PalvolveNative/PalvolveNative.dll`.

Copy the built `PalvolveNative.dll` to `Palvolve/dlls/main.dll`, then check that the game logs
`[PalvolveNative] loaded v<version>` with the version you expect. The release gate compares
`ModVersionString` against the mod version, but only the log proves the binary was rebuilt.

Always build `Game__Shipping__Win64`. A Debug build links a different C runtime than the
shipped UE4SS and will not load.
