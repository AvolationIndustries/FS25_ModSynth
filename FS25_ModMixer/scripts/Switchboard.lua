-- Switchboard.lua  (FS25_ModMixer, Stage 2)
-- ─────────────────────────────────────────────────────────────────────────────
-- THE SWITCHBOARD
-- Lets the player compose features ACROSS mods by driving each mod's OWN feature
-- flags at runtime, inside their own game session.
--
-- BRIGHT LINE (non-negotiable): we operate at RUNTIME, in the USER'S OWN session
-- only. We NEVER modify, repackage, or redistribute any mod's files. This is just
-- a better UI for options a mod already exposes — the user composing THEIR install,
-- not us altering anyone's product. (LOOT / Wrye Bash / mod managers all pick
-- between mods exactly like this.)
--
-- TRANSPARENCY: every override is logged and attributed to ModMixer, so a
-- "missing feature" always traces back to us — never to the mod's author.
--
-- Stage 2 progress:
--   step 2 (DONE): flag-DRIVER, proven end-to-end on FarmKit.
--   step 1 (THIS): persistence — desired state saved to / loaded from
--                  modSettings/FS25_ModMixer/switchboard.xml, survives restarts.
--   step 3 (next): in-game UI to edit the overrides.
-- ─────────────────────────────────────────────────────────────────────────────

ModMixerSwitchboard = ModMixerSwitchboard or {}
local SB = ModMixerSwitchboard

-- Double-load guard (the same zip-vs-source-folder trap ModMixer.lua guards).
if SB._loaded then return end
SB._loaded = true

local SB_TAG = "[ModMixer Switchboard]"

local function gamelog(msg)
    -- Switchboard actions are user-facing notices (which features WE changed),
    -- so they belong in the game log as the visible ModMixer attribution.
    print(SB_TAG .. " " .. tostring(msg))
end

local function present(modName)
    if g_modManager == nil then return false end
    local name = modName:gsub("%.zip$", "")   -- single assignment drops gsub's count
    return g_modManager:getModByName(name) ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CROSS-MOD GLOBAL ACCESS
