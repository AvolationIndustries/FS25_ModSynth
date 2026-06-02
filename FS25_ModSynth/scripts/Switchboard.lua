-- Switchboard.lua  (FS25_ModSynth, Stage 2)
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
-- TRANSPARENCY: every override is logged and attributed to ModSynth, so a
-- "missing feature" always traces back to us — never to the mod's author.
--
-- Stage 2 progress:
--   step 2 (DONE): flag-DRIVER, proven end-to-end on FarmKit.
--   step 1 (THIS): persistence — desired state saved to / loaded from
--                  modSettings/FS25_ModSynth/switchboard.xml, survives restarts.
--   step 3 (next): in-game UI to edit the overrides.
-- ─────────────────────────────────────────────────────────────────────────────

ModSynthSwitchboard = ModSynthSwitchboard or {}
local SB = ModSynthSwitchboard

-- Double-load guard (the same zip-vs-source-folder trap ModSynth.lua guards).
if SB._loaded then return end
SB._loaded = true

local SB_TAG = "[ModSynth Switchboard]"

local function gamelog(msg)
    -- Switchboard actions are user-facing notices (which features WE changed),
    -- so they belong in the game log as the visible ModSynth attribution.
    print(SB_TAG .. " " .. tostring(msg))
end

local function present(modName)
    if g_modManager == nil then return false end
    local name = modName:gsub("%.zip$", "")   -- single assignment drops gsub's count
    return g_modManager:getModByName(name) ~= nil
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
            { id = "dustMultiplier",         label = "Dust Amount",               kind = "value"  },
            { id = "plowingEnabled",         label = "Realistic Plowing",         kind = "toggle" },
            { id = "realisticEngineEnabled", label = "Realistic Engine RPM",      kind = "toggle" },
            { id = "hudEnabled",             label = "FarmKit HUD",               kind = "toggle" },
        },

        -- Drive FarmKit through its OWN public settings API so its menu, savefile
        -- and multiplayer sync all stay coherent with what we set. Layered
        -- fallbacks cover version drift (best-effort across installs).
        apply = function(featureId, value)
            local S = rawget(_G, "NXFarmKitSettings")
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
-- FarmKit wheel-physics fix — the exact bug that started ModSynth (keep FarmKit's
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

-- ─────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE  —  modSettings/FS25_ModSynth/switchboard.xml
-- Wrapped in pcall, mirroring ModSynth.lua's io-hardening: a restricted XML/file
-- API in a published sandbox can never error the mod's load.
-- ─────────────────────────────────────────────────────────────────────────────

local SETTINGS_DIR    = "modSettings/FS25_ModSynth/"
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

    local xml = loadXMLFile("ModSynthSwitchboard", path)
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

    delete(xml)
    SB.overrides = loaded
    return true, string.format("loaded %d mod override set(s)", mi)
end

local function doSave()
    createFolder(getUserProfileAppPath() .. SETTINGS_DIR)
    local path = settingsPath()

    local xml = createXMLFile("ModSynthSwitchboard", path, "switchboard")
    if xml == nil or xml == 0 then
        return false, "could not create switchboard.xml"
    end
    setXMLInt(xml, "switchboard#version", SCHEMA_VERSION)

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

    saveXMLFile(xml)
    delete(xml)
    return true, string.format("saved %d mod override set(s)", mi)
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
        -- Note: reverting to the mod's OWN default at runtime would require asking
        -- the mod to re-apply its saved value; for now a clear takes effect next
        -- map load. (Most mods re-read their own settings at load.)
    end
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
-- FS25_ModSynth, so our appended callback runs LAST and our override wins.
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
