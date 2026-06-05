-- ModMixerHooks.lua  v1.2.0  — enriched interceptor + VETO (Switchboard S2).
-- Loaded FIRST (mod named FS25_0_ModMixer) so it patches Utils.* before any other
-- mod registers a hook. It (1) records who hooks which curated target function, and
-- (2) ENFORCES the user's veto choices: a hook the user vetoed last session is simply
-- NOT installed this session (restart-to-apply). Veto choices are read from
-- switchboard.xml at our load — self-contained, since we load before Switchboard.lua.
--
--   Utils.__ms_registry[wrapper] = { prev, impl, kind, mod, target }   (named only)
--   Utils.__ms_hooksByMod[mod]   = { [target] = { kind, count, wrapper } }
--   Utils.__ms_fnNames[fnValue]  = "Class.method"
--   Utils.__ms_stats             = { calls, named }
--   Utils.__ms_vetoApplied       = count of hooks skipped this load

local MSH_VERSION = "1.2.0"
local function log(msg)
    print(string.format("[ModMixerHooks %s] %s", MSH_VERSION, tostring(msg)))
end

if type(Utils) ~= "table" or type(Utils.overwrittenFunction) ~= "function" then
    log("Utils.overwrittenFunction not found — cannot install hooks.")
    return
end
if Utils.__ms_hooks_installed then
    log("Already installed — skipping second-pass re-patch.")
    return
end
Utils.__ms_hooks_installed = true

-- One-shot probe: is the debug library actually available in our env? If not, ALL
-- introspection-based attribution (source path, call-stack walk) is dead and only
-- g_currentModName works — which is nil for deferred hooks (= the "(unknown)" rows).
do
    local d = debug
    log(string.format("debug probe: type(debug)=%s  type(debug.getinfo)=%s  type(debug.traceback)=%s",
        type(d),
        (type(d) == "table") and type(d.getinfo) or "n/a",
        (type(d) == "table") and type(d.traceback) or "n/a"))
end

Utils.__ms_registry   = {}
Utils.__ms_hooksByMod = {}
Utils.__ms_fnNames    = {}
Utils.__ms_stats      = { calls = 0, named = 0 }
Utils.__ms_vetoApplied = 0
local _untrackedByMod = {}   -- mod -> count of hooks on untracked fns (widen the net?)

-- Distinct hook FUNCTIONS installed per target. A mod that re-registers the same
-- overwrite per vehicle type (ADS does, ~475x) installs the SAME function reference
-- each time -> 1 distinct impl. A genuinely different hooker installs a DIFFERENT
-- function. So (distinct impls > mods we named) == a hook we couldn't attribute =
-- HIDDEN/dynamic; (distinct impls <= mods named) == per-type dupes of a named mod.
-- This is what tells the ADS per-type flood apart from a real hidden 4th party.
Utils.__ms_implsSeen = {}    -- [target] = { [implFn] = true }
Utils.__ms_implCount = {}    -- [target] = number of distinct impls (cached count)
local function noteImpl(target, impl)
    if target == nil or impl == nil then return end
    local s = Utils.__ms_implsSeen[target]
    if s == nil then s = {}; Utils.__ms_implsSeen[target] = s end
    if s[impl] == nil then
        s[impl] = true
        Utils.__ms_implCount[target] = (Utils.__ms_implCount[target] or 0) + 1
    end
end

-- Reorder (S3, lever c part 2) bookkeeping.
Utils.__ms_installSeq   = 0    -- monotonic hook-install counter = TRUE firing order
Utils.__ms_reorderBuf   = {}   -- [target] = { base=fn, hooks={ {mod,impl,kind}, ... }, _tramp=fn }
Utils.__ms_reorderBuilt = {}   -- [target] = built chain wrapper (lazy, built on first call)
Utils.__ms_trampTargets = {}   -- [trampolineFn] = target  (so a re-hook of a reordered slot resolves)

