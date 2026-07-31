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

#include <atomic>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <string>
#include <vector>

#include <Mod/CppUserModBase.hpp>
#include <UE4SSProgram.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>

#include <Unreal/AGameModeBase.hpp>
#include <Unreal/Hooks.hpp>
#include <Unreal/FURL.hpp>
#include <Unreal/FWorldContext.hpp>
#include <Unreal/UEngine.hpp>
#include <Unreal/FString.hpp>
#include <Unreal/UObject.hpp>
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
    constexpr const wchar_t* ModVersionString = STR("1.4.3");

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
            },
            {.bOnce = false, .bReadonly = true,
             .OwnerModName = STR("Palvolve"), .HookName = STR("PalvolveNativeWorldContext")});

        // Dropping the context when a map starts loading keeps a torn-down game mode from
        // being handed to the setters as a world context. The next InitGameState refills it.
        Hook::RegisterLoadMapPreCallback(
            [](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                g_world_context.store(nullptr);
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
