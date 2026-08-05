// PalvolveNative - native companion for the Palvolve Lua mod.
//
// Purpose: set the capture record of a Pal species so that catch-gated technologies (saddles,
// Pal gear) unlock after an evolution. The data lives in replicated FastArrays that UE4SS-Lua
// cannot map, which is why this part is native. Everything else stays in Lua.
//
// The mod exposes three functions to the Palvolve Lua mod through UE4SS' Lua bridge:
//   PalvolveNative_Version()                              -> string
//   PalvolveNative_GetCaptureRecord(characterId, uid?)    -> count, flagSet, message
//   PalvolveNative_UnlockCaptureRecord(characterId, uid?) -> ok, message
//
// Record layout and the FFrame/ref-parameter technique are documented in
// Workspace/docs/CPP-MODDING.md, sections 6.4c to 6.4f.

// Module range for the native getter probe (PE headers). NOMINMAX is mandatory: without it the
// min/max macros collide with std::numeric_limits inside the UE4SS headers.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <array>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <cwchar>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include <safetyhook.hpp>

#include <Mod/CppUserModBase.hpp>
#include <UE4SSProgram.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>

#include <Unreal/AGameModeBase.hpp>
#include <Unreal/Hooks.hpp>
#include <Unreal/FURL.hpp>
#include <Unreal/FWorldContext.hpp>
#include <Unreal/UEngine.hpp>
#include <Unreal/FString.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/Property/FStructProperty.hpp>
#include <Unreal/Property/FObjectProperty.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr const wchar_t* ModVersionString = STR("1.5.0");

    // A world context object is required by the *_ForServer setters. The game mode is the
    // first reliable one available and exists only on the authority, which doubles as the
    // authority guard: no game mode means no business writing records here.
    std::atomic<UObject*> g_world_context{nullptr};

    auto find_fn(const wchar_t* Path) -> UFunction*
    {
        return UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, Path);
    }

    // Parameter buffer built from real property offsets rather than a mirrored C++ struct,
    // so a game patch that moves a parameter does not silently corrupt the call.
    struct FParamBuffer
    {
        UFunction* Function{};
        std::vector<uint8> Data;

        explicit FParamBuffer(UFunction* Fn) : Function(Fn)
        {
            int32 Size = 0;
            for (FProperty* Prop : Fn->ForEachProperty())
            {
                if (!Prop->HasAnyPropertyFlags(EPropertyFlags::CPF_Parm)) continue;
                const int32 End = Prop->GetOffset_Internal() + Prop->GetSize();
                if (End > Size) Size = End;
            }
            Data.assign(static_cast<size_t>(Size), 0);
        }

        auto Find(const wchar_t* Name) -> FProperty*
        {
            for (FProperty* Prop : Function->ForEachProperty())
            {
                if (Prop->HasAnyPropertyFlags(EPropertyFlags::CPF_Parm) && Prop->GetName() == Name) return Prop;
            }
            return nullptr;
        }

        template<typename T> auto Set(const wchar_t* Name, const T& Value) -> bool
        {
            auto* Prop = Find(Name);
            if (!Prop || Prop->GetSize() < static_cast<int32>(sizeof(T))) return false;
            std::memcpy(Data.data() + Prop->GetOffset_Internal(), &Value, sizeof(T));
            return true;
        }

        auto SetRaw(const wchar_t* Name, const void* Src, size_t Bytes) -> bool
        {
            auto* Prop = Find(Name);
            if (!Prop || static_cast<size_t>(Prop->GetSize()) != Bytes) return false;
            std::memcpy(Data.data() + Prop->GetOffset_Internal(), Src, Bytes);
            return true;
        }

        template<typename T> auto Get(const wchar_t* Name) -> T
        {
            auto* Prop = Find(Name);
            T Out{};
            if (Prop) std::memcpy(&Out, Data.data() + Prop->GetOffset_Internal(), sizeof(T));
            return Out;
        }

        auto Call(UObject* Context) -> void { Context->ProcessEvent(Function, Data.data()); }
    };

    // Calls a UFunction that takes a UPARAM(ref) struct. ProcessEvent cannot be used for
    // those: it keeps every parameter inline, so the callee would work on a byte copy of a
    // container that carries lock state - which crashes the process. The reference address
    // has to travel through the OutParms chain instead.
    auto call_with_ref_param(UObject* Context, UFunction* Function,
                             void* Locals, FProperty* RefProp, void* RealAddress) -> bool
    {
        auto* ExecThunk = reinterpret_cast<void(*)(UObject*, FFrame&, void*)>(Function->GetFuncPtr());
        if (!ExecThunk || !RefProp || !RealAddress) return false;

        FOutParmRec OutRec{};
        OutRec.Property = RefProp;
        OutRec.PropAddr = static_cast<uint8*>(RealAddress);
        OutRec.NextOutParm = nullptr;

        std::vector<uint8> FrameStorage(sizeof(FFrame_51_AndAbove) + 64, 0);
        auto* Raw = reinterpret_cast<FFrame_51_AndAbove*>(FrameStorage.data());
        Raw->Node = Function;
        Raw->Object = Context;
        Raw->Code = nullptr; // nullptr selects the StepCompiledIn path
        Raw->Locals = static_cast<uint8*>(Locals);
        Raw->OutParms = &OutRec;
        Raw->PropertyChainForCompiledIn = Function->GetChildProperties();
        Raw->CurrentNativeFunction = Function;

        ExecThunk(Context, *reinterpret_cast<FFrame*>(Raw), nullptr);
        return true;
    }

    auto guid_string(const void* Guid) -> std::wstring
    {
        const auto* P = static_cast<const uint32*>(Guid);
        wchar_t Buffer[40]{};
        swprintf_s(Buffer, L"%08X-%08X-%08X-%08X", P[0], P[1], P[2], P[3]);
        return Buffer;
    }

    // An unset FGuid formats as all zeros. It is not a usable identity but it is not empty
    // either, so a plain emptiness check lets it through and it then matches nothing.
    auto is_zero_guid(const std::wstring& Guid) -> bool
    {
        if (Guid.empty()) return false;
        return Guid.find_first_not_of(STR("0-")) == std::wstring::npos;
    }

    // Reporters paste server logs into public threads. The first block of a uid is enough to
    // tell "all zeros" from "does not match anything", so full player identities stay out.
    auto guid_prefix(const std::wstring& Guid) -> std::wstring
    {
        if (Guid.empty()) return STR("<none>");
        return Guid.substr(0, Guid.find(L'-'));
    }

    // Reads an FGuid-shaped struct property off an object, empty when it is not there.
    auto read_guid_prop(UObject* Object, const wchar_t* PropName) -> std::wstring
    {
        if (!Object) return {};
        auto* Prop = CastField<FStructProperty>(Object->GetPropertyByNameInChain(PropName));
        if (!Prop) return {};
        return guid_string(Prop->ContainerPtrToValuePtr<void>(Object));
    }

    auto is_live(UObject* Object) -> bool
    {
        return Object && Object->GetName().find(STR("Default__")) == StringType::npos;
    }

    // ================================================================== work suitability
    //
    // After an evolution the screens and the base camp keep using the work suitability of
    // the species the Pal evolved FROM. Those values come from a native cache built when the
    // individual parameter is CONSTRUCTED, and nothing rebuilds it while the world runs.
    // Every write path is ruled out, most recently the one reflected setter
    // (SetWorkSuitabilityAddRank reports success and moves nothing).
    //
    // So this fixes the READ. The getters go through UFunction dispatch, so a post-hook can
    // answer with the ranks of the species the Pal is NOW, taken from
    // PalDatabaseCharacterParameter - the same table the constructor reads.
    //
    // Two rules paid for in crashes and dead ends:
    //   * A hook must never dispatch a script call. Calling GetCharacterID (ProcessEvent)
    //     from inside these hooks re-entered them on the game thread with the mutex held and
    //     took the process down within seconds of an evolution.
    //   * The Lua side hands over the parameter OBJECT, never a key it built itself. Its own
    //     key helper falls back to GetFullName when the struct read fails, and the native
    //     side then received a name where it expected a guid and installed nothing.

    constexpr size_t WorkSuitabilityMax = 16;   // EPalWorkSuitability: 13 real types in 0..15

    // Unreal's object index plus serial number is generation-safe: it rejects an object-array
    // slot that has been reused after GC. Serial allocation is restricted to override install;
    // the hook path only reads an already-assigned serial and never triggers engine dispatch.
    using FWorkKey = std::array<int32, 2>;

    struct FWorkOverride
    {
        std::wstring CharacterId;
        std::vector<uint8> MapStorage;
        // The same ranks, flat. The screens read the whole map, the base camp asks per work
        // type - showing the right icons while the Pal refuses the job is worse than nothing.
        std::array<int32, WorkSuitabilityMax> Ranks{};
    };

    // Captured BEFORE any UE4SS hook is registered. Once a UFunction has been hooked its Func
    // pointer permanently points at UE4SS' own dispatcher rather than the game (CPP-MODDING.md
    // 8.3c), and a native hook placed on that address hooks UE4SS and hangs the process.
    //
    // Two functions matter. The base camp reaches the pal through
    //   UPalBaseCampWorkerDirector::HasWorkerWithSuitabilityRank
    //     -> director's CharacterContainer -> slot -> handle -> TryGetIndividualParameter
    //     -> UPalIndividualCharacterParameter::HasWorkSuitabilityRank   (native, direct call)
    // so HasWorkSuitabilityRank is the one that decides work behaviour. GetWorkSuitabilityRank
    // is hooked as well because other native callers use it, but hooking only that one was
    // measured to change nothing.
    void* g_rank_thunk{nullptr};
    void* g_hasrank_thunk{nullptr};

    // Every call target inside an exec thunk. One of them is the C++ method; which one is
    // decided by measurement, not by position.
    std::vector<uintptr_t> g_rank_candidates;
    std::vector<uintptr_t> g_hasrank_candidates;
    std::atomic<uintptr_t> g_rank_native{0};
    std::atomic<uintptr_t> g_hasrank_native{0};

    // The database hands its rank map back in a different key space than the getter the base
    // camp asks. Measured once per session rather than hardcoded, so a game patch that moves
    // the enum cannot silently put every rank under the wrong work type again.
    std::atomic<int32> g_key_offset{0};
    std::atomic<bool> g_key_offset_known{false};

    std::mutex g_work_mutex;
    std::map<FWorkKey, FWorkOverride> g_work_overrides;
    // Read before the hook takes the lock: a session that never evolved anything must not pay
    // for a lookup on a per-frame path.
    std::atomic<size_t> g_work_override_count{0};
    FMapProperty* g_work_map_prop{nullptr};

    auto object_key(UObject* Param, FWorkKey& Out) -> bool
    {
        if (!Param) return false;
        const int32 Index = Param->GetInternalIndex();
        auto* Item = FUObjectArray::IndexToObject(Index);
        if (!Item || Item->GetUObject() != Param) return false;
        const int32 Serial = Item->GetSerialNumber();
        if (Serial == 0) return false;
        Out = {Index, Serial};
        return true;
    }

    auto allocate_object_key(UObject* Param, FWorkKey& Out) -> bool
    {
        if (!Param) return false;
        const int32 Index = Param->GetInternalIndex();
        auto* Item = FUObjectArray::IndexToObject(Index);
        if (!Item || Item->GetUObject() != Param) return false;
        const int32 Serial = FUObjectArray::AllocateSerialNumber(Index);
        if (Serial == 0) return false;
        Out = {Index, Serial};
        return true;
    }

    auto character_name_fast(UObject* Param) -> FName
    {
        FName Out{};
        if (!Param) return Out;
        auto* SaveProp = CastField<FStructProperty>(Param->GetPropertyByNameInChain(STR("SaveParameter")));
        if (!SaveProp) return Out;
        auto* Base = static_cast<uint8*>(SaveProp->ContainerPtrToValuePtr<void>(Param));
        if (!Base) return Out;
        for (FProperty* Inner : SaveProp->GetStruct()->ForEachProperty())
        {
            if (Inner->GetName() != STR("CharacterID")) continue;
            if (Inner->GetElementSize() < static_cast<int32>(sizeof(FName))) return Out;
            std::memcpy(&Out, Base + Inner->GetOffset_Internal(), sizeof(FName));
            return Out;
        }
        return Out;
    }

    struct FScopedPropertyValue
    {
        FProperty* Property{};
        void* Value{};

        FScopedPropertyValue(FProperty* InProperty, void* InValue)
            : Property(InProperty), Value(InValue) {}
        FScopedPropertyValue(const FScopedPropertyValue&) = delete;
        auto operator=(const FScopedPropertyValue&) -> FScopedPropertyValue& = delete;

        ~FScopedPropertyValue()
        {
            if (Property && Value) Property->DestroyValue(Value);
        }
    };

    auto map_layout_matches(FMapProperty* Left, FMapProperty* Right) -> bool
    {
        if (!Left || !Right) return false;
        auto* LeftKey = Left->GetKeyProp();
        auto* RightKey = Right->GetKeyProp();
        auto* LeftValue = Left->GetValueProp();
        auto* RightValue = Right->GetValueProp();
        if (!LeftKey || !RightKey || !LeftValue || !RightValue) return false;

        return LeftKey->GetClass() == RightKey->GetClass()
            && LeftValue->GetClass() == RightValue->GetClass()
            && LeftKey->GetElementSize() == RightKey->GetElementSize()
            && LeftValue->GetElementSize() == RightValue->GetElementSize()
            && LeftKey->GetMinAlignment() == RightKey->GetMinAlignment()
            && LeftValue->GetMinAlignment() == RightValue->GetMinAlignment()
            && Left->GetMapLayout().ValueOffset == Right->GetMapLayout().ValueOffset;
    }

    auto return_property(UFunction* Function) -> FProperty*
    {
        if (!Function) return nullptr;
        FProperty* Result = nullptr;
        for (FProperty* Prop : Function->ForEachProperty())
        {
            if (!Prop->HasAnyPropertyFlags(EPropertyFlags::CPF_ReturnParm)) continue;
            if (Result) return nullptr;
            Result = Prop;
        }
        return Result;
    }

    // Defined below; the probes need them and sit here so they read next to the findings they
    // came from.
    auto build_species_map(UObject* WorldCtx, const std::wstring& CharacterId,
                           std::vector<uint8>& OutStorage) -> bool;
    auto flatten_ranks(const std::vector<uint8>& Storage,
                       std::array<int32, WorkSuitabilityMax>& Out, int32 KeyOffset) -> bool;
    auto clear_work_override(UObject* Param) -> bool;
    auto probe_native_getter() -> std::wstring;
    auto install_native_rank_hook() -> void;

    // Locates the native work suitability cache inside the parameter object.
    //
    // Why this exists: the four reflected getters are hooked and answer correctly, and the
    // Team and Palbox screens follow. The base camp does not - measured, with logging on
    // every hook: after three evolutions and an override installed each time, not one scalar
    // getter was ever called. The work system reads the cache in native code without going
    // through UFunction dispatch, so no post-hook can reach it.
    //
    // That leaves writing the cache. This probe finds it: it asks the database for the ranks
    // of a species and scans the object's own memory for that byte pattern. Run it on a Pal
    // that was just evolved, searching for the species it evolved FROM, and any hit is the
    // stale cache. Read-only, and the scan never leaves the object's own allocation.
    auto scan_work_cache(UObject* Param, const std::wstring& SpeciesId) -> std::wstring
    {
        if (!Param) return STR("no parameter object");

        auto* WorldCtx = g_world_context.load();
        if (!WorldCtx)
        {
            std::vector<UObject*> Chars;
            UObjectGlobals::FindAllOf(STR("PalPlayerCharacter"), Chars);
            for (auto* C : Chars) { if (is_live(C)) { WorldCtx = C; break; } }
        }
        if (!WorldCtx) return STR("no world context");

        std::vector<uint8> Storage;
        std::array<int32, WorkSuitabilityMax> Ranks{};
        if (!build_species_map(WorldCtx, SpeciesId, Storage)) return STR("species not in the database");
        const bool Flat = flatten_ranks(Storage, Ranks, g_key_offset.load());
        if (g_work_map_prop) g_work_map_prop->DestroyValue(Storage.data());
        if (!Flat) return STR("could not read the species ranks");

        // The signature: the ranks of work types 1..13 in enum order. Distinctive enough,
        // because most species have several zeros and a couple of specific values.
        std::wstring Wanted;
        for (size_t i = 1; i < WorkSuitabilityMax; ++i)
        {
            Wanted += std::to_wstring(Ranks[i]);
            if (i + 1 < WorkSuitabilityMax) Wanted += STR(",");
        }

        auto* Class = Param->GetClassPrivate();
        if (!Class) return STR("no class");
        const size_t ObjectSize = static_cast<size_t>(Class->GetPropertiesSize());
        if (ObjectSize < 64 || ObjectSize > (1u << 20)) return STR("implausible object size");
        const auto* Bytes = reinterpret_cast<const uint8*>(Param);

        std::wstring Hits;
        int32 Found = 0;

        // Two widths, because a rank fits in a byte but the game may well store int32s.
        for (size_t Offset = 0; Offset + WorkSuitabilityMax * 4 <= ObjectSize; ++Offset)
        {
            bool MatchByte = true, MatchInt = true;
            for (size_t i = 1; i < WorkSuitabilityMax; ++i)
            {
                if (MatchByte && static_cast<int32>(Bytes[Offset + i - 1]) != Ranks[i]) MatchByte = false;
                if (MatchInt)
                {
                    int32 Value = 0;
                    std::memcpy(&Value, Bytes + Offset + (i - 1) * 4, sizeof(int32));
                    if (Value != Ranks[i]) MatchInt = false;
                }
                if (!MatchByte && !MatchInt) break;
            }
            if (MatchByte || MatchInt)
            {
                if (Found < 8)
                {
                    Hits += STR(" 0x");
                    wchar_t Buffer[24]{};
                    swprintf_s(Buffer, L"%X(%s)", static_cast<uint32>(Offset), MatchByte ? L"u8" : L"i32");
                    Hits += Buffer;
                }
                ++Found;
            }
        }

        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] cache scan for '{}' ranks [{}] in {} bytes: {} hit(s){}\n"),
            SpeciesId, Wanted, static_cast<int32>(ObjectSize), Found, Hits);

        // Second pass, different hypothesis. If the ranks are not stored as a vector, the
        // object probably keeps its own copy of the SPECIES - an FName, or a handle derived
        // from one at construction - and derives suitability from that on demand. Every place
        // holding the OLD species after an evolution is a candidate for what to update.
        const FName Wanted2(SpeciesId.c_str());
        std::wstring NameHits;
        int32 NameFound = 0;
        for (size_t Offset = 0; Offset + sizeof(FName) <= ObjectSize; Offset += 4)
        {
            FName Candidate{};
            std::memcpy(&Candidate, Bytes + Offset, sizeof(FName));
            if (!(Candidate == Wanted2)) continue;
            if (NameFound < 8)
            {
                wchar_t Buffer[24]{};
                swprintf_s(Buffer, L" 0x%X", static_cast<uint32>(Offset));
                NameHits += Buffer;
            }
            ++NameFound;
        }
        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] cache scan: species name '{}' still present at {} offset(s){}\n"),
            SpeciesId, NameFound, NameHits);

        if (Found > 0 || NameFound > 0) return STR("see log for offsets");
        return STR("no match in the object");
    }

    // Retest of the one reflected setter, on the object Lua hands over.
    //
    // The first attempt at this ran from Lua through a helper that picks "the first owned
    // monster", and that helper was later proven to grab the wrong actor - it reported a
    // Penking while a Pengullet was summoned. The conclusion drawn from it ("the setter does
    // nothing") is therefore worthless and has to be redone on a known object.
    //
    // This runs from a Lua call, not from inside a hook, so ProcessEvent is allowed here.
    auto test_add_rank(UObject* Param, int32 Work, int32 Delta) -> std::wstring
    {
        if (!Param) return STR("no parameter object");
        if (Work < 1 || Work >= static_cast<int32>(WorkSuitabilityMax)) return STR("work type out of range");

        // Any override for this pal is dropped first: both getters below are hooked, and a
        // leftover entry would answer for them and hide whatever the setter really did.
        clear_work_override(Param);

        auto* BaseFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRank"));
        auto* RankFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRankWithCharacterRank"));
        auto* ListFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityPassiveAddRankList"));
        auto* SetFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:SetWorkSuitabilityAddRank"));
        if (!BaseFn || !SetFn) return STR("getter or setter not found");

        // Two getters, because the base value and the value including rank/passive bonuses
        // are separate functions. A book's effect may well only show in the second one, which
        // would explain why the first test looked like the setter does nothing.
        auto ReadWith = [&](UFunction* Fn, const wchar_t* ParamName) -> int32 {
            if (!Fn) return -1;
            FParamBuffer Buffer(Fn);
            Buffer.Set(ParamName, static_cast<uint8>(Work));
            Buffer.Call(Param);
            return Buffer.Get<int32>(STR("ReturnValue"));
        };

        const int32 BaseBefore = ReadWith(BaseFn, STR("InWorkSuitability"));
        const int32 RankBefore = ReadWith(RankFn, STR("WorkSuitability"));

        FParamBuffer SetBuffer(SetFn);
        const bool SetWork = SetBuffer.Set(STR("WorkSuitability"), static_cast<uint8>(Work));
        const bool SetDelta = SetBuffer.Set(STR("addRank"), Delta);
        if (!SetWork || !SetDelta) return STR("setter parameters did not match");
        SetBuffer.Call(Param);

        const int32 BaseAfter = ReadWith(BaseFn, STR("InWorkSuitability"));
        const int32 RankAfter = ReadWith(RankFn, STR("WorkSuitability"));

        // The passive add-rank list is where a book's bonus is stored. If the setter wrote
        // anything at all, it shows up here even when both getters stay put.
        int32 ListCount = -1;
        if (ListFn)
        {
            FParamBuffer ListBuffer(ListFn);
            ListBuffer.Call(Param);
            if (auto* ArrayProp = CastField<FArrayProperty>(ListBuffer.Find(STR("ReturnValue"))))
            {
                FScriptArray* Array = nullptr;
                std::memcpy(&Array, ListBuffer.Data.data() + ArrayProp->GetOffset_Internal(), sizeof(void*));
                ListCount = Array ? Array->Num() : -1;
            }
        }

        const bool Moved = (BaseBefore != BaseAfter) || (RankBefore != RankAfter);
        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] addrank test: work={} delta={:+} base {}->{} withRank {}->{} addList={} ({})\n"),
            Work, Delta, BaseBefore, BaseAfter, RankBefore, RankAfter, ListCount,
            Moved ? STR("MOVED") : STR("unchanged"));

        return Moved ? STR("setter works") : STR("setter had no effect");
    }

    // Builds one species' rank map from the database the game itself reads and copies it into
    // storage we own. The engine builds the container, so its hashing stays the engine's job.
    auto build_species_map(UObject* WorldCtx, const std::wstring& CharacterId,
                           std::vector<uint8>& OutStorage) -> bool
    {
        if (!g_work_map_prop || !WorldCtx) return false;

        auto* UtilFn = find_fn(STR("/Script/Pal.PalUtility:GetDatabaseCharacterParameter"));
        auto* Util = UObjectGlobals::StaticFindObject<UObject*>(
            nullptr, nullptr, STR("/Script/Pal.Default__PalUtility"));
        if (!UtilFn || !Util) return false;

        FParamBuffer UtilBuffer(UtilFn);
        UtilBuffer.Set(STR("WorldContextObject"), WorldCtx);
        UtilBuffer.Call(Util);
        auto* Database = UtilBuffer.Get<UObject*>(STR("ReturnValue"));
        if (!is_live(Database)) return false;

        auto* DbFn = find_fn(STR("/Script/Pal.PalDatabaseCharacterParameter:GetWorkSuitabilityRank"));
        if (!DbFn) return false;

        FParamBuffer DbBuffer(DbFn);
        FName Row(CharacterId.c_str());
        if (!DbBuffer.Set(STR("RowName"), Row)) return false;
        auto* OutProp = CastField<FMapProperty>(DbBuffer.Find(STR("WorkSuitabilities")));
        if (!OutProp) return false;
        auto* OutValue = DbBuffer.Data.data() + OutProp->GetOffset_Internal();
        FScopedPropertyValue DestroyOutValue{OutProp, OutValue};
        DbBuffer.Call(Database);

        // Layout guard: the copy writes raw container memory, so a game patch that changes
        // either side has to stop the feature instead of corrupting a map.
        if (!map_layout_matches(OutProp, g_work_map_prop)) return false;

        OutStorage.assign(static_cast<size_t>(g_work_map_prop->GetSize()), 0);
        g_work_map_prop->InitializeValue(OutStorage.data());
        g_work_map_prop->CopyCompleteValue(OutStorage.data(), OutValue);
        return true;
    }

    // Flattens the stored map to rank-per-work-type, walked through FScriptMap with the
    // property's own layout rather than a mirrored struct.
    auto flatten_ranks(const std::vector<uint8>& Storage, std::array<int32, WorkSuitabilityMax>& Out,
                       int32 KeyOffset) -> bool
    {
        Out.fill(0);
        if (!g_work_map_prop || Storage.empty()) return false;

        auto* KeyProp = g_work_map_prop->GetKeyProp();
        auto* ValueProp = g_work_map_prop->GetValueProp();
        if (!KeyProp || !ValueProp) return false;
        if (ValueProp->GetElementSize() != static_cast<int32>(sizeof(int32))) return false;

        const int32 KeySize = KeyProp->GetElementSize();
        if (KeySize != 1 && KeySize != 4) return false;

        const auto& Layout = g_work_map_prop->GetMapLayout();
        const auto* Map = reinterpret_cast<const FScriptMap*>(Storage.data());

        int32 Found = 0;
        for (int32 Index = 0; Index < Map->GetMaxIndex(); ++Index)
        {
            if (!Map->IsValidIndex(Index)) continue;
            const auto* Pair = static_cast<const uint8*>(Map->GetData(Index, Layout));
            if (!Pair) continue;

            int32 Key = 0;
            if (KeySize == 1) Key = static_cast<int32>(*Pair);
            else std::memcpy(&Key, Pair, sizeof(int32));
            Key -= KeyOffset;
            if (Key < 0 || Key >= static_cast<int32>(WorkSuitabilityMax)) continue;

            int32 Value = 0;
            std::memcpy(&Value, Pair + Layout.ValueOffset, sizeof(int32));
            Out[static_cast<size_t>(Key)] = Value;
            ++Found;
        }
        return Found > 0;
    }

    // Reads the Nth input parameter of a hooked getter as an integer. Offsets come from the
    // function's own properties, never a hardcoded zero. Index 0 is the work type everywhere;
    // HasWorkSuitabilityRank takes a required rank as index 1.
    auto int_param_of(UnrealScriptFunctionCallableContext& Ctx, UFunction* Fn, int32 Which) -> int32
    {
        if (!Fn) return -1;
        const auto* Base = static_cast<const uint8*>(static_cast<void*>(Ctx.TheStack.Locals()));
        if (!Base) return -1;

        int32 Seen = 0;
        for (FProperty* Prop : Fn->ForEachProperty())
        {
            if (!Prop->HasAnyPropertyFlags(EPropertyFlags::CPF_Parm)) continue;
            if (Prop->HasAnyPropertyFlags(EPropertyFlags::CPF_ReturnParm)) continue;
            if (Seen++ != Which) continue;

            const int32 Size = Prop->GetElementSize();
            int32 Value = 0;
            if (Size == 1) Value = static_cast<int32>(*(Base + Prop->GetOffset_Internal()));
            else if (Size == 4) std::memcpy(&Value, Base + Prop->GetOffset_Internal(), sizeof(int32));
            else return -1;
            return Value;
        }
        return -1;
    }

    // Caller holds g_work_mutex. Object index plus serial rejects a slot reused after GC.
    auto find_entry_locked(UObject* Param) -> FWorkOverride*
    {
        FWorkKey Key{};
        if (!object_key(Param, Key)) return nullptr;
        auto It = g_work_overrides.find(Key);
        return It == g_work_overrides.end() ? nullptr : &It->second;
    }

    // Instance ids belong to one world, so nothing survives a map change.
    auto clear_work_overrides() -> void
    {
        std::lock_guard<std::mutex> Lock(g_work_mutex);
        if (g_work_map_prop)
        {
            for (auto& Pair : g_work_overrides)
            {
                if (!Pair.second.MapStorage.empty())
                {
                    g_work_map_prop->DestroyValue(Pair.second.MapStorage.data());
                }
            }
        }
        g_work_overrides.clear();
        g_work_override_count.store(0);
    }

    auto install_work_hooks() -> void
    {
        static std::atomic<bool> s_installed{false};
        bool Expected = false;
        if (!s_installed.compare_exchange_strong(Expected, true)) return;

        auto* MapFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRanksWithCharacterRank"));
        if (!MapFn)
        {
            Output::send<LogLevel::Warning>(STR("[PalvolveNative] work suitability: map getter not found\n"));
            return;
        }
        g_work_map_prop = CastField<FMapProperty>(return_property(MapFn));
        if (!g_work_map_prop)
        {
            Output::send<LogLevel::Warning>(STR("[PalvolveNative] work suitability: return value is not a map\n"));
            return;
        }

        // Feeds the Team screen, the Palbox detail panel and the worker info.
        MapFn->RegisterPostHook([](UnrealScriptFunctionCallableContext& Ctx, void*) {
            if (g_work_override_count.load(std::memory_order_relaxed) == 0) return;
            if (!Ctx.Context || !Ctx.RESULT_DECL || !g_work_map_prop) return;

            std::lock_guard<std::mutex> Lock(g_work_mutex);
            auto* Entry = find_entry_locked(Ctx.Context);
            if (!Entry) return;
            g_work_map_prop->CopyCompleteValue(Ctx.RESULT_DECL, Entry->MapStorage.data());
        });

        // Feed the base camp, which asks per work type. Which of these the work system really
        // uses is not documented anywhere, so each one reports the first time it changes an
        // answer - one line per function per session, enough to see what actually matters.
        enum class EScalarKind { Rank, Has, HasRank };
        struct FScalarHook { const wchar_t* Path; EScalarKind Kind; };
        static constexpr FScalarHook ScalarHooks[] = {
            {STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRankWithCharacterRank"), EScalarKind::Rank},
            {STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRank"), EScalarKind::Rank},
            {STR("/Script/Pal.PalIndividualCharacterParameter:HasWorkSuitability"), EScalarKind::Has},
            // Two parameters: work type plus the rank being asked for. Left out of the first
            // version, and the base camp kept using the old species - a strong hint that this
            // is the one it asks.
            {STR("/Script/Pal.PalIndividualCharacterParameter:HasWorkSuitabilityRank"), EScalarKind::HasRank},
        };

        // Has to happen before the first RegisterPostHook below, see g_rank_thunk.
        if (auto* RankFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRank")))
        {
            g_rank_thunk = reinterpret_cast<void*>(RankFn->GetFuncPtr());
        }
        if (auto* HasRankFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:HasWorkSuitabilityRank")))
        {
            g_hasrank_thunk = reinterpret_cast<void*>(HasRankFn->GetFuncPtr());
        }

        int32 Installed = 0;
        for (const auto& Spec : ScalarHooks)
        {
            auto* ScalarFn = find_fn(Spec.Path);
            if (!ScalarFn) continue;
            const auto Kind = Spec.Kind;
            const wchar_t* Label = Spec.Path;
            auto* ReturnProp = return_property(ScalarFn);
            auto* RankReturnProp = Kind == EScalarKind::Rank ? CastField<FIntProperty>(ReturnProp) : nullptr;
            auto* BoolReturnProp = Kind != EScalarKind::Rank ? CastField<FBoolProperty>(ReturnProp) : nullptr;
            const bool ReturnTypeValid = Kind == EScalarKind::Rank
                ? RankReturnProp && RankReturnProp->GetElementSize() == static_cast<int32>(sizeof(int32))
                : BoolReturnProp != nullptr;
            if (!ReturnTypeValid)
            {
                Output::send<LogLevel::Warning>(
                    STR("[PalvolveNative] work suitability: unexpected return type for {}\n"), Label);
                continue;
            }
            // A counter, not a one-shot flag. The first version logged only the first hit per
            // function, and the mod's own diagnostic calls consumed that one shot - which made
            // a silent "the base camp never asks" out of a measurement that never ran.
            ScalarFn->RegisterPostHook([Kind, ScalarFn, RankReturnProp, BoolReturnProp](UnrealScriptFunctionCallableContext& Ctx, void*) {
                if (g_work_override_count.load(std::memory_order_relaxed) == 0) return;
                if (!Ctx.Context || !Ctx.RESULT_DECL) return;

                const int32 Work = int_param_of(Ctx, ScalarFn, 0);
                if (Work < 0 || Work >= static_cast<int32>(WorkSuitabilityMax)) return;

                std::lock_guard<std::mutex> Lock(g_work_mutex);
                auto* Entry = find_entry_locked(Ctx.Context);
                if (!Entry) return;

                const int32 Rank = Entry->Ranks[static_cast<size_t>(Work)];
                switch (Kind)
                {
                case EScalarKind::Rank:
                    RankReturnProp->SetPropertyValue(Ctx.RESULT_DECL, Rank);
                    break;
                case EScalarKind::Has:
                    BoolReturnProp->SetPropertyValue(Ctx.RESULT_DECL, Rank > 0);
                    break;
                case EScalarKind::HasRank:
                {
                    const int32 Required = int_param_of(Ctx, ScalarFn, 1);
                    BoolReturnProp->SetPropertyValue(Ctx.RESULT_DECL, Required >= 0 && Rank >= Required);
                    break;
                }
                }

            });
            ++Installed;
        }

        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] work suitability hooks installed (map + {} scalar)\n"), Installed);
        probe_native_getter();
    }

    auto module_range(uintptr_t& OutBase, uintptr_t& OutEnd) -> bool
    {
        auto* Module = GetModuleHandleW(nullptr);
        if (!Module) return false;
        auto* Dos = reinterpret_cast<IMAGE_DOS_HEADER*>(Module);
        if (Dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
        auto* Nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(reinterpret_cast<uint8*>(Module) + Dos->e_lfanew);
        if (Nt->Signature != IMAGE_NT_SIGNATURE) return false;
        OutBase = reinterpret_cast<uintptr_t>(Module);
        OutEnd = OutBase + Nt->OptionalHeader.SizeOfImage;
        return true;
    }

    // Lists the call targets inside the exec thunk. The thunk unpacks the script parameters and
    // then calls the real C++ method - and that method is what the base camp uses. The measured
    // reason this is needed: the director asks its reflected question hundreds of times while
    // the four reflected pal getters are never called once, so the per-pal answer is native.
    auto scan_thunk_calls(void* ThunkPtr, const wchar_t* Label, std::vector<uintptr_t>& Out) -> void
    {
        Out.clear();
        if (!ThunkPtr) return;

        uintptr_t Base = 0;
        uintptr_t End = 0;
        if (!module_range(Base, End)) return;

        const auto Thunk = reinterpret_cast<uintptr_t>(ThunkPtr);
        const bool InGame = Thunk >= Base && Thunk < End;
        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] {} thunk {:#x}, game module {:#x}..{:#x} ({})\n"),
            Label, Thunk, Base, End, InGame ? STR("inside the game") : STR("NOT the game - unusable"));
        if (!InGame) return;

        const auto* Bytes = reinterpret_cast<const uint8*>(Thunk);
        int32 Found = 0;
        for (size_t i = 0; i + 5 <= 0x100; ++i)
        {
            if (Bytes[i] == 0xC3 && Found > 0) break;   // first return after at least one call
            if (Bytes[i] != 0xE8) continue;
            int32 Rel = 0;
            std::memcpy(&Rel, Bytes + i + 1, sizeof(Rel));
            const uintptr_t Target = Thunk + i + 5 + static_cast<uintptr_t>(static_cast<intptr_t>(Rel));
            if (Target < Base || Target >= End) continue;
            ++Found;
            Out.push_back(Target);
            Output::send<LogLevel::Normal>(
                STR("[PalvolveNative]   {} call #{} at +{:#x} -> {:#x} (rva {:#x})\n"),
                Label, Found, i, Target, Target - Base);
        }
    }

    auto probe_native_getter() -> std::wstring
    {
        scan_thunk_calls(g_rank_thunk, STR("rank"), g_rank_candidates);
        scan_thunk_calls(g_hasrank_thunk, STR("hasrank"), g_hasrank_candidates);
        if (g_rank_candidates.empty() && g_hasrank_candidates.empty())
        {
            return STR("no call found in either thunk - the methods may be inlined");
        }
        return STR("call targets logged");
    }

    // Works out how the database's key space lines up with the getter's.
    //
    // Both describe the same species, so the SET of work types carrying a rank has to match.
    // Only the numbering can differ, and it differed by one: every rank landed one work type
    // too high, which is how a Penking ended up gathering - a job neither it nor its previous
    // form has. Matching key sets rather than values, because the live map carries the pal's
    // condenser rank on top and the database map does not.
    auto measure_key_offset(UObject* Sample) -> void
    {
        if (g_key_offset_known.load()) return;

        // Every way out of here says so. A silent return is what made the first attempt look
        // like it had run when it had not.
        auto bail = [](const wchar_t* Why) {
            Output::send<LogLevel::Warning>(STR("[PalvolveNative] key offset not measured: {}\n"), Why);
        };

        if (!Sample || !g_work_map_prop) { bail(STR("no sample or map property")); return; }

        auto* WorldCtx = g_world_context.load();
        if (!WorldCtx) { bail(STR("no world context")); return; }
        std::wstring Species = character_name_fast(Sample).ToString();
        if (Species == STR("None")) Species.clear();

        // What the base camp sees for this pal, in the key space that decides work.
        auto* LiveFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRanksWithCharacterRank"));
        if (!LiveFn) { bail(STR("live getter not found")); return; }

        // The sample has to be a pal that actually does work. The first live parameter in the
        // world is regularly a wild pal or an NPC with no suitabilities at all, and an empty
        // map has no keys to line up - that is what "live map unreadable" really was.
        auto live_entries = [&](UObject* Candidate, std::array<int32, WorkSuitabilityMax>& Out) -> int32 {
            FParamBuffer Buffer(LiveFn);
            Buffer.Call(Candidate);
            auto* Prop = CastField<FMapProperty>(Buffer.Find(STR("ReturnValue")));
            if (!Prop) return 0;
            std::vector<uint8> Copy(static_cast<size_t>(g_work_map_prop->GetSize()), 0);
            g_work_map_prop->InitializeValue(Copy.data());
            g_work_map_prop->CopyCompleteValue(Copy.data(), Buffer.Data.data() + Prop->GetOffset_Internal());
            const bool Ok = flatten_ranks(Copy, Out, 0);
            g_work_map_prop->DestroyValue(Copy.data());
            if (!Ok) return 0;
            int32 N = 0;
            for (int32 v : Out) { if (v != 0) ++N; }
            return N;
        };

        std::array<int32, WorkSuitabilityMax> Live{};
        std::wstring UsedSpecies = Species;
        if (Species.empty() || live_entries(Sample, Live) == 0)
        {
            UObject* Better = nullptr;
            std::vector<UObject*> Params;
            UObjectGlobals::FindAllOf(STR("PalIndividualCharacterParameter"), Params);
            for (auto* P : Params)
            {
                if (!is_live(P)) continue;
                std::array<int32, WorkSuitabilityMax> Try{};
                if (live_entries(P, Try) == 0) continue;
                // "None" is what an unset FName stringifies to, and it is not the empty string.
                // Letting it through measured an offset of 0 against a species the database
                // does not have, which looked like a result and was not one.
                const std::wstring Name = character_name_fast(P).ToString();
                if (Name.empty() || Name == STR("None")) continue;
                Live = Try;
                Better = P;
                break;
            }
            if (!Better) { bail(STR("no loaded pal has any work suitability yet")); return; }
            Sample = Better;
            UsedSpecies = character_name_fast(Better).ToString();
        }

        // The same species straight out of the database.
        std::vector<uint8> Storage;
        if (!build_species_map(WorldCtx, UsedSpecies, Storage)) { bail(STR("database map unavailable")); return; }
        std::array<int32, WorkSuitabilityMax> Db{};
        const bool Ok = flatten_ranks(Storage, Db, 0);
        g_work_map_prop->DestroyValue(Storage.data());
        if (!Ok) { bail(STR("database map unreadable")); return; }

        auto keys_match = [&](int32 Shift) {
            for (int32 i = 0; i < static_cast<int32>(WorkSuitabilityMax); ++i)
            {
                const int32 Src = i + Shift;
                const bool HasDb = Src >= 0 && Src < static_cast<int32>(WorkSuitabilityMax) && Db[Src] != 0;
                if (HasDb != (Live[i] != 0)) return false;
            }
            return true;
        };

        int32 LiveCount = 0;
        int32 DbCount = 0;
        for (int32 v : Live) { if (v != 0) ++LiveCount; }
        for (int32 v : Db) { if (v != 0) ++DbCount; }
        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] key offset input on '{}': live {} entries, database {} entries\n"),
            UsedSpecies, LiveCount, DbCount);
        if (LiveCount == 0 || DbCount == 0) { bail(STR("one of the two maps is empty")); return; }

        for (int32 Shift = -2; Shift <= 2; ++Shift)
        {
            if (!keys_match(Shift)) continue;
            g_key_offset.store(Shift);
            g_key_offset_known.store(true);
            Output::send<LogLevel::Normal>(
                STR("[PalvolveNative] work suitability key offset measured on '{}': {:+}\n"), Species, Shift);
            return;
        }

        Output::send<LogLevel::Warning>(
            STR("[PalvolveNative] could not line up the database keys with the getter on '{}' - leaving them as they are\n"),
            Species);
        g_key_offset_known.store(true);
    }

    using TRankGetter = int32(__fastcall*)(void*, uint8);
    using THasRank = bool(__fastcall*)(void*, uint8, int32);

    // Calling an address that turns out not to be this function reads through a bad pointer.
    // The guard keeps a wrong guess from taking the game down; no C++ objects live here,
    // because SEH and unwinding cannot share a frame.
    __declspec(noinline) auto try_call_rank(uintptr_t Address, void* Self, uint8 Work, int32& Out) -> bool
    {
        __try
        {
            Out = reinterpret_cast<TRankGetter>(Address)(Self, Work);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    __declspec(noinline) auto try_call_hasrank(uintptr_t Address, void* Self, uint8 Work,
                                               int32 Required, bool& Out) -> bool
    {
        __try
        {
            Out = reinterpret_cast<THasRank>(Address)(Self, Work, Required);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    // Decides which of the thunk's call targets is the C++ getter, by comparing each candidate
    // against the reflected answer over every work type. A candidate that matches all of them
    // is the method; anything else is a helper the thunk happens to call.
    auto verify_native_getter() -> void
    {
        // Runs once per session. A negative result has to stick too, otherwise the tick keeps
        // calling into an address that already proved to be the wrong one.
        static std::atomic<bool> s_done{false};
        if (g_rank_candidates.empty() || s_done.load()) return;

        auto* GetRankFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:GetWorkSuitabilityRank"));
        if (!GetRankFn) return;

        // A pal without an override, so the reflected answer is the game's own and not ours.
        UObject* Sample = nullptr;
        {
            std::vector<UObject*> Params;
            UObjectGlobals::FindAllOf(STR("PalIndividualCharacterParameter"), Params);
            std::lock_guard<std::mutex> Lock(g_work_mutex);
            for (auto* P : Params)
            {
                if (!is_live(P)) continue;
                FWorkKey Key{};
                if (object_key(P, Key) && g_work_overrides.count(Key) != 0) continue;
                Sample = P;
                break;
            }
        }
        if (!Sample) return;

        measure_key_offset(Sample);

        std::array<int32, WorkSuitabilityMax> Expected{};
        for (uint8 Work = 0; Work < static_cast<uint8>(WorkSuitabilityMax); ++Work)
        {
            FParamBuffer Buffer(GetRankFn);
            Buffer.Set(STR("InWorkSuitability"), Work);
            Buffer.Call(Sample);
            Expected[Work] = Buffer.Get<int32>(STR("ReturnValue"));
        }

        // Only the last call in the thunk is tried. An exec thunk unpacks its script parameters
        // first and calls the C++ method last, and that is what measured out: candidate #4 of 4
        // matched. Trying the earlier ones as well cost a crash - they are real functions with
        // different signatures, and calling one with the wrong arguments corrupts state without
        // ever raising the exception the guard below can catch.
        const uintptr_t Address = g_rank_candidates.back();
        bool Matches = true;
        for (uint8 Work = 0; Work < static_cast<uint8>(WorkSuitabilityMax) && Matches; ++Work)
        {
            int32 Value = 0;
            if (!try_call_rank(Address, Sample, Work, Value) || Value != Expected[Work]) Matches = false;
        }

        Output::send<LogLevel::Normal>(
            STR("[PalvolveNative] native getter {:#x} (rva {:#x}): {}\n"),
            Address, Address - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)),
            Matches ? STR("MATCHES the reflected answer") : STR("does not match - not hooking"));

        // A non-match means the layout moved. Leaving g_rank_native at zero disables the native
        // half rather than hooking something unknown; the display half keeps working.
        g_rank_native.store(Matches ? Address : 0);

        // The one that actually decides work behaviour. The director's native loop walks its
        // character container to each slot's handle, resolves the individual parameter and
        // calls this - never GetWorkSuitabilityRank, which is why hooking that alone changed
        // nothing at all.
        if (!g_hasrank_candidates.empty())
        {
            auto* HasRankFn = find_fn(STR("/Script/Pal.PalIndividualCharacterParameter:HasWorkSuitabilityRank"));
            const uintptr_t HasAddress = g_hasrank_candidates.back();
            bool HasMatches = HasRankFn != nullptr;

            for (uint8 Work = 0; Work < static_cast<uint8>(WorkSuitabilityMax) && HasMatches; ++Work)
            {
                // Several required ranks, not just one: a candidate that ignores the second
                // parameter would still match if only rank 1 were ever asked for.
                for (int32 Required = 0; Required <= 3 && HasMatches; ++Required)
                {
                    FParamBuffer Buffer(HasRankFn);
                    Buffer.Set(STR("InWorkSuitability"), Work);
                    Buffer.Set(STR("SuitabilityRank"), Required);
                    Buffer.Call(Sample);
                    const bool ExpectedValue = Buffer.Get<uint8>(STR("ReturnValue")) != 0;

                    bool Value = false;
                    if (!try_call_hasrank(HasAddress, Sample, Work, Required, Value) ||
                        Value != ExpectedValue)
                    {
                        HasMatches = false;
                    }
                }
            }

            Output::send<LogLevel::Normal>(
                STR("[PalvolveNative] native has-rank {:#x} (rva {:#x}): {}\n"),
                HasAddress, HasAddress - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)),
                HasMatches ? STR("MATCHES the reflected answer") : STR("does not match - not hooking"));
            g_hasrank_native.store(HasMatches ? HasAddress : 0);
        }

        s_done.store(true);
        install_native_rank_hook();
    }

    SafetyHookInline g_rank_hook{};
    SafetyHookInline g_hasrank_hook{};
    std::atomic<uint64> g_native_hits{0};
    std::atomic<uint64> g_native_overridden{0};
    std::atomic<uint64> g_hasrank_hits{0};
    std::atomic<uint64> g_hasrank_overridden{0};

    // Looks up the evolved species' rank for one work type. Returns false when this object is
    // not one the mod evolved, which is the overwhelmingly common case.
    auto evolved_rank(void* Self, uint8 Work, int32& OutRank) -> bool
    {
        if (g_work_override_count.load(std::memory_order_relaxed) == 0) return false;
        if (!Self || Work >= static_cast<uint8>(WorkSuitabilityMax)) return false;

        FWorkKey Key{};
        if (!object_key(static_cast<UObject*>(Self), Key)) return false;

        std::lock_guard<std::mutex> Lock(g_work_mutex);
        auto It = g_work_overrides.find(Key);
        if (It == g_work_overrides.end()) return false;
        OutRank = It->second.Ranks[Work];
        return true;
    }

    // The base camp's per-pal answer. Everything reflected was measured dead first: the four
    // reflected getters are never called by the camp, both rank delegates have no listeners,
    // and re-applying the work preferences through the camp's own request changes nothing.
    // This is the only place the camp actually reads, so this is where the new species has to
    // appear.
    auto __fastcall rank_detour(void* Self, uint8 Work) -> int32
    {
        g_native_hits.fetch_add(1, std::memory_order_relaxed);

        int32 Rank = 0;
        if (evolved_rank(Self, Work, Rank))
        {
            g_native_overridden.fetch_add(1, std::memory_order_relaxed);
            return Rank;
        }

        // Every pal the mod has not evolved keeps the game's own answer. Reconstructing the
        // formula here instead would change vanilla behaviour for every pal in every base.
        return g_rank_hook.call<int32>(Self, Work);
    }

    // The predicate the base camp's worker director asks. This is what decides whether a pal
    // is eligible for a job, and therefore what makes an evolved pal actually change work.
    auto __fastcall hasrank_detour(void* Self, uint8 Work, int32 Required) -> bool
    {
        g_hasrank_hits.fetch_add(1, std::memory_order_relaxed);

        int32 Rank = 0;
        if (evolved_rank(Self, Work, Rank))
        {
            g_hasrank_overridden.fetch_add(1, std::memory_order_relaxed);
            return Rank >= Required;
        }

        return g_hasrank_hook.call<bool>(Self, Work, Required);
    }

    auto install_native_rank_hook() -> void
    {
        const uintptr_t Address = g_rank_native.load();
        const uintptr_t HasAddress = g_hasrank_native.load();
        if ((Address == 0 && HasAddress == 0) || g_rank_hook || g_hasrank_hook) return;

        // Emergency off switch that needs no rebuild. CPP-MODDING.md 8.3c records that calling
        // back into an original can hang the process; if that ever happens here, the game is
        // unresponsive and dropping this file into the mod folder is the way back.
        std::error_code Ec;
        const auto Marker = std::filesystem::path(UE4SSProgram::get_program().get_working_directory())
                          / "Mods" / "Palvolve" / "NO_NATIVE_WORK_HOOK";
        if (std::filesystem::exists(Marker, Ec))
        {
            Output::send<LogLevel::Warning>(
                STR("[PalvolveNative] native work suitability hook disabled by marker file\n"));
            return;
        }

        if (Address != 0)
        {
            g_rank_hook = safetyhook::create_inline(reinterpret_cast<void*>(Address),
                                                    reinterpret_cast<void*>(&rank_detour));
            Output::send<LogLevel::Normal>(
                STR("[PalvolveNative] native GetWorkSuitabilityRank hook at {:#x}: {}\n"),
                Address, g_rank_hook ? STR("installed") : STR("FAILED"));
        }
        if (HasAddress != 0)
        {
            g_hasrank_hook = safetyhook::create_inline(reinterpret_cast<void*>(HasAddress),
                                                       reinterpret_cast<void*>(&hasrank_detour));
            Output::send<LogLevel::Normal>(
                STR("[PalvolveNative] native HasWorkSuitabilityRank hook at {:#x}: {}\n"),
                HasAddress, g_hasrank_hook ? STR("installed") : STR("FAILED"));
        }
    }

    // The object identity and species are both taken from the parameter object supplied by Lua.
    auto set_work_override(UObject* Param) -> std::pair<bool, std::wstring>
    {
        if (!Param) return {false, STR("no parameter object")};
        if (!g_work_map_prop) return {false, STR("hooks not installed")};

        FWorkKey Key{};
        if (!allocate_object_key(Param, Key)) return {false, STR("parameter object has no valid weak identity")};

        const FName Name = character_name_fast(Param);
        const std::wstring CharacterId = Name.ToString();
        if (CharacterId.empty()) return {false, STR("no character id on this pal")};

        auto* WorldCtx = g_world_context.load();
        if (!WorldCtx)
        {
            // Clients have no game mode; any live player character is a world context.
            std::vector<UObject*> Chars;
            UObjectGlobals::FindAllOf(STR("PalPlayerCharacter"), Chars);
            for (auto* C : Chars) { if (is_live(C)) { WorldCtx = C; break; } }
        }
        if (!WorldCtx) return {false, STR("no world context")};

        std::vector<uint8> Storage;
        if (!build_species_map(WorldCtx, CharacterId, Storage))
        {
            return {false, STR("could not read the species ranks (game patch?)")};
        }

        FWorkOverride Entry{CharacterId, std::move(Storage), {}};
        if (!flatten_ranks(Entry.MapStorage, Entry.Ranks, g_key_offset.load()))
        {
            // Installing the display half alone would show a Pal that can mine and then have
            // it refuse to mine, so nothing is installed.
            g_work_map_prop->DestroyValue(Entry.MapStorage.data());
            return {false, STR("species ranks unreadable (container layout changed?)")};
        }

        const std::array<int32, WorkSuitabilityMax> Ranks = Entry.Ranks;

        {
            std::lock_guard<std::mutex> Lock(g_work_mutex);
            auto It = g_work_overrides.find(Key);
            if (It != g_work_overrides.end())
            {
                g_work_map_prop->DestroyValue(It->second.MapStorage.data());
                g_work_overrides.erase(It);
            }
            g_work_overrides.emplace(Key, std::move(Entry));
            g_work_override_count.store(g_work_overrides.size());
        }

        // The ranks that were just installed, spelled out. A pal taking on work that neither
        // its old nor its new species has means a rank landed under the wrong key, and that
        // cannot be told apart from a correct install without seeing the numbers.
        {
            std::wstring Line;
            for (size_t i = 0; i < WorkSuitabilityMax; ++i)
            {
                const int32 Rank = Ranks[i];
                if (Rank == 0) continue;
                if (!Line.empty()) Line += STR(", ");
                Line += std::to_wstring(i) + STR("=") + std::to_wstring(Rank);
            }
            Output::send<LogLevel::Normal>(
                STR("[PalvolveNative] ranks installed for '{}': {}\n"),
                CharacterId, Line.empty() ? std::wstring(STR("none")) : Line);
        }

        // Nothing else has to be pushed, told or re-registered. The native hooks answer the
        // base camp's own question from here on; every notification, preference re-apply and
        // worker re-registration that was tried instead was measured to do nothing.
        return {true, CharacterId};
    }

    auto clear_work_override(UObject* Param) -> bool
    {
        FWorkKey Key{};
        if (!object_key(Param, Key)) return false;
        std::lock_guard<std::mutex> Lock(g_work_mutex);
        auto It = g_work_overrides.find(Key);
        if (It == g_work_overrides.end()) return false;
        if (g_work_map_prop) g_work_map_prop->DestroyValue(It->second.MapStorage.data());
        g_work_overrides.erase(It);
        g_work_override_count.store(g_work_overrides.size());
        return true;
    }

    // The uid the Lua side computes comes from the replicated PlayerState. Reading it here
    // instead, straight off the authority's own object, removes that link from the chain: the
    // caller only has to name which PlayerState it is.
    auto uid_from_player_state(const std::wstring& StateName) -> std::wstring
    {
        if (StateName.empty()) return {};
        std::vector<UObject*> States;
        UObjectGlobals::FindAllOf(STR("PalPlayerState"), States);
        for (auto* State : States)
        {
            if (!is_live(State) || State->GetName() != StateName) continue;
            return read_guid_prop(State, STR("PlayerUId"));
        }
        return {};
    }

    // Picks the record of the requesting player, trying the identities in order of how much
    // they can be trusted. Falling back to "the one record in this world" is only allowed while
    // exactly one live record exists, so a caller that could not resolve its uid never writes a
    // stranger's record in multiplayer.
    auto find_player_record(const std::wstring& PlayerUid, const std::wstring& PlayerStateName,
                            std::wstring& OutError) -> UObject*
    {
        // 1. Prefer the uid read natively off the named PlayerState over the one passed in.
        const bool bZeroFromCaller = is_zero_guid(PlayerUid);
        std::wstring Uid = uid_from_player_state(PlayerStateName);
        const bool bFromState = !Uid.empty() && !is_zero_guid(Uid);
        if (!bFromState) Uid = PlayerUid;
        if (is_zero_guid(Uid)) Uid.clear();

        // 2. The player account carries both the uid and the record, so it resolves the record
        //    even when the record's own OwnerPlayerUId is not set.
        if (!Uid.empty())
        {
            std::vector<UObject*> Accounts;
            UObjectGlobals::FindAllOf(STR("PalPlayerAccount"), Accounts);
            for (auto* Account : Accounts)
            {
                if (!is_live(Account)) continue;
                if (read_guid_prop(Account, STR("PlayerUId")) != Uid) continue;
                // Cast rather than trust the name: a game patch that turns RecordData into a
                // different property type would otherwise make the deref read a garbage pointer.
                auto* RecordProp = CastField<FObjectProperty>(Account->GetPropertyByNameInChain(STR("RecordData")));
                if (!RecordProp) continue;
                auto* Record = *RecordProp->ContainerPtrToValuePtr<UObject*>(Account);
                if (is_live(Record)) return Record;
            }
        }

        // 3. Match the records themselves.
        std::vector<UObject*> Records;
        UObjectGlobals::FindAllOf(STR("PalPlayerRecordData"), Records);

        UObject* Fallback = nullptr;
        int32 LiveCount = 0;
        std::wstring Seen;

        for (auto* Record : Records)
        {
            if (!is_live(Record)) continue;
            ++LiveCount;
            if (!Fallback) Fallback = Record;

            const std::wstring Owner = read_guid_prop(Record, STR("OwnerPlayerUId"));
            if (!Seen.empty()) Seen += STR(",");
            Seen += guid_prefix(Owner);

            if (!Uid.empty() && Owner == Uid) return Record;
        }

        if (!Fallback) { OutError = STR("no PalPlayerRecordData in this world"); return nullptr; }

        // 4. Single-player and any world with one record left: unambiguous by construction.
        if (LiveCount == 1) return Fallback;

        OutError = STR("player record ambiguous: uid=") + guid_prefix(Uid)
                 + (Uid.empty() ? STR(" (unresolved)") : (bFromState ? STR(" (from playerstate)") : STR(" (from caller)")))
                 + ((!bFromState && bZeroFromCaller) ? STR(" zero-guid") : STR(""))
                 + STR(" records=") + std::to_wstring(LiveCount)
                 + STR(" owners=[") + Seen + STR("]");
        return nullptr;
    }

    auto resolve_tribe_id(const std::wstring& CharacterId, uint16& OutValue, std::wstring& OutError) -> bool
    {
        auto* TribeEnum = UObjectGlobals::StaticFindObject<UEnum*>(nullptr, nullptr, STR("/Script/Pal.EPalTribeID"));
        if (!TribeEnum) { OutError = STR("EPalTribeID not found"); return false; }

        for (auto&& Pair : TribeEnum->ForEachName())
        {
            auto Name = Pair.Key.ToString();
            const bool Exact = (Name == CharacterId);
            const bool Suffix = Name.size() > CharacterId.size()
                && Name.compare(Name.size() - CharacterId.size(), CharacterId.size(), CharacterId) == 0
                && Name[Name.size() - CharacterId.size() - 1] == STR(':');
            if (Exact || Suffix)
            {
                OutValue = static_cast<uint16>(Pair.Value);
                return true;
            }
        }
        OutError = STR("no EPalTribeID entry for '") + CharacterId + STR("'");
        return false;
    }

    struct FRecordAccess
    {
        UObject* Record{};
        UObject* Utility{};
        UObject* World{};
        void* CountContainer{};
        void* FlagContainer{};
        size_t CountSize{};
        size_t FlagSize{};
        FProperty* CountProp{};
        FProperty* FlagProp{};
        uint16 TribeId{};
    };

    auto prepare(const std::wstring& CharacterId, const std::wstring& PlayerUid,
                 const std::wstring& PlayerStateName, FRecordAccess& Out, std::wstring& OutError) -> bool
    {
        Out.World = g_world_context.load();
        if (!Out.World) { OutError = STR("no world authority (client-side call?)"); return false; }

        if (!resolve_tribe_id(CharacterId, Out.TribeId, OutError)) return false;

        Out.Record = find_player_record(PlayerUid, PlayerStateName, OutError);
        if (!Out.Record) return false;

        Out.Utility = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/Pal.Default__PalPlayerRecordDataUtility"));
        if (!Out.Utility) { OutError = STR("PalPlayerRecordDataUtility CDO not found"); return false; }

        auto* CountProp = CastField<FStructProperty>(Out.Record->GetPropertyByNameInChain(STR("PalCaptureCount")));
        auto* FlagProp = CastField<FStructProperty>(Out.Record->GetPropertyByNameInChain(STR("PaldeckUnlockFlag")));
        if (!CountProp || !FlagProp) { OutError = STR("record containers missing (game patch?)"); return false; }

        Out.CountProp = CountProp;
        Out.FlagProp = FlagProp;
        Out.CountContainer = CountProp->ContainerPtrToValuePtr<void>(Out.Record);
        Out.FlagContainer = FlagProp->ContainerPtrToValuePtr<void>(Out.Record);
        Out.CountSize = static_cast<size_t>(CountProp->GetSize());
        Out.FlagSize = static_cast<size_t>(FlagProp->GetSize());
        return true;
    }

    auto read_record(const FRecordAccess& A, int32& OutCount, bool& OutFlag) -> bool
    {
        auto* GetCountFn = find_fn(STR("/Script/Pal.PalPlayerRecordDataUtility:GetRecordData_TribeIdCount"));
        auto* GetFlagFn = find_fn(STR("/Script/Pal.PalPlayerRecordDataUtility:GetRecordData_TribeIdFlag"));
        if (!GetCountFn || !GetFlagFn) return false;

        // Every Set must land. A renamed or resized parameter after a game patch would
        // otherwise leave the field zeroed and silently query tribe id 0.
        FParamBuffer C{GetCountFn};
        if (!C.SetRaw(STR("RecordData"), A.CountContainer, A.CountSize)) return false;
        if (!C.Set<uint16>(STR("Key"), A.TribeId)) return false;
        C.Call(A.Utility);
        OutCount = C.Get<int32>(STR("ReturnValue"));

        FParamBuffer F{GetFlagFn};
        if (!F.SetRaw(STR("RecordData"), A.FlagContainer, A.FlagSize)) return false;
        if (!F.Set<uint16>(STR("Key"), A.TribeId)) return false;
        F.Call(A.Utility);
        OutFlag = F.Get<uint8>(STR("ReturnValue")) != 0;
        return true;
    }
}