-- Curated TARGET functions to name (and allow vetoing). Bounded list — NOT every
-- method of a class (a metatable __index can lead into a huge shared table and
-- over-name). Grow from the conflict catalogue as needed.
local TARGETS = {
    "WheelPhysics.serverUpdate", "WheelPhysics.finalize", "WheelPhysics.updatePhysics",
    "WheelPhysics.updateTireFriction", "WheelPhysics.updateFriction", "WheelPhysics.updateWheelFriction",
    "WheelPhysics.updateContact",
    "WheelsUtil.updateWheelsPhysics", "WheelsUtil.updateWheelsPhysicsGroundContact",
    "WheelsUtil.getSmoothedAcceleratorAndBrakePedals",
    "Drivable.updateVehiclePhysics",
    "Motorized.updateConsumers", "Motorized.onUpdate", "Motorized.getMaxPtoRpm",
    "Motorized.getUseAutomaticGearShifting", "Motorized.getUseAutomaticGroupShifting",
    "Vehicle.update", "Vehicle.updateTick", "Vehicle.onUpdate", "Vehicle.load", "Vehicle.getSpeedLimit",
    "FSBaseMission.update", "FSBaseMission.sendInitialClientState", "FSBaseMission.onConnectionFinishedLoading",
    "Sprayer.processSprayerArea", "Cutter.onEndWorkAreaProcessing",
    "BunkerSilo.update", "BunkerSilo.load", "BunkerSilo.loadFromXMLFile",
    "PlayerHUDUpdater.showSplitShapeInfo", "PlayerHUDUpdater.showFieldInfo",
    "ConstructionBrush.verifyAccess", "Farm.changeBalance", "InfoDialog.show",
    "VehicleMaterial.apply", "VehicleMaterial.applyToVehicle",
    "PlaceableProductionPoint.onFinalizePlacement", "ProductionPoint.load",
    "DensityMapHeightManager.loadMapData", "Weather.update",
    -- Damage / Wear — vehicle-health fns damage overhauls (ADS) overwrite via specs.
    "Wearable.updateDamageAmount", "Wearable.setOperatingTime",
    "Motorized.getCanMotorRun", "Motorized.startMotor", "Motorized.updateMotorTemperature",
    "Vehicle.getSellPrice",
}

-- NON-raw global read: FS25 runs each mod in its own environment; engine classes
-- live in the BASE table reached via the env metatable __index — rawget bypasses
-- that and finds nothing. (Same trap as FarmKit cross-mod access.)
local function safeGlobal(name)
    local ok, v = pcall(function() return _G[name] end)
    if ok then return v end
    return nil
end

local _snapped = false
local function snapshotOne(qualified)
    local class, method = string.match(qualified, "^([^.]+)%.(.+)$")
    if class ~= nil and method ~= nil then
        local C = safeGlobal(class)
        if type(C) == "table" then
            local fn = C[method]   -- non-raw read: resolves inherited methods too
            if type(fn) == "function" and Utils.__ms_fnNames[fn] == nil then
                Utils.__ms_fnNames[fn] = qualified
            end
        end
    end
end
local function buildNameMap()
    -- Curated core (hardcoded above = guaranteed even if the dataset is missing) …
    for _, q in ipairs(TARGETS) do snapshotOne(q) end
    -- … plus the WIDER net: discovered conflict targets from the bundled dataset
    -- (tools/gen_targets.py — every Class.method 2+ mods overwrite in this install).
    if type(ModMixerTargets) == "table" then
        for _, q in ipairs(ModMixerTargets) do snapshotOne(q) end
    end
end
local function ensureSnapshot()
    if _snapped then return end
    _snapped = true
    pcall(buildNameMap)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- VETO config (read once at our early load; restart-to-apply).
-- ─────────────────────────────────────────────────────────────────────────────
-- One-file kill switch for ALL load-time levers (vetoes + reorders). Drop an empty
-- file named MODMIXER_SAFE_MODE.txt (or the legacy DISABLE_VETOES.txt) into
-- modSettings/FS25_ModMixer/ to neutralise them for one load WITHOUT losing config.
-- This is the recovery hatch if a veto/reorder ever leaves the game uncontrollable.
local function _mmSafeMode(dir)
    if type(fileExists) ~= "function" then return false end
    return fileExists(dir .. "MODMIXER_SAFE_MODE.txt")
        or fileExists(dir .. "DISABLE_VETOES.txt")
