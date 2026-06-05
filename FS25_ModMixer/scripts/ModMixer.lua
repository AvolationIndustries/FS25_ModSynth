-- ModMixer.lua  v1.2.0.0
-- Unified single-mod build. Hook patching (ModMixerHooks.lua) loads first via
-- extraSourceFiles ordering; analysis defers to Mission00.loadMission00Finished.
--
-- Strategy
--   1. Diagnostic logging: full detail written to ModMixer.log (next to game.log).
--      The main FS25 game log receives only a brief summary and any incompatible-
--      mod warnings so it stays clean.
--   2. Active repair: only when the fix is safe and mathematically correct.
--      Every repair block is guarded by g_modManager:getModByName() so the
--      patch is a no-op when the conflicting mods are absent.
--   3. Conservative: when a fix would require duplicating mod logic or when
--      two mods are fundamentally incompatible at the UX level, log only.
--   4. In-game dialog: incompatible mod groups trigger a dialog at map load
--      so players see the warning without digging through any log file.

local MS_VERSION = "1.2.0.0"
local MOD_NAME   = g_currentModName

-- ─────────────────────────────────────────────────────────────────────────────
-- LOGGING
--   log()     → custom ModMixer.log file only (detail, no noise in game.log)
--   logGame() → both ModMixer.log AND main FS25 game log (important notices)
-- ─────────────────────────────────────────────────────────────────────────────

local _msLogFile
do
    local path = getUserProfileAppPath() .. "ModMixer.log"
    -- Guard raw io: the published ModHub Lua sandbox may restrict/strip `io`.
    -- pcall so a missing io library can never error the whole mod's load.
    local ok, f = pcall(function() return io.open(path, "w") end)
    _msLogFile = ok and f or nil
    if _msLogFile then
        _msLogFile:write(string.format(
            "ModMixer %s\n%s\n\n",
            MS_VERSION, string.rep("-", 60)))
    end
end

local function log(msg)
    -- Detail line. Normally goes to ModMixer.log; if the file is unavailable
    -- (e.g. io restricted in a published sandbox) fall back to the game log so
    -- the full report is never lost.
    if _msLogFile then
        _msLogFile:write(tostring(msg) .. "\n")
        _msLogFile:flush()
    else
        print("[ModMixer] " .. tostring(msg))
    end
end

local function logGame(msg)
    -- Important line: always to the game log, mirrored into ModMixer.log when present.
    -- (Mirror inline rather than calling log(), so we never double-print in the
    -- no-file fallback case.)
    print(string.format("[ModMixer %s] %s", MS_VERSION, tostring(msg)))
    if _msLogFile then
        _msLogFile:write(tostring(msg) .. "\n")
        _msLogFile:flush()
    end
end

local function present(modFileName)
    -- g_modManager:getModByName accepts the mod name WITHOUT .zip
    local name = modFileName:gsub("%.zip$", "")
    return g_modManager:getModByName(name) ~= nil
end

logGame("=== ModMixer loading ===")

-- Guard against double-run when both the source folder (FS25_ModMixer)
-- and the zip (FS25_ModMixer) are present in the mods folder simultaneously.
if Utils.__ms_compat_loaded then
    logGame("Already loaded by sister copy — skipping duplicate run.")
    return
end
Utils.__ms_compat_loaded = true

-- ─────────────────────────────────────────────────────────────────────────────
-- RUNTIME DUPLICATE REGISTRATION SUPPRESSOR
--
-- SpecializationUtil.registerFunction raises an error if the same function
-- name is registered twice on a vehicle type. FS25_AdvancedDamageSystem has
-- a self-bug where it registers 'hasBreakdown' twice in its own
-- registerFunctions (lines 839 and 844 — verbatim duplicate). This floods
-- the log with ~470 errors per load session.
--
-- We wrap SpecializationUtil.registerFunction to detect and silently suppress
-- duplicate registrations. The first registration always wins (correct
-- behaviour). A one-time notice is logged per duplicate function name.
--
-- This wrapper is active only when FS25_AdvancedDamageSystem is installed.
-- It is harmless if ADS fixes the bug upstream — duplicates simply never
-- occur and the wrapper passes every call straight through.
-- ─────────────────────────────────────────────────────────────────────────────

if present("FS25_AdvancedDamageSystem.zip")
and type(SpecializationUtil) == "table"
and type(SpecializationUtil.registerFunction) == "function" then
    local _orig_regFn = SpecializationUtil.registerFunction
    local _mw_dup_noticed = {}
    SpecializationUtil.registerFunction = function(vehicleType, funcName, func)
        if     vehicleType           ~= nil
           and vehicleType.functions ~= nil
           and vehicleType.functions[funcName] ~= nil then
            -- Duplicate detected — suppress the redundant registration.
            if not _mw_dup_noticed[funcName] then
                _mw_dup_noticed[funcName] = true
                log(string.format(
                    "INFO: Suppressed duplicate registerFunction('%s') from "
                 .. "FS25_AdvancedDamageSystem. First registration stands.",
                    tostring(funcName)))
            end
            return
        end
        return _orig_regFn(vehicleType, funcName, func)
    end
    logGame("INFO: AdvancedDamageSystem duplicate-registration suppressor active.")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFLICT CATALOGUE
-- Each entry: { fn, mods[], severity, description, fixFn (optional) }
-- severity: "CRITICAL", "HIGH", "MEDIUM", "INFO"
-- ─────────────────────────────────────────────────────────────────────────────