class PalvolveNative : public CppUserModBase
{
  public:
    PalvolveNative() : CppUserModBase()
    {
        ModName = STR("Palvolve");
        ModVersion = ModVersionString;
        ModDescription = STR("Native companion: unlocks catch-gated technologies on evolution.");
        ModAuthors = STR("DooDesch");

        Output::send<LogLevel::Normal>(STR("[PalvolveNative] loaded v{}\n"), ModVersionString);
    }

    ~PalvolveNative() override = default;

    // Diagnostic read, opt-in through a marker file in the mod folder so a normal install
    // never pays for it: writing a character id into <Mod>/CHECK_SPECIES logs that species'
    // capture record once, then the marker is consumed.
    auto on_update() -> void override
    {
        if (!g_world_context.load()) return;

        static uint64 s_ticks = 0;
        if (++s_ticks % 120 != 0) return;

        verify_native_getter();
        if (g_work_override_count.load(std::memory_order_relaxed) > 0)
        {
            // One line per session, the first time the base camp actually gets an evolved
            // pal's answer from us. That single line is what a support report needs; the
            // camp asks this several hundred times a second, so anything periodic would
            // drown the log.
            // Both counters, not just the overridden one. "No line" used to mean either the
            // base camp never asks or it asks and misses our override, and those need
            // different fixes.
            static uint64 s_lastHits = 0;
            const uint64 Hits = g_hasrank_hits.load(std::memory_order_relaxed);
            const uint64 Ours = g_hasrank_overridden.load(std::memory_order_relaxed);
            if (Hits != s_lastHits)
            {
                Output::send<LogLevel::Normal>(
                    STR("[PalvolveNative] work asked: +{} call(s), {} of {} answered from the new species\n"),
                    Hits - s_lastHits, Ours, Hits);
                s_lastHits = Hits;
            }
        }

        auto Marker = std::filesystem::path(UE4SSProgram::get_program().get_working_directory())
                    / "Mods" / "Palvolve" / "CHECK_SPECIES";
        std::error_code Ec;
        if (!std::filesystem::exists(Marker, Ec)) return;

        std::wifstream In(Marker);
        std::wstring Species;
        std::getline(In, Species);
        In.close();

        while (!Species.empty() && (Species.back() == L'\r' || Species.back() == L'\n' || Species.back() == L' '))
        {
            Species.pop_back();
        }
        if (Species.empty()) { std::filesystem::remove(Marker, Ec); return; }

        // The player record spawns later than the game mode, so keep retrying and only
        // consume the marker once a read actually succeeded.
        FRecordAccess Access{};
        std::wstring Error;
        if (!prepare(Species, std::wstring{}, std::wstring{}, Access, Error)) return;

        int32 Count = 0;
        bool Flag = false;
        if (!read_record(Access, Count, Flag)) return;

        std::filesystem::remove(Marker, Ec);
        Output::send<LogLevel::Normal>(STR("[PalvolveNative] CHECK {} captureCount={} paldeckFlag={}\n"),
                                       Species, Count, Flag);
    }