end

local _vetoSet = {}
local function readVetoes()
    if type(getUserProfileAppPath) ~= "function" or type(loadXMLFile) ~= "function" then return end
    local dir = getUserProfileAppPath() .. "modSettings/FS25_ModMixer/"
    if _mmSafeMode(dir) then
        log("SAFE MODE: kill-switch file present — all vetoes ignored this load.")
        return
    end
    local path = dir .. "switchboard.xml"
    if type(fileExists) == "function" and not fileExists(path) then return end
    local xml = loadXMLFile("ModMixerVetoRead", path)
    if xml == nil or xml == 0 then return end
    local i = 0
    while true do
        local key = string.format("switchboard.vetoes.veto(%d)", i)
        local mod = getXMLString(xml, key .. "#mod")
        if mod == nil then break end
        local target = getXMLString(xml, key .. "#target")
        if target ~= nil then _vetoSet[mod .. "|" .. target] = true end
        i = i + 1
    end
    if type(delete) == "function" then delete(xml) end
end
pcall(readVetoes)

local function isVetoed(mod, target)
    if mod == nil or target == nil then return false end
    return _vetoSet[mod .. "|" .. target] == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- REORDER config (read once at our early load; restart-to-apply). For a target
-- the user has reordered, _reorderOrder[target] = { mod1, mod2, ... } is the
-- desired FIRING order. DISABLE_VETOES.txt also disables reorders (one-file kill
-- switch for all load-time levers).
-- ─────────────────────────────────────────────────────────────────────────────
local _reorderOrder = {}
local function readReorders()
    if type(getUserProfileAppPath) ~= "function" or type(loadXMLFile) ~= "function" then return end
    local dir = getUserProfileAppPath() .. "modSettings/FS25_ModMixer/"
    if _mmSafeMode(dir) then
        log("SAFE MODE: kill-switch file present — all reorders ignored this load.")
        return
    end
    local path = dir .. "switchboard.xml"
    if type(fileExists) == "function" and not fileExists(path) then return end
    local xml = loadXMLFile("ModMixerReorderRead", path)
    if xml == nil or xml == 0 then return end
    local i = 0
    while true do
        local rk = string.format("switchboard.reorders.reorder(%d)", i)
        local target = getXMLString(xml, rk .. "#target")
        if target == nil then break end
        local mods, j, hasUnknown = {}, 0, false
        while true do
            local name = getXMLString(xml, string.format("%s.mod(%d)#name", rk, j))
            if name == nil then break end
            if name == "(unknown)" then hasUnknown = true end
            mods[#mods + 1] = name
            j = j + 1
        end
        -- SAFETY: never apply a reorder that contains an unidentified hook. The chain
        -- builder places hooks by name; an "(unknown)" can't be positioned reliably, so
        -- the resulting order is guesswork that can mis-wire the chain and break vehicle
        -- specs at load (observed: AIAutomaticSteering left nil → dead controls). Skip it
        -- and tell the user to re-create it now that deferred hooks are named by inference.
        if hasUnknown then
            log(string.format("REORDER SKIPPED for %s: contains an unidentified (unknown) hook — "
                .. "cannot order a chain whose members aren't all named. Re-create it in the "
                .. "Switchboard (hooks are inferred/named now).", target))
        elseif #mods > 0 then
            _reorderOrder[target] = mods
        end
        i = i + 1
    end
    if type(delete) == "function" then delete(xml) end
end
pcall(readReorders)

local function isReordered(target)
    return target ~= nil and _reorderOrder[target] ~= nil
end

-- Load-critical functions: even if the config says veto, REFUSE (install anyway).
-- Removing a mod's load/init hook can hang the load (lesson from "veto everything
-- -> 60% hang"). The UI shows these as locked. Published so the UI can read it.
local NO_VETO = {
    ["Vehicle.load"] = true,
    ["FSBaseMission.onConnectionFinishedLoading"] = true,
    ["FSBaseMission.sendInitialClientState"] = true,
    ["ProductionPoint.load"] = true,
    ["PlaceableProductionPoint.onFinalizePlacement"] = true,
    ["BunkerSilo.load"] = true,
    ["BunkerSilo.loadFromXMLFile"] = true,
    ["DensityMapHeightManager.loadMapData"] = true,
    ["VehicleMaterial.apply"] = true,
    ["VehicleMaterial.applyToVehicle"] = true,
}
Utils.__ms_noVeto = NO_VETO

-- Attribute a hook to its mod. IN-GAME `debug` IS UNAVAILABLE (confirmed by the probe
-- above: type(debug)=nil — GIANTS strips it outside a -cheats/dev launch), so source-
-- path and call-stack introspection are impossible. The ONLY runtime attribution
-- signal is g_currentModName: set for TOP-LEVEL hook installs, nil for DEFERRED ones
-- (installed inside loadMap / loadMission00Finished callbacks). Deferred "(unknown)"
-- hooks are named instead by OFFLINE scan-elimination in the UI — hookmap[target]
-- minus the mods we DID name on that target (see SwitchboardFrame.inferUnknownLabel,
-- dataset scripts/mm_hookmap_generated.lua). The old debug-based source/stack matcher
-- was removed 2026-06-04: it silently no-op'd in normal play (debug absent).
local function resolveMod()
    if g_currentModName ~= nil and g_currentModName ~= "" then return g_currentModName end
    return nil   -- deferred hook; the UI's scan-elimination names it from the hook-map
end

-- Capped one-liner: note each deferred hook we couldn't name at load, so the log shows
-- which curated targets carry an "(unknown)" the hook-map is expected to resolve.
local _unknownLogged = 0
local function logUnknown(target, kind, newFn)
    if _unknownLogged >= 10 then return end
    _unknownLogged = _unknownLogged + 1
    log(string.format("deferred unknown on %s (%s) fn=%s — g_currentModName nil; UI names it via hook-map.",
        target, tostring(kind), tostring(newFn)))
end

-- Mods already recorded as hooking `target` this session (real names only).
local function recordedModsOnTarget(target)
    local set = {}
    for m, targets in pairs(Utils.__ms_hooksByMod) do
        if m ~= "(unknown)" and targets[target] ~= nil then set[m] = true end
    end
    return set
end

-- Install-time scan-elimination: name a DEFERRED hook (g_currentModName nil) from the
-- static hook-map minus the mods already recorded on this target, ∩ installed. Works
-- because top-level (named) hooks all install during mod-load, BEFORE deferred ones
-- (map load) — so the recorded set is complete when a deferred hook arrives. A clean
-- singleton makes the hook ACTIONABLE: it's recorded under its real name, so veto /
-- winner / reorder enforce on it just like any named hook. (Sequential resolution: a
-- first inferred hook is recorded → excluded from the next deferred hook's candidates.)
local function inferDeferredMod(target)
    if type(ModMixerHookMap) ~= "table" then return nil end
    local candidates = ModMixerHookMap[target]
    if type(candidates) ~= "table" then return nil end
    local named = recordedModsOnTarget(target)
    local left, n = nil, 0
    for _, m in ipairs(candidates) do
        local installed = (g_modManager ~= nil and type(g_modManager.getModByName) == "function"
            and g_modManager:getModByName(m) ~= nil)
        if installed and not named[m] then n = n + 1; left = m end
    end
    if n == 1 then return left end
    return nil   -- 0 = not in map (truly hidden); 2+ = ambiguous (UI shows a "maybe" list)
end

local function bumpSeq()
    Utils.__ms_installSeq = Utils.__ms_installSeq + 1
    return Utils.__ms_installSeq
end

-- Update the per-mod / per-target bookkeeping the UI reads (count, kind, true
-- firing-order seq). `wrapper` is the installed wrapper, or nil for a buffered
-- (reordered) hook that has no individual wrapper yet.
local function noteHook(mod, target, kind, wrapper, reordered, inferred)
    mod = mod or "(unknown)"
    local byMod = Utils.__ms_hooksByMod[mod]
    if byMod == nil then byMod = {}; Utils.__ms_hooksByMod[mod] = byMod end
    local e = byMod[target]
    if e == nil then e = { kind = kind, count = 0 }; byMod[target] = e end
    e.count     = e.count + 1
    e.kind      = kind
    e.seq       = bumpSeq()             -- order this mod's hook installed = its firing slot
    e.reordered = reordered or e.reordered
    if inferred then e.inferred = true end   -- named by scan-elimination, not g_currentModName
    if wrapper ~= nil then e.wrapper = wrapper end
    Utils.__ms_stats.named = Utils.__ms_stats.named + 1
    return e
end

-- Store a captured (named, non-vetoed) hook.
local function record(result, existingFn, newFn, kind, target, mod, inferred)
    Utils.__ms_fnNames[result] = target   -- chain the name onto the new wrapper
    mod = mod or "(unknown)"
    Utils.__ms_registry[result] = { prev = existingFn, impl = newFn, kind = kind, mod = mod, target = target }
    noteHook(mod, target, kind, result, false, inferred)
end

local _orig_overwrite = Utils.overwrittenFunction
local _orig_append    = (type(Utils.appendedFunction)  == "function") and Utils.appendedFunction  or nil
local _orig_prepend   = (type(Utils.prependedFunction) == "function") and Utils.prependedFunction or nil

-- ─────────────────────────────────────────────────────────────────────────────
-- REORDER MACHINERY (deferred-replay trampoline).
-- For a reordered target we do NOT install hooks as they arrive. Instead we keep
-- the pristine base fn + a buffer of every mod's {impl,kind}, and hand back ONE
-- trampoline that each hooker stores into the class slot. On the FIRST runtime
-- call (long after all mods have loaded) the trampoline folds the buffered impls
-- onto the base IN THE USER'S ORDER, caches the result, and forwards to it. This
-- works because FS25 looks specialization functions up by name at call time, so
-- whatever sits in the class slot when the function first runs is what runs.
-- ─────────────────────────────────────────────────────────────────────────────
local function classMethodSet(target, fn)
    local class, method = string.match(target, "^([^.]+)%.(.+)$")
    if class ~= nil and method ~= nil then
        local C = safeGlobal(class)
        if type(C) == "table" then C[method] = fn end
    end
end

local function combinatorFor(kind)
    if kind == "prepend"   then return _orig_prepend end
    if kind == "overwrite" then return _orig_overwrite end
    return _orig_append
end

-- Fold the buffered hooks onto the base in the desired order. Any buffered mod
-- not named in the desired order is applied last, in install order (so a mod
-- added since the config was saved is never dropped). Fully pcall-guarded.
local function buildReorderChain(target)
    local buf = Utils.__ms_reorderBuf[target]
    if buf == nil or buf.base == nil then return function() end end
    local chain   = buf.base
    local desired = _reorderOrder[target] or {}
    local used    = {}

    local function applyHook(h)
        if used[h] then return end
        used[h] = true
        local comb = combinatorFor(h.kind)
        if comb ~= nil then
            local ok, res = pcall(comb, chain, h.impl)
            if ok and type(res) == "function" then chain = res end
        end
    end

    -- DRIFT GUARD: only reorder if every mod named in the saved order is actually a
    -- hooker on this target this load. If a named mod is absent (it updated, was added
    -- or removed since the order was saved), the saved order no longer describes this
    -- chain — applying it can mis-wire the result. Fall back to NATURAL install order
    -- (exactly what the game would do without ModMixer) and log it.
    local present = {}
    for _, h in ipairs(buf.hooks) do present[h.mod] = true end
    for _, wantMod in ipairs(desired) do
        if not present[wantMod] then
            log(string.format("REORDER DRIFT for %s: saved order names '%s' which is not in the "
                .. "live chain this load (a mod changed) — applying NATURAL order, not reordering.",
                target, tostring(wantMod)))
            for _, h in ipairs(buf.hooks) do applyHook(h) end
            return chain
        end
    end

    for _, wantMod in ipairs(desired) do
        for _, h in ipairs(buf.hooks) do
            if h.mod == wantMod then applyHook(h) end
        end
    end
    for _, h in ipairs(buf.hooks) do applyHook(h) end   -- any not covered by desired
    return chain
end

local function getTrampoline(target)
    local buf = Utils.__ms_reorderBuf[target]
    if buf._tramp == nil then
        local t
        t = function(...)
            local built = Utils.__ms_reorderBuilt[target]
            if built == nil then
                local ok, res = pcall(buildReorderChain, target)
                built = (ok and type(res) == "function") and res or buf.base
                Utils.__ms_reorderBuilt[target] = built
                pcall(classMethodSet, target, built)   -- short-circuit future direct lookups
            end
            return built(...)
        end
        buf._tramp = t
        Utils.__ms_trampTargets[t] = target
    end
    return buf._tramp
end

-- The one place that names the target, checks veto/reorder, and skips, buffers,
-- or installs.
local function patched(orig, existingFn, newFn, kind)
    ensureSnapshot()
    Utils.__ms_stats.calls = Utils.__ms_stats.calls + 1
    -- existingFn may be a trampoline we already installed for a reordered target
    -- (a later mod re-hooking the same slot) — resolve the target from it.
    local target = Utils.__ms_trampTargets[existingFn] or Utils.__ms_fnNames[existingFn]
    -- Attribution for named targets: g_currentModName (top-level) → install-time
    -- scan-elimination (deferred). debug is unavailable in-game, so these are the only
    -- signals. An inferred name is RECORDED as the real mod, so veto/winner/reorder
    -- enforce on it below exactly like a runtime-named hook. nil = truly unresolvable
    -- (not in the map, or ambiguous) → stays "(unknown)"; the UI shows a maybe-list.
    local mod, inferred = nil, false
    if target ~= nil then
        noteImpl(target, newFn)   -- distinct-impl tally (per-type dupe vs hidden 4th party)
        mod = resolveMod()
        if mod == nil then
            mod = inferDeferredMod(target)
            if mod ~= nil then inferred = true end
        end
        if mod == nil then logUnknown(target, kind, newFn) end
    end

    -- Gap 3: hook is on a function outside our named set — track which mods do this so
    -- coverageLog can flag them as candidates to add to gen_targets.py.
    if target == nil then
        local m = resolveMod() or "(anonymous)"
        _untrackedByMod[m] = (_untrackedByMod[m] or 0) + 1
    end

    if target ~= nil and isVetoed(mod, target) then
        if NO_VETO[target] then
            log(string.format("VETO IGNORED: %s -> %s is load-critical (installed anyway).",
                tostring(mod), target))
        else
            Utils.__ms_vetoApplied = Utils.__ms_vetoApplied + 1
            log(string.format("VETO: %s -> %s NOT installed (%s).", tostring(mod), target, kind))
            return existingFn   -- skip: the hook never installs; the chain is unchanged
        end
    end

    -- REORDER path: buffer the hook and return the trampoline (load-critical
    -- targets are never reordered — they fall through to normal install).
    if target ~= nil and isReordered(target) and not NO_VETO[target] then
        local buf = Utils.__ms_reorderBuf[target]
        if buf == nil then
            buf = { base = existingFn, hooks = {} }   -- first hooker: existingFn is pristine
            Utils.__ms_reorderBuf[target] = buf
        end
        buf.hooks[#buf.hooks + 1] = { mod = mod or "(unknown)", impl = newFn, kind = kind }
        noteHook(mod, target, kind, nil, true, inferred)
        log(string.format("REORDER: buffered %s -> %s (%s).", tostring(mod), target, kind))
        return getTrampoline(target)
    end

    local result = orig(existingFn, newFn)
    if target ~= nil and type(result) == "function" then
        record(result, existingFn, newFn, kind, target, mod, inferred)
    end
    return result
end

Utils.overwrittenFunction = function(existingFn, newFn)
    return patched(_orig_overwrite, existingFn, newFn, "overwrite")
end
if _orig_append then
    Utils.appendedFunction = function(existingFn, newFn)
        return patched(_orig_append, existingFn, newFn, "append")
    end
end
if _orig_prepend then
    Utils.prependedFunction = function(existingFn, newFn)
        return patched(_orig_prepend, existingFn, newFn, "prepend")
    end
end

do
    local nVetoes, nReorders = 0, 0
    for _ in pairs(_vetoSet) do nVetoes = nVetoes + 1 end
    for _ in pairs(_reorderOrder) do nReorders = nReorders + 1 end
    log(string.format("interceptor active (named targets + veto + reorder). Loaded first. "
        .. "%d veto rule(s), %d reorder rule(s) loaded.", nVetoes, nReorders))
    if nVetoes > 0 or nReorders > 0 then
        log("RECOVERY: if the game loads with no input/control, create an empty file named")
        log("  MODMIXER_SAFE_MODE.txt  in  modSettings/FS25_ModMixer/  then restart.")
        log("  It disables ALL vetoes + reorders for that load WITHOUT losing your config.")
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- COVERAGE + DIAGNOSTICS — logged after map load via the ORIGINAL append.
-- ─────────────────────────────────────────────────────────────────────────────
local function coverageLog()
    local nNames, nWheelPhysics = 0, 0
    for _, name in pairs(Utils.__ms_fnNames) do
        nNames = nNames + 1
        if string.sub(name, 1, 13) == "WheelPhysics." then nWheelPhysics = nWheelPhysics + 1 end
    end
    local nMods = 0
    for _ in pairs(Utils.__ms_hooksByMod) do nMods = nMods + 1 end

    log(string.format("named %d target fns (WheelPhysics: %d). calls=%d, stored=%d across %d mods, "
        .. "vetoes applied=%d.", nNames, nWheelPhysics, Utils.__ms_stats.calls, Utils.__ms_stats.named,
        nMods, Utils.__ms_vetoApplied))

    -- ── Chain summary: how many targets active, how many unknowns remain ──────
    local activeTargetSet = {}
    for mod, targets in pairs(Utils.__ms_hooksByMod) do
        for target, _ in pairs(targets) do activeTargetSet[target] = true end
    end
    local nActive = 0
    for _ in pairs(activeTargetSet) do nActive = nActive + 1 end

    -- Count targets that have at least one unknown hook. Note: e.count can be inflated
    -- when a mod re-registers a hook per vehicle instance (not just at load time) — so
    -- we report "X targets have unknowns" rather than summing the raw counts, which
    -- would be misleading. A separate warning flags the re-hooking pattern below.
    local unknownEntry = Utils.__ms_hooksByMod["(unknown)"] or {}
    local unknownList = {}
    for target, _ in pairs(unknownEntry) do
        unknownList[#unknownList + 1] = target
    end
    table.sort(unknownList)
    log(string.format("CHAIN SUMMARY: %d targets active, %d target(s) have unknown hook(s)%s",
        nActive, #unknownList,
        (#unknownList > 0 and (": " .. table.concat(unknownList, ", ")) or ".")))

    -- ── HIDDEN HOOK vs per-type DUPE detection ────────────────────────────────
    -- For every target carrying an unknown, decide which of two very different things
    -- it is, using the distinct-impl tally (Utils.__ms_implCount):
    --   • leftKnown > 0  → a hook-map mod that simply hasn't been named yet (deferred).
    --                      The UI's maybe-list handles it; not our business here.
    --   • leftKnown == 0 → every offline-known hooker is already named. Then:
    --       impls  >  named  → a hook FUNCTION exists that no named mod accounts for =
    --                          HIDDEN / dynamic hook (e.g. the 4th overwrite on the
    --                          steering chain). Flag it.
    --       impls <= named  → the unknown bucket is just the SAME function re-registered
    --                          per vehicle type (ADS does this ~475x). Redundant — tell
    --                          the UI to suppress the noise row, NOT flag it as hidden.
    -- This is what stops single-source ADS targets (startMotor, updateDamageAmount, …)
    -- from being mislabelled "hidden": their 475 dupes share ONE impl, so impls<=named.
    Utils.__ms_hiddenHooks      = {}
    Utils.__ms_redundantUnknown = {}
    local function namedCountOn(target)
        local n = 0
        for m, byMod in pairs(Utils.__ms_hooksByMod) do
            if m ~= "(unknown)" and byMod[target] ~= nil then n = n + 1 end
        end
        return n
    end
    local function leftKnownOn(target)
        local mapMods = (type(ModMixerHookMap) == "table") and ModMixerHookMap[target] or nil
        if type(mapMods) ~= "table" then return 0 end
        local n = 0
        for _, m in ipairs(mapMods) do
            local installed = (g_modManager ~= nil and type(g_modManager.getModByName) == "function"
                and g_modManager:getModByName(m) ~= nil)
            local byMod = Utils.__ms_hooksByMod[m]
            if installed and (byMod == nil or byMod[target] == nil) then n = n + 1 end
        end
        return n
    end
    for target, _ in pairs(unknownEntry) do
        if leftKnownOn(target) == 0 then
            local impls = Utils.__ms_implCount[target] or 0
            local named = namedCountOn(target)
            if impls > named then
                Utils.__ms_hiddenHooks[target] = true
                log(string.format("HIDDEN HOOK on %s: %d distinct hook fn(s) installed but only "
                    .. "%d mod(s) attributed -> a hook here comes from a dynamic pattern static "
                    .. "analysis can't name.", target, impls, named))
            else
                Utils.__ms_redundantUnknown[target] = true   -- per-type dupes of a named mod
            end
        end
    end

    -- ── Untracked hooks: mods hooking fns outside our named set ───────────────
    -- These mods are installing hooks on Class.method we don't snapshot. Each entry
    -- is a candidate to add to gen_targets.py so we start seeing their conflicts.
    -- Note: debug is nil in-game (GIANTS strips it) so we can't name the function —
    -- look the mod up manually and inspect its Utils.* calls to identify candidates.
    local untrackedMods = {}
    for mod, count in pairs(_untrackedByMod) do
        untrackedMods[#untrackedMods + 1] = { mod = mod, count = count }
    end
    table.sort(untrackedMods, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.mod < b.mod
    end)
    if #untrackedMods > 0 then
        local parts = {}
        for _, e in ipairs(untrackedMods) do
            parts[#parts + 1] = string.format("%s(x%d)", e.mod, e.count)
        end
        log("UNTRACKED hooks (outside the net — inspect these mods for gen_targets.py candidates):")
        log("  " .. table.concat(parts, "  "))
    end

    -- ── Runtime re-hooking warning ────────────────────────────────────────────
    -- If calls >> stored by a large margin, some mod is calling Utils.*Function
    -- inside a per-vehicle or per-frame callback (not just at mod load). This
    -- inflates counters and wastes interceptor overhead on every vehicle spawn.
    local reHookRatio = (Utils.__ms_stats.stored or Utils.__ms_stats.named or 0)
    if Utils.__ms_stats.calls > reHookRatio * 5 and Utils.__ms_stats.calls > 1000 then
        log(string.format("WARNING: %d interceptor calls but only %d stored — a mod is "
            .. "re-registering hooks at runtime (inside onLoad/update/spawn). "
            .. "Check UNTRACKED list above and mods with high call counts.",
            Utils.__ms_stats.calls, reHookRatio))
    end

    -- ── Physics watch-list ────────────────────────────────────────────────────
    local watch = {
        ["WheelPhysics.serverUpdate"]=true, ["WheelPhysics.finalize"]=true,
        ["WheelPhysics.updateTireFriction"]=true, ["WheelPhysics.updateFriction"]=true,
        ["WheelsUtil.updateWheelsPhysics"]=true, ["Drivable.updateVehiclePhysics"]=true,
    }
    local byTarget = {}
    for mod, targets in pairs(Utils.__ms_hooksByMod) do
        for target, e in pairs(targets) do
            if watch[target] then
                byTarget[target] = byTarget[target] or {}
                table.insert(byTarget[target], string.format("%s(%s)", mod, e.kind))
            end
        end
    end
    for target, mods in pairs(byTarget) do
        log(string.format("  physics hook %s  <-  %s", target, table.concat(mods, ", ")))
    end
end

if Mission00 ~= nil and type(Mission00.loadMission00Finished) == "function" and _orig_append then
    -- pcall wrapper: coverageLog is diagnostic only — an error here must NEVER
    -- propagate into loadMission00Finished and hang the load sequence.
    Mission00.loadMission00Finished = _orig_append(Mission00.loadMission00Finished, function(...)
        local ok, err = pcall(coverageLog)
        if not ok then log("coverageLog error (non-fatal): " .. tostring(err)) end
    end)
end
