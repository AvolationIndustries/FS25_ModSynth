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

-- ─────────────────────────────────────────────────────────────────────────────
-- HIBERNATE (live mod parking) — gate a mod's per-frame entry points so its CPU
-- cost drops to ~zero, REVERSIBLY and WITHOUT a restart. We load first, before any
-- mod registers, so we wrap addModEventListener: each registered listener is tagged
-- with the mod that registered it (g_currentModName) and its update/draw/mouseEvent/
-- keyEvent are wrapped with a one-line gate that early-returns while the mod is parked.
-- loadMap/loadMapFinished/deleteMap are NEVER gated (load/save lifecycle — same
-- principle as isLoadCritical for vetoes). Toggling = a single boolean flip
-- (Utils.__ms_hibernate[mod]); the Switchboard drives it live and persists it. The
-- wrappers install ONCE at registration; only a boolean changes at runtime, so there
-- is no mid-game re-wrapping and no load-brick risk (the Farm.new lesson). The mod
-- loads + inits fully first; parking only skips its subsequent per-frame work.
-- ─────────────────────────────────────────────────────────────────────────────
Utils.__ms_hibernate    = Utils.__ms_hibernate    or {}   -- [modName]=true → parked (read every frame)
Utils.__ms_modListeners = Utils.__ms_modListeners or {}   -- [modName] = { listener, ... }
Utils.__ms_hibernatable = Utils.__ms_hibernatable or {}   -- ordered modName list (UI / console)
local _hibTable       = Utils.__ms_hibernate
local _gatedListeners = {}                                 -- [listener]=true (dedupe re-adds)

-- Per-mod main-loop COST (ms/frame). We already wrap every listener's update/draw, so
-- timing the inner call is almost free AND measures exactly what parking reclaims. The
-- in-game readout (mmCost) means no external overlay is needed — and overlays can't
-- attribute cost per-mod anyway. Stored as running totals; mmCost divides by frames,
-- mmCostReset zeroes them for a clean activity measurement.
Utils.__ms_cost = Utils.__ms_cost or {}                   -- [modName] = { upd, drw, frames, savedMs }
local _cost = Utils.__ms_cost
Utils.__ms_frame = Utils.__ms_frame or { acc = 0, n = 0 } -- wall-clock frame-time accumulator (dt → ms/frame + fps)
local _now  = (type(getTimeSec) == "function") and getTimeSec or nil