    auto on_unreal_init() -> void override
    {
        // The game mode only exists on the authority, so this doubles as the authority guard.
        Hook::RegisterInitGameStatePostCallback(
            [](Hook::TCallbackIterationData<void>&, AGameModeBase* Context) {
                if (Context) g_world_context.store(Context);
                // Installed here rather than in on_unreal_init: the game's UFunctions are
                // resolvable once a world starts, and the guard inside makes repeats free.
                install_work_hooks();
            },
            {.bOnce = false, .bReadonly = true,
             .OwnerModName = STR("Palvolve"), .HookName = STR("PalvolveNativeWorldContext")});

        // Dropping the context when a map starts loading keeps a torn-down game mode from
        // being handed to the setters as a world context. The next InitGameState refills it.
        Hook::RegisterLoadMapPreCallback(
            [](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                g_world_context.store(nullptr);
                // Instance ids belong to one world. An override that survived a map change is
                // the one way this could ever touch a stranger's pal.
                clear_work_overrides();
            },
            {.bOnce = false, .bReadonly = true,
             .OwnerModName = STR("Palvolve"), .HookName = STR("PalvolveNativeWorldReset")});
    }

    // Fires for the Lua mod that shares this mod's name, i.e. Palvolve itself.
    auto on_lua_start(LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua&, LuaMadeSimple::Lua&, LuaMadeSimple::Lua*) -> void override
    {
        lua.register_function("PalvolveNative_Version", [](const LuaMadeSimple::Lua& L) -> int {
            L.set_string(to_string(std::wstring{ModVersionString}));
            return 1;
        });

        lua.register_function("PalvolveNative_GetCaptureRecord", [](const LuaMadeSimple::Lua& L) -> int {
            return handle_call(L, false);
        });

        lua.register_function("PalvolveNative_UnlockCaptureRecord", [](const LuaMadeSimple::Lua& L) -> int {
            return handle_call(L, true);
        });

        // Work suitability after an evolution. The Lua side passes the individual parameter
        // OBJECT; both the instance id and the species are read from it natively, so the two
        // sides cannot disagree about which Pal is meant.
        lua.register_function("PalvolveNative_SetWorkSuitability", [](const LuaMadeSimple::Lua& L) -> int {
            UObject* Param = nullptr;
            if (L.is_userdata())
            {
                const auto& LuaObject = L.get_userdata<LuaType::UObject>();
                Param = LuaObject.get_remote_cpp_object();
            }
            if (!Param)
            {
                L.set_bool(false);
                L.set_string("individual parameter (object) required");
                return 2;
            }
            const auto [Ok, Message] = set_work_override(Param);
            L.set_bool(Ok);
            L.set_string(to_string(Message));
            return 2;
        });

        lua.register_function("PalvolveNative_ClearWorkSuitability", [](const LuaMadeSimple::Lua& L) -> int {
            UObject* Param = nullptr;
            if (L.is_userdata())
            {
                const auto& LuaObject = L.get_userdata<LuaType::UObject>();
                Param = LuaObject.get_remote_cpp_object();
            }
            L.set_bool(Param ? clear_work_override(Param) : false);
            return 1;
        });

        // Dev probe: retest the reflected add-rank setter on a known object.
        lua.register_function("PalvolveNative_ScanWorkCache", [](const LuaMadeSimple::Lua& L) -> int {
            UObject* Param = nullptr;
            if (L.is_userdata())
            {
                const auto& LuaObject = L.get_userdata<LuaType::UObject>();
                Param = LuaObject.get_remote_cpp_object();
            }
            if (!Param || !L.is_string())
            {
                L.set_string("individual parameter (object) and species id (string) required");
                return 1;
            }
            const auto Species = to_wstring(std::string{L.get_string()});
            L.set_string(to_string(scan_work_cache(Param, Species)));
            return 1;
        });

        Output::send<LogLevel::Normal>(STR("[PalvolveNative] lua bindings registered\n"));
    }