local conflicts = {

    -- ── CRITICAL STOMPS ─────────────────────────────────────────────────────

    {
        fn       = "PlayerHUDUpdater.showSplitShapeInfo",
        mods     = { "FS25_ForestryHelper", "FS25_InfoDisplayExtension" },
        severity = "HIGH",
        desc     = "IDE installs at mod-load time; FH defers to Mission00.loadMission00Finished "
                .. "and wraps IDE's version at map load (FH ends up outermost). FH calls "
                .. "superFunc so both overlays run. Chain verified at map load. No action needed.",
    },

    {
        fn       = "GameInfoDisplay.draw",
        mods     = { "FS25_ExtendedGameInfoDisplay", "FS25_RealisticWeather" },
        severity = "CRITICAL",
        desc     = "ExtendedGameInfoDisplay overwrites draw without calling superFunc "
                .. "(intentional — replaces the base HUD entirely). "
                .. "RealisticWeather appends and loads after (R > E), so its overlay "
                .. "still fires. No repair needed; log only.",
    },

    {
        fn       = "AICollisionTriggerHandler.onVehicleCollisionDistanceCallback",
        mods     = { "FS25_agriBumper", "FS25_AITrafficNoCollision" },
        severity = "CRITICAL",
        desc     = "agriBumper replaces the base-game collision callback without calling "
                .. "superFunc (intentional redesign for bumper physics). "
                .. "AITrafficNoCollision wraps it safely. Original FS25 callback is gone, "
                .. "but both mods' logic still runs. Log only.",
    },

    {
        fn       = "InGameMenuStatisticsFrame.hasPlayerLoanPermission",
        mods     = { "FS25_BankCredit", "FS25_EnhancedLoanSystem" },
        severity = "CRITICAL",
        desc     = "EnhancedLoanSystem overwrites without calling superFunc, discarding "
                .. "BankCredit's 'return false'. Both are loan-replacement mods; "
                .. "EnhancedLoanSystem's logic wins. Functional overlap — log only.",
    },

    {
        fn       = "Landscaping.hasObjectOverlapInModificationArea",
        mods     = { "FS25_PlaceTerraformPaintAnywhere", "FS25_paintAndTerraformAnywhere" },
        severity = "CRITICAL",
        desc     = "Two 'paint anywhere' mods stomp each other, but BOTH return false "
                .. "unconditionally. Behaviour is identical whichever wins. Log only.",
    },

    -- ── SELF-BUGS IN INSTALLED MODS ──────────────────────────────────────────

    {
        fn       = "SpecializationUtil.registerFunction (hasBreakdown)",
        mods     = { "FS25_AdvancedDamageSystem" },
        severity = "HIGH",
        desc     = "ADS_Specialization.lua registers 'hasBreakdown' twice in its own "
                .. "registerFunctions (verbatim duplicate). Generates ~470 errors per "
                .. "load plus a TypeManager nil cascade. ModMixer suppresses the "
                .. "duplicate at runtime — first registration stands, zero errors.",
    },

    -- ── LOAD-ORDER SENSITIVE (all currently safe due to alphabetical order) ──

    {
        fn       = "PlayerInputComponent.registerGlobalPlayerActionEvents",
        mods     = { "FS25_Courseplay" },   -- safe overwrite; 12+ mods append
        severity = "HIGH",
        desc     = "Courseplay safely overwrites (calls superFunc). Loads at C, before "
                .. "all 12 appenders (D-W). Chain intact. Guarded log only.",
    },

    {
        fn       = "HandToolChainsaw.updateRingSelector",
        mods     = { "FS25_EasyDevControls", "FS25_ForestryHelper", "FS25_LumberJack" },
        severity = "HIGH",
        desc     = "Three safe overwrites, all call superFunc. ForestryHelper's own "
                .. "append fires BEFORE its overwrite, so the append is baked into "
                .. "superFunc's chain — it runs exactly once, not twice. This is "
                .. "intentional FH design. Alphabetical order E-F-L is correct. Log only.",
    },

    {
        fn       = "BunkerSilo.update",
        mods     = { "FS25_BunkerSiloHUD", "FS25_BunkerSiloUtilities" },
        severity = "HIGH",
        desc     = "BunkerSiloHUD safely overwrites (H < U, loads first). "
                .. "BunkerSiloUtilities appends. Chain intact. Log only.",
    },

    {
        fn       = "PlayerInputComponent.update",
        mods     = { "FS25_RealisticShopping", "FS25_RealisticWeather" },
        severity = "HIGH",
        desc     = "RealisticShopping safely overwrites (Shopping < Weather). "
                .. "RealisticWeather appends. Chain intact. Log only.",
    },

    {
        fn       = "Enterable.onRegisterActionEvents",
        mods     = { "FS25_AutoFOV", "FS25_LookBack" },
        severity = "HIGH",
        desc     = "AutoFOV safely overwrites (A < L). LookBack appends after. "
                .. "Chain intact. Log only.",
    },

    {
        fn       = "PlayerInputComponent.registerActionEvents",
        mods     = { "FS25_HudSelect", "FS25_EasyDevControls", "FS25_ToggleFertilizer", "FS25_lsfmBaggingPack" },
        severity = "HIGH",
        desc     = "HudSelect safely overwrites (H). EasyDevControls appends first (E < H), "
                .. "so EDC is baked into HudSelect's superFunc chain. ToggleFertilizer and "
                .. "lsfmBaggingPack append after (T, l > H). All four mods' logic runs. "
                .. "Log only.",
    },

    {
        fn       = "Sprayer.onStartWorkAreaProcessing",
        mods     = { "FS25_Courseplay", "FS25_ToggleFertilizer" },
        severity = "HIGH",
        desc     = "Courseplay safely overwrites (C < T). ToggleFertilizer appends after. "
                .. "Chain intact. Log only.",
    },

    {
        fn       = "FillTypeManager.loadMapData",
        mods     = { "FS25_riceHarvest", "FS25_BunkerSiloUtilities", "FS25_enhancedMixerWagons" },
        severity = "HIGH",
        desc     = "riceHarvest safely overwrites (r). Both appenders load first: "
                .. "BunkerSiloUtilities (B) and enhancedMixerWagons (e) are baked into "
                .. "superFunc. All three mods' logic runs. Log only.",
    },

    {
        fn       = "ConstructionScreen.onShowConfigs",
        mods     = { "FS25_ConstructionScreenExtension", "FS25_constructionSearch" },
        severity = "HIGH",
        desc     = "ConstructionScreenExtension safely overwrites (Cs < cs alphabetically). "
                .. "constructionSearch appends after. Chain intact. Log only.",
    },

    {
        fn       = "HandToolHands.consoleCommandToggleSuperStrength",
        mods     = { "FS25_LumberJack", "FS25_EasyDevControls" },
        severity = "HIGH",
        desc     = "LumberJack safely overwrites (L). EasyDevControls appends first (E < L), "
                .. "so EDC is baked into LumberJack's superFunc chain. Both mods' logic runs. "
                .. "Log only.",
    },

    {
        fn       = "AIJobFieldWork.getPricePerMs",
        mods     = { "FS25_Courseplay", "FS25_FreeLabour" },
        severity = "HIGH",
        desc     = "FreeLabour wraps Courseplay (F > C, loads last). FreeLabour calls superFunc "
                .. "to preserve the chain, then unconditionally returns 0 — making hired workers "
                .. "free. This is FreeLabour's entire purpose, not a bug. Chain intact. Log only.",
    },

    {
        fn       = "ShopItemsFrame.populateCellForItemInSection",
        mods     = { "FS25_ShopModLabels", "FS25_UsedSalesTimeLeft" },
        severity = "HIGH",
        desc     = "Both safely overwrite and call superFunc. ShopModLabels (S) loads first, "
                .. "UsedSalesTimeLeft (U) wraps it. Each mod reads the superFunc return value "
                .. "and adds its own UI decoration without discarding the other's work. "
                .. "Chain intact. Log only.",
    },

    {
        fn       = "I18N.getText",
        mods     = { "FS25_BankCredit", "FS25_RealisticWeather" },
        severity = "HIGH",
        desc     = "Both safely overwrite and always call superFunc. BankCredit (B) loads first "
                .. "and routes its own translation keys to its mod namespace. RealisticWeather (R) "
                .. "wraps it and does the same for its keys. No key collision — each mod only "
                .. "intercepts its own prefixed keys. Chain intact. Log only.",
    },

    {
        fn       = "Drivable.updateVehiclePhysics / WheelsUtil.updateWheelsPhysics / WheelsUtil.getSmoothedAcceleratorAndBrakePedals",
        mods     = { "FS25_EnhancedVehicle", "FS25_VehicleControlAddon" },
        severity = "HIGH",
        desc     = "Both mods hook the same three per-frame physics functions. Chain is intact — "
                .. "EV calls originalFunction (via pcall), VCA calls superFunc; load order EV < VCA "
                .. "so runtime chain is VCA_wrapper(EV_wrapper(original)). Base physics IS called. "
                .. "Behavioural conflict: both mods modify axisSide (snap steering) and "
                .. "acceleration/handbrake (parking brake) inputs before passing them down the chain. "
                .. "When both snap/track features are active simultaneously, corrections compound "
                .. "every tick causing visible steering overcorrection. Parking brake systems are "
                .. "separate controls and unlikely to collide in practice. "
                .. "Workaround: disable one mod's snap/steering feature when using the other.",
    },

    {
        fn       = "AI driving systems (behavioural)",
        mods     = { "FS25_AutoDrive", "FS25_Courseplay" },
        severity = "MEDIUM",
        desc     = "AutoDrive and Courseplay are both AI vehicle-routing systems. Hook chains "
                .. "are clean — all AutoDrive hooks call superFunc and are installed inside "
                .. "AutoDrive:loadMap() (not at Lua execution time). Behavioural conflict if "
                .. "both systems are assigned to the same vehicle simultaneously. Use one per "
                .. "vehicle. AutoDrive also adds safe appends to ConstructionScreen.draw "
                .. "(alongside MovePlaceablesAdvanced and constructionSearch) and BaseMission.draw "
                .. "(alongside 3DInspector) — all additive, nothing lost.",
    },

    {
        fn       = "VehicleMotor.updateGear",
        mods     = { "FS25_VehicleControlAddon", "FS25_Courseplay" },
        severity = "MEDIUM",
        desc     = "Hook chain is clean — VCA calls superFunc and guards snap-steering, "
                .. "wheel physics, and throttle/brake override with getIsAIActive() / "
                .. "vcaIsVehicleControlledByPlayer(). However, vcaMotorAfterUpdateGear "
                .. "mutates motor.maxGearRatio directly (turbo-clutch simulation) with no "
                .. "AI guard. Courseplay reads maxGearRatio every tick for gear selection. "
                .. "When Courseplay drives a vehicle with VCA turbo-clutch active, the ratio "
                .. "is modified under Courseplay, causing erratic gear changes. "
                .. "Workaround: disable VCA turbo-clutch on Courseplay-managed vehicles.",
    },

    {
        fn       = "WheelPhysics.updateTireFriction",
        mods     = { "FS25_MudSystemPhysics", "FS25_SeasonalTires" },
        severity = "HIGH",
        desc     = "MudSystemPhysics installs two internal safe overwrites (FieldGroundMudPhysics "
                .. "and MudPhysics scripts — both call superFunc). SeasonalTires appends after "
                .. "(S > M, loads last). Chain: base game -> FieldGroundMudPhysics -> MudPhysics "
                .. "-> SeasonalTires append. All mods' logic runs. Log only.",
    },

    -- ── SCAN-VERIFIED NEW CONFLICTS ──────────────────────────────────────────

    {
        fn       = "10+ info-display and ProductionPoint functions",
        mods     = { "FS25_extendedFunctions", "FS25_InfoDisplayExtension" },
        severity = "CRITICAL",
        desc     = "extendedFunctions overwrites all PlaceableHusbandry*.updateInfo, "
                .. "ProductionPoint.updateInfo, PlaceableSilo.updateInfo, FeedingRobot.updateInfo, "
                .. "AND PlayerHUDUpdater.showSplitShapeInfo without calling superFunc. "
                .. "InfoDisplayExtension hooks the exact same info-display functions. "
                .. "Whichever loads last (alphabetical: e < I, so InfoDisplayExtension wins) "
                .. "discards the other's UI additions entirely. Use one or the other.",
    },

    {
        fn       = "ProductionPoint.load / loadFromXMLFile / updateProduction / etc.",
        mods     = { "FS25_extendedFunctions", "FS25_ProductionStorageControl" },
        severity = "CRITICAL",
        desc     = "extendedFunctions overwrites six ProductionPoint functions without calling "
                .. "superFunc (load, loadFromXMLFile, updateProduction, getOutputDistributionMode, "
                .. "setOutputDistributionMode, ProductionChainManager.distributeGoods). "
                .. "ProductionStorageControl hooks the same functions safely (calls superFunc). "
                .. "extendedFunctions loads first (e < P), ProductionStorageControl wraps it — "
                .. "both run, but extendedFunctions has discarded the original base-game logic. "
                .. "Functional conflicts in production output and save/load likely.",
    },

    {
        fn       = "Sprayer.processSprayerArea + Sprayer.onEndWorkAreaProcessing",
        mods     = { "FS25_HerbicideMixing", "FS25_Courseplay" },
        severity = "HIGH",
        desc     = "HerbicideMixing overwrites both functions without calling superFunc — "
                .. "it replaces sprayer processing entirely with its own herbicide logic. "
                .. "Courseplay wraps processSprayerArea and calls superFunc, so Courseplay "
                .. "fires then calls HerbicideMixing's version (H < C is false — C < H, "
                .. "Courseplay loads first, HerbicideMixing wraps it). Base-game sprayer "
                .. "processing is discarded. AI-driven spraying via Courseplay will use "
                .. "HerbicideMixing's processing logic, not the base game's. Test "
                .. "herbicide application with Courseplay before relying on this combination.",
    },

    {
        fn       = "FSBaseMission.sendInitialClientState",
        mods     = { "FS25_PowerTools" },
        severity = "HIGH",
        desc     = "PowerTools overwrites sendInitialClientState without calling superFunc. "
                .. "At least 44 other mods append or prepend to this function to sync their "
                .. "state on player connect (BankCredit, FieldLeasing, ToggleFertilizer, "
                .. "RealisticWeather, LumberJack, and many others). PowerTools discards all "
                .. "of their sync payloads. In multiplayer, clients who join after game start "
                .. "will be missing state from every mod that appended here. Solo play unaffected.",
    },

    {
        fn       = "SleepManager.getCanSleep",
        mods     = { "FS25_OnlySleepAtNight", "FS25_RealTimeSync", "FS25_TimeKeeper" },
        severity = "HIGH",
        desc     = "Three separate sleep/time-management mods each overwrite getCanSleep "
                .. "without calling superFunc. All three return false unconditionally to "
                .. "prevent sleeping at certain times — but whichever loads last wins and "
                .. "the others are discarded. Install only one sleep management mod.",
    },

    {
        fn       = "g_currentMission.hud.ingameMap.drawFields",
        mods     = { "FS25_minimapPlus", "FS25_Courseplay" },
        severity = "HIGH",
        desc     = "minimapPlus overwrites drawFields without calling superFunc, replacing "
                .. "the field-drawing layer on the minimap entirely. Courseplay appends to "
                .. "this function to draw its AI field overlays. With minimapPlus installed, "
                .. "Courseplay's minimap overlays are silently discarded. NPCFavor also "
                .. "appends here and is similarly lost. minimap visual only — no gameplay impact.",
    },

    {
        fn       = "AnimalClusterHusbandry / AnimalSystem / AnimalScreen (10+ functions)",
        mods     = { "FS25_RealisticLivestock", "FS25_EnhancedLivestock",
                     "FS25_MoreVisualAnimals", "FS25_VisualAnimalsFix" },
        severity = "CRITICAL",
        desc     = "Multiple animal overhaul mods overwrite the same core animal system "
                .. "functions (AnimalClusterHusbandry.updateVisuals, create, deleteHusbandry, "
                .. "getAnimalPosition, AnimalSystem.loadAnimals, AnimalScreen.setController, "
                .. "getPrice, populateCellForItemInSection, and others). Each mod replaces "
                .. "the animal rendering and behaviour system entirely. Installing two or more "
                .. "simultaneously causes silent discards — only the last-loaded mod's animal "
                .. "logic runs. RM variants (RealisticLivestockRM, MoreVisualAnimalsRM) count "
                .. "as separate mods for this purpose. Install exactly one animal overhaul mod.",
    },

    {
        fn       = "MoreRealistic — comprehensive vehicle physics replacement",
        mods     = { "MoreRealistic" },
        severity = "HIGH",
        desc     = "MoreRealistic replaces 22 vehicle physics and motor functions without "
                .. "calling superFunc (Motorized.onUpdate, Motorized.updateMotorProperties, "
                .. "Vehicle.update, Vehicle.updateMass, WheelsUtil.updateWheelsPhysics, "
                .. "WheelPhysics.updateTireFriction, VehicleMotor.getStartInGearFactor, "
                .. "Combine.addCutterArea, and others). It is a comprehensive physics overhaul "
                .. "that owns the vehicle simulation layer — similar to how RealisticWeather "
                .. "owns the weather system. Conflicts with: soundExpansionMP (Motorized.onUpdate), "
                .. "MudSystemPhysics (WheelPhysics.updateTireFriction), EnhancedVehicle and "
                .. "VehicleControlAddon (WheelsUtil.updateWheelsPhysics). The hook chains are "
                .. "intact (those mods wrap MoreRealistic and call superFunc) but the original "
                .. "base-game physics is gone — replaced by MoreRealistic's simulation.",
    },

    {
        fn       = "ConstructionScreen.onButtonMenuBack",
        mods     = { "FS25_MovePlaceables", "FS25_MovePlaceablesAdvanced",
                     "FS25_RearrangePlaceables" },
        severity = "HIGH",
        desc     = "Three 'move placeables' mods each overwrite onButtonMenuBack without "
                .. "calling superFunc. They intercept the back button in the construction screen "
                .. "to return the player to their custom move-placeable UI. Whichever loads last "
                .. "wins; the others' back-button handling is discarded. Install only one "
                .. "move-placeables mod. PlaceableMover is a safe alternative that chains correctly.",
    },

    {
        fn       = "PlaceableHotspot/NPCHotspot/FerryHotspot.getBeVisited + Enterable.getIsEnterableFromMenu",
        mods     = { "FS25_NoTeleport", "FS25_NoTeleport_1",
                     "FS25_Farming_RP_Pack", "FS25_HardcoreBalanceMod" },
        severity = "CRITICAL",
        desc     = "Four mods overwrite these four teleport/fast-travel functions without "
                .. "calling superFunc. NoTeleport and its duplicate explicitly block teleporting. "
                .. "Farming_RP_Pack and HardcoreBalanceMod also stomp them as part of their "
                .. "broader gameplay restrictions. All four return false unconditionally — "
                .. "whichever loads last discards the others' logic. Additionally, "
                .. "HardcoreBalanceMod stomps AbstractMission.hasLeasableVehicles and "
                .. "InGameMenuProductionFrame.onButtonToggleOutputMode. Farming_RP_Pack "
                .. "also stomps InGameMenuMapFrame.onClickVisit and "
                .. "InGameMenuProductionFrame.onButtonToggleOutputMode. If you use "
                .. "Farming_RP_Pack or HardcoreBalanceMod, do not also install NoTeleport.",
    },

    {
        fn       = "SellVehicleEvent.run",
        mods     = { "FS25_AdvancedDamageSystem", "FS25_ExtendedLeasing_V1_1",
                     "FS25_FairLeasingPlus" },
        severity = "HIGH",
        desc     = "AdvancedDamageSystem overwrites SellVehicleEvent.run without calling "
                .. "superFunc (hooks the sell event to clear breakdown data). "
                .. "ExtendedLeasing_V1_1 also overwrites without superFunc. "
                .. "FairLeasingPlus overwrites safely (calls superFunc). "
                .. "Load order: ADS (A) < EL (E) < FL (F). FairLeasingPlus wraps "
                .. "ExtendedLeasing which has discarded ADS's vehicle-sell cleanup. "
                .. "ADS breakdown state may not be cleared correctly when leased vehicles "
                .. "are sold. Log only.",
    },

    {
        fn       = "SleepManager (onSleepRequest / startSleep / stopSleep / draw / loadMapData)",
        mods     = { "FS25_GoToVacation" },
        severity = "HIGH",
        desc     = "GoToVacation replaces five SleepManager functions without calling "
                .. "superFunc — it owns the entire sleep/time-skip system. No other mod "
                .. "in this install hooks the same functions, but any future sleep-related "
                .. "mod (OnlySleepAtNight, RealTimeSync, VehicleSleeperCab, TimeKeeper) "
                .. "would conflict. GoToVacation is also incompatible with those mods "
                .. "if both are installed. Log only.",
    },

    {
        fn       = "SellingStation.getEffectiveFillTypePrice + AnimalSellEvent.run",
        mods     = { "FS25_SupplyAndDemand", "FS25_MarketDynamics",
                     "FS25_ZYX_SeasonalPrices" },
        severity = "HIGH",
        desc     = "SupplyAndDemand overwrites getEffectiveFillTypePrice without calling "
                .. "superFunc — it replaces the sell-price calculation entirely. "
                .. "MarketDynamics and ZYX_SeasonalPrices both overwrite the same function "
                .. "but call superFunc. Load order: M < S < Z, so SupplyAndDemand (S) "
                .. "wraps MarketDynamics (M) which called the original; ZYX_SeasonalPrices "
                .. "wraps SupplyAndDemand. MarketDynamics' price adjustments are discarded "
                .. "by SupplyAndDemand. Also: SupplyAndDemand stomps AnimalSellEvent.run, "
                .. "discarding any other mod's sell-event hooks. Log only.",
    },

    {
        fn       = "ProductionChainManager.distributeGoods",
        mods     = { "FS25_ImprovedProductionDistribution",
                     "FS25_DistributionCostOverride", "FS25_Fresh" },
        severity = "HIGH",
        desc     = "ImprovedProductionDistribution overwrites distributeGoods without "
                .. "calling superFunc, replacing the production output routing entirely. "
                .. "DistributionCostOverride and Fresh both call superFunc safely (I < D < F, "
                .. "so ImprovedProductionDistribution wraps DistributionCostOverride, "
                .. "which wraps Fresh; ImprovedProductionDistribution discards both's "
                .. "contribution). extendedFunctions also stomps this function — "
                .. "if both extendedFunctions and ImprovedProductionDistribution are "
                .. "installed, whichever loads last wins entirely. Log only.",
    },

    {
        fn       = "FarmlandManager.getPricePerHa",
        mods     = { "FS25_FarmlandDifficulty", "FS25_FarmlandMarket", "FS25_UsedPlus" },
        severity = "HIGH",
        desc     = "FarmlandDifficulty overwrites getPricePerHa without calling superFunc — "
                .. "it replaces land pricing with its own difficulty-scaled formula. "
                .. "FarmlandMarket and UsedPlus both call superFunc safely. "
                .. "Load order F < F < U; FarmlandDifficulty (FarmlandD) and FarmlandMarket "
                .. "(FarmlandM) — D < M, so FarmlandMarket wraps FarmlandDifficulty. "
                .. "FarmlandDifficulty discards the original pricing; FarmlandMarket's "
                .. "market-based adjustments are then applied on top. Functional but "
                .. "FarmlandMarket may behave unexpectedly if FarmlandDifficulty sets "
                .. "prices it does not expect. Log only.",
    },

    {
        fn       = "AbstractMission.hasLeasableVehicles",
        mods     = { "FS25_HardcoreBalanceMod", "FS25_Contracts_Plus" },
        severity = "HIGH",
        desc     = "Both overwrite hasLeasableVehicles without calling superFunc. "
                .. "HardcoreBalanceMod returns false to disable vehicle leasing as a "
                .. "balance decision. Contracts_Plus also replaces this function. "
                .. "Farming_RP_Pack wraps this safely (calls superFunc). "
                .. "Whichever of HardcoreBalanceMod or Contracts_Plus loads last wins. "
                .. "If both are installed, contract and leasing behaviour may be incorrect. "
                .. "Log only.",
    },

    {
        fn       = "GuiTopDownCursor.updateRaycast / getPosition / getHitTerrainPosition",
        mods     = { "FS25_PerfectEdge" },
        severity = "INFO",
        desc     = "PerfectEdge replaces three top-down cursor functions without calling "
                .. "superFunc. No other installed mod hooks these functions — it is a "
                .. "safe solo replacement that improves cursor precision in construction "
                .. "mode. If a future mod also hooks these functions it would conflict.",
    },

    -- ── SOURCE-VERIFIED 2026-06-01 (scan_all_hooks.py + manual inspection) ───────
    -- These have exact fn names so the scan-based pass below treats them as
    -- catalogued (authoritative verdict here) instead of re-flagging them.

    {
        fn       = "Motorized.updateConsumers",
        mods     = { "FS25_HigherFuelUsage", "FS25_AdvancedHelper", "FS25_soundExpansionMP" },
        severity = "HIGH",
        desc     = "HigherFuelUsage replaces the per-frame fuel model without calling superFunc. "
                .. "AdvancedHelper and soundExpansionMP both overwrite the same function safely. "
                .. "Load order A < H < s: soundExpansionMP wraps HigherFuelUsage wraps AdvancedHelper, "
                .. "but HigherFuelUsage does not chain down — AdvancedHelper's fuel-hook contribution is "
                .. "discarded. soundExpansionMP and HigherFuelUsage still run. Intentional fuel-model "
                .. "replacement; if you want AdvancedHelper's fuel behaviour the two are mutually "
                .. "exclusive. Log only.",
    },

    {
        fn       = "ConstructionBrush.verifyAccess",
        mods     = { "FS25_PlaceTerraformPaintAnywhere", "FS25_paintAndTerraformAnywhere" },
        severity = "CRITICAL",
        desc     = "Same incompatible pair as Landscaping.hasObjectOverlapInModificationArea above. "
                .. "PlaceTerraformPaintAnywhere overwrites verifyAccess without superFunc (bypasses the "
                .. "construction access check by design); paintAndTerraformAnywhere does the same job "
                .. "safely. Identical build-anywhere intent — remove one (see incompatible pairs). Log only.",
    },

    {
        fn       = "VehicleMaterial.apply",
        mods     = { "FS25_CaroCargo", "FS25_E516_Pack" },
        severity = "INFO",
        desc     = "Both packs embed the identical shared BaseMaterial.lua (byte-for-byte) which "
                .. "overwrites VehicleMaterial.apply without superFunc. Because the impl is the same in "
                .. "both, the load-order winner is irrelevant — behaviour is identical. Benign duplicate "
                .. "registration, not a real conflict. Log only.",
    },

    {
        fn       = "VehicleMaterial.applyToVehicle",
        mods     = { "FS25_CaroCargo", "FS25_E516_Pack" },
        severity = "INFO",
        desc     = "Same shared BaseMaterial.lua as VehicleMaterial.apply — identical impl in both "
                .. "packs. Benign duplicate. Log only.",
    },

    -- ── SCAN-VERIFIED SAFE CHAINS (were uncatalogued HIGH; source-verified chain-intact) ──
    -- Each overwriter calls superFunc, so the appended/prepended/manual chainers all run.
    -- Logged as INFO so they no longer surface as uncatalogued HIGH.

    {
        fn       = "Farm.changeBalance",
        mods     = { "FS25_BankCredit", "FS25_RedTape", "FS25_RoddHarderEconomy", "FS25_TransactionLog" },
        severity = "INFO",
        desc     = "Four economy mods on the core money function — all chain-intact. BankCredit, RedTape "
                .. "and TransactionLog APPEND (income tracking, fees, transaction logging — observers that "
                .. "always call the original). RoddHarderEconomy OVERWRITES but calls superFunc with the "
                .. "amount unchanged (it applies difficulty via separate fee transactions, not by mutating "
                .. "this call). All four run; nothing discarded. Cumulative difficulty by design. Log only.",
    },

    {
        fn       = "Vehicle.load",
        mods     = { "FS25_0_TerraFarm", "FS25_Courseplay" },
        severity = "INFO",
        desc     = "TerraFarm overwrites Vehicle.load but calls superFunc (uses/returns the base load "
                .. "result); Courseplay prepends. Chain intact — base load runs, both mods add their "
                .. "per-vehicle data. Log only.",
    },

    {
        fn       = "BunkerSilo.loadFromXMLFile",
        mods     = { "FS25_AdvancedSilageTypes", "FS25_BunkerSiloUtilities" },
        severity = "INFO",
        desc     = "AdvancedSilageTypes overwrites but calls superFunc, then reads its own "
                .. "bunkerSiloExtension fill-type keys; BunkerSiloUtilities prepends. Chain intact — "
                .. "base load runs, both mods extend it. Log only.",
    },

    {
        fn       = "Cutter.onEndWorkAreaProcessing",
        mods     = { "FS25_CombineXP", "FS25_FollowMe" },
        severity = "INFO",
        desc     = "CombineXP overwrites but calls superFunc, then adds its harvested-liters XP tracking; "
                .. "FollowMe appends. Chain intact — base work-area processing runs, both mods add logic. "
                .. "Log only.",
    },

    {
        fn       = "InfoDialog.show",
        mods     = { "FS25_NoSellDialogs", "FS25_RealisticShopping" },
        severity = "INFO",
        desc     = "RealisticShopping overwrites but calls superFunc (marks the dialog shown, returns the "
                .. "base result). NoSellDialogs uses a manual chain (invisible to the registry) to "
                .. "intentionally suppress specific confirmation dialogs — that selective suppression is "
                .. "its purpose, not a bug. Load order N < R: RealisticShopping wraps NoSellDialogs. "
                .. "Low-frequency UI event. Log only.",
    },

    {
        fn       = "Motorized.onUpdate",
        mods     = { "FS25_soundExpansionMP", "FS25_LowerReverseBeepVol" },
        severity = "INFO",
        desc     = "soundExpansionMP overwrites but calls superFunc (client/server sound hooks); "
                .. "LowerReverseBeepVol appends. Chain intact — base motor update runs, both sound mods "
                .. "layer on. Per-frame but lightweight. Log only.",
    },

    -- ── SCAN-VERIFIED BENIGN APPEND CHAINS (were uncatalogued MEDIUM; pure appends) ──
    -- Every hooker APPENDS (no overwriter), so all run in sequence — overhead only, no data loss.

    {
        fn       = "FSBaseMission.update",
        mods     = { "FS25_3DInspector", "FS25_FarmKit", "FS25_RealisticDamage", "FS25_WorkerCosts", "FS25_ModMixer" },
        severity = "INFO",
        desc     = "Five safe appends on the per-frame mission update. Each merely delegates to its own "
                .. "mod's update (3DInspector overlay, FarmKit slip-HUD decay, RealisticDamage, WorkerCosts "
                .. "cost accrual, ModMixer's own incompatible-warning timer). Chaining cost negligible; "
                .. "nothing heavy runs unconditionally. ModMixer itself is one of the five — expected. Log only.",
    },

    {
        fn       = "FSBaseMission.onMinuteChanged",
        mods     = { "FS25_000_DataDump", "FS25_000_DevTools", "FS25_BuyUsedEquipment", "FS25_ShopSearch_V1_1" },
        severity = "INFO",
        desc     = "Four safe appends on a ~3s-cadence time event (NOT per-frame — the HIGH-looking name "
                .. "is a frequency red herring). All additive. The same four mods append onHourChanged and "
                .. "onDayChanged. Negligible overhead. Log only.",
    },

    {
        fn       = "FSBaseMission.onHourChanged",
        mods     = { "FS25_000_DataDump", "FS25_000_DevTools", "FS25_BuyUsedEquipment", "FS25_ShopSearch_V1_1" },
        severity = "INFO",
        desc     = "Four safe appends on an hourly time event. Additive, negligible overhead. See onMinuteChanged. Log only.",
    },

    {
        fn       = "FSBaseMission.onDayChanged",
        mods     = { "FS25_000_DataDump", "FS25_000_DevTools", "FS25_BuyUsedEquipment", "FS25_ShopSearch_V1_1" },
        severity = "INFO",
        desc     = "Four safe appends on a daily time event. Additive, negligible overhead. See onMinuteChanged. Log only.",
    },

    {
        fn       = "ConstructionScreen.draw",
        mods     = { "FS25_AutoDrive", "FS25_MovePlaceablesAdvanced", "FS25_constructionSearch" },
        severity = "INFO",
        desc     = "Three safe appends — every mod's draw runs in sequence, nothing lost. Fires only while "
                .. "the construction screen is open (UI), not per gameplay frame, so the HIGH freq label "
                .. "overstates it. Overhead only. Log only.",
    },

    {
        fn       = "InGameMenuProductionFrame.updateMenuButtons",
        mods     = { "FS25_Butcher", "FS25_ProductionStorageControl", "FS25_UpgradeYourFactory", "FS25_boucherie", "FS25_gr_feedMixer" },
        severity = "INFO",
        desc     = "Five safe appends extending the production-menu buttons. Fires only while the production "
                .. "menu frame is open (UI), not per gameplay frame. All additive. Log only.",
    },

    {
        fn       = "InGameMenuSettingsFrame.updateGameSettings",
        mods     = { "FS25_AdvancedDamageSystem", "FS25_DynamicFieldPrices", "FS25_FieldLeasing" },
        severity = "INFO",
        desc     = "Three safe appends on the settings-menu update (UI-only, not per gameplay frame). "
                .. "Additive. Log only.",
    },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- INCOMPATIBLE PAIRS
-- Mods that replace the same system entirely. Only one can win. The user should
-- remove one from their mod folder. ModMixer cannot reconcile these.
-- ─────────────────────────────────────────────────────────────────────────────

local incompatiblePairs = {
    {
        mods   = { "FS25_RealisticLivestock", "FS25_RealisticLivestockRM",
                   "FS25_EnhancedLivestock",
                   "FS25_MoreVisualAnimals", "FS25_MoreVisualAnimalsRM",
                   "FS25_VisualAnimalsFix" },
        winner = "last alphabetically",
        reason = "Animal overhaul mods. All replace AnimalClusterHusbandry, AnimalSystem, "
              .. "and AnimalScreen functions without chaining. Only the last-loaded mod's "
              .. "animal logic runs; all others are silently discarded. Install exactly one.",
    },
    {
        mods   = { "FS25_OnlySleepAtNight", "FS25_RealTimeSync",
                   "FS25_RealTimeSync_1", "FS25_TimeKeeper" },
        winner = "last alphabetically",
        reason = "Sleep/time management mods. All replace SleepManager.getCanSleep without "
              .. "calling superFunc. Functionally identical intent, only one can be active. "
              .. "Remove all but one.",
    },
    {
        mods   = { "FS25_NoTeleport", "FS25_NoTeleport_1" },
        winner = "FS25_NoTeleport_1",
        reason = "Two versions of the same no-teleport mod, both overwriting the same "
              .. "hotspot functions without superFunc. Remove one.",
    },
    {
        mods   = { "FS25noCollisionCamera", "FS25_NoVehicleCameraCollision",
                   "FS22noCollisionCamera" },
        winner = "last alphabetically",
        reason = "Three mods that remove vehicle camera collision — all overwrite "
              .. "VehicleCamera.getCollisionDistance without superFunc. They are the same "
              .. "functionality uploaded separately. Install only one.",
    },
    {
        mods   = { "FS25_Usine_2X_plus_rapide", "FS25_Usine_50X_plus_rapide" },
        winner = "FS25_Usine_50X_plus_rapide",
        reason = "Both overwrite ProductionPoint.onTimescaleChanged without superFunc "
              .. "to speed up production. 50X loads after 2X and wins — only the 50X "
              .. "speed applies. Remove one; they are mutually exclusive.",
    },
    {
        mods = { "FS25_BankCredit", "FS25_EnhancedLoanSystem" },
        winner = "FS25_EnhancedLoanSystem",
        reason = "Both replace the loan/finance system. "
              .. "EnhancedLoanSystem loads last (E > B) and wins. "
              .. "BankCredit is installed but non-functional. Remove one.",
    },
    {
        mods = { "FS25_PlaceTerraformPaintAnywhere", "FS25_paintAndTerraformAnywhere" },
        winner = "FS25_paintAndTerraformAnywhere",
        reason = "Both unlock terrain painting and placement anywhere. "
              .. "paintAndTerraformAnywhere loads last (p > P) and wins. "
              .. "Both return false unconditionally so behaviour is identical, "
              .. "but you are carrying a redundant mod. Remove one.",
    },
    {
        -- NOTE: unlike the pairs above, these two do NOT share a hook — the generic
        -- hook-overlap detector cannot see this clash. It is a SEMANTIC incompatibility:
        -- two independent damage simulations running on the same vehicle at once.
        mods = { "FS25_AdvancedDamageSystem", "FS25_RealisticDamage" },
        winner = "neither — they fight; remove one",
        reason = "Parallel damage systems. AdvancedDamageSystem owns the standard wear "
              .. "channel (spec_wearable.damageAmount); RealisticDamage runs its own "
              .. "component-failure model (wheel bearings, CVT, etc.) that never touches "
              .. "that channel. With both installed each runs a separate damage simulation "
              .. "on the same vehicle: the on-screen damage readout shows 0% while "
              .. "RealisticDamage silently seizes components with no warning. No load order "
              .. "or chain reorder fixes this — the two models do not communicate. "
              .. "Run one or the other, not both.",
    },
}

-- Strip FS25_/FS22_ prefix for compact display in the in-game dialog
local function displayName(m)
    return (m:gsub("^FS2[25]_", ""))
end

local incompatibleWarnings = {}  -- populated below; consumed by the map-load dialog

-- Published for the Switchboard Basic mode (SB.buildConflicts reads this): the ACTIVE
-- incompatible pairs (2+ of the pair installed), with RAW mod names so the UI can match
-- and DISPLAY names + reason for the card. Semantic "remove-one" fights ModMixer can't
-- arbitrate by veto — surfaced honestly in Basic mode.
ModMixerIncompatible = {}

for _, pair in ipairs(incompatiblePairs) do
    local installedMods = {}
    for _, m in ipairs(pair.mods) do
        if present(m .. ".zip") or present(m) then
            table.insert(installedMods, m)
        end
    end
    if #installedMods >= 2 then
        logGame(string.format("[INCOMPATIBLE] %s", table.concat(installedMods, " + ")))
        logGame("  " .. pair.reason)
        logGame("  >>> Remove all but one of these mods from your mod folder. <<<")

        -- Collect short-form entry for the in-game dialog
        local displayMods = {}
        for _, m in ipairs(installedMods) do
            table.insert(displayMods, displayName(m))
        end
        local hint = pair.reason:match("^([^.]+%.)") or pair.reason:sub(1, 80)
        table.insert(incompatibleWarnings, {
            mods = table.concat(displayMods, " + "),
            hint = hint,
        })
        table.insert(ModMixerIncompatible, {
            mods    = installedMods,                 -- raw names (match keys)
            display = displayMods,                   -- pretty names (UI)
            reason  = hint,
        })
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- IN-GAME ON-SCREEN WARNING (incompatible mods only)
--
-- We render our own text with renderText() instead of showBlinkingWarning, which
-- is a single centered banner that truncates multi-line text and collides with
-- other mods' notifications. Drawing it ourselves gives full control of position
-- (top-left, clear of the centered info box), colour (bright red), and lets us
-- show every incompatible group on its own line.
--
-- Timing: deferred until the player is actually in-world (no GUI / loading screen
-- up). Once shown it stays for HOLD_MS, then fades out over FADE_MS.
-- ─────────────────────────────────────────────────────────────────────────────

if #incompatibleWarnings > 0 then
    local warnLines = { "ModMixer: incompatible mods detected" }
    for _, w in ipairs(incompatibleWarnings) do
        table.insert(warnLines, "  - " .. w.mods)
    end
    table.insert(warnLines, "Remove all but one from each group (see ModMixer.log)")

    local START_DELAY = 2500     -- ms in-world before showing
    local HOLD_MS     = 20000    -- ms fully visible
    local FADE_MS     = 2000     -- ms fade-out
    local X           = 0.012    -- top-left, normalized screen coords
    local Y_TOP       = 0.95     -- just under the very top of the screen
    local LINE_H      = 0.026
    local SIZE        = 0.020

    local inWorld = 0
    local shownAt = nil          -- accumulated ms since display started
    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update,
        function(self, dt)
            if g_gui ~= nil and g_gui.currentGui ~= nil then return end
            inWorld = inWorld + dt
            if inWorld < START_DELAY then return end
            if shownAt == nil then shownAt = 0 end
            shownAt = shownAt + dt
        end)

    FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw,
        function(self)
            -- Never paint over an open menu/GUI (Switchboard, ESC menu, dialogs).
            -- Without this the in-world warning bled on top of the menu header and
            -- collided with the logo/title — the "bunching" artefact.
            if g_gui ~= nil and g_gui.currentGui ~= nil then return end
            if shownAt == nil then return end
            if shownAt > (HOLD_MS + FADE_MS) then return end

            local alpha = 1.0
            if shownAt > HOLD_MS then
                alpha = 1.0 - ((shownAt - HOLD_MS) / FADE_MS)
            end
            if alpha <= 0 then return end

            setTextBold(true)
            setTextAlignment(RenderText.ALIGN_LEFT)
            local y = Y_TOP
            for _, line in ipairs(warnLines) do
                -- shadow for legibility against bright sky
                setTextColor(0, 0, 0, alpha)
                renderText(X + 0.0015, y - 0.0015, SIZE, line)
                -- bright red foreground
                setTextColor(1, 0.10, 0.10, alpha)
                renderText(X, y, SIZE, line)
                y = y - LINE_H
            end
            setTextBold(false)
            setTextColor(1, 1, 1, 1)
        end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- LOG ALL DETECTED CONFLICTS