-- Engine perf-API probe (one-shot): does FS25 expose a frame/CPU timing global we could
-- ALSO surface (the engine's ".ms cycle time" split)? Log which candidates resolve so we
-- can wire the real one next pass. The dt-based frame time below works regardless.
do
    local cands = { "getFrameTimerTime", "getFps", "getAverageFrameTime", "getFrameTime",
                    "getProfilerTime", "getCpuLoad", "getMonotonicTime", "getPerformanceTime" }
    local found = {}
    for _, name in ipairs(cands) do
        local ok, v = pcall(function() return _G[name] end)
        if ok and v ~= nil then found[#found + 1] = name .. "(" .. type(v) .. ")" end
    end
    log("perf-api probe: " .. (#found > 0 and table.concat(found, ", ")
        or "no candidate timing globals found — frame time from dt"))
end

-- Timer-resolution probe (one-shot, at load): is getTimeSec fine-grained enough to time a
-- sub-ms mod update? Logs the smallest non-zero tick so we know if the numbers are solid.
if _now ~= nil then
    pcall(function()
        local minD, last = nil, _now()
        for _ = 1, 100000 do
            local cur = _now()
            local d = cur - last
            if d > 0 then if minD == nil or d < minD then minD = d end; last = cur end
        end
        log(string.format("timer probe: getTimeSec min tick = %s s (%.5f ms) — %s",
            tostring(minD), (minD or 0) * 1000,
            (minD ~= nil and minD < 0.0005) and "sub-ms OK for per-mod cost"
            or "COARSE: per-mod cost will be noisy"))
    end)
else
    log("timer probe: getTimeSec unavailable — per-mod cost disabled.")
end

-- Never park ourselves: the watchdog / save-guard listener must keep ticking.
local HIBERNATE_SKIP = { ["FS25_0_ModMixer"] = true, ["FS25_ModMixer"] = true }
-- Gate ONLY per-frame work (update/draw). Input (mouseEvent/keyEvent) is left LIVE: gating
-- it strands a parked mod's own menu/hotkeys → locked controls (RealisticShopping, 2026-06-08).
-- Input handlers fire only on actual input, not per-frame, so leaving them live costs nothing.
local GATED_METHODS  = { "update", "draw" }

-- Accrue elapsed time for a timed method. Multi-return-safe: orig's results pass through
-- untouched, and an error inside orig propagates exactly as it would un-wrapped (we never
-- pcall it — that would alter mod semantics + add overhead). Also tracks PEAK single-call
-- time + spike count (a periodic tick is a SPIKE, not steady cost — averages hide it) and
-- LIVE-LOGS any call over SPIKE_MS so a felt stutter can be matched to its mod by timestamp.
local SPIKE_MS = 3       -- a single frame's listener/hook/spec cost over this = a stutter contributor
local function _accrue(modName, slot, t0, ...)
    local now = _now()
    local el  = now - t0
    local c = _cost[modName]
    if c == nil then c = { upd = 0, drw = 0, frames = 0, maxMs = 0, spikes = 0, lastSpikeT = 0 }; _cost[modName] = c end
    c[slot] = c[slot] + el
    if slot == "upd" then c.frames = c.frames + 1 end
    local elMs = el * 1000
    if elMs > c.maxMs then c.maxMs = elMs end
    if elMs > SPIKE_MS then
        c.spikes = c.spikes + 1
        if now - (c.lastSpikeT or 0) > 1.0 then           -- rate-limit: <=1 log/mod/sec
            c.lastSpikeT = now
            print(string.format("[ModMixer SPIKE] %s %s took %.1f ms this frame "
                .. "(periodic tick suspect)", modName, slot, elMs))
        end
    end
    return ...
end

local function _gateListenerMethod(listener, methodName, modName)
    local orig = listener[methodName]
    if type(orig) ~= "function" then return end          -- never ADD a method that wasn't there
    if _now ~= nil and (methodName == "update" or methodName == "draw") then
        local slot = (methodName == "update") and "upd" or "drw"
        listener[methodName] = function(self, ...)
            if _hibTable[modName] then return end        -- parked → skip + cost nothing
            return _accrue(modName, slot, _now(), orig(self, ...))
        end
    else
        listener[methodName] = function(self, ...)
            if _hibTable[modName] then return end        -- parked → skip this mod's frame work
            return orig(self, ...)
        end
    end
end

local function _registerHibernatable(modName, listener)
    if modName == nil or listener == nil or HIBERNATE_SKIP[modName] then return end
    if _gatedListeners[listener] then return end          -- already gated this object
    _gatedListeners[listener] = true
    local lst = Utils.__ms_modListeners[modName]
    if lst == nil then
        lst = {}
        Utils.__ms_modListeners[modName] = lst
        Utils.__ms_hibernatable[#Utils.__ms_hibernatable + 1] = modName
    end
    lst[#lst + 1] = listener
    for _, m in ipairs(GATED_METHODS) do _gateListenerMethod(listener, m, modName) end
end

-- Registration interception. A bare-global override is env-LOCAL in FS25 (confirmed
-- in-game 2026-06-07: our _G write did NOT reach other mods → gated 0, while our
-- Utils.* override DOES reach them because Utils is a SHARED TABLE field). Engine
-- globals resolve through each mod env's metatable __index → a shared base table, so
-- to be seen by other mods the wrapper must be written THERE. We try every route and
-- log which were writable; the loadMission00Finished fallback (enumerate
-- g_modEventListeners) gates anything these miss.
if type(addModEventListener) == "function" then
    local _orig_addEvent = addModEventListener
    local _wrappedAddEvent = function(listener)
        local modName = (g_currentModName ~= nil and g_currentModName ~= "") and g_currentModName or nil
        if modName ~= nil and type(listener) == "table" then
            pcall(_registerHibernatable, modName, listener)
        end
        return _orig_addEvent(listener)
    end
    local routes = {}
    addModEventListener = _wrappedAddEvent   -- our own env (covers our own later call)
    pcall(function() _G.addModEventListener = _wrappedAddEvent; routes[#routes + 1] = "_G" end)
    pcall(function()
        local mt = getmetatable(_G)
        log("env probe: getmetatable(_G)=" .. type(mt)
            .. (type(mt) == "table" and (" __index=" .. type(mt.__index)) or ""))
        if type(mt) == "table" and type(mt.__index) == "table" then
            mt.__index.addModEventListener = _wrappedAddEvent
            routes[#routes + 1] = "mt.__index"
        end
    end)
    log("addModEventListener override routes written: "
        .. (#routes > 0 and table.concat(routes, ", ") or "NONE"))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HOOK-COST PROBE (opt-in, file-armed) — times per-mod cost INSIDE the hook chains
-- (the per-frame physics/update functions mods overwrite), which the listener cost
-- timer can't see. Default OFF with ZERO overhead: the timing wrapper is only installed
-- when modSettings/FS25_ModMixer/MODMIXER_HOOKPROBE.txt exists at load. Once armed, the
-- wrapper is boolean-gated (mmHookProbe on/off) so you can isolate live. A per-frame
-- rollup (folded into MMSaveGuard:update) catches a periodic tick whether it's one fat
-- call or spread across many vehicles in a frame. Caveat: an OVERWRITE's measured time
-- includes the inner chain it calls (superFunc); APPENDS time cleanly. Enough to name it.
-- ─────────────────────────────────────────────────────────────────────────────
local _hookProbeArmed = false
if _now ~= nil and type(getUserProfileAppPath) == "function" and type(fileExists) == "function" then
    local dir = getUserProfileAppPath() .. "modSettings/FS25_ModMixer/"
    _hookProbeArmed = fileExists(dir .. "MODMIXER_HOOKPROBE.txt")
end
Utils.__ms_hookProbe = Utils.__ms_hookProbe or { on = _hookProbeArmed }
Utils.__ms_hookCost  = Utils.__ms_hookCost  or {}
Utils.__ms_hookArmed = _hookProbeArmed   -- UI reads this (Performance tier) to know if hook/spec cost is live
local _hp       = Utils.__ms_hookProbe
local _hookCost = Utils.__ms_hookCost
if _hookProbeArmed then
    log("HOOK PROBE ARMED (MODMIXER_HOOKPROBE.txt present) — timing named hook chains. "
        .. "mmHookCost to read, mmHookProbe on/off to toggle, mmHookProbeReset to zero. "
        .. "Delete the file + restart to disarm.")
end

-- Accrue a hooked call's time into a per-(mod,target) entry's running + per-frame totals
-- (per-frame field rolled up by MMSaveGuard:update). Multi-return-safe; never pcalls fn.
local function _accrueHook(c, t0, ...)
    local el = _now() - t0
    c.t = c.t + el; c.n = c.n + 1; c.frameT = c.frameT + el
    return ...
end

-- One cost entry per mod+target so the readout/spike log names the exact function. The
-- entry is captured in the closure (no per-call lookup). target nil = a hook outside the
-- named set (shown as "(untracked)") — still attributed to the mod that installed it.
local function _wrapHookTiming(mod, target, fn)
    local key = mod .. "|" .. (target or "(untracked)")
    local c = _hookCost[key]
    if c == nil then
        c = { mod = mod, target = target or "(untracked)", t = 0, n = 0, maxMs = 0,
              spikes = 0, lastSpikeT = 0, frameT = 0 }
        _hookCost[key] = c
    end
    return function(...)
        if not _hp.on then return fn(...) end
        return _accrueHook(c, _now(), fn(...))
    end
end

-- SPEC-UPDATE PROBE (same file-arm as the hook probe). Vehicle/implement specializations
-- register their per-frame work via SpecializationUtil.registerEventListener(type, "onUpdate"
-- / "onUpdateTick", specTable) — NOT through Utils.* or addModEventListener, so neither the
-- hook nor listener probe can see them (this is the field-work-implement tick's hiding spot).
-- We wrap that registration and time the spec fn, routed through the SAME _hookCost path so it
-- shows in mmHookCost / the spike log as "<specName> -> spec:onUpdate". Attribution: the spec's
-- registered name via g_specializationManager (best), else the loading mod, else a stable id.
-- Dedupe by fn (a spec fn is shared across vehicle types). Multi-return-safe, never pcalls fn.
if _hookProbeArmed and type(SpecializationUtil) == "table"
   and type(SpecializationUtil.registerEventListener) == "function" then
    local _specWrapped = {}
    local _SPEC_EVENTS = { onUpdate = true, onUpdateTick = true }
    local _specSeq = 0

    local function _specLabel(specTable)
        local ok, nm = pcall(function()
            local mgr = g_specializationManager
            if mgr == nil then return nil end
            for _, lst in ipairs({ mgr.specializationsByName, mgr.specializations }) do
                if type(lst) == "table" then
                    for k, e in pairs(lst) do
                        if e == specTable then return (type(k) == "string") and k or nil end
                        if type(e) == "table" and (e.object == specTable
                           or e.specializationObject == specTable) then
                            return e.name or ((type(k) == "string") and k or nil)
                        end
                    end
                end
            end
            return nil
        end)
        if ok and type(nm) == "string" then return nm end
        if g_currentModName ~= nil and g_currentModName ~= "" then return g_currentModName end
        _specSeq = _specSeq + 1
        return "spec#" .. _specSeq
    end

    local _orig_regEL = SpecializationUtil.registerEventListener
    SpecializationUtil.registerEventListener = function(vehicleType, eventName, specTable)
        if _SPEC_EVENTS[eventName] and type(specTable) == "table" then
            local fn = specTable[eventName]
            if type(fn) == "function" and not _specWrapped[fn] then
                local label = _specLabel(specTable)
                if not HIBERNATE_SKIP[label] then
                    _specWrapped[fn] = true
                    local wrapped = _wrapHookTiming(label, "spec:" .. eventName, fn)
                    _specWrapped[wrapped] = true   -- don't re-wrap if a later type re-registers
                    local _ek = label .. "|spec:" .. eventName
                    if _hookCost[_ek] then _hookCost[_ek].specTable = specTable end  -- for lazy name resolve
                    specTable[eventName] = wrapped
                end
            end
        end
        return _orig_regEL(vehicleType, eventName, specTable)
    end
    log("SPEC PROBE armed: timing specializations' onUpdate/onUpdateTick (→ mmHookCost).")
end

-- Resolve a spec module table → its registered name, via g_specializationManager (built
-- once, lazily, at runtime when the manager is fully populated). Used by the per-frame
-- rollup to relabel "spec#N" entries with real names (e.g. "cultivator", "mulching").
local _specRevMap = nil
local function _buildSpecRevMap()
    _specRevMap = {}
    -- Scan ALL THREE spec managers (vehicle / placeable / hand-tool) so placeable + handtool
    -- specs resolve to names too, not just vehicle ones (the main source of leftover spec#N).
    local mgrs = { g_specializationManager, g_placeableSpecializationManager, g_handToolSpecializationManager }
    local scanned, mapped = 0, 0
    for _, mgr in ipairs(mgrs) do
        if type(mgr) == "table" then
            local lists = {}
            if type(mgr.specializations) == "table" then lists[#lists + 1] = mgr.specializations end
            if type(mgr.specializationsByName) == "table" then lists[#lists + 1] = mgr.specializationsByName end
            for _, lst in ipairs(lists) do
                for k, e in pairs(lst) do
                    scanned = scanned + 1
                    local name = (type(k) == "string") and k or nil
                    if type(e) == "table" then
                        if name ~= nil and _specRevMap[e] == nil then _specRevMap[e] = name; mapped = mapped + 1 end
                        name = (type(e.name) == "string" and e.name) or name
                        local objs = { e.object, e.specializationObject, e.specialization }
                        if type(e.className) == "string" then objs[#objs + 1] = (rawget(_G, e.className) or _G[e.className]) end
                        for _, o in ipairs(objs) do
                            if type(o) == "table" and name ~= nil and _specRevMap[o] == nil then
                                _specRevMap[o] = name; mapped = mapped + 1
                            end
                        end
                    end
                end
            end
        end
    end
    log(string.format("specmap: scanned=%d mapped=%d (vehicle+placeable+handtool managers)", scanned, mapped))
end
local function _resolveSpecName(specTable)
    if specTable == nil then return nil end
    if _specRevMap == nil then pcall(_buildSpecRevMap) end
    return _specRevMap and _specRevMap[specTable] or nil
end

-- Curated TARGET functions to name (and allow vetoing). Bounded list — NOT every
-- method of a class (a metatable __index can lead into a huge shared table and
-- over-name). Grow from the conflict catalogue as needed.
-- NOTE: pruned 2026-06-06 — entries whose CLASS resolves but METHOD never does in FS25
-- (confirmed dead by the snapshot "never resolved" audit): WheelPhysics.updateWheelFriction,
-- WheelsUtil.updateWheelsPhysicsGroundContact, Motorized.getMaxPtoRpm,
-- Motorized.getUseAutomaticGearShifting/getUseAutomaticGroupShifting, Vehicle.onUpdate,
-- Wearable.setOperatingTime. They were FS22 names / guesses that matched nothing.
local TARGETS = {
    "WheelPhysics.serverUpdate", "WheelPhysics.finalize", "WheelPhysics.updatePhysics",
    "WheelPhysics.updateTireFriction", "WheelPhysics.updateFriction",
    "WheelPhysics.updateContact",
    "WheelsUtil.updateWheelsPhysics",
    "WheelsUtil.getSmoothedAcceleratorAndBrakePedals",
    "Drivable.updateVehiclePhysics",
    "Motorized.updateConsumers", "Motorized.onUpdate",
    "Vehicle.update", "Vehicle.updateTick", "Vehicle.load", "Vehicle.getSpeedLimit",
    "FSBaseMission.update", "FSBaseMission.sendInitialClientState", "FSBaseMission.onConnectionFinishedLoading",
    "Sprayer.processSprayerArea", "Cutter.onEndWorkAreaProcessing",
    "BunkerSilo.update", "BunkerSilo.load", "BunkerSilo.loadFromXMLFile",
    "PlayerHUDUpdater.showSplitShapeInfo", "PlayerHUDUpdater.showFieldInfo",
    "ConstructionBrush.verifyAccess", "Farm.changeBalance", "InfoDialog.show",
    "VehicleMaterial.apply", "VehicleMaterial.applyToVehicle",
    "PlaceableProductionPoint.onFinalizePlacement", "ProductionPoint.load",
    "DensityMapHeightManager.loadMapData", "Weather.update",
    -- Damage / Wear — vehicle-health fns damage overhauls (ADS) overwrite via specs.
    "Wearable.updateDamageAmount",
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
local _pending = nil     -- TARGET strings whose class/method wasn't defined at first snapshot
local _sealed  = false   -- stop retrying once the map is fully loaded (post loadMission00Finished)

-- Returns true once the target is named (or is unnameable garbage), false if its class or
-- method isn't available YET — so the caller keeps it pending and retries on a later hook.
local function snapshotOne(qualified)
    local class, method = string.match(qualified, "^([^.]+)%.(.+)$")
    if class == nil or method == nil then return true end
    local C = safeGlobal(class)
    if type(C) ~= "table" then return false end          -- class not defined yet → pending
    local fn = C[method]                                  -- non-raw read: resolves inherited too
    if type(fn) ~= "function" then return false end       -- method not present yet → pending
    if Utils.__ms_fnNames[fn] == nil then Utils.__ms_fnNames[fn] = qualified end
    return true
end
local function buildNameMap()
    _pending = {}
    local function consider(q)
        if not snapshotOne(q) then _pending[#_pending + 1] = q end
    end
    -- Curated core (hardcoded above = guaranteed even if the dataset is missing) …
    for _, q in ipairs(TARGETS) do consider(q) end
    -- … plus the WIDER net: discovered conflict targets from the bundled dataset
    -- (tools/gen_targets.py — every Class.method 2+ mods overwrite in this install).
    if type(ModMixerTargets) == "table" then
        for _, q in ipairs(ModMixerTargets) do consider(q) end
    end
end
-- One-shot first pass, then RE-TRY the still-unresolved targets on each later hook. Some
-- engine classes — notably HUD/GUI tables like GameInfoDisplay — are defined AFTER our
-- first snapshot, so their ORIGINAL fn must be captured the moment the class appears and
-- before a mod wraps it. Retrying here (patched() calls this BEFORE resolving the target)
-- means even the FIRST mod to hook a late class still gets named: we snapshot C.method,
-- which == that hook's existingFn, just-in-time. Self-terminating: stops the moment
-- _pending empties, and is sealed after map load so never-present classes cost nothing.
local function ensureSnapshot()
    if not _snapped then
        _snapped = true
        pcall(buildNameMap)
    elseif not _sealed and _pending ~= nil and #_pending > 0 then
        local still = {}
        for _, q in ipairs(_pending) do
            if not snapshotOne(q) then still[#still + 1] = q end
        end
        _pending = still
    end
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

-- ─────────────────────────────────────────────────────────────────────────────
-- SAVE WATCHDOG (boot state) — load-time half. We persist a single PHASE across boots
-- in boot_state.xml: "pending" (a lever boot started but never confirmed healthy),
-- "ok" (confirmed healthy), or "recovered" (we auto-disabled levers after a pending).
-- Reading "pending" at the next boot means the previous lever boot bricked/hung/crashed,
-- so we auto-disable levers this boot to recover the player hands-free.
--
-- WHY a phase and not a delete-the-flag file: deleteFile is unreliable here — confirmed
-- 2026-06-06 it silently no-op'd at BOTH early load AND runtime, which would have trapped
-- the player in permanent safe mode. createXMLFile/saveXMLFile/getXMLString ARE proven
-- (it's how switchboard.xml round-trips), so we only ever OVERWRITE the phase, never
-- delete. WRITES happen at runtime (the listener); the READ happens here at early load.
local _safeModeActive   = false   -- levers disabled this boot (manual kill switch OR auto-recovery)
local _autoRecovered    = false   -- disabled specifically because the prior boot never confirmed
local _safeModeResolved = false   -- resolve the decision + log it exactly once
local _leversActive     = false   -- set once we know vetoes/reorders are actually being applied

local function _statePath(dir) return dir .. "boot_state.xml" end

local function _readPhase(dir)
    if dir == nil or type(loadXMLFile) ~= "function" then return nil end
    local p = _statePath(dir)
    if type(fileExists) == "function" and not fileExists(p) then return nil end
    local xml = loadXMLFile("MMBootRead", p)
    if xml == nil or xml == 0 then return nil end
    local phase = (type(getXMLString) == "function") and getXMLString(xml, "modmixerBoot#phase") or nil
    if type(delete) == "function" then delete(xml) end
    return phase
end

-- Overwrite the persisted phase. Runtime-only callers (createXMLFile is proven there).
-- Returns true on a confirmed write so callers can log/verify.
local function _writePhase(dir, phase)
    if dir == nil or type(createXMLFile) ~= "function" then return false end
    if type(createFolder) == "function" then pcall(createFolder, dir) end
    local ok = false
    pcall(function()
        local x = createXMLFile("MMBootWrite", _statePath(dir), "modmixerBoot")
        if x == nil or x == 0 then return end
        if type(setXMLString) == "function" then
            setXMLString(x, "modmixerBoot#phase", phase)
            setXMLString(x, "modmixerBoot#ts",
                (type(getDate) == "function" and getDate("%Y-%m-%d %H:%M:%S")) or "")
        end
        if type(saveXMLFile) == "function" then saveXMLFile(x) end
        if type(delete) == "function" then delete(x) end
        ok = true
    end)
    return ok
end

-- Decide ONCE whether load-time levers run this boot. Disable them for either reason:
--   • manual kill switch (MODMIXER_SAFE_MODE.txt) — user-triggered recovery, or
--   • watchdog auto-recovery — phase=="pending" left by a previous unconfirmed boot.
local function _resolveSafeMode(dir)
    if _safeModeResolved then return _safeModeActive end
    _safeModeResolved = true
    if _mmSafeMode(dir) then
        _safeModeActive = true
        log("SAFE MODE: kill-switch file present — all vetoes + reorders ignored this load.")
    elseif _readPhase(dir) == "pending" then
        _safeModeActive = true
        _autoRecovered  = true
        log("AUTO SAFE MODE: the previous boot applied ModMixer levers but never confirmed a")
        log("  healthy load (brick / hang / crash). Levers are DISABLED this boot so you can")
        log("  recover hands-free. Your config is untouched; the next boot returns to normal.")
        log("  If it bricks again with levers on, one specific veto is at fault — check the")
        log("  Switchboard for the contested target and lock or re-decide it.")
    end
    return _safeModeActive
end

local _vetoSet = {}
local function readVetoes()
    if type(getUserProfileAppPath) ~= "function" or type(loadXMLFile) ~= "function" then return end
    local dir = getUserProfileAppPath() .. "modSettings/FS25_ModMixer/"
    if _resolveSafeMode(dir) then return end
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
    if _resolveSafeMode(dir) then return end
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
    -- Constructors of core, persisted save-state objects. Vetoing one mod's hook
    -- here HALF-INITIALISES the object: the mod's OTHER hooks still run and read
    -- fields the constructor never created -> the savegame's farm/economy load
    -- throws and aborts, leaving 0 money + no owned vehicles (no Tab control).
    -- Confirmed brick 2026-06-06: vetoing FS25_SeasonalTires -> Farm.new. NEVER vetoable.
    ["Farm.new"] = true,
}
Utils.__ms_noVeto = NO_VETO

-- Beyond the explicit list above, protect the whole CLASS of load-critical hooks by
-- name pattern. Vetoing a constructor or init/load hook half-initialises a mod -> its
-- other hooks read state that was never created -> the save bricks. We refuse vetoes
-- on these by pattern so we stop finding them one brick at a time (Farm.new was the
-- last one found the hard way). OVER-protecting is safe: the worst case is a veto the
-- user wanted is logged as "VETO IGNORED", never a brick. UNDER-protecting loses saves.
local LOAD_CRITICAL_PATTERNS = {
    "%.new$",                          -- constructors: Farm.new, Vehicle.new, ...
    "%.load$",                         -- X:load(...)
    "%.loadFromXMLFile$",
    "%.onLoad$", "%.onPreLoad$", "%.onPostLoad$",
    "%.loadMapData$",
    "%.onFinalizePlacement$",
    "%.onConnectionFinishedLoading$",
    "%.sendInitialClientState$",
}
local _lcCache = {}
local function isLoadCritical(target)
    if target == nil then return false end
    if NO_VETO[target] then return true end
    local cached = _lcCache[target]
    if cached ~= nil then return cached end
    local hit = false
    for _, pat in ipairs(LOAD_CRITICAL_PATTERNS) do
        if string.find(target, pat) ~= nil then hit = true; break end
    end
    _lcCache[target] = hit
    return hit
end
Utils.__ms_isLoadCritical = isLoadCritical

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

-- ─────────────────────────────────────────────────────────────────────────────
-- STOMP DETECTOR — turn the static "[ow!] MIGHT stomp" guess into a runtime VERDICT.
-- For a non-load-critical overwrite we build the chain OURSELVES so we can hand the mod's
-- function a TRACKED superFunc and watch (one-shot, on the first call) whether it actually
-- calls through. If it ran WITHOUT calling super, it discarded the mods below it = CONFIRMED
-- stomp. After that one shot the wrapper is byte-for-byte the stock behaviour
-- (impl(superFunc, ...)), so there's zero ongoing cost. Disabled in safe mode (recovery).
-- ─────────────────────────────────────────────────────────────────────────────
-- STOMP VERDICT MAP — kept as an (intentionally never-populated) table so the Advanced view's
-- lookup stays safe. We deliberately do NOT confirm stomps at runtime.
--
-- WHY NOT: confirming "did this overwrite call through?" means replacing GIANTS' overwrite
-- wrapper for the ~100 contested functions. On a real stack that SILENTLY HANGS the async map
-- i3d load at ~20% — reproduced on 2026-06-08 with two independent, sound wrapper designs:
--   (1) wrapped-super (hand the impl a tracked super), and
--   (2) identity-safe run-ledger (impl gets the REAL super byte-for-byte; detection lives in
--       our own wrapper via a per-link sequence stamp).
-- Both hang identically, with no Lua error — so the cause is not super identity, it is the mere
-- act of substituting our closure on that hot path during the fragile async-load phase. The
-- juice is not worth the squeeze: a published mod must never risk a user's load to confirm a
-- guess. The Advanced view shows the STATIC estimate instead — the outermost overwrite on a
-- contested target is [ow!] (positioned to discard the mods below it), which is the actionable
-- signal the user actually asked for.
Utils.__ms_stompVerdict = Utils.__ms_stompVerdict or {}   -- intentionally never populated

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
        if isLoadCritical(target) then
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
    if target ~= nil and isReordered(target) and not isLoadCritical(target) then
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

    -- Hook-cost probe: when armed, install the mod's impl wrapped in a (boolean-gated)
    -- timing layer so we can measure its per-frame cost INSIDE the chain. record() still
    -- stores the ORIGINAL newFn as the impl (display / distinct-impl tally are unchanged).
    -- Widened beyond the named set: a periodic tick is usually ONE mod's solo work on a
    -- function only it hooks (so not "contested"/named) — attribute those to the installer.
    local implToInstall = newFn
    if _hookProbeArmed then
        local hookMod = mod or ((target == nil) and resolveMod()) or nil
        if hookMod ~= nil then implToInstall = _wrapHookTiming(hookMod, target, newFn) end
    end
    -- Always install via GIANTS' own wrapper (orig). We never substitute our closure on the
    -- overwrite hot path — see the STOMP VERDICT MAP note above for why (it hangs the load).
    local result = orig(existingFn, implToInstall)
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
        -- WATCHDOG arm: this boot is applying levers. The listener writes phase="pending"
        -- at runtime (loadMap) and flips it to "ok" once the farm loads healthy. If we never
        -- get there (brick/hang/crash) it stays "pending" and the NEXT boot auto-recovers.
        if not _safeModeActive then
            _leversActive = true
        end
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

    -- ── Hibernate coverage: how many listeners we can park live ───────────────
    -- A non-trivial count here proves addModEventListener interception reached other
    -- mods (cross-mod _G write worked). If this is ~0, parking won't catch anything —
    -- the empirical check before we trust the feature.
    do
        local nL, nM = 0, 0
        for _, lst in pairs(Utils.__ms_modListeners) do nM = nM + 1; nL = nL + #lst end
        log(string.format("HIBERNATE: gated %d listener(s) across %d mod(s) — park any live via the "
            .. "Switchboard or  mmHibernate <ModName>  (mmHibernateList for names).", nL, nM))
    end

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

-- Fallback hibernate registration: if registration interception didn't reach other
-- mods, enumerate the engine's listener list at map-load and gate each listener we can
-- attribute to a mod by scanning mod env namespaces (a mod's listener is usually a
-- table field of its env, _G[modName].<field> == listener). Best-effort; logs coverage.
-- Runs ONCE at loadMission00Finished, before coverageLog (so its gated count is final).
local function _hibernateFallbackScan()
    local list = safeGlobal("g_modEventListeners")
    log("hibernate fallback: g_modEventListeners type=" .. type(list)
        .. (type(list) == "table" and (" count=" .. tostring(#list)) or ""))
    if type(list) ~= "table" or #list == 0 then return end
    -- object -> modName via a one-level scan of each installed mod's env namespace.
    local objToMod = {}
    if g_modManager ~= nil and type(g_modManager.mods) == "table" then
        for _, mod in ipairs(g_modManager.mods) do
            local modName = mod and mod.modName
            local env = modName and safeGlobal(modName)
            if type(env) == "table" then
                pcall(function()
                    for _, v in pairs(env) do
                        if type(v) == "table" and objToMod[v] == nil then objToMod[v] = modName end
                    end
                end)
            end
        end
    end
    local newlyGated, unattributed = 0, 0
    for _, listener in ipairs(list) do
        if type(listener) == "table" and not _gatedListeners[listener] then
            local modName = objToMod[listener]
            if modName ~= nil and not HIBERNATE_SKIP[modName] then
                pcall(_registerHibernatable, modName, listener)
                newlyGated = newlyGated + 1
            else
                unattributed = unattributed + 1
            end
        end
    end
    log(string.format("hibernate fallback: gated %d listener(s) via enumeration, %d unattributed "
        .. "(local/unnamed listeners we can't pin to a mod).", newlyGated, unattributed))
end

if Mission00 ~= nil and type(Mission00.loadMission00Finished) == "function" and _orig_append then
    -- pcall wrapper: coverageLog is diagnostic only — an error here must NEVER
    -- propagate into loadMission00Finished and hang the load sequence.
    Mission00.loadMission00Finished = _orig_append(Mission00.loadMission00Finished, function(...)
        ensureSnapshot()           -- final retry pass for any late-defined classes
        if _pending ~= nil and #_pending > 0 then
            log(string.format("snapshot: %d target(s) never resolved (class absent in this "
                .. "install): %s", #_pending, table.concat(_pending, ", ")))
        end
        _sealed = true             -- everything that will exist is defined now; stop retrying
        pcall(_hibernateFallbackScan)   -- gate listeners reg-interception missed
        local ok, err = pcall(coverageLog)
        if not ok then log("coverageLog error (non-fatal): " .. tostring(err)) end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SAVE GUARD — runtime half of the watchdog. ONLY armed when this boot actually
-- applied levers (so a vanilla / safe-mode load is never touched). Once the mission
-- is fully started we confirm the local player is on a real farm. If so → write phase
-- "ok" (this boot is proven healthy). If NOT (the brick signature: spectator / no farm)
-- → leave phase "pending" (next boot auto-recovers) AND block saves this session so an
-- autosave can't overwrite the good on-disk save with the broken state.
-- ─────────────────────────────────────────────────────────────────────────────
local MMSaveGuard = { started = false, checked = false, grace = 0, wrapped = false, blockOn = false }

-- True only when the local player is genuinely assigned to a real (non-spectator) farm.
local function _farmHealthy()
    local mc = g_currentMission
    if mc == nil or type(mc.getFarmId) ~= "function" then return false end
    local farmId = mc:getFarmId()
    if farmId == nil or farmId == 0 then return false end
    if FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID then return false end
    if g_farmManager ~= nil and type(g_farmManager.getFarmById) == "function"
        and g_farmManager:getFarmById(farmId) == nil then return false end
    return true
end

-- Wrap g_currentMission:saveSavegame at the instance level so EVERY save path (auto +
-- manual) routes through us. We only refuse while blockOn is set (a confirmed bad load).
local function _installSaveBlock()
    if MMSaveGuard.wrapped then return end
    local mc = g_currentMission
    if mc == nil or type(mc.saveSavegame) ~= "function" then return end
    local orig = mc.saveSavegame
    mc.saveSavegame = function(self, ...)
        if MMSaveGuard.blockOn then
            log("SAVE BLOCKED: this session loaded with no valid farm (likely a veto/conflict "
                .. "brick). Refusing to save so your on-disk savegame stays intact. Quit WITHOUT "
                .. "saving and restart — ModMixer auto-disables levers on the next boot.")
            if type(self.showBlinkingWarning) == "function" then
                pcall(self.showBlinkingWarning, self,
                    "ModMixer: abnormal load (no farm) - SAVE BLOCKED to protect your savegame. "
                    .. "Restart to recover.", 8000)
            end
            return
        end
        return orig(self, ...)
    end
    MMSaveGuard.wrapped = true
end

-- Reset per mission load — a new mission gets a fresh g_currentMission + farm.
function MMSaveGuard:loadMap(name)
    -- Persist this boot's phase at runtime (createXMLFile is reliable here, unlike deleteFile).
    -- Auto-recovery boot -> "recovered" (clears the prior "pending" so the NEXT boot is normal).
    -- A normal lever boot -> "pending" until the health check below flips it to "ok". Manual
    -- safe-mode boots touch nothing.
    local dir = (type(getUserProfileAppPath) == "function")
        and (getUserProfileAppPath() .. "modSettings/FS25_ModMixer/") or nil
    if dir ~= nil then
        if _autoRecovered then
            local ok = _writePhase(dir, "recovered")
            log("watchdog: phase -> recovered (auto-recovery boot) " .. (ok and "[written]" or "[WRITE FAILED]"))
        elseif _leversActive and not _safeModeActive then
            local ok = _writePhase(dir, "pending")
            log("watchdog: phase -> pending (lever boot armed) " .. (ok and "[written]" or "[WRITE FAILED]"))
        end
    end
    MMSaveGuard.started = false
    MMSaveGuard.checked = false
    MMSaveGuard.grace   = 0
    MMSaveGuard.wrapped = false
    MMSaveGuard.blockOn = false
end

function MMSaveGuard:update(dt)
    -- Frame-time tracker (runs ALWAYS, even in safe mode): dt = wall-clock ms this frame =
    -- the per-frame "cycle time" + gives FPS. Reset by mmCostReset; shown atop mmCost. This
    -- listener is never gated (we skip ourselves), so it's a reliable per-frame tick.
    local _f = Utils.__ms_frame
    -- Clamp out pause/load frames so the average isn't poisoned: a real frame is < 1000ms
    -- even at 1fps; anything above is the game PAUSED (alt-tab, loading), not a slow frame.
    if _f ~= nil and dt ~= nil and dt > 0 and dt < 1000 then
        _f.acc = _f.acc + dt; _f.n = _f.n + 1
        if dt > (_f.maxMs or 0) then _f.maxMs = dt end   -- worst frame = the tick's magnitude
    end
    -- Hook-probe per-frame rollup (only when armed + on): fold each mod's accumulated hook
    -- time THIS frame into its peak + spike detection, then reset. Catches a periodic hook
    -- tick whether concentrated in one call or spread across many vehicles in the frame.
    if _hp.on and _now ~= nil then
        local hnow = _now()
        for _, c in pairs(_hookCost) do
            if c.specTable ~= nil and not c.specResolved then   -- relabel spec#N → real name, once
                c.specResolved = true
                local nm = _resolveSpecName(c.specTable)
                if nm ~= nil then c.mod = nm end
            end
            local fMs = (c.frameT or 0) * 1000
            if fMs > (c.maxMs or 0) then c.maxMs = fMs end
            if fMs > SPIKE_MS then
                c.spikes = (c.spikes or 0) + 1
                if hnow - (c.lastSpikeT or 0) > 1.0 then
                    c.lastSpikeT = hnow
                    print(string.format("[ModMixer HOOK SPIKE] %s -> %s used %.1f ms this frame "
                        .. "(periodic tick suspect)", c.mod, c.target, fMs))
                end
            end
            c.frameT = 0
        end
    end
    if _safeModeActive or not _leversActive then return end   -- nothing we did could brick this boot
    if g_currentMission == nil then return end
    if not MMSaveGuard.wrapped then pcall(_installSaveBlock) end
    if MMSaveGuard.checked or not MMSaveGuard.started then return end
    -- single-player only: in MP the save is server-authoritative and a joining client's
    -- farm assignment can legitimately lag — never risk a false positive there.
    if g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer == true then
        MMSaveGuard.checked = true
        return
    end
    MMSaveGuard.grace = MMSaveGuard.grace + (dt or 0)
    if MMSaveGuard.grace < 1500 then return end   -- let farm assignment settle after start
    MMSaveGuard.checked = true
    local dir = (type(getUserProfileAppPath) == "function")
        and (getUserProfileAppPath() .. "modSettings/FS25_ModMixer/") or nil
    if _farmHealthy() then
        local ok = _writePhase(dir, "ok")
        log("BOOT CONFIRMED HEALTHY: farm loaded with levers on — watchdog phase -> ok "
            .. (ok and "[written]." or "[WRITE FAILED — tell the dev]."))
    else
        MMSaveGuard.blockOn = true
        log("ABNORMAL LOAD: no valid farm after the mission started (spectator/none) — the brick "
            .. "signature. Keeping the watchdog sentinel (next boot auto-disables levers) and "
            .. "BLOCKING saves this session to protect your savegame.")
        local mc = g_currentMission
        if type(mc.showBlinkingWarning) == "function" then
            pcall(mc.showBlinkingWarning, mc,
                "ModMixer: this load looks broken (no farm). Saves are BLOCKED to protect your "
                .. "savegame. Quit without saving and restart to recover.", 12000)
        end
    end
end

-- "Mission fully started" is the only safe moment to judge farm health: it fires AFTER
-- all loading completes, so it can't false-positive on a long load (yours stream vehicles
-- for minutes). On a hang the mission never starts -> we never clear -> next boot recovers.
if Mission00 ~= nil and type(Mission00.onStartMission) == "function" and _orig_append then
    Mission00.onStartMission = _orig_append(Mission00.onStartMission, function(...)
        MMSaveGuard.started = true
        MMSaveGuard.grace   = 0
    end)
end

if type(addModEventListener) == "function" then
    addModEventListener(MMSaveGuard)
end