-- FS25 runs each mod's scripts in its OWN environment, published into the shared
-- global table under the mod's name. A mod's custom globals (e.g. NXFarmKitSettings)
-- therefore live at  _G["FS25_FarmKit"].NXFarmKitSettings  — NOT bare in _G. Engine
-- globals (Utils, Mission00, Vehicle, g_*) ARE shared via each env's metatable; only
-- mod-defined globals are namespaced. (A bare _G / rawget reach from another mod
-- silently fails — this is exactly why our first FarmKit override no-op'd.)
-- Idiom confirmed by FarmKit's OWN PF-Bridge, which reaches PrecisionFarming via
-- _G["FS25_precisionFarming"].PrecisionFarming.
-- ─────────────────────────────────────────────────────────────────────────────
local function safeGlobal(name)
    local ok, v = pcall(function() return _G[name] end)
    if ok then return v end
    return nil
end

-- Reach a global another mod defined: the mod's namespace table first, then the
-- shared _G (a few mods publish there explicitly, e.g. via _G.X = X).
local function modGlobal(modName, globalName)
    local env = safeGlobal(modName)
    if type(env) == "table" then
        local v = env[globalName]
        if v ~= nil then return v end
    end
    return safeGlobal(globalName)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FEATURE REGISTRY
-- Each entry describes how to drive ONE mod's own feature flags. `apply` is the
-- only place that knows the mod's API; everything else stays declarative so new
-- mods are added as data, not code.
--
--   kind = "toggle"      → boolean on/off
--   kind = "value"       → numeric/other (driven verbatim; UI handles ranges later)
-- ─────────────────────────────────────────────────────────────────────────────

SB.registry = {

    ["FS25_FarmKit"] = {
        label  = "FarmKit",
        author = "NX Modding",
        -- FarmKit's own settings UI is buggy; driving its flags IS the win, and
        -- it's pro-author (we keep users from uninstalling the whole mod).
        features = {
            { id = "wheelPhysicsEnabled",    label = "Realistic Wheel Physics",   kind = "toggle" },
            { id = "densityEnabled",         label = "Ground Density / Mud",      kind = "toggle" },
            { id = "dustEnabled",            label = "Dust Particles",            kind = "toggle" },
            { id = "dustMultiplier",         label = "Dust Amount",               kind = "value",
              min = 0.5, max = 5.0, step = 0.5, default = 2.0 },
            { id = "plowingEnabled",         label = "Realistic Plowing",         kind = "toggle" },
            { id = "realisticEngineEnabled", label = "Realistic Engine RPM",      kind = "toggle" },
            { id = "hudEnabled",             label = "FarmKit HUD",               kind = "toggle" },
        },

        -- Drive FarmKit through its OWN public settings API so its menu, savefile
        -- and multiplayer sync all stay coherent with what we set. Layered
        -- fallbacks cover version drift (best-effort across installs).
        apply = function(featureId, value)
            local S = modGlobal("FS25_FarmKit", "NXFarmKitSettings")
            if S ~= nil and type(S.setValue) == "function" then
                -- setValue sets the value AND calls applyToSubsystems() for us.
                S.setValue(featureId, value)
                return true, "NXFarmKitSettings.setValue"
            elseif S ~= nil and type(S.values) == "table" then
                S.values[featureId] = value
                if type(S.applyToSubsystems) == "function" then
                    S.applyToSubsystems()
                end
                return true, "NXFarmKitSettings.values + applyToSubsystems"
            end
            return false, "NXFarmKitSettings API not found"
        end,
        -- Live readout: what value FarmKit currently holds (so an un-overridden
        -- row can show "SetByMod (ON)" etc.).
        read = function(featureId)
            local S = modGlobal("FS25_FarmKit", "NXFarmKitSettings")
            if S ~= nil and type(S.values) == "table" then
                return S.values[featureId]
            end
            return nil
        end,
    },

    ["FS25_DynamicDrivePro"] = {
        label  = "DynamicDrivePro",
        author = "Papa_Matze",
        features = {
            { id = "gripIntensity", label = "Wet Grip Intensity", kind = "value",
              min = 0.2, max = 2.5, step = 0.2, default = 1.0 },
        },
        -- DDP reads WetWheelTracks.settings:getGripIntensity() per-tick (in
        -- getEffectStrength), so driving it is LIVE. NOTE: with STOCK DDP the wet
        -- effect is muted at road speed (SPEED_OFF=18) — bigger range once DDP's
        -- road-speed wet grip is enabled.
        apply = function(featureId, value)
            local W = modGlobal("FS25_DynamicDrivePro", "WetWheelTracks")
            if W ~= nil then
                W.settings = W.settings or {}
                W.settings.getGripIntensity = function() return value end  -- self arg ignored
                return true, "WetWheelTracks grip intensity"
            end
            return false, "WetWheelTracks not found"
        end,
        read = function(featureId)
            local W = modGlobal("FS25_DynamicDrivePro", "WetWheelTracks")
            if W ~= nil and W.settings ~= nil and type(W.settings.getGripIntensity) == "function" then
                return W.settings.getGripIntensity()
            end
            return nil
        end,
    },

    ["FS25_SeasonalTires"] = {
        label  = "SeasonalTires",
        author = "Unknown",
        features = {
            -- frictionModifier is the per-type base grip multiplier, read every tick in
            -- TireManager.getEffectiveFriction(). Stock value = 1.0 for all types.
            -- NOTE: SeasonalTires' injPhysWheelUpdateTireFriction caps frictionScale at
            -- the vehicle's own baseScale, so values > 1.0 here are neutralised — useful
            -- range is [0.5, 1.0] (reduce below default) unless the cap is patched.
            { id = "mud_frictionModifier",       label = "Mud Tire Friction",        kind = "value",
              min = 0.5, max = 1.5, step = 0.1, default = 1.0 },
            { id = "allSeason_frictionModifier", label = "All-Season Tire Friction", kind = "value",
              min = 0.5, max = 1.5, step = 0.1, default = 1.0 },
            { id = "snow_frictionModifier",      label = "Snow Tire Friction",       kind = "value",
              min = 0.5, max = 1.5, step = 0.1, default = 1.0 },
            { id = "road_frictionModifier",      label = "Road Tire Friction",       kind = "value",
              min = 0.5, max = 1.5, step = 0.1, default = 1.0 },
            -- rainBonus is added to baseFriction in rain (negative = penalty, 0 = neutral).
            -- mud default = 0 (no rain effect); allSeason/snow/road default = -0.1 (rain penalty).
            { id = "mud_rainBonus",       label = "Mud Tire Rain Bonus",      kind = "value",
              min = -0.3, max = 0.3, step = 0.05, default = 0.0 },
            { id = "allSeason_rainBonus", label = "All-Season Rain Bonus",    kind = "value",
              min = -0.3, max = 0.1, step = 0.05, default = -0.1 },
        },
        apply = function(featureId, value)
            local TM = modGlobal("FS25_SeasonalTires", "TireManager")
            if TM == nil or TM.tireTypes == nil then
                return false, "TireManager not found"
            end
            -- featureId = "<tireType>_<field>"; split on the last underscore so
            -- "allSeason_rainBonus" → tireType="allSeason", field="rainBonus".
            local sep = string.find(featureId, "_[^_]+$")
            if sep == nil then return false, "unknown feature: " .. featureId end
            local tireType = string.sub(featureId, 1, sep - 1)
            local field    = string.sub(featureId, sep + 1)
            local td = TM.tireTypes[tireType]
            if td == nil then return false, "unknown tire type: " .. tireType end
            td[field] = value
            return true, string.format("TireManager.tireTypes.%s.%s", tireType, field)
        end,
        read = function(featureId)
            local TM = modGlobal("FS25_SeasonalTires", "TireManager")
            if TM == nil or TM.tireTypes == nil then return nil end
            local sep = string.find(featureId, "_[^_]+$")
            if sep == nil then return nil end
            local tireType = string.sub(featureId, 1, sep - 1)
            local field    = string.sub(featureId, sep + 1)
            local td = TM.tireTypes[tireType]
            if td == nil then return nil end
            return td[field]
        end,
    },

    ["FS25_EnhancedVehicle"] = {
        label  = "EnhancedVehicle",
        author = "Majo76",
        -- These plain fields are checked per-tick inside EV's specialization update
        -- functions, so toggling them takes effect immediately.
        features = {
            { id = "functionSnapIsEnabled",         label = "Steering Snap (angle assist)",  kind = "toggle" },
            { id = "functionDiffIsEnabled",         label = "Differential Controls",         kind = "toggle" },
            { id = "functionParkingBrakeIsEnabled", label = "Parking Brake",                 kind = "toggle" },
            { id = "functionHydraulicIsEnabled",    label = "Hydraulic Controls",            kind = "toggle" },
            { id = "functionOdoMeterIsEnabled",     label = "Odometer",                      kind = "toggle" },
        },
        apply = function(featureId, value)
            local EV = modGlobal("FS25_EnhancedVehicle", "FS25_EnhancedVehicle")
            if EV ~= nil then
                EV[featureId] = value
                return true, "FS25_EnhancedVehicle." .. featureId
            end
            return false, "FS25_EnhancedVehicle global not found"
        end,
        read = function(featureId)
            local EV = modGlobal("FS25_EnhancedVehicle", "FS25_EnhancedVehicle")
            if EV ~= nil then return EV[featureId] end
            return nil
        end,
    },

    -- REAwheels (Papa Matze): global REAwheels table holds per-tick physics knobs.
    -- Verified live-read: RollingResistanceScale at the rolling-resistance calc
    -- (baseRR = sinkStrength * scale * 0.02); HelperPhysicsFactor scales sink
    -- friction each tick. (GroundWetnessFactor is RECOMPUTED every tick from
    -- GetGroundWetness(), so it's not a user knob — excluded.) NOTE: the mod name
    -- carries a version suffix; if REAwheels updates, update this key. modGlobal
    -- falls back to bare _G so a republish without the namespace still resolves.
    ["FS25_REAwheels_by_Papa_Matze_v1_0_1"] = {
        label  = "REAwheels",
        author = "Papa_Matze",
        features = {
            { id = "RollingResistanceScale", label = "Rolling Resistance", kind = "value",
              min = 0.5, max = 4.0, step = 0.5, default = 2.0 },
            { id = "HelperPhysicsFactor",    label = "Helper Physics",     kind = "value",
              min = 0.5, max = 2.0, step = 0.1, default = 1.0 },
        },
        apply = function(featureId, value)
            local R = modGlobal("FS25_REAwheels_by_Papa_Matze_v1_0_1", "REAwheels")
            if R ~= nil then R[featureId] = value; return true, "REAwheels." .. featureId end
            return false, "REAwheels global not found"
        end,
        read = function(featureId)
            local R = modGlobal("FS25_REAwheels_by_Papa_Matze_v1_0_1", "REAwheels")
            if R ~= nil then return R[featureId] end
            return nil
        end,
    },

    -- SplitBrakes: global SplitBrakes table; all multipliers read inside
    -- SplitBrakes:onUpdate(dt) (per-tick) and its friction handler, so driving them
    -- is LIVE. Front high/low = grip multipliers selected by brake intensity.
    ["FS25_SplitBrakes"] = {
        label  = "SplitBrakes",
        author = "Unknown",
        features = {
            { id = "BrakeForceMultiplikator",        label = "Brake Force",            kind = "value",
              min = 10, max = 80, step = 5, default = 40 },
            { id = "frictionFrontMultiplikatorHigh", label = "Front Brake Grip (high)", kind = "value",
              min = 0.5, max = 2.0, step = 0.1, default = 1.2 },
            { id = "frictionFrontMultiplikatorLow",  label = "Front Brake Grip (low)",  kind = "value",
              min = 0.1, max = 1.0, step = 0.1, default = 0.3 },
            { id = "frictionRearMultiplikator",      label = "Rear Brake Grip",         kind = "value",
              min = 5, max = 30, step = 1, default = 15 },
        },
        apply = function(featureId, value)
            local S = modGlobal("FS25_SplitBrakes", "SplitBrakes")
            if S ~= nil then S[featureId] = value; return true, "SplitBrakes." .. featureId end
            return false, "SplitBrakes global not found"
        end,
        read = function(featureId)
            local S = modGlobal("FS25_SplitBrakes", "SplitBrakes")
            if S ~= nil then return S[featureId] end
            return nil
        end,
    },

    -- TirePneumatics: global TirePneumatics.wearMultiplier read live in the tire-wear
    -- calc (USED_MAX_M * wearMultiplier). 1 = stock; 0 = tires never wear; >1 faster.
    -- (punctureFreq is a STRING enum "normal"/etc. — not a numeric slider knob.)
    -- ALSO appends WheelPhysics.updateTireFriction + .updateContact, so it shows as a
    -- consecutive (reorderable) hook contest with SeasonalTires under Vehicle Physics.
    ["FS25_TirePneumaticsMod"] = {
        label  = "TirePneumatics",
        author = "Unknown",
        features = {
            { id = "wearMultiplier", label = "Tire Wear Rate", kind = "value",
              min = 0.0, max = 3.0, step = 0.25, default = 1.0 },
        },
        apply = function(featureId, value)
            local T = modGlobal("FS25_TirePneumaticsMod", "TirePneumatics")
            if T ~= nil then T[featureId] = value; return true, "TirePneumatics." .. featureId end
            return false, "TirePneumatics global not found"
        end,
        read = function(featureId)
            local T = modGlobal("FS25_TirePneumaticsMod", "TirePneumatics")
            if T ~= nil then return T[featureId] end
            return nil
        end,
    },

    -- REA Implements (Papa Matze): global REAimplements holds per-tick realism
    -- factors, all read inside updateVehicleImplements() (the drawbar-force calc).
    ["FS25_REA_by_Papa_Matze_v1_0_4"] = {
        label  = "REA Implements",
        author = "Papa_Matze",
        features = {
            { id = "ImplementResistance", label = "Implement Drag",        kind = "value",
              min = 1.0, max = 5.0, step = 0.2, default = 2.6 },
            { id = "PullForceScale",      label = "Pull Force",            kind = "value",
              min = 1.0, max = 5.0, step = 0.2, default = 2.8 },
            { id = "SoilSinkFactor",      label = "Soil Softness",         kind = "value",
              min = 0.5, max = 5.0, step = 0.5, default = 2.5 },
            { id = "HelperWeightFactor",  label = "AI Helper Weight",      kind = "value",
              min = 1.0, max = 4.0, step = 0.2, default = 2.4 },
            { id = "HelperGripBoost",     label = "AI Helper Grip",        kind = "value",
              min = 1.0, max = 3.0, step = 0.2, default = 1.8 },
        },
        apply = function(featureId, value)
            local R = modGlobal("FS25_REA_by_Papa_Matze_v1_0_4", "REAimplements")
            if R ~= nil then R[featureId] = value; return true, "REAimplements." .. featureId end
            return false, "REAimplements global not found"
        end,
        read = function(featureId)
            local R = modGlobal("FS25_REA_by_Papa_Matze_v1_0_4", "REAimplements")
            if R ~= nil then return R[featureId] end
            return nil
        end,
    },

    -- MoreRealistic — a DATA-DRIVEN conversion mod: ~95% of what it does is rewriting each
    -- vehicle's weight / power / gear ratios / tyre friction from 200+ per-vehicle XMLs +
    -- a friction table, baked AT VEHICLE LOAD (not script knobs we can drive). The ONLY
    -- global script-level tunables are these four RealisticMain FX constants. Sprayer &
    -- combine factors are read per-operation (LIVE); engine braking is normally baked at
    -- motor init, so we ALSO push it live onto the current vehicle's motor.
    -- (RealisticMain lives in MoreRealistic's namespace: _G["MoreRealistic"].RealisticMain.)
    ["MoreRealistic"] = {
        label  = "MoreRealistic",
        author = "MoreRealistic Team",
        features = {
            { id = "SPRAYER_EMPTYSPEED_FX",        label = "Sprayer Discharge Speed",     kind = "value",
              min = 0.5, max = 3.0, step = 0.25, default = 1.5 },
            { id = "COMBINE_CAPACITY_FX",          label = "Combine Capacity",            kind = "value",
              min = 0.5, max = 3.0, step = 0.25, default = 1.25 },
            { id = "ENGINE_BRAKING_FX_DEFAULT",    label = "Engine Braking (standard)",   kind = "value",
              min = 0.0, max = 2.0, step = 0.1, default = 0.85 },
            { id = "ENGINE_BRAKING_FX_HYDROSTATIC",label = "Engine Braking (hydrostatic)",kind = "value",
              min = 0.0, max = 2.0, step = 0.1, default = 1.1 },
        },
        apply = function(featureId, value)
            local RM = modGlobal("MoreRealistic", "RealisticMain")
            if RM == nil then return false, "RealisticMain not found" end
            RM[featureId] = value
            -- Engine braking is baked into the motor at init — push it live onto the
            -- CURRENT vehicle's motor so the change is felt now (correct FX by transmission).
            if featureId == "ENGINE_BRAKING_FX_DEFAULT" or featureId == "ENGINE_BRAKING_FX_HYDROSTATIC" then
                local v = g_currentMission ~= nil and g_currentMission.controlledVehicle or nil
                local motor = v ~= nil and v.spec_motorized ~= nil and v.spec_motorized.motor or nil
                if motor ~= nil then
                    local hydro = v.mrTransmissionIsHydrostatic == true
                    motor.mrEngineBrakingPowerFx = hydro and RM.ENGINE_BRAKING_FX_HYDROSTATIC
                                                   or  RM.ENGINE_BRAKING_FX_DEFAULT
                end
            end
            return true, "RealisticMain." .. featureId
        end,
        read = function(featureId)
            local RM = modGlobal("MoreRealistic", "RealisticMain")
            if RM ~= nil then return RM[featureId] end
            return nil
        end,
    },

}

local function featureKind(modName, featureId)
    local entry = SB.registry[modName]
    if entry ~= nil then
        for _, f in ipairs(entry.features) do
            if f.id == featureId then return f.kind end
        end
    end
    return "toggle"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DESIRED STATE (overrides)
-- SB.overrides only lists features the user wants CHANGED from the mod's own
-- default. Anything not listed is left exactly as the mod set it.
--
-- DEFAULTS (used only when no switchboard.xml exists yet): for now this seeds the
-- FarmKit wheel-physics fix — the exact bug that started ModMixer (keep FarmKit's
-- particles + ground destruction, drop its wheel physics, redundant with DDP).
-- TODO step 3: once the in-game UI exists, the default becomes EMPTY (opt-in) —
-- we should not change anyone's mods until they ask via the UI.
-- ─────────────────────────────────────────────────────────────────────────────

SB.defaultOverrides = {
    ["FS25_FarmKit"] = {
        wheelPhysicsEnabled = false,
    },
}

local function deepCopyOverrides(src)
    local out = {}
    for modName, feats in pairs(src) do
        local copy = {}
        for k, v in pairs(feats) do copy[k] = v end
        out[modName] = copy
    end
    return out
end

-- Runtime state. SB.load() may replace this wholesale from the save file.
SB.overrides = deepCopyOverrides(SB.defaultOverrides)

-- Session-only memory of each feature's value BEFORE we first overrode it, so a
-- clear can hand control back to the mod (re-apply its own value) live — instead
-- of leaving it stuck at whatever we last forced. [mod][feat] = { v = <value> }.
-- Boxed so a legit false/nil original is stored, not lost. Not persisted (it's the
-- mod's live default, recaptured each session on first touch).
SB.originalValues = {}

-- Hook vetoes (S2): a set of "modName|target" the user has turned OFF at the hook
-- level. Enforced by ModMixerHooks at the NEXT load (restart-to-apply, not live).
SB.vetoes = {}

-- Hook reorders (S3, lever c part 2): [target] = { mod1, mod2, ... } desired FIRING
-- order. Enforced by ModMixerHooks at the NEXT load (restart-to-apply): it buffers
-- the contesting mods' hooks and replays them onto the base in this order.
SB.reorders = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- TIERED RESOLUTION (Seating / Category / Advanced) — friendly layers over the veto
-- path. NONE of these is a new enforcement mechanism: they all DRIVE setHookWinner in
-- bulk, so they inherit every safety property of the proven veto path (load-critical
-- refusal, recovery hatches). Reorder stays Advanced-only.
--
-- HONEST MODEL (learned from in-game feedback): in a hook chain EVERYONE runs; whoever
-- wraps OUTERMOST (last-installed) gets the final say. So a "fight" only exists when an
-- overwrite WRAPS other mods and may discard them — a STOMP. Shared stacks (appends, or
-- an overwrite sitting innermost) aren't fights: all run, order just picks who seasons
-- last. We therefore only ARBITRATE stomps, and "make winner" = mute the losers (we say
-- so plainly). Shared stacks are shown for information, never muted.
--
--   SB.mode           "seating" | "category" | "advanced"  — which tier the UI shows
--   SB.priorityGlobal ranked mod list (Tier 1 seating) — the default order everywhere
--   SB.priorityByCat  [category] = ranked mod list (Tier 2) — overrides global in a realm
--   SB.basicWinners   [target] = winnerMod — explicit per-fight pick (highest precedence)
-- Precedence for a stomp on target T in category C:
--   basicWinners[T]  >  priorityByCat[C]  >  priorityGlobal  >  natural (undecided)
-- ─────────────────────────────────────────────────────────────────────────────
SB.mode           = SB.mode or "seating"   -- soft-launch default = simplest tier
-- migrate the older two-mode field values
if SB.mode == "basic" then SB.mode = "seating" end
SB.priorityGlobal = SB.priorityGlobal or SB.priority or {}   -- SB.priority = pre-rename key
SB.priorityByCat  = SB.priorityByCat or {}
SB.basicWinners   = SB.basicWinners or {}

-- ─────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE  —  modSettings/FS25_ModMixer/switchboard.xml
-- Wrapped in pcall, mirroring ModMixer.lua's io-hardening: a restricted XML/file
-- API in a published sandbox can never error the mod's load.
-- ─────────────────────────────────────────────────────────────────────────────

local SETTINGS_DIR    = "modSettings/FS25_ModMixer/"
local SETTINGS_FILE   = SETTINGS_DIR .. "switchboard.xml"
local SCHEMA_VERSION  = 1

local function settingsPath()
    return getUserProfileAppPath() .. SETTINGS_FILE
end

local function doLoad()
    local path = settingsPath()
    if not fileExists(path) then
        return false, "no save file (using defaults)"
    end

    local xml = loadXMLFile("ModMixerSwitchboard", path)
    if xml == nil or xml == 0 then
        return false, "could not open switchboard.xml"
    end

    local loaded = {}
    local mi = 0
    while true do
        local mk = string.format("switchboard.mod(%d)", mi)
        local modName = getXMLString(xml, mk .. "#name")
        if modName == nil then break end

        local feats = {}
        local fi = 0
        while true do
            local fk = string.format("%s.feature(%d)", mk, fi)
            local fid = getXMLString(xml, fk .. "#id")
            if fid == nil then break end

            local ftype = getXMLString(xml, fk .. "#type") or "bool"
            local v
            if ftype == "value" then
                v = getXMLFloat(xml, fk .. "#value")
            elseif ftype == "string" then
                v = getXMLString(xml, fk .. "#value")
            else
                v = getXMLBool(xml, fk .. "#value")
            end
            if v ~= nil then feats[fid] = v end
            fi = fi + 1
        end

        loaded[modName] = feats
        mi = mi + 1
    end

    local loadedVetoes = {}
    local vi = 0
    while true do
        local vk = string.format("switchboard.vetoes.veto(%d)", vi)
        local vmod = getXMLString(xml, vk .. "#mod")
        if vmod == nil then break end
        local vtarget = getXMLString(xml, vk .. "#target")
        if vtarget ~= nil then loadedVetoes[vmod .. "|" .. vtarget] = true end
        vi = vi + 1
    end

    local loadedReorders = {}
    local ri = 0
    while true do
        local rk = string.format("switchboard.reorders.reorder(%d)", ri)
        local rtarget = getXMLString(xml, rk .. "#target")
        if rtarget == nil then break end
        local mods, mj = {}, 0
        while true do
            local m = getXMLString(xml, string.format("%s.mod(%d)#name", rk, mj))
            if m == nil then break end
            mods[#mods + 1] = m
            mj = mj + 1
        end
        if #mods > 0 then loadedReorders[rtarget] = mods end
        ri = ri + 1
    end

    local loadedMode = getXMLString(xml, "switchboard#mode")

    local loadedPriority = {}
    local pj = 0
    while true do
        local m = getXMLString(xml, string.format("switchboard.priority.mod(%d)#name", pj))
        if m == nil then break end
        loadedPriority[#loadedPriority + 1] = m
        pj = pj + 1
    end

    local loadedCatPriority = {}
    local ci = 0
    while true do
        local ck = string.format("switchboard.catPriority.cat(%d)", ci)
        local cat = getXMLString(xml, ck .. "#name")
        if cat == nil then break end
        local list, mj = {}, 0
        while true do
            local m = getXMLString(xml, string.format("%s.mod(%d)#name", ck, mj))
            if m == nil then break end
            list[#list + 1] = m
            mj = mj + 1
        end
        if #list > 0 then loadedCatPriority[cat] = list end
        ci = ci + 1
    end

    local loadedWinners = {}
    local wj = 0
    while true do
        local wk = string.format("switchboard.basicWinners.win(%d)", wj)
        local wt = getXMLString(xml, wk .. "#target")
        if wt == nil then break end
        local wm = getXMLString(xml, wk .. "#mod")
        if wm ~= nil then loadedWinners[wt] = wm end
        wj = wj + 1
    end

    local loadedDismissed = {}
    local dj = 0
    while true do
        local dk = getXMLString(xml, string.format("switchboard.reviewDismissed.item(%d)#key", dj))
        if dk == nil then break end
        loadedDismissed[dk] = true
        dj = dj + 1
    end

    delete(xml)
    SB.overrides = loaded
    SB.vetoes = loadedVetoes
    SB.reorders = loadedReorders
    SB.reviewDismissed = loadedDismissed
    -- migrate the older two-mode value ("basic" → "seating")
    if loadedMode == "basic" then loadedMode = "seating" end
    if loadedMode == "seating" or loadedMode == "category" or loadedMode == "advanced"
       or loadedMode == "review" then
        SB.mode = loadedMode
    end
    SB.priorityGlobal = loadedPriority
    SB.priorityByCat  = loadedCatPriority
    SB.basicWinners   = loadedWinners
    return true, string.format("loaded %d override set(s), %d veto(es), %d reorder(s), %d ranked mod(s)",
        mi, vi, ri, pj)
end

local function doSave()
    createFolder(getUserProfileAppPath() .. SETTINGS_DIR)
    local path = settingsPath()

    local xml = createXMLFile("ModMixerSwitchboard", path, "switchboard")
    if xml == nil or xml == 0 then
        return false, "could not create switchboard.xml"
    end
    setXMLInt(xml, "switchboard#version", SCHEMA_VERSION)
    setXMLString(xml, "switchboard#mode", SB.mode or "basic")

    local mi = 0
    for modName, feats in pairs(SB.overrides) do
        -- skip mods with no actual overrides so the file stays clean
        local hasAny = false
        for _ in pairs(feats) do hasAny = true break end
        if hasAny then
            local mk = string.format("switchboard.mod(%d)", mi)
            setXMLString(xml, mk .. "#name", modName)
            local fi = 0
            for fid, val in pairs(feats) do
                local fk = string.format("%s.feature(%d)", mk, fi)
                setXMLString(xml, fk .. "#id", fid)
                if type(val) == "boolean" then
                    setXMLString(xml, fk .. "#type", "bool")
                    setXMLBool(xml, fk .. "#value", val)
                elseif type(val) == "number" then
                    setXMLString(xml, fk .. "#type", "value")
                    setXMLFloat(xml, fk .. "#value", val)
                else
                    setXMLString(xml, fk .. "#type", "string")
                    setXMLString(xml, fk .. "#value", tostring(val))
                end
                fi = fi + 1
            end
            mi = mi + 1
        end
    end

    local vi = 0
    for key, on in pairs(SB.vetoes) do
        if on then
            local vmod, vtarget = string.match(key, "^(.-)|(.+)$")
            if vmod ~= nil and vtarget ~= nil then
                local vk = string.format("switchboard.vetoes.veto(%d)", vi)
                setXMLString(xml, vk .. "#mod", vmod)
                setXMLString(xml, vk .. "#target", vtarget)
                vi = vi + 1
            end
        end
    end

    local ri = 0
    for target, mods in pairs(SB.reorders) do
        if type(mods) == "table" and #mods > 0 then
            local rk = string.format("switchboard.reorders.reorder(%d)", ri)
            setXMLString(xml, rk .. "#target", target)
            for j, m in ipairs(mods) do
                setXMLString(xml, string.format("%s.mod(%d)#name", rk, j - 1), m)
            end
            ri = ri + 1
        end
    end

    -- Tiered resolution: global seating + per-category ranks + per-fight card overrides.
    for j, m in ipairs(SB.priorityGlobal) do
        setXMLString(xml, string.format("switchboard.priority.mod(%d)#name", j - 1), m)
    end
    local ci = 0
    for cat, list in pairs(SB.priorityByCat) do
        if type(list) == "table" and #list > 0 then
            local ck = string.format("switchboard.catPriority.cat(%d)", ci)
            setXMLString(xml, ck .. "#name", cat)
            for j, m in ipairs(list) do
                setXMLString(xml, string.format("%s.mod(%d)#name", ck, j - 1), m)
            end
            ci = ci + 1
        end
    end
    local wi = 0
    for target, mod in pairs(SB.basicWinners) do
        local wk = string.format("switchboard.basicWinners.win(%d)", wi)
        setXMLString(xml, wk .. "#target", target)
        setXMLString(xml, wk .. "#mod", mod)
        wi = wi + 1
    end

    local di = 0
    for key, on in pairs(SB.reviewDismissed or {}) do
        if on then
            setXMLString(xml, string.format("switchboard.reviewDismissed.item(%d)#key", di), key)
            di = di + 1
        end
    end

    saveXMLFile(xml)
    delete(xml)
    return true, string.format("saved %d override set(s), %d veto(es), %d reorder(s)", mi, vi, ri)
end

function SB.load()
    local ok, result, detail = pcall(doLoad)
    if not ok then
        gamelog("load failed (XML API unavailable?) — using defaults: " .. tostring(result))
        return false
    end
    return result   -- doLoad's first return (boolean); detail logged by caller if wanted
end

function SB.save()
    local ok, result = pcall(doSave)
    if not ok then
        gamelog("save failed (XML API unavailable?): " .. tostring(result))
        return false
    end
    return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC API (for the step-3 in-game UI)
--   getOverride : current desired value, or nil if not overridden
--   setOverride : set + persist + apply live
--   clearOverride : drop an override (revert to the mod's own default) + persist
-- ─────────────────────────────────────────────────────────────────────────────

function SB.getOverride(modName, featureId)
    local feats = SB.overrides[modName]
    if feats == nil then return nil end
    return feats[featureId]
end

function SB.setOverride(modName, featureId, value)
    -- Remember the mod's own value the FIRST time we touch this feature, so a
    -- later clear can hand it back (see clearOverride). Captured at user-action
    -- time (post-load, mod fully initialised), once per feature per session.
    SB.captureOriginal(modName, featureId)
    SB.overrides[modName] = SB.overrides[modName] or {}
    SB.overrides[modName][featureId] = value
    SB.save()
    SB.applyAll()   -- re-apply live (idempotent); takes effect immediately in-game
end

function SB.clearOverride(modName, featureId)
    local feats = SB.overrides[modName]
    if feats ~= nil then
        feats[featureId] = nil
        SB.save()
    end
    -- Hand control back to the mod LIVE: re-apply the value it had before we first
    -- overrode it. (Without this, "SetByMod" would lie — the feature would stay
    -- stuck at whatever we last forced until the next map load, and an enable-flag
    -- we turned OFF would leave the mod's feature frozen.)
    SB.restoreOriginal(modName, featureId)
end

-- Record a feature's pre-override value once (boxed so false/nil survive).
function SB.captureOriginal(modName, featureId)
    SB.originalValues[modName] = SB.originalValues[modName] or {}
    if SB.originalValues[modName][featureId] == nil then
        SB.originalValues[modName][featureId] = { v = SB.readLive(modName, featureId) }
    end
end

-- Re-apply (and forget) a feature's captured original value, live, via its driver.
function SB.restoreOriginal(modName, featureId)
    local mo  = SB.originalValues[modName]
    local box = mo and mo[featureId]
    if box == nil then return end
    mo[featureId] = nil
    if box.v == nil then return end   -- mod had no value to begin with: don't write nil
    local entry = SB.registry[modName]
    if entry ~= nil and type(entry.apply) == "function" then
        pcall(entry.apply, featureId, box.v)
    end
end

-- Live readout: read the mod's CURRENT value for a feature (not our override),
-- so an un-overridden ("SetByMod") row can show what the mod itself holds. Fully
-- pcall-guarded — reaching into another mod's global must never error the UI.
function SB.readLive(modName, featureId)
    local entry = SB.registry[modName]
    if entry == nil or type(entry.read) ~= "function" then return nil end
    local ok, v = pcall(entry.read, featureId)
    if ok then return v end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HOOK-VETO API (S2). A veto = "ModMixerHooks, don't install THIS mod's hook on
-- THIS function next load." Restart-to-apply (it's the load-time lever, not live).
-- ─────────────────────────────────────────────────────────────────────────────
function SB.isHookVetoed(modName, target)
    return SB.vetoes[modName .. "|" .. target] == true
end

function SB.setHookVeto(modName, target, vetoed)
    local key = modName .. "|" .. target
    if vetoed then SB.vetoes[key] = true else SB.vetoes[key] = nil end
    SB.save()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- WINNER PICK (S3, lever c). When 2+ mods hook the same function, "winner" =
-- suppress every OTHER mod's hook on that target (veto the losers), keep the
-- winner's. Built entirely on the proven veto path: ModMixerHooks already skips
-- vetoed hooks at load, so this is restart-to-apply and inherits all the veto
-- safety (load-critical targets refuse vetoes; recovery hatches apply).
--
-- `allMods` is the list of mods that hook `target` (the UI passes it from
-- Utils.__ms_hooksByMod). One batched save, not one per mod.
-- ─────────────────────────────────────────────────────────────────────────────
function SB.setHookWinner(target, winnerMod, allMods, deferSave)
    for _, m in ipairs(allMods) do
        local key = m .. "|" .. target
        if m == winnerMod then SB.vetoes[key] = nil else SB.vetoes[key] = true end
    end
    if not deferSave then SB.save() end   -- batch callers (basicApply) pass true, save once
end

-- Drop the whole contest for a target: un-veto every mod that hooks it.
function SB.clearHookContest(target, allMods)
    for _, m in ipairs(allMods) do
        SB.vetoes[m .. "|" .. target] = nil
    end
    SB.save()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- REORDER API (S3, lever c part 2). The desired FIRING order for a target's
-- contesting mods. Restart-to-apply: ModMixerHooks buffers the contenders next
-- load and replays them onto the base in this order. Like winner-pick, this is a
-- load-time lever (the chain is built once, at load).
-- ─────────────────────────────────────────────────────────────────────────────
function SB.getHookOrder(target)
    return SB.reorders[target]
end

-- Move `mod` one slot earlier (-1) or later (+1) in the firing order for `target`.
-- `currentOrder` is the mods in their CURRENT firing order (the UI passes it from
-- the live chain), used to seed the order the first time it's reordered.
function SB.moveHookInOrder(target, mod, dir, currentOrder)
    -- Reconcile any stored order against the LIVE chain before operating. The stored
    -- order is a name snapshot from when it was first saved; it goes stale when a mod
    -- updates (its attributed name changes) or when a deferred hook that was "(unknown)"
    -- at save time is now named by inference. A stale snapshot used to make the live row
    -- un-findable (idx == nil → silent return false → "won't move"). We instead keep the
    -- stored sequence for mods still live, drop mods that vanished, and append any newly
    -- appeared live mods (the updated/renamed one) in their current position.
    local live = currentOrder or {}
    local stored = SB.reorders[target]
    local order = {}
    if stored == nil then
        for _, m in ipairs(live) do order[#order + 1] = m end
    else
        local liveSet = {}
        for _, m in ipairs(live) do liveSet[m] = true end
        local seen = {}
        for _, m in ipairs(stored) do
            if liveSet[m] and not seen[m] then order[#order + 1] = m; seen[m] = true end
        end
        for _, m in ipairs(live) do
            if not seen[m] then order[#order + 1] = m; seen[m] = true end
        end
    end
    local idx
    for i, m in ipairs(order) do if m == mod then idx = i break end end
    if idx == nil then return false end
    local j = idx + dir
    if j < 1 or j > #order then return false end       -- already at an end
    order[idx], order[j] = order[j], order[idx]
    SB.reorders[target] = order
    SB.save()
    return true
end

-- Drop a target's custom order (back to natural load order next load).
function SB.clearHookOrder(target)
    SB.reorders[target] = nil
    SB.save()
end

-- Console recovery: `msVetoClear` wipes all hook vetoes (restart to apply). Use
-- this if a veto causes trouble and the game still loads enough to reach the
-- console (~). For a total load brick, delete switchboard.xml or drop a
-- DISABLE_VETOES.txt in modSettings/FS25_ModMixer/.
function SB.consoleClearVetoes()
    local n = 0
    for _ in pairs(SB.vetoes) do n = n + 1 end
    SB.vetoes = {}
    SB.save()
    return string.format("ModMixer: cleared %d hook veto(es). Restart to apply.", n)
end

-- Console recovery for reorders: `msReorderClear` wipes all chain reorders. Use if
-- a reordered chain misbehaves and the game still loads enough to reach the console.
function SB.consoleClearReorders()
    local n = 0
    for _ in pairs(SB.reorders) do n = n + 1 end
    SB.reorders = {}
    SB.save()
    return string.format("ModMixer: cleared %d chain reorder(s). Restart to apply.", n)
end

-- Nuclear reset: clear ALL overrides, vetoes and reorders in one shot. Used by
-- the in-game UI "Reset all" button. One save, re-applies (all mods get control
-- back live, hook changes take effect on next restart as usual).
function SB.resetAll()
    SB.overrides  = {}
    SB.vetoes     = {}
    SB.reorders   = {}
    SB.originalValues = {}   -- discard any captured pre-override values too
    SB.save()
    SB.applyAll()   -- re-apply with empty overrides = let every mod drive itself
end

if addConsoleCommand ~= nil and not SB._consoleRegistered then
    SB._consoleRegistered = true
    addConsoleCommand("msVetoClear", "Clear all ModMixer hook vetoes (restart to apply)",
        "consoleClearVetoes", SB)
    addConsoleCommand("msReorderClear", "Clear all ModMixer chain reorders (restart to apply)",
        "consoleClearReorders", SB)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TIERED RESOLUTION API  (Seating / Category / Advanced)
-- ─────────────────────────────────────────────────────────────────────────────

local MODE_CYCLE = { seating = "category", category = "advanced", advanced = "review", review = "seating" }
function SB.setMode(m)
    if m ~= "seating" and m ~= "category" and m ~= "advanced" and m ~= "review" then m = "seating" end
    SB.mode = m
    SB.save()
end
function SB.cycleMode()
    SB.setMode(MODE_CYCLE[SB.mode] or "seating")
    return SB.mode
end
SB.toggleMode = SB.cycleMode   -- back-compat alias for the old two-mode switch

-- Category of a hooked target — delegated to the frame's resolver (ModMixerCategoryOf,
-- published at frame load; both files share this mod's globals). Resolved at call time so
-- the frame need only have loaded by the time the UI asks.
local function targetCategory(target)
    local f = safeGlobal("ModMixerCategoryOf")
    if type(f) == "function" then
        local ok, c = pcall(f, target)
        if ok and c ~= nil then return c end
    end
    return "Other"
end

-- Build the conflict model from the LIVE interceptor data. THE HONEST MODEL: a hook chain
-- runs EVERYONE; only an overwrite that WRAPS another mod can discard it (a STOMP). So we
-- classify each target 2+ named mods contest:
--   "shared"  no overwrite wraps another mod (all appends, or the only overwrite is
--             innermost) → all run, order just picks who has the last word. NOT a fight.
--   "clean"   a stomp risk, all named, no hidden hook → keep one, mute the rest.
--   "partial" a stomp risk WITH a hidden/dynamic hook → mute the named losers; the hidden
--             one stays (we say so).
--   "locked"  load-critical target → can't arbitrate, info only.
-- `mods` is ordered by install seq: innermost(first) … outermost(last = natural last-word).
-- Plus semantic "remove-one" pairs from ModMixerIncompatible.
function SB.buildConflicts()
    local conflicts = {}
    local hooksByMod = (type(Utils) == "table") and Utils.__ms_hooksByMod or nil
    if type(hooksByMod) == "table" then
        local hidden = (type(Utils.__ms_hiddenHooks) == "table") and Utils.__ms_hiddenHooks or {}
        local noVeto = (type(Utils.__ms_noVeto)      == "table") and Utils.__ms_noVeto      or {}
        -- Prefer the interceptor's pattern-based load-critical test (catches constructors
        -- and init/load hooks by name, not just the explicit list) so the UI locks exactly
        -- what the veto path will refuse. Fall back to the raw table if unavailable.
        local isLoadCritical = (type(Utils.__ms_isLoadCritical) == "function")
            and Utils.__ms_isLoadCritical or function(t) return noVeto[t] == true end

        -- invert: target -> list of { mod, kind, seq }
        local byTarget = {}
        for mod, targets in pairs(hooksByMod) do
            if mod ~= "(unknown)" then
                for target, e in pairs(targets) do
                    byTarget[target] = byTarget[target] or {}
                    local lst = byTarget[target]
                    lst[#lst + 1] = { mod = mod, kind = (e and e.kind) or "append", seq = (e and e.seq) or 0 }
                end
            end
        end

        for target, lst in pairs(byTarget) do
            if #lst >= 2 then
                table.sort(lst, function(a, b) return (a.seq or 0) < (b.seq or 0) end)  -- inner→outer
                local mods, stomp = {}, false
                for i, h in ipairs(lst) do
                    mods[#mods + 1] = h.mod
                    if h.kind == "overwrite" and i >= 2 then stomp = true end   -- wraps inner mod(s)
                end
                local locked    = isLoadCritical(target) == true
                local hasHidden = hidden[target] == true
                if hasHidden then stomp = true end   -- an unidentified overwrite may wrap
                local res
                if     locked      then res = "locked"
                elseif not stomp   then res = "shared"
                elseif hasHidden   then res = "partial"
                else                    res = "clean" end
                conflicts[#conflicts + 1] = {
                    kind = "hook", target = target, category = targetCategory(target),
                    mods = mods, stomp = stomp, hasHidden = hasHidden, locked = locked,
                    resolvability = res,
                }
            end
        end
    end

    local incompat = safeGlobal("ModMixerIncompatible")
    if type(incompat) == "table" then
        for _, w in ipairs(incompat) do
            if type(w) == "table" and type(w.mods) == "table" and #w.mods >= 2 then
                conflicts[#conflicts + 1] = {
                    kind = "incompatible", category = "Incompatible", mods = w.mods,
                    reason = w.reason, resolvability = "remove-one",
                }
            end
        end
    end
    return conflicts
end

-- ── REVIEW HUB ───────────────────────────────────────────────────────────────
-- The "things worth a look" dashboard, assembled from three sources:
--   • redundancy  — duplicate-PURPOSE candidates from the offline scan (name + hook
--                   signals) carrying each mod's modDesc description so the player can
--                   judge at a glance. Advisory only.
--   • incompatible— remove-one pairs (two mods replacing the same system).
--   • hud         — mods that both draw the same HUD strip. The honest STOMP model calls
--                   these "shared" (both run), but the player still SEES them collide
--                   (e.g. the weather HUD vanishing), so we surface them here to decide.
-- Nothing is auto-changed. The player dismisses items they've judged; dismissals persist.
SB.reviewDismissed = SB.reviewDismissed or {}   -- [key] = true

function SB.dismissReview(key, on)
    if key == nil then return end
    if on == false then SB.reviewDismissed[key] = nil else SB.reviewDismissed[key] = true end
    SB.save()
end
function SB.clearReviewDismissals()
    SB.reviewDismissed = {}
    SB.save()
end

-- ORPHANED SETTINGS — modSettings/ entries whose mod is no longer installed (the method
-- that cracked the SeasonalCropStress HUD hunt, made a feature). RUNTIME-only: it's the
-- PLAYER's modSettings vs THEIR installed mods, so it can't be precomputed offline.
-- Normalise both sides (drop FS25_/FS22_ prefix + 0_/zzz_ load brackets + .xml) so e.g.
-- the `FS25_ModMixer` settings folder matches the installed `FS25_0_ModMixer`.
local function _normMod(s)
    s = tostring(s):gsub("%.xml$", "")
    s = s:gsub("^FS25_", ""):gsub("^FS22_", ""):gsub("^LS25_", ""):gsub("^LS22_", "")
    s = s:gsub("^0+_", ""):gsub("^z+_", "")
    return (s:lower())
end

local _orphanCollector = { entries = nil }
function _orphanCollector:onEntry(filename, _isDirectory)
    if filename == nil or filename == "." or filename == ".." then return end
    self.entries[#self.entries + 1] = filename
end

SB._orphanScan = nil   -- cached (scan once per session)
function SB.scanOrphanedSettings()
    if SB._orphanScan ~= nil then return SB._orphanScan end
    local result = {}
    SB._orphanScan = result
    if type(getUserProfileAppPath) ~= "function" or type(getFiles) ~= "function"
       or g_modManager == nil then return result end
    -- normalised set of installed mod names
    local installed = {}
    if type(g_modManager.mods) == "table" then
        for _, m in ipairs(g_modManager.mods) do
            if type(m) == "table" and m.modName ~= nil then installed[_normMod(m.modName)] = true end
        end
    end
    -- enumerate modSettings/ (getFiles is synchronous; fills _orphanCollector.entries)
    _orphanCollector.entries = {}
    pcall(function() getFiles(getUserProfileAppPath() .. "modSettings/", "onEntry", _orphanCollector) end)
    for _, entry in ipairs(_orphanCollector.entries) do
        -- only clearly mod-named entries (FS25_/FS22_/LS25_ prefix) to avoid false positives
        -- on generic/feature-named files. Skip our own settings explicitly.
        if (entry:match("^FS%d%d_") or entry:match("^LS%d%d_")) then
            local norm = _normMod(entry)
            if norm ~= "modmixer" and not installed[norm] then
                result[#result + 1] = entry
            end
        end
    end
    return result
end

function SB.buildReviewItems()
    local items = {}
    -- 1) Redundancy candidates (offline detector: name/hook signals + modDesc descriptions)
    local red = safeGlobal("ModMixerRedundancy")
    if type(red) == "table" then
        for _, p in ipairs(red) do
            if type(p) == "table" and p.a ~= nil and p.b ~= nil then
                local key = "red|" .. tostring(p.a) .. "|" .. tostring(p.b)
                items[#items + 1] = {
                    rkind = "redundancy", key = key, dismissed = SB.reviewDismissed[key] == true,
                    a = p.a, b = p.b, confidence = p.confidence or "low",
                    descA = p.descA or "", descB = p.descB or "",
                    nameTokens = p.nameTokens, sharedFns = p.sharedFns, descOverlap = p.descOverlap,
                }
            end
        end
    end
    -- 2) Incompatible remove-one pairs (from the live conflict model — these come from the
    --    curated ModMixerIncompatible list, not from runtime hook attribution, so reliable).
    local conflicts = (type(SB.buildConflicts) == "function") and SB.buildConflicts() or {}
    for _, c in ipairs(conflicts) do
        if c.kind == "incompatible" and type(c.mods) == "table" then
            local key = "inc|" .. table.concat(c.mods, "|")
            items[#items + 1] = {
                rkind = "incompatible", key = key, dismissed = SB.reviewDismissed[key] == true,
                mods = c.mods, reason = c.reason,
            }
        end
    end
    -- 3) HUD / visual overlaps — sourced OFFLINE from the bundled hookmap, NOT live
    --    attribution. Two+ installed mods that both draw the same HUD element collide
    --    visually even though the chain technically runs both (e.g. a vanished weather
    --    panel). The interceptor can't name HUD-class hooks at runtime (the class loads
    --    after our snapshot), so the offline hookmap is the reliable source here.
    local hookmap = safeGlobal("ModMixerHookMap")
    if type(hookmap) == "table" then
        local HUD_CLASS = { GameInfoDisplay = true, HUD = true, PlayerHUDUpdater = true }
        for target, mods in pairs(hookmap) do
            local cls = string.match(target, "^([^.]+)%.")
            if cls ~= nil and HUD_CLASS[cls] and type(mods) == "table" and #mods >= 2 then
                local key = "hud|" .. target
                items[#items + 1] = {
                    rkind = "hud", key = key, dismissed = SB.reviewDismissed[key] == true,
                    target = target, mods = mods,
                }
            end
        end
    end
    -- 4) Orphaned settings: modSettings/ left behind by uninstalled mods (runtime scan).
    for _, entry in ipairs(SB.scanOrphanedSettings()) do
        local key = "orphan|" .. entry
        items[#items + 1] = {
            rkind = "orphan", key = key, dismissed = SB.reviewDismissed[key] == true,
            entry = entry,
        }
    end
    return items
end

-- First mod in `order` that's among `mods` (= the highest-priority present contestant).
local function firstRankedIn(order, mods)
    if type(order) ~= "table" then return nil end
    local set = {}
    for _, m in ipairs(mods) do set[m] = true end
    for _, m in ipairs(order) do if set[m] then return m end end
    return nil
end

-- Decide a stomp's winner by precedence: explicit card > per-category rank > global
-- seating > undecided (natural = the outermost / last-installed mod). Returns (mod, decided).
function SB.rankWinner(target, mods, category)
    category = category or targetCategory(target)
    local card = SB.basicWinners[target]
    if card ~= nil then
        for _, m in ipairs(mods) do if m == card then return card, true end end
    end
    local byCat = firstRankedIn(SB.priorityByCat[category], mods)
    if byCat ~= nil then return byCat, true end
    local glob = firstRankedIn(SB.priorityGlobal, mods)
    if glob ~= nil then return glob, true end
    return mods[#mods], false   -- natural last-word holder; nobody ranked → undecided
end

-- Apply resolution: for every STOMP the user has expressed a preference on, keep the
-- chosen winner (mute the named losers) via the proven winner path. Shared / locked /
-- incompatible are NEVER muted. Untouched = zero vetoes. One batched save.
function SB.basicApply()
    local conflicts = SB.buildConflicts()
    local resolved, partial, shared, untouched, skipped = 0, 0, 0, 0, 0
    for _, c in ipairs(conflicts) do
        if c.kind == "hook" and (c.resolvability == "clean" or c.resolvability == "partial") then
            local winner, decided = SB.rankWinner(c.target, c.mods, c.category)
            if decided then
                SB.setHookWinner(c.target, winner, c.mods, true)   -- defer save
                if c.resolvability == "partial" then partial = partial + 1 else resolved = resolved + 1 end
            else
                untouched = untouched + 1
            end
        elseif c.kind == "hook" and c.resolvability == "shared" then
            shared = shared + 1
        else
            skipped = skipped + 1
        end
    end
    SB.save()
    return { resolved = resolved, partial = partial, shared = shared,
             untouched = untouched, skipped = skipped, total = #conflicts }
end

-- Generic ranked-list move (shared by the global and per-category lists). Auto-adds the
-- mod at lowest rank if absent; caller re-resolves.
local function moveInList(list, mod, dir)
    local idx
    for i, m in ipairs(list) do if m == mod then idx = i; break end end
    if idx == nil then list[#list + 1] = mod; idx = #list end
    local j = idx + dir
    if j >= 1 and j <= #list then list[idx], list[j] = list[j], list[idx] end
end
local function removeFromList(list, mod)
    local out = {}
    for _, m in ipairs(list) do if m ~= mod then out[#out + 1] = m end end
    return out
end

-- TIER 1 — global seating. TIER 2 — per-category. Both always re-resolve so the
-- displayed winners and the stored vetoes never disagree.
function SB.moveGlobalPriority(mod, dir)
    moveInList(SB.priorityGlobal, mod, dir); SB.basicApply(); return true
end
function SB.unrankGlobal(mod)
    SB.priorityGlobal = removeFromList(SB.priorityGlobal, mod); SB.basicApply()
end
function SB.moveCatPriority(category, mod, dir)
    SB.priorityByCat[category] = SB.priorityByCat[category] or {}
    moveInList(SB.priorityByCat[category], mod, dir); SB.basicApply(); return true
end
function SB.unrankCat(category, mod)
    if SB.priorityByCat[category] then
        SB.priorityByCat[category] = removeFromList(SB.priorityByCat[category], mod)
    end
    SB.basicApply()
end
-- back-compat aliases (old single global list)
function SB.moveModPriority(mod, dir) return SB.moveGlobalPriority(mod, dir) end
function SB.unrankMod(mod) return SB.unrankGlobal(mod) end

-- Per-fight winner card override (highest precedence).
function SB.setBasicWinner(target, mod) SB.basicWinners[target] = mod; SB.basicApply() end
function SB.clearBasicWinner(target)    SB.basicWinners[target] = nil; SB.basicApply() end

-- Drop ALL tiered state (global + per-cat ranks + cards) and the vetoes they produced.
function SB.clearBasic()
    SB.priorityGlobal = {}
    SB.priorityByCat  = {}
    SB.basicWinners   = {}
    local conflicts = SB.buildConflicts()
    for _, c in ipairs(conflicts) do
        if c.kind == "hook" then SB.clearHookContest(c.target, c.mods) end  -- un-veto all
    end
    SB.save()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- APPLY
-- ─────────────────────────────────────────────────────────────────────────────

local function featureLabel(entry, featureId)
    for _, f in ipairs(entry.features) do
        if f.id == featureId then return f.label end
    end
    return featureId
end

local function describeValue(value)
    if value == true  then return "ON"  end
    if value == false then return "OFF" end
    return tostring(value)
end

function SB.applyAll()
    for modName, wanted in pairs(SB.overrides) do
        local entry = SB.registry[modName]
        if entry == nil then
            gamelog(string.format("no driver registered for %s — skipped", modName))
        elseif not present(modName) then
            -- Mod not installed: nothing to drive. Stay silent (normal case).
        else
            for featureId, value in pairs(wanted) do
                local ok, how = entry.apply(featureId, value)
                local fLabel  = featureLabel(entry, featureId)
                if ok then
                    gamelog(string.format("%s: %s -> %s  (override via %s)",
                        entry.label, fLabel, describeValue(value), how))
                else
                    gamelog(string.format("%s: could NOT set %s -> %s  (%s)",
                        entry.label, fLabel, describeValue(value), how))
                end
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ARM
-- Defer until after the map loads — and after each driven mod's OWN
-- loadMission00Finished has set its defaults. FS25_FarmKit sorts before
-- FS25_ModMixer, so our appended callback runs LAST and our override wins.
-- Order within our callback: load saved config first, THEN apply it.
-- ─────────────────────────────────────────────────────────────────────────────

if Mission00 ~= nil and type(Mission00.loadMission00Finished) == "function"
   and Utils ~= nil and type(Utils.appendedFunction) == "function" then
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            SB.load()
            SB.applyAll()
        end)
    gamelog("armed — config loads + overrides apply at map load")
else
    gamelog("Mission00.loadMission00Finished unavailable — switchboard inactive this load")
end