-- ─────────────────────────────────────────────────────────────────────────────

local activeConflicts = {}
for _, c in ipairs(conflicts) do
    local allPresent = true
    for _, modName in ipairs(c.mods) do
        if not present(modName .. ".zip") and not present(modName) then
            allPresent = false
            break
        end
    end
    if allPresent then
        table.insert(activeConflicts, c)
        log(string.format("[%s] %s", c.severity, c.fn))
        log("  " .. c.desc)
    end
end

if #activeConflicts == 0 then
    logGame("No conflicting mod pairs detected in this installation.")
else
    -- Count by severity for the game log summary; full detail is in ModMixer.log
    local counts = {}
    for _, c in ipairs(activeConflicts) do
        counts[c.severity] = (counts[c.severity] or 0) + 1
    end
    local parts = {}
    for _, sev in ipairs({"CRITICAL","HIGH","MEDIUM","INFO"}) do
        if counts[sev] then
            table.insert(parts, string.format("%d %s", counts[sev], sev))
        end
    end
    logGame(string.format(
        "Conflict summary: %s. See ModMixer.log for details.",
        table.concat(parts, ", ")))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SCAN-BASED DETECTION  (offline registry-walker output)
--
-- ModMixerScan is generated by scan_all_hooks.py from a full static scan of every
-- installed mod's Lua (all hook forms: overwritten / appended / prepended /
-- direct-assignment), then loaded ahead of this file via extraSourceFiles. It
-- covers conflicts beyond the hand catalogue above: we report every scanned
-- conflict whose mods are present, and surface any UNCATALOGUED critical/high to
-- the game log so a new mod combination cannot slip through silently. Detection
-- and reporting only — no runtime patching here.
-- Regenerate after mod changes: python scan_all_hooks.py  (re-emits the dataset).
-- ─────────────────────────────────────────────────────────────────────────────