  private:
    // Shared entry for both bindings. Never throws into Lua and never crashes the game:
    // every failure comes back as (false/0, message) so the Lua side can degrade quietly.
    static auto handle_call(const LuaMadeSimple::Lua& L, bool bWrite) -> int
    {
        std::wstring CharacterId;
        std::wstring PlayerUid;
        std::wstring PlayerStateName;

        if (!L.is_string())
        {
            if (bWrite) { L.set_bool(false); } else { L.set_integer(-1); L.set_bool(false); }
            L.set_string("characterId (string) required");
            return bWrite ? 2 : 3;
        }
        CharacterId = to_wstring(std::string{L.get_string()});
        if (L.is_string()) PlayerUid = to_wstring(std::string{L.get_string()});
        if (L.is_string()) PlayerStateName = to_wstring(std::string{L.get_string()});

        FRecordAccess Access{};
        std::wstring Error;
        if (!prepare(CharacterId, PlayerUid, PlayerStateName, Access, Error))
        {
            Output::send<LogLevel::Warning>(STR("[PalvolveNative] {} failed: {}\n"),
                                            bWrite ? STR("unlock") : STR("read"), Error);
            if (bWrite) { L.set_bool(false); } else { L.set_integer(-1); L.set_bool(false); }
            L.set_string(to_string(Error));
            return bWrite ? 2 : 3;
        }

        int32 Count = 0;
        bool Flag = false;
        if (!read_record(Access, Count, Flag))
        {
            if (bWrite) { L.set_bool(false); } else { L.set_integer(-1); L.set_bool(false); }
            L.set_string("record getters unavailable");
            return bWrite ? 2 : 3;
        }

        if (!bWrite)
        {
            L.set_integer(Count);
            L.set_bool(Flag);
            L.set_string("ok");
            return 3;
        }

        // Idempotent: an already registered species is left untouched so repeated evolutions
        // never inflate the counter.
        if (Count > 0 && Flag)
        {
            L.set_bool(true);
            L.set_string("already unlocked");
            return 2;
        }

        auto* SetCountFn = find_fn(STR("/Script/Pal.PalPlayerRecordDataUtility:SetRecordData_TribeIdCount_ForServer"));
        auto* SetFlagFn = find_fn(STR("/Script/Pal.PalPlayerRecordDataUtility:SetRecordData_TribeIdFlag_ForServer"));
        if (!SetCountFn || !SetFlagFn)
        {
            L.set_bool(false);
            L.set_string("record setters not found (game patch?)");
            return 2;
        }

        // The ref parameter travels outside the buffer, so a mismatched Key or Value would go
        // unnoticed here and write against tribe id 0. Bail instead of writing a wrong record.
        if (Count <= 0)
        {
            FParamBuffer S{SetCountFn};
            if (!S.Set<UObject*>(STR("WorldContextObject"), Access.World)
                || !S.Set<uint16>(STR("Key"), Access.TribeId)
                || !S.Set<int32>(STR("Value"), 1))
            {
                L.set_bool(false);
                L.set_string("capture count setter has an unexpected signature");
                return 2;
            }
            call_with_ref_param(Access.Utility, SetCountFn, S.Data.data(), S.Find(STR("RecordData")), Access.CountContainer);
        }
        if (!Flag)
        {
            FParamBuffer S{SetFlagFn};
            if (!S.Set<UObject*>(STR("WorldContextObject"), Access.World)
                || !S.Set<uint16>(STR("Key"), Access.TribeId))
            {
                L.set_bool(false);
                L.set_string("paldeck flag setter has an unexpected signature");
                return 2;
            }
            call_with_ref_param(Access.Utility, SetFlagFn, S.Data.data(), S.Find(STR("RecordData")), Access.FlagContainer);
        }

        int32 AfterCount = 0;
        bool AfterFlag = false;
        read_record(Access, AfterCount, AfterFlag);

        const bool Ok = AfterCount > 0 && AfterFlag;
        Output::send<LogLevel::Normal>(STR("[PalvolveNative] unlock {}: count {}->{} flag {}->{}\n"),
                                        CharacterId, Count, AfterCount, Flag, AfterFlag);

        L.set_bool(Ok);
        L.set_string(Ok ? "unlocked" : "write did not take effect");
        return 2;
    }
};

#define PALVOLVENATIVE_API __declspec(dllexport)
extern "C"
{
    PALVOLVENATIVE_API CppUserModBase* start_mod()
    {
        return new PalvolveNative();
    }

    PALVOLVENATIVE_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