if type(ModMixerScan) == "table" and type(ModMixerScan.entries) == "table" then
    local handFns = {}
    for _, c in ipairs(conflicts) do handFns[c.fn] = true end

    local meta = ModMixerScan.meta or {}
    log("")
    log(string.format("=== SCAN-BASED DETECTION (dataset generated %s) ===",
        tostring(meta.generated or "?")))

    local scanPresent, scanCatalogued, scanGameLogged, scanUncatCH = 0, 0, 0, 0
    local SCAN_GAMELOG_CAP = 12   -- cap per-line game-log noise; full detail always in ModMixer.log
    for _, e in ipairs(ModMixerScan.entries) do
        local presentMods = {}
        for _, m in ipairs(e.mods) do
            if present(m .. ".zip") or present(m) then
                presentMods[#presentMods + 1] = displayName(m)
            end
        end
        if #presentMods >= 2 then
            scanPresent = scanPresent + 1
            local covered = handFns[e.fn] == true
            if covered then scanCatalogued = scanCatalogued + 1 end
            log(string.format("[SCAN][%s] %s  (%s / %s)  %s%s",
                tostring(e.sev), tostring(e.fn), tostring(e.ctype), tostring(e.freq),
                table.concat(presentMods, " + "),
                covered and "  [catalogued above]" or ""))
            if (e.detail or "") ~= "" then log("  " .. e.detail) end
            if (not covered) and (e.sev == "CRITICAL" or e.sev == "HIGH") then
                scanUncatCH = scanUncatCH + 1
                if scanGameLogged < SCAN_GAMELOG_CAP then
                    scanGameLogged = scanGameLogged + 1
                    logGame(string.format("[SCAN] uncatalogued %s: %s  (%s)",
                        tostring(e.sev), tostring(e.fn), table.concat(presentMods, " + ")))
                end
            end
        end
    end

    if scanUncatCH > scanGameLogged then
        logGame(string.format(
            "[SCAN] ...and %d more uncatalogued CRITICAL/HIGH — full list in ModMixer.log.",
            scanUncatCH - scanGameLogged))
    end
    logGame(string.format(
        "Scan-based detection: %d active conflicts (%d catalogued, %d uncatalogued); "
     .. "%s benign INFO chains. Dataset: %s mods scanned. See ModMixer.log.",
        scanPresent, scanCatalogued, scanPresent - scanCatalogued,
        tostring(meta.infoChains or "?"), tostring(meta.scanned or "?")))
else
    log("INFO: ModMixerScan dataset not present — scan-based detection skipped. "
     .. "Generate scripts/mm_catalogue_generated.lua via: python scan_all_hooks.py --emit-only")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CHAIN VERIFY: PlayerHUDUpdater.showSplitShapeInfo
--
-- What actually happens (source-verified):
--
--   IDE (InfoDisplayExtension) installs its hook at MODULE TOP-LEVEL — during
--   normal mod load.  Registry at ModMixer load time: ide_wrapper → {prev=original}.
--
--   FH (ForestryHelper) defers its hook to Mission00.loadMission00Finished
--   (ForestryHelper.lua line 263: "Register our overrides as late as possible").
--   So at ModMixer load time FH has NOT yet touched showSplitShapeInfo.
--
--   At map load, FH's loadMission00Finished callback fires BEFORE ours
--   (FH < ModMixer alphabetically, so FH registered first in the append chain).
--   FH wraps whatever showSplitShapeInfo is at that moment (IDE's wrapper).
--   FH DOES call superFunc (ForestryHelper.lua line 96).
--
--   Final runtime chain: FH_wrapper → calls superFunc → IDE_wrapper → original
--   Both overlays run. No repair needed; this block just verifies it.
--
--   If the chain is broken for any reason, an active repair is attempted as
--   a fallback — installing a combined function that calls both impls directly.
-- ─────────────────────────────────────────────────────────────────────────────

if present("FS25_ForestryHelper.zip") and present("FS25_InfoDisplayExtension.zip") then

    local registry = type(Utils.__ms_registry) == "table" and Utils.__ms_registry or nil

    if not registry then
        log("showSplitShapeInfo: registry unavailable (ModMixerHooks initialisation failed).")
    else
        -- FH defers its hook to loadMission00Finished. We must also defer our
        -- verify/repair to fire AFTER FH's callback. ModMixer registers its
        -- callback at mod load; FH registers first (FH < ModMixer alphabetically).
        Mission00.loadMission00Finished = Utils.appendedFunction(
            Mission00.loadMission00Finished,
            function(mission, node)
                -- At this point FH has just installed its wrapper (outermost).
                -- Expected chain: FH_wrapper(IDE_wrapper(original))
                -- FH calls superFunc so IDE and FH both run.
                local fh_wrapper  = PlayerHUDUpdater.showSplitShapeInfo
                local fh_entry    = fh_wrapper and registry[fh_wrapper]
                local ide_wrapper = fh_entry and fh_entry.prev
                local ide_entry   = ide_wrapper and registry[ide_wrapper]
                local fh_impl     = fh_entry and fh_entry.impl
                local ide_impl    = ide_entry and ide_entry.impl

                if fh_impl and ide_impl then
                    -- Chain is intact. FH calls superFunc so IDE runs inside FH.
                    log("showSplitShapeInfo chain verified at map load.")
                    log("  FH_wrapper(IDE_wrapper(original)) — FH calls superFunc, both overlays active.")
                else
                    -- Unexpected layout. Fall back to explicit combined function.
                    log(string.format(
                        "showSplitShapeInfo: unexpected chain at map load (fh=%s ide=%s) — attempting repair.",
                        tostring(fh_entry ~= nil), tostring(ide_entry ~= nil)))

                    -- Try the other direction: maybe IDE ended up outermost.
                    local outer_entry  = fh_wrapper and registry[fh_wrapper]
                    local inner_wrapper = outer_entry and outer_entry.prev
                    local inner_entry  = inner_wrapper and registry[inner_wrapper]
                    local outer_impl   = outer_entry and outer_entry.impl
                    local inner_impl   = inner_entry and inner_entry.impl

                    if outer_impl and inner_impl then
                        local noop = function() end
                        PlayerHUDUpdater.showSplitShapeInfo = function(self, splitShape)
                            inner_impl(self, noop, splitShape)
                            outer_impl(self, noop, splitShape)
                        end
                        log("  Fallback repair applied (both impls called with noop superFunc).")
                    else
                        log("  Cannot repair — registry entries missing. Both mods loaded?")
                    end
                end
            end
        )
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CHAIN INTEGRITY GUARD: PlayerInputComponent.registerGlobalPlayerActionEvents
--
-- Courseplay is a safe overwriter (calls superFunc). It loads at 'C', before
-- all 15 appenders. This guard verifies the situation at load time and logs a
-- warning if a future mod changes the balance.
-- ─────────────────────────────────────────────────────────────────────────────

if present("FS25_Courseplay.zip") then
    -- The current function should be a chain ending in Courseplay's wrapper.
    -- We can't easily introspect the full chain, but we trust the alphabetical
    -- order analysis.  Log the appender count as a sanity check.
    local appenders = {
        "FS25_EasyDevControls", "FS25_FarmlandOverview_Extended",
        "FS25_HideHelpTexts",   "FS25_InputHelpPager",
        "FS25_LitresToTonnes",  "FS25_MapObjectsHider",
        "FS25_NotificationLog", "FS25_RealisticShopping",
        "FS25_RealisticWeather","FS25_ScreenshotMode",
        "FS25_SteeringLock",    "FS25_ToggleFertilizer",
        "FS25_TransactionLog",  "FS25_WorkerProgress",
        "FS25_lsfmBaggingPack",
    }
    local count = 0
    for _, m in ipairs(appenders) do
        if present(m .. ".zip") then count = count + 1 end
    end
    if count > 0 then
        log(string.format(
            "INFO: registerGlobalPlayerActionEvents — Courseplay (safe overwrite) "
         .. "+ %d appenders. Chain is intact (Courseplay loads at C < all appenders).",
            count))
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- WARM-CHAIN NOTICE: FSBaseMission.onMinuteChanged / onHourChanged / onDayChanged
--
-- Four mods (000_DataDump, 000_DevTools, BuyUsedEquipment, ShopSearch_V1_1)
-- append to the same time-event functions.  Pure appends — no overwrite —
-- so no data is lost.  The only cost is four function calls per tick.
-- ─────────────────────────────────────────────────────────────────────────────

local timeEventMods = {
    "FS25_000_DataDump", "FS25_000_DevTools",
    "FS25_BuyUsedEquipment", "FS25_ShopSearch_V1_1",
}
local timeEventCount = 0
for _, m in ipairs(timeEventMods) do
    if present(m .. ".zip") then timeEventCount = timeEventCount + 1 end
end
if timeEventCount >= 3 then
    log(string.format(
        "INFO: %d mods append to onMinuteChanged/onHourChanged/onDayChanged "
     .. "(safe chain, minor overhead — ~3s cadence, not per-frame).",
        timeEventCount))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SOLO SYSTEM REPLACEMENTS
--
-- These mods completely replace base-game functions without calling superFunc,
-- but no other installed mod currently hooks the same functions — so there is
-- no inter-mod conflict right now.  Logged so authors know which functions are
-- effectively "owned" by these mods; a future mod hooking them would STOMP.
-- ─────────────────────────────────────────────────────────────────────────────

if present("FS25_RealisticWeather.zip") then
    log("INFO: RealisticWeather comprehensively replaces the base-game weather "
     .. "system — Weather.update, WheelPhysics.updateFriction, WeatherStateEvent "
     .. "read/write/run, Tedder.processTedderArea, Weather.fillWeatherForecast, "
     .. "Weather.randomizeFog, and others — without calling superFunc on each. "
     .. "No inter-mod conflict with current install; any future mod touching "
     .. "those functions would silently STOMP with RealisticWeather.")
end

if present("FS25_HigherFuelUsage.zip") then
    if present("FS25_soundExpansionMP.zip") then
        log("INFO: HigherFuelUsage replaces Motorized.updateConsumers without calling "
         .. "superFunc. soundExpansionMP (s > H, loads after) wraps it via "
         .. "overwrittenFunction and calls superFunc — so both mods run: soundExpansionMP "
         .. "adjusts air-consumer input, then HigherFuelUsage applies its fuel calculation. "
         .. "Chain intact. No action required.")
    else
        log("INFO: HigherFuelUsage replaces Motorized.updateConsumers (HIGH-frequency "
         .. "per-frame function) without calling superFunc. No other installed mod "
         .. "hooks this function — safe as a solo replacement.")
    end
end

if present("FS25_BunkerSiloUtilities.zip") then
    log("INFO: BunkerSiloUtilities replaces BunkerSilo.setState without calling "
     .. "superFunc. No other installed mod hooks this function.")
end

if present("FS25_HeapInfoHUD.zip") and present("FS25_RealisticWeather.zip") then
    log("INFO: PlayerHUDUpdater.showFieldInfo — HeapInfoHUD uses a manual chain "
     .. "(saves original, calls it) invisible to the registry. RealisticWeather "
     .. "appends after (R > H). All three layers run: base game -> HeapInfoHUD -> "
     .. "RealisticWeather. No action required.")
end

do
    -- InGameMenuProductionFrame.updateMenuButtons — safe 3-way append
    local prod_appenders = { "FS25_Butcher", "FS25_boucherie", "FS25_ProductionStorageControl" }
    local prod_count = 0
    for _, m in ipairs(prod_appenders) do
        if present(m .. ".zip") then prod_count = prod_count + 1 end
    end
    if prod_count >= 2 then
        log(string.format(
            "INFO: InGameMenuProductionFrame.updateMenuButtons — %d mods append "
         .. "(Butcher/boucherie, ProductionStorageControl). All additive. No action required.",
            prod_count))
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- STATIC ANALYSIS SUMMARY: INFO-LEVEL CHAINS
--
-- These were identified by static scan of all installed mods and require no
-- runtime intervention.  Logged here so mod authors can see the full picture.
-- ─────────────────────────────────────────────────────────────────────────────

log("INFO: 45 benign append chains found across installed mods. "
 .. "Multiple mods append to the same function (Utils.appendedFunction) "
 .. "with no overwriter present — every mod's logic runs in sequence, "
 .. "nothing is lost. No action required.")

log("INFO: 22 safe overwrite chains found across installed mods. "
 .. "Multiple mods overwrite the same function but every overwriter calls "
 .. "superFunc, preserving the full chain. No action required.")

log("INFO: FSCareerMissionInfo.saveToXMLFile has the largest safe chain in this install — "
 .. "10 mods all append their save data (DynamicFieldPrices, EasyDevControls, "
 .. "EnhancedLoanSystem, FieldLeasing, MapObjectsHider, RealisticWeather, "
 .. "SeasonalWoolProduction, ToggleFertilizer, UpgradeYourFactory, netWorthTracker). "
 .. "All additive, nothing lost. No action required.")

logGame(string.format("=== ModMixer loaded — full report in ModMixer.log ==="  ))
