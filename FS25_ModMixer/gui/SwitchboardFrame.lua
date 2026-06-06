-- SwitchboardFrame.lua  (FS25_ModMixer, Stage 2 / step 3)
-- The in-game-menu page for the Switchboard. A TabbedMenuFrameElement subclass
-- holding a SmoothList of mod-feature rows, backed by a tiny list delegate that
-- reads ModMixerSwitchboard.registry and writes via setOverride/clearOverride.
-- Pattern modelled on FS25_RedTape (the Courseplay in-game-menu-page recipe).

-- unpack is global in FS25's Lua 5.1; table.unpack in newer Lua (e.g. lupa tests).
local unpack = unpack or table.unpack

-- ─────────────────────────────────────────────────────────────────────────────
-- VALUE SLIDER TEXTS  (must be above RowSource — populateCellForItemInSection
-- references valueTextsFor, and Lua locals aren't hoisted)
-- ─────────────────────────────────────────────────────────────────────────────
local _valueTextsCache = {}   -- [modName.."|"..featureId] = { texts, values }

local function valueTextsFor(row)
    if row == nil or row.vmin == nil or row.vmax == nil or row.vstep == nil then return nil end
    local key = (row.modName or "") .. "|" .. (row.featureId or "")
    if _valueTextsCache[key] ~= nil then return _valueTextsCache[key] end
    local texts, values = {}, {}
    local step = math.max(row.vstep, 1e-9)
    local v = row.vmin
    while v <= row.vmax + step * 0.01 do
        local snap = math.floor(v / step + 0.5) * step
        if snap > row.vmax + step * 0.01 then break end
        texts[#texts+1]   = string.format("%.4g", snap)
        values[#values+1] = snap
        v = snap + step
    end
    local entry = { texts = texts, values = values }
    _valueTextsCache[key] = entry
    return entry
end

-- ─────────────────────────────────────────────────────────────────────────────
-- LIST DELEGATE  (data source + selection delegate for the feature list)
-- ─────────────────────────────────────────────────────────────────────────────
local RowSource = {}
local RowSource_mt = Class(RowSource)

function RowSource.new()
    local self = setmetatable({}, RowSource_mt)
    self.rows = {}
    self.selectedRow = -1
    return self
end

function RowSource:setData(rows)
    self.rows = rows or {}
end

function RowSource:getNumberOfSections()
    return 1
end

function RowSource:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function RowSource:getTitleForSectionHeader(list, section)
    return ""
end

function RowSource:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil then return end

    local modEl    = cell:getAttribute("mod")
    local featEl   = cell:getAttribute("feature")
    local stateEl  = cell:getAttribute("state")
    local trackEl  = cell:getAttribute("valueScaleTrack")
    local fillEl   = cell:getAttribute("valueScaleFill")
    local sliderEl = cell:getAttribute("valueSlider")

    if modEl  ~= nil then modEl:setText(row.modLabel) end
    if featEl ~= nil then featEl:setText(row.featureLabel) end

    -- Value rows: smooth green fill bar + compact MTO slider. All others: state text.
    -- (Hiding the track hides its nested fill too; fill is also toggled explicitly.)
    local isValue = (row.kind == "value")
    if stateEl  ~= nil then pcall(function() stateEl:setVisible(not isValue) end) end
    if trackEl  ~= nil then pcall(function() trackEl:setVisible(isValue) end) end
    if sliderEl ~= nil then pcall(function() sliderEl:setVisible(isValue) end) end

    if isValue and sliderEl ~= nil then
        local tv = valueTextsFor(row)
        if tv ~= nil then
            pcall(function() sliderEl:setTexts(tv.texts) end)
            -- Current effective value: override if set, else live readout or default.
            local SB  = ModMixerSwitchboard
            local cur = SB and SB.getOverride and SB.getOverride(row.modName, row.featureId)
            if cur == nil then
                cur = (SB and SB.readLive and SB.readLive(row.modName, row.featureId))
                   or row.vdefault or row.vmin or 0
            end
            -- Find the nearest step index for this value.
            local state = 1
            local best  = math.huge
            for i, v in ipairs(tv.values) do
                local d = math.abs(v - cur)
                if d < best then best = d; state = i end
            end
            pcall(function() sliderEl:setState(state, false) end)
            -- Smooth fill bar: green fill width = fraction of the way min→max.
            -- RedTape recipe: fill width = inner track width × ratio (grows from
            -- the track's left edge since fill is nested in the track).
            if trackEl ~= nil and fillEl ~= nil then
                local ratio = (state - 1) / math.max(#tv.values - 1, 1)
                ratio = math.max(0, math.min(1, ratio))
                if ratio <= 0 then
                    -- At minimum: empty bar (grey track only).
                    pcall(function() fillEl:setVisible(false) end)
                else
                    pcall(function() fillEl:setVisible(true) end)
                    local margin = (fillEl.margin ~= nil and fillEl.margin[1]) or 0
                    local fullW  = ((trackEl.size ~= nil and trackEl.size[1]) or 0) - margin * 2
                    if fullW > 0 then
                        pcall(function() fillEl:setSize(fullW * ratio, nil) end)
                    end
                end
            end
        end
    else
        if stateEl ~= nil then stateEl:setText(row.stateText) end
        if fillEl  ~= nil then pcall(function() fillEl:setVisible(false) end) end
    end
end

function RowSource:onListSelectionChanged(list, section, index)
    self.selectedRow = index
    -- Notify the frame so it can update context-sensitive button labels.
    if self.onSelectionChanged ~= nil then self.onSelectionChanged() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

-- ASCII progress bar for value rows: "1.0  [======....]  (0.2-2.5)"
-- Still used for the state-text fallback path (row not a value, or slider hidden).
local function rangeBar(v, vmin, vmax)
    local lo, hi = vmin or 0, vmax or 1
    local ratio  = (v - lo) / math.max(hi - lo, 1e-9)
    ratio = math.max(0, math.min(1, ratio))
    local width = 10
    local pos   = math.floor(ratio * width + 0.5)
    return string.format("%.4g  [%s%s]  (%.4g-%.4g)",
        v,
        string.rep("=", pos),
        string.rep(".", width - pos),
        lo, hi)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Friendly names + categories for the tracked functions. Plain-English label
-- first, the code name shown after — so you don't need to know the FS codebase.
-- Category drives grouping/sort. (Grow alongside ModMixerHooks' TARGETS list.)
-- ─────────────────────────────────────────────────────────────────────────────
local TARGET_INFO = {
    ["WheelPhysics.serverUpdate"]                      = { name = "Wheel grip / sink (per-tick)",     cat = "Vehicle Physics" },
    ["WheelPhysics.finalize"]                          = { name = "Wheel setup",                      cat = "Vehicle Physics" },
    ["WheelPhysics.updateTireFriction"]                = { name = "Tire friction",                    cat = "Vehicle Physics" },
    ["WheelPhysics.updateContact"]                     = { name = "Tire ground contact (per-tick)",   cat = "Vehicle Physics" },
    ["WheelPhysics.updateFriction"]                    = { name = "Ground friction (weather/surface)",cat = "Vehicle Physics" },
    ["WheelPhysics.updateWheelFriction"]               = { name = "Wheel friction",                   cat = "Vehicle Physics" },
    ["WheelPhysics.updatePhysics"]                     = { name = "Wheel physics step",               cat = "Vehicle Physics" },
    ["WheelsUtil.updateWheelsPhysics"]                 = { name = "Drivetrain physics",               cat = "Vehicle Physics" },
    ["WheelsUtil.updateWheelsPhysicsGroundContact"]    = { name = "Wheel ground contact",             cat = "Vehicle Physics" },
    ["WheelsUtil.getSmoothedAcceleratorAndBrakePedals"]= { name = "Pedal smoothing",                  cat = "Vehicle Physics" },
    ["Drivable.updateVehiclePhysics"]                  = { name = "Vehicle drive physics",            cat = "Vehicle Physics" },
    ["Motorized.updateConsumers"]                      = { name = "Fuel / power use",                 cat = "Engine" },
    ["Motorized.onUpdate"]                             = { name = "Engine update",                    cat = "Engine" },
    ["Motorized.getMaxPtoRpm"]                         = { name = "PTO max RPM",                       cat = "Engine" },
    ["Motorized.getUseAutomaticGearShifting"]          = { name = "Auto gear shifting",               cat = "Engine" },
    ["Motorized.getUseAutomaticGroupShifting"]         = { name = "Auto group shifting",              cat = "Engine" },
    ["Vehicle.update"]                                 = { name = "Vehicle update",                   cat = "Vehicle Core" },
    ["Vehicle.updateTick"]                             = { name = "Vehicle tick",                     cat = "Vehicle Core" },
    ["Vehicle.onUpdate"]                               = { name = "Vehicle on-update",                cat = "Vehicle Core" },
    ["Vehicle.load"]                                   = { name = "Vehicle load",                     cat = "Vehicle Core" },
    ["Vehicle.getSpeedLimit"]                          = { name = "Speed limit",                      cat = "Vehicle Core" },
    ["FSBaseMission.update"]                           = { name = "Main game loop",                   cat = "Game Core" },
    ["FSBaseMission.sendInitialClientState"]           = { name = "Multiplayer sync (initial state)", cat = "Multiplayer" },
    ["FSBaseMission.onConnectionFinishedLoading"]      = { name = "Load finalization",                cat = "Game Core" },
    ["Sprayer.processSprayerArea"]                     = { name = "Spraying",                         cat = "Field Work" },
    ["Cutter.onEndWorkAreaProcessing"]                 = { name = "Harvester cutter",                 cat = "Field Work" },
    ["BunkerSilo.update"]                              = { name = "Bunker silo (per-frame)",          cat = "Bunkers" },
    ["BunkerSilo.load"]                                = { name = "Bunker silo load",                 cat = "Bunkers" },
    ["BunkerSilo.loadFromXMLFile"]                     = { name = "Bunker silo savegame",             cat = "Bunkers" },
    ["PlayerHUDUpdater.showSplitShapeInfo"]            = { name = "Wood info overlay",                cat = "HUD" },
    ["PlayerHUDUpdater.showFieldInfo"]                 = { name = "Field info overlay",               cat = "HUD" },
    ["ConstructionBrush.verifyAccess"]                 = { name = "Build / terraform permission",     cat = "Terraforming" },
    ["Farm.changeBalance"]                             = { name = "Money changes",                    cat = "Economy" },
    ["InfoDialog.show"]                                = { name = "Info dialogs",                     cat = "UI" },
    ["VehicleMaterial.apply"]                          = { name = "Vehicle material",                 cat = "Visual" },
    ["VehicleMaterial.applyToVehicle"]                 = { name = "Vehicle material (apply)",         cat = "Visual" },
    ["PlaceableProductionPoint.onFinalizePlacement"]   = { name = "Production placement",             cat = "Economy" },
    ["ProductionPoint.load"]                           = { name = "Production load",                  cat = "Economy" },
    ["DensityMapHeightManager.loadMapData"]            = { name = "Terrain height data",              cat = "Terraforming" },
    ["Weather.update"]                                 = { name = "Weather",                          cat = "Weather" },
    -- Damage / Wear — vehicle-health functions damage overhauls (ADS etc.) overwrite.
    ["Wearable.updateDamageAmount"]                    = { name = "Damage accumulation",              cat = "Damage / Wear" },
    ["Motorized.getCanMotorRun"]                       = { name = "Can engine run (breakdown)",       cat = "Damage / Wear" },
    ["Motorized.startMotor"]                           = { name = "Engine start",                     cat = "Damage / Wear" },
    ["Motorized.updateMotorTemperature"]               = { name = "Engine temperature",               cat = "Damage / Wear" },
    ["Vehicle.getSellPrice"]                           = { name = "Resale value (wear-adjusted)",     cat = "Damage / Wear" },
    ["Wearable.setOperatingTime"]                      = { name = "Operating hours",                  cat = "Damage / Wear" },
}

-- Plain-English definitions for the help box (top-right). Keyed by target. Kept in a
-- side table so TARGET_INFO stays compact; discovered targets fall back to a generic line.
local TARGET_DESC = {
    ["WheelPhysics.updateFriction"]     = "Ground grip from weather and surface — how wet/mud/road affect traction.",
    ["WheelPhysics.updateTireFriction"] = "Per-tire grip — seasonal tyres, pneumatics and pressure live here.",
    ["WheelPhysics.serverUpdate"]       = "The per-tick wheel physics step — sink, grip and rolling resistance.",
    ["WheelsUtil.updateWheelsPhysics"]  = "Drivetrain physics — how engine power reaches the wheels.",
    ["Drivable.updateVehiclePhysics"]   = "Core drive physics that moves the vehicle — steering and handling feel.",
    ["Drivable.getAccelerationAxis"]    = "Reads your throttle input each tick.",
    ["Drivable.getDecelerationAxis"]    = "Reads your brake input each tick.",
    ["Motorized.updateConsumers"]       = "Fuel and power draw — consumption realism mods change this.",
    ["Motorized.getCanMotorRun"]        = "Decides if the engine may run — breakdown/damage mods gate it here.",
    ["Motorized.startMotor"]            = "Engine start sequence.",
    ["Motorized.updateMotorTemperature"]= "Engine temperature simulation.",
    ["VehicleMotor.shiftGear"]          = "Gear changes — transmission/shift mods touch this.",
    ["VehicleMotor.applyTargetGear"]    = "Applies the selected gear ratio.",
    ["VehicleMotor.getMinMaxGearRatio"] = "The gearbox ratio range.",
    ["VehicleMotor.setLastRpm"]         = "Records engine RPM each tick.",
    ["PowerConsumer.getConsumedPtoTorque"] = "PTO load — how much torque an implement draws.",
    ["Wearable.updateDamageAmount"]     = "How fast wear/damage accumulates.",
    ["Wearable.setOperatingTime"]       = "Operating-hours tracking.",
    ["Vehicle.getSellPrice"]            = "Resale value (wear-adjusted) — damage/economy mods adjust it.",
    ["Vehicle.getSpeedLimit"]           = "The vehicle's speed limit.",
    ["Vehicle.updateMass"]              = "Total mass calculation — load/weight mods change it.",
    ["Sprayer.processSprayerArea"]      = "Spraying behaviour over the worked area.",
    ["Sprayer.onStartWorkAreaProcessing"]= "Start-of-pass spraying setup.",
    ["Cutter.onEndWorkAreaProcessing"]  = "Harvester cutter end-of-pass processing.",
    ["BunkerSilo.update"]               = "Bunker silo per-frame logic — compaction/fermentation mods stack here.",
    ["Farm.changeBalance"]              = "Every money change — economy/log mods watch this.",
    ["ConstructionBrush.verifyAccess"]  = "Permission to build/terraform at a spot.",
    ["Landscaping.hasObjectOverlapInModificationArea"] = "Terraforming overlap check — build-anywhere mods relax it.",
    ["I18N.getText"]                    = "Text/translation lookup.",
    ["InGameMenuSettingsFrame.updateButtons"] = "The settings menu's button bar.",
    ["WorkshopScreen.setVehicle"]       = "The workshop screen when a vehicle is selected.",
    ["ConstructionScreen.setBrush"]     = "The construction screen's active build tool.",
    ["Dashboard.defaultDashboardStateFunc"] = "Default cab dashboard readouts.",
    ["FSBaseMission.onMinuteChanged"]   = "Fires every in-game minute — schedulers hook it.",
    ["FSBaseMission.onHourChanged"]     = "Fires every in-game hour.",
    ["FSBaseMission.onDayChanged"]      = "Fires every in-game day.",
}

local CAT_ORDER = {
    ["Current Vehicle"]=98,   -- diagnostic panel — sort near the end, not dominating
    ["Live Mod Features"]=1, ["Vehicle Physics"]=2, ["Engine"]=3, ["Damage / Wear"]=4,
    ["Vehicle Core"]=5, ["Field Work"]=6, ["Bunkers"]=7, ["Economy"]=8, ["Terraforming"]=9,
    ["Weather"]=10, ["HUD"]=11, ["UI"]=12, ["Multiplayer"]=13, ["Game Core"]=14, ["Visual"]=15,
    ["Other"]=99,
}
local function catOrder(c) return CAT_ORDER[c] or 50 end

-- ─────────────────────────────────────────────────────────────────────────────
-- HELP TEXT (top-right box) + bottom legend, both per-tier. Defined BEFORE the frame
-- methods so updateHelp/updateChrome capture these as upvalues (Lua locals aren't
-- hoisted — a forward reference would silently read a nil global).
-- ─────────────────────────────────────────────────────────────────────────────
local DEFAULT_HELP = "Select a row to see what it does.\nSwitch View (top-left): Simple ranks mods, By category settles each realm, Advanced is full control."

local function prettyMod(m) return (string.gsub(tostring(m), "^FS25_", "")) end

-- Friendly area name for a hooked function (plain-English label, no code).
local function areaName(target)
    local info = TARGET_INFO[target]
        or (type(ModMixerTargetInfo) == "table" and ModMixerTargetInfo[target])
    if type(info) == "table" and info.name ~= nil then return info.name end
    return target
end

-- Category a fight belongs to (Vehicle Physics / Engine / …), from TARGET_INFO /
-- ModMixerTargetInfo — also PUBLISHED as ModMixerCategoryOf for Switchboard.buildConflicts.
local function areaCat(target)
    local info = TARGET_INFO[target]
        or (type(ModMixerTargetInfo) == "table" and ModMixerTargetInfo[target])
    if type(info) == "table" and info.cat ~= nil then return info.cat end
    return "Other"
end
ModMixerCategoryOf = areaCat

-- Definition of a hooked function: friendly name — what it does   [code name].
local function targetHelp(target)
    if target == nil then return "" end
    local info = TARGET_INFO[target] or (type(ModMixerTargetInfo) == "table" and ModMixerTargetInfo[target])
    local name = (type(info) == "table" and info.name) or target
    local desc = TARGET_DESC[target]
        or (type(info) == "table" and info.desc)
        or "An engine function several mods hook."
    return name .. " \226\128\148 " .. desc .. "\n[" .. tostring(target) .. "]"
end

-- Build the help-box text for the selected row.
local function helpForRow(row)
    if row == nil then return DEFAULT_HELP end
    local rt = row.rowType
    if rt == "basicPriority" then
        return "SEATING \226\128\148 rank this mod. Higher = it wins its conflicts in EVERY category. "
            .. "Promote (Space) or Move \226\150\178\226\150\188 to re-rank."
    elseif rt == "catPriority" then
        return "CATEGORY RANK \226\128\148 rank this mod within " .. (row.catName or "this realm")
            .. ". Higher = it wins this realm's conflicts. Per-realm so it never competes with mods elsewhere."
    elseif rt == "basicFight" then
        return "STOMP \226\128\148 one mod's version can override the others here. Change winner (Space) keeps "
            .. "one; the rest sit out. Clear pick returns to your ranking.\n" .. targetHelp(row.target)
    elseif rt == "basicShared" then
        return "SHARED \226\128\148 all these mods run together; the last one has the final say. Nothing is removed.\n"
            .. targetHelp(row.target)
    elseif rt == "basicIncompat" then
        return "INCOMPATIBLE \226\128\148 these mods fundamentally fight and ModMixer can't merge them. "
            .. "Keep only one installed."
    elseif rt == "basicInfo" then
        return row.featureLabel or ""
    elseif rt == "feature" then
        return "Live setting from " .. (row.modLabel or "this mod")
            .. ". Change it with the action keys; it applies immediately in-game."
    elseif rt == "hook" then
        local s = targetHelp(row.featureId)
        if row.locked then s = s .. "\nLoad-critical \226\128\148 cannot be vetoed (removing it can hang the load)." end
        return s
    elseif rt == "vehicleState" then
        return "Live read-only state of your current vehicle (updates ~2x/sec). Wheel rows show "
            .. "MoreRealistic's computed per-wheel grip / load / rolling-resistance \226\128\148 compare LEFT "
            .. "vs RIGHT to spot a veer, or watch the Grip spread row."
    elseif rt == "reviewRedundancy" then
        local a = "A: " .. (row.descA ~= nil and row.descA ~= "" and row.descA or "(no description)")
        local b = "B: " .. (row.descB ~= nil and row.descB ~= "" and row.descB or "(no description)")
        return "POSSIBLE DUPLICATE \226\128\148 two mods may do the same job. Read both; keep one if so. "
            .. "Dismiss (Space) if they're actually different.\n" .. a .. "\n" .. b
    elseif rt == "reviewHud" then
        return "HUD OVERLAP \226\128\148 these mods all draw the same HUD area, so they can collide visually "
            .. "(e.g. a vanished weather panel). ModMixer can't mute HUD draws \226\128\148 if one misbehaves, "
            .. "remove that mod. Dismiss (Space) to hide.\n[" .. (row.target or "") .. "]"
    elseif rt == "reviewIncompat" then
        return "INCOMPATIBLE \226\128\148 these mods replace the same system and can't coexist cleanly. "
            .. "Keep only one installed. Dismiss (Space) to hide."
    elseif rt == "reviewInfo" then
        return row.featureLabel or ""
    end
    return DEFAULT_HELP
end

-- Bottom-legend text per tier.
local TIER_LEGEND = {
    seating  = "SIMPLE \226\128\148 rank your mods; a higher seat wins its conflicts everywhere. Switch View top-left.",
    category = "BY CATEGORY \226\128\148 settle one realm at a time. Change winner picks a fight; Promote/Move ranks within the realm; shared stacks all run.",
    advanced = "ADVANCED \226\128\148 #/# = firing position; [ow] overwrites (wraps inner); [ow!] may STOMP inner mods. Move reorders (restart). Make-Winner mutes others (restart).",
    review   = "REVIEW \226\128\148 things worth a look: duplicate-purpose mods, incompatible pairs, HUD overlaps. Select a row for the evidence; Dismiss (Space) hides ones you've judged.",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- FRAME
-- ─────────────────────────────────────────────────────────────────────────────
ModMixerSwitchboardFrame = {}
ModMixerSwitchboardFrame._mt = Class(ModMixerSwitchboardFrame, TabbedMenuFrameElement)

function ModMixerSwitchboardFrame.new(i18n)
    local self = ModMixerSwitchboardFrame:superClass().new(nil, ModMixerSwitchboardFrame._mt)
    self.name = "ModMixerSwitchboardFrame"
    self.i18n = i18n
    self.rowSource = RowSource.new()
    self.menuButtonInfo = {}
    -- Category filter state. activeCategory == "All" shows everything; otherwise
    -- only rows in that category. filterCats is rebuilt from present rows on open.
    self.activeCategory = "All"
    self.filterCats = { "All" }
    return self
end

-- Called by g_gui:loadGui once element ids are bound to self.<id>.
function ModMixerSwitchboardFrame:onGuiSetupFinished()
    ModMixerSwitchboardFrame:superClass().onGuiSetupFinished(self)
    if self.featureList ~= nil then
        self.featureList:setDataSource(self.rowSource)
        self.featureList:setDelegate(self.rowSource)
        -- When the selection changes, refresh button labels AND the help box so both
        -- match the selected row type (toggle vs value vs hook vs fight…).
        self.rowSource.onSelectionChanged = function()
            self:setMenuButtonInfoDirty()
            self:updateHelp()
        end
    end
end

-- Help box (top-right): explain the selected row in plain English.
function ModMixerSwitchboardFrame:updateHelp()
    if self.featureHelp == nil then return end
    local ok, txt = pcall(helpForRow, self:getSelectedRow())
    pcall(function() self.featureHelp:setText((ok and txt) or "") end)
end

-- Chrome that follows the active tier: the VIEW switch position + the bottom legend.
function ModMixerSwitchboardFrame:updateChrome()
    local mode = (ModMixerSwitchboard ~= nil and ModMixerSwitchboard.mode) or "seating"
    if self.headerInfo ~= nil then
        pcall(function() self.headerInfo:setText(TIER_LEGEND[mode] or "") end)
    end
    if self.tierSwitch ~= nil then
        local idx = (mode == "seating" and 1) or (mode == "category" and 2)
                 or (mode == "advanced" and 3) or 4
        pcall(function() self.tierSwitch:setTexts({ "Simple", "By category", "Advanced", "Review" }) end)
        pcall(function() self.tierSwitch:setState(idx, false) end)
    end
end

-- VIEW switch clicked (Simple / By category / Advanced) — set the tier and rebuild.
function ModMixerSwitchboardFrame:onTierSwitchChanged(state)
    local s = state
    if type(s) ~= "number" and self.tierSwitch ~= nil then s = self.tierSwitch:getState() end
    local mode = (s == 1 and "seating") or (s == 2 and "category")
              or (s == 3 and "advanced") or "review"
    if ModMixerSwitchboard ~= nil and ModMixerSwitchboard.setMode ~= nil then
        ModMixerSwitchboard.setMode(mode)
    end
    self:rebuildFilterCats()
    self:refresh()
    self:updateChrome()
    self:updateHelp()
    self:setMenuButtonInfoDirty()
end

function ModMixerSwitchboardFrame:initialize()
    ModMixerSwitchboardFrame:superClass().initialize(self)

    self.btnBack = { inputAction = InputAction.MENU_BACK }

    -- Category paging — custom actions so they don't conflict with the sidebar
    -- MENU_PAGE_PREV/NEXT (Q/E), which the menu container intercepts for tab
    -- switching. Player assigns keys in Settings > Controls.
    self.btnFilterPrev = {
        inputAction = "ModMixer_SB_FILTER_PREV",
        text = "Prev category",
        callback = function() self:onFilterStep(-1) end,
    }
    self.btnFilterNext = {
        inputAction = "ModMixer_SB_FILTER_NEXT",
        text = "Next category",
        callback = function() self:onFilterStep(1) end,
    }

    -- Primary action: context-sensitive label (Toggle / Step + / Veto hook / …)
    self.btnActivate = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = "Toggle",
        callback = function() self:onActivate() end,
    }
    -- Secondary action: Clear override (toggle/hook) OR Step − (value)
    self.btnExtra1 = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = "Clear override",
        callback = function() self:onExtra1() end,
    }
    -- Tertiary action (value rows only): Reset to default
    self.btnExtra2 = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = "Reset to default",
        callback = function() self:onExtra2() end,
    }

    -- Reorder a contended hook chain: custom actions so they never conflict with
    -- the sidebar (MENU_PAGE_PREV/NEXT = Q/E = tab switching). Player assigns
    -- keys in Settings > Controls — any key that works for their layout.
    self.btnMoveUp = {
        inputAction = "ModMixer_SB_MOVE_EARLIER",
        text = "Move earlier",
        callback = function() self:onMoveHook(-1) end,
    }
    self.btnMoveDown = {
        inputAction = "ModMixer_SB_MOVE_LATER",
        text = "Move later",
        callback = function() self:onMoveHook(1) end,
    }

    -- Reset buttons — three escalating tiers, all on Backspace (defaults in modDesc).
    -- Row = instant (low stakes, easily redone). Page/All = confirmation dialog.
    -- The key combo is spelled out in the label text because the engine glyph only
    -- shows the modifier ("SHIFT"), not the +Backspace.
    self.btnResetOne = {
        inputAction = "ModMixer_SB_RESET_ONE",
        text = "Reset row (Backspace)",
        callback = function() self:onResetOne() end,
    }
    self.btnResetPage = {
        inputAction = "ModMixer_SB_RESET_PAGE",
        text = "Reset page (Ctrl+Backspace)",
        callback = function() self:onResetPageConfirm() end,
    }
    self.btnResetAll = {
        inputAction = "ModMixer_SB_RESET_ALL",
        text = "Reset all (Shift+Backspace)",
        callback = function() self:onResetAllConfirm() end,
    }
end

-- Context-sensitive button set. Called by the menu system whenever
-- isMenuButtonInfoDirty is true (set on frame open and on selection change).
function ModMixerSwitchboardFrame:getMenuButtonInfo()
    local row = self:getSelectedRow()
    local SB  = ModMixerSwitchboard

    -- extras = category filter nav (if multiple cats) + reset buttons (always).
    -- Reset buttons are last so they don't displace context-sensitive ones.
    local extras = {}
    if #self.filterCats > 1 then
        extras[#extras+1] = self.btnFilterPrev
        extras[#extras+1] = self.btnFilterNext
    end
    extras[#extras+1] = self.btnResetOne
    extras[#extras+1] = self.btnResetPage
    extras[#extras+1] = self.btnResetAll

    -- Basic-mode rows (and the mode toggle, present in both modes).
    if row ~= nil and row.rowType == "modeToggle" then
        self.btnActivate.text = "Switch"
        return { self.btnBack, self.btnActivate }
    end
    if row ~= nil and row.rowType == "basicFight" then
        self.btnActivate.text = "Change winner"
        self.btnExtra1.text   = "Clear pick"
        return { self.btnBack, self.btnActivate, self.btnExtra1, unpack(extras) }
    end
    if row ~= nil and (row.rowType == "basicPriority" or row.rowType == "catPriority") then
        self.btnActivate.text = "Promote"
        return { self.btnBack, self.btnActivate, self.btnMoveUp, self.btnMoveDown, unpack(extras) }
    end
    if row ~= nil and (row.rowType == "basicIncompat" or row.rowType == "basicInfo"
                       or row.rowType == "basicShared") then
        return { self.btnBack, unpack(extras) }   -- info only
    end

    if row == nil or row.rowType == "header" or row.rowType == "vehicleState" then
        return { self.btnBack, unpack(extras) }   -- read-only rows: no actions
    end

    if row.kind == "value" then
        self.btnActivate.text = "Step +"
        self.btnExtra1.text   = "Step -"
        self.btnExtra2.text   = "Reset"
        return { self.btnBack, self.btnActivate, self.btnExtra1, self.btnExtra2, unpack(extras) }
    end

    if row.rowType == "hook" then
        if row.locked then
            self.btnActivate.text = "(load-critical)"
            return { self.btnBack, self.btnActivate, unpack(extras) }
        end
        local vetoed = SB ~= nil and SB.isHookVetoed ~= nil
                       and SB.isHookVetoed(row.modName, row.featureId)
        self.btnActivate.text = vetoed and "Un-veto" or "Veto hook"
        self.btnExtra1.text   = "Clear veto"
        -- Consecutive target → offer winner-pick + reorder (all consecutive chains).
        -- [ow]/[ow!] rows: order controls who wraps whom + whose return value wins.
        if row.consecutive then
            self.btnExtra2.text = row.isWinner and "Clear winner" or "Make winner"
            if row.reorderable then
                return { self.btnBack, self.btnActivate, self.btnExtra1, self.btnExtra2,
                         self.btnMoveUp, self.btnMoveDown, unpack(extras) }
            end
            return { self.btnBack, self.btnActivate, self.btnExtra1, self.btnExtra2, unpack(extras) }
        end
        return { self.btnBack, self.btnActivate, self.btnExtra1, unpack(extras) }
    end

    -- toggle row (default)
    self.btnActivate.text = "Toggle"
    self.btnExtra1.text   = "Clear override"
    return { self.btnBack, self.btnActivate, self.btnExtra1, unpack(extras) }
end

-- Collect the flat, unsorted, UNFILTERED row data (feature rows + hook rows) from
-- the switchboard registry (installed registered mods only). buildRows() filters,
-- sorts and inserts headers on top of this.
-- Scan-elimination: name a deferred "(unknown)" hook by subtracting the mods we DID
-- name on this target from the static hook-map (ModMixerHookMap, bundled + regenerated
-- offline), intersected with installed mods. `debug` is unavailable in-game so this
-- offline cross-reference is the ONLY way to attribute a deferred hook. Returns a
-- display label: "ModName  (inferred)" on a clean singleton; "(unknown — maybe a / b)"
-- when several fit; or nil to keep the plain "(unknown)".
local function inferUnknownLabel(target, hookerMods)
    -- HIDDEN HOOK takes priority: the interceptor flagged this target as carrying a
    -- hook installed by a dynamic pattern (a runtime-built method name, a local alias)
    -- that NO zip scan can attribute — distinct from a deferred hook the hook-map will
    -- name. (Set in ModMixerHooks.coverageLog when every offline-known hooker is already
    -- named yet an unknown remains, e.g. the 4th overwrite on the steering chain.)
    if type(Utils) == "table" and type(Utils.__ms_hiddenHooks) == "table"
        and Utils.__ms_hiddenHooks[target] then
        return "(hidden — dynamic hook, unidentifiable)"
    end
    if type(ModMixerHookMap) ~= "table" then return nil end
    local candidates = ModMixerHookMap[target]
    if type(candidates) ~= "table" then return nil end
    local named, nUnknown = {}, 0
    for _, m in ipairs(hookerMods) do
        if m == "(unknown)" then nUnknown = nUnknown + 1 else named[m] = true end
    end
    local left = {}
    for _, m in ipairs(candidates) do
        local installed = (g_modManager ~= nil and g_modManager:getModByName(m) ~= nil)
        if installed and not named[m] then left[#left + 1] = m end
    end
    if #left == 0 then
        -- Every offline-known hooker is named. Whether this leftover unknown is a HIDDEN
        -- dynamic hook or just a per-type dupe of a named mod is decided by the
        -- interceptor's distinct-impl tally — surfaced via Utils.__ms_hiddenHooks
        -- (checked at the top) and Utils.__ms_redundantUnknown (suppresses the row in
        -- collectRows). Nothing left to infer by name here.
        return nil
    end
    local function pretty(s) return (string.gsub(s, "^FS25_", "")) end
    if #left == 1 and nUnknown == 1 then
        return pretty(left[1]) .. "  (inferred)"
    end
    local names = {}
    for i, m in ipairs(left) do names[i] = pretty(m) end
    return "(unknown — maybe: " .. table.concat(names, " / ") .. ")"
end

-- ─── #3: live read-only state of the player's current vehicle ─────────────────
-- The lens for STATE conflicts the hook view can't show (e.g. two damage mods
-- fighting over the same spec_wearable value — ADS vs RealisticDamage). Read-only
-- rows, refreshed live by update() while the "Current Vehicle" category is active.
-- RE-ENABLED 2026-06-06: now also the per-wheel MoreRealistic physics diagnostic
-- (friction L↔R, load, rolling resistance) for diagnosing modded-vehicle veer / brakes.
local SHOW_VEHICLE_STATE = true
local function controlledVehicle()
    if g_currentMission == nil then return nil end
    local v = g_currentMission.controlledVehicle
    if v == nil and g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local ok, r = pcall(function() return g_localPlayer:getCurrentVehicle() end)
        if ok then v = r end
    end
    return v
end

local function vehicleStateRows()
    local v = controlledVehicle()
    local out = {}
    if v == nil then
        out[1] = { rowType = "vehicleState", category = "Current Vehicle", orderIdx = 1,
            modName = "(none)", modLabel = "—", featureId = "cv.none",
            featureLabel = "No vehicle entered", stateText = "enter a vehicle to watch its live state" }
        return out
    end
    local name = "Vehicle"
    pcall(function() if v.getFullName ~= nil then name = v:getFullName() end end)
    local idx = 0
    local function add(label, fn)
        local ok, val = pcall(fn)
        if ok and val ~= nil then
            idx = idx + 1
            out[#out + 1] = { rowType = "vehicleState", category = "Current Vehicle", orderIdx = idx,
                modName = name, modLabel = name, featureId = "cv." .. idx,
                featureLabel = label, stateText = tostring(val) }
        end
    end
    add("Damage", function()
        local d = (v.getDamageAmount ~= nil) and v:getDamageAmount()
            or (v.spec_wearable ~= nil and v.spec_wearable.damageAmount)
        if type(d) ~= "number" then return nil end
        return string.format("%.0f %%", d * 100)
    end)
    add("Wear / operating hours", function()
        local t = (v.getOperatingTime ~= nil) and v:getOperatingTime() or nil
        if type(t) ~= "number" then return nil end
        return string.format("%.1f h", t / (1000 * 60 * 60))
    end)
    add("Engine temperature", function()
        local m  = v.spec_motorized
        local mt = m and m.motorTemperature
        local val = (type(mt) == "table") and mt.value or mt
        if type(val) ~= "number" then return nil end
        return string.format("%.0f \194\176C", val)
    end)
    add("Engine RPM", function()
        local m = v.spec_motorized
        if m == nil or m.motor == nil or m.motor.getLastModulatedMotorRpm == nil then return nil end
        return string.format("%.0f rpm", m.motor:getLastModulatedMotorRpm())
    end)
    add("Speed", function()
        if v.getLastSpeed == nil then return nil end
        return string.format("%.0f km/h", v:getLastSpeed())
    end)
    add("Total mass", function()
        if v.getTotalMass == nil then return nil end
        return string.format("%.1f t", v:getTotalMass())
    end)

    -- ── Per-wheel MoreRealistic physics — the veer / grip diagnosis ──────────────
    -- MR computes each wheel's grip (tireGroundFrictionCoeff × mrDynamicFrictionScale),
    -- load and rolling resistance. On a modded vehicle MR couldn't hand-tune, these can
    -- come out ASYMMETRIC (left ≠ right) → the vehicle pulls to one side. Compare the
    -- wheel rows, and the spread row flags it.
    local okW, wheels = pcall(function() return v.spec_wheels and v.spec_wheels.wheels end)
    if okW and type(wheels) == "table" and #wheels > 0 then
        local function sideOf(w)
            local ok, x = pcall(function()
                local n = w.node or (w.physics and w.physics.wheel and w.physics.wheel.node)
                if n == nil or getTranslation == nil then return nil end
                local tx = getTranslation(n)
                return tx
            end)
            if ok and type(x) == "number" then
                return (x < -0.05 and "L") or (x > 0.05 and "R") or "C"
            end
            return "?"
        end
        local grips = {}
        for i, w in ipairs(wheels) do
            local p = w.physics
            if type(p) == "table" then
                local coeff = p.tireGroundFrictionCoeff
                local scale = p.mrDynamicFrictionScale
                local grip  = (type(coeff) == "number" and type(scale) == "number") and (coeff * scale)
                           or (type(coeff) == "number" and coeff) or nil
                if type(grip) == "number" then grips[#grips + 1] = grip end
                local parts = {}
                if type(grip)  == "number" then parts[#parts + 1] = string.format("grip %.2f", grip) end
                if type(scale) == "number" then parts[#parts + 1] = string.format("scale %.2f", scale) end
                if type(p.mrLastTireLoadS) == "number" then parts[#parts + 1] = string.format("load %.0f", p.mrLastTireLoadS) end
                if type(p.mrLastRrFx)      == "number" then parts[#parts + 1] = string.format("RR %.2f", p.mrLastRrFx) end
                idx = idx + 1
                out[#out + 1] = { rowType = "vehicleState", category = "Current Vehicle", orderIdx = idx,
                    modName = name, modLabel = name, featureId = "cv.w" .. i,
                    featureLabel = string.format("Wheel %d (%s)", i, sideOf(w)),
                    stateText = (#parts > 0 and table.concat(parts, "   ")) or "no MR data (not converted)" }
            end
        end
        if #grips >= 2 then
            local lo, hi = grips[1], grips[1]
            for _, g in ipairs(grips) do lo = math.min(lo, g); hi = math.max(hi, g) end
            local spread = (hi > 0) and ((hi - lo) / hi) or 0
            idx = idx + 1
            out[#out + 1] = { rowType = "vehicleState", category = "Current Vehicle", orderIdx = idx,
                modName = name, modLabel = name, featureId = "cv.spread",
                featureLabel = "Grip spread (veer check)",
                stateText = string.format("min %.2f / max %.2f   \226\134\146   %s", lo, hi,
                    (spread > 0.25 and "ASYMMETRIC \226\128\148 likely veers") or "balanced") }
        end
    end
    return out
end

function ModMixerSwitchboardFrame:collectRows()
    local SB = ModMixerSwitchboard
    if SB == nil then return {} end
    local data = {}

    -- Live mod-feature rows (instant toggles/values — e.g. FarmKit, DDP).
    if SB.registry ~= nil then
        for modName, entry in pairs(SB.registry) do
            local installed = (g_modManager ~= nil and g_modManager:getModByName(modName) ~= nil)
            if installed and entry.features ~= nil then
                for _, f in ipairs(entry.features) do
                    -- (Same `false or nil` trap as `live` below — fetch explicitly.)
                    local ov = nil
                    if SB.getOverride ~= nil then ov = SB.getOverride(modName, f.id) end
                    local kind = f.kind or "toggle"
                    -- The mod's CURRENT live value (not our override) — lets an
                    -- un-overridden row show "SetByMod (ON)" / "SetByMod 1.0 [bar]"
                    -- so it's never confused with a forced ON/OFF of equal effect.
                    -- (Don't use `and ... or nil`: a legit `false` reading would
                    -- collapse to nil via Lua's `false or nil`.)
                    local live = nil
                    if SB.readLive ~= nil then live = SB.readLive(modName, f.id) end
                    local stateText

                    if kind == "value" then
                        if ov ~= nil then
                            stateText = rangeBar(ov, f.min, f.max) .. "  (set)"
                        elseif type(live) == "number" then
                            stateText = "SetByMod  " .. rangeBar(live, f.min, f.max)
                        else
                            local def = f.default or f.min or 0
                            stateText = "SetByMod  " .. rangeBar(def, f.min, f.max)
                        end
                    else  -- toggle
                        if ov == true then        stateText = "ON  (set)"
                        elseif ov == false then   stateText = "OFF  (set)"
                        elseif live == true then  stateText = "SetByMod (ON)"
                        elseif live == false then stateText = "SetByMod (OFF)"
                        else                       stateText = "SetByMod"
                        end
                    end

                    data[#data + 1] = {
                        rowType = "feature", category = "Live Mod Features",
                        modName = modName, modLabel = entry.label or modName,
                        featureId = f.id, featureLabel = f.label or f.id,
                        kind = kind, stateText = stateText,
                        vmin = f.min, vmax = f.max, vstep = f.step, vdefault = f.default,
                    }
                end
            end
        end
    end

    -- Hook veto rows (restart-to-apply). Friendly name + code name; load-critical
    -- hooks are shown locked.
    local reg    = Utils ~= nil and Utils.__ms_hooksByMod or nil
    local noVeto = Utils ~= nil and Utils.__ms_noVeto or {}
    if reg ~= nil then
        -- A target whose leftover "(unknown)" is just the same mod re-registered per
        -- vehicle type (impls <= named, decided by the interceptor) — fold it out so it
        -- isn't counted as a distinct hooker. Without this, single-source ADS targets
        -- (startMotor, updateDamageAmount, …) would show "ADS + (unknown)" when there's
        -- really only one ADS hook applied per type.
        local redundant = (type(Utils) == "table" and type(Utils.__ms_redundantUnknown) == "table")
            and Utils.__ms_redundantUnknown or {}

        -- First pass: which mods hook each target (the contest map), each tagged
        -- with its true install seq + kind. A target with 2+ hookers is a
        -- "consecutive" chain → eligible for winner-pick / reorder.
        local hookersByTarget = {}
        for modName, targets in pairs(reg) do
            for target, e in pairs(targets) do
                if not (modName == "(unknown)" and redundant[target]) then
                    local list = hookersByTarget[target]
                    if list == nil then list = {}; hookersByTarget[target] = list end
                    list[#list + 1] = { mod = modName, seq = (e and e.seq) or 0, kind = (e and e.kind) or "append" }
                end
            end
        end

        -- Order each target's hookers: the user's saved reorder if any, else true
        -- install (= firing) order from the recorded seq.
        for target, list in pairs(hookersByTarget) do
            local desired = SB.getHookOrder ~= nil and SB.getHookOrder(target) or nil
            if desired ~= nil then
                local rank = {}
                for i, m in ipairs(desired) do rank[m] = i end
                table.sort(list, function(a, b)
                    local ra, rb = rank[a.mod] or 1e9, rank[b.mod] or 1e9
                    if ra ~= rb then return ra < rb end
                    return (a.seq or 0) < (b.seq or 0)
                end)
            else
                table.sort(list, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
            end
        end

        for modName, targets in pairs(reg) do
            for target, e in pairs(targets) do
                -- Skip the redundant per-type "(unknown)" row (folded out of the contest
                -- map above) — it's the same mod re-registered per vehicle type, not a
                -- distinct hooker.
                local skipRow = (modName == "(unknown)") and redundant[target]
                -- Hand-curated info first; else the auto-derived info for a discovered
                -- (wider-net) target; else a plain default.
                local info   = TARGET_INFO[target]
                    or (type(ModMixerTargetInfo) == "table" and ModMixerTargetInfo[target])
                    or { name = target, cat = "Other" }
                local locked = noVeto[target] == true
                local vetoed = SB.isHookVetoed ~= nil and SB.isHookVetoed(modName, target)
                local list   = hookersByTarget[target]
                local nHook  = #list
                local consecutive = (nHook >= 2) and not locked

                -- This mod's own hook kind, position in the chain, and the ordered
                -- mod-name list. Load-critical targets excluded via locked/noVeto.
                local thisKind = (e and e.kind) or "append"
                local orderIdx = nil
                local hookerMods = {}
                for i, h in ipairs(list) do
                    hookerMods[i] = h.mod
                    if h.mod == modName then orderIdx = i end
                end
                local hasCustomOrder = SB.getHookOrder ~= nil and SB.getHookOrder(target) ~= nil
                local reorderable    = consecutive   -- all consecutive chains are reorderable

                -- Among a consecutive target's hookers, count how many are NOT vetoed.
                -- Exactly one non-vetoed = a decided winner.
                local nonVetoed = 0
                if consecutive then
                    for _, h in ipairs(list) do
                        if not (SB.isHookVetoed ~= nil and SB.isHookVetoed(h.mod, target)) then
                            nonVetoed = nonVetoed + 1
                        end
                    end
                end
                local isWinner = consecutive and not vetoed and nonVetoed == 1

                -- State text: compact, per-row.
                -- [ow]  = this hook overwrites (wraps the chain inside it via superFunc).
                --         At innermost position (1): only wraps the base game — limited risk.
                -- [ow!] = overwrite at non-innermost position: has other mod hooks inside it
                --         that it may be STOMPING if it never calls superFunc.
                -- No marker on append/prepend rows (can't stomp by construction).
                local isStompRisk = (thisKind == "overwrite") and consecutive and (orderIdx or 1) > 1
                local kindTag = ""
                if thisKind == "overwrite" then
                    kindTag = isStompRisk and " [ow!]" or " [ow]"
                end

                local stateText
                if locked     then stateText = "load-critical"
                elseif vetoed then stateText = "VETOED (restart)"
                elseif isWinner then stateText = "WINNER (restart)"
                elseif hasCustomOrder and consecutive then
                    stateText = string.format("reordered %d/%d%s", orderIdx or 0, nHook, kindTag)
                elseif consecutive then
                    stateText = string.format("%d/%d%s", orderIdx or 0, nHook, kindTag)
                else
                    stateText = "active"
                end

                -- Inferred hooks are now named at install (scan-elimination) and
                -- recorded under their REAL mod name, so they're fully actionable
                -- (veto/winner/reorder). Tag them "(inferred)" for honesty. Anything
                -- still "(unknown)" (not in map, or ambiguous) falls back to a maybe-list.
                local displayLabel = (string.gsub(modName, "^FS25_", ""))
                if e ~= nil and e.inferred then
                    displayLabel = displayLabel .. "  (inferred)"
                elseif modName == "(unknown)" then
                    local lbl = inferUnknownLabel(target, hookerMods)
                    if lbl ~= nil then displayLabel = lbl end
                end

                if not skipRow then
                data[#data + 1] = {
                    rowType = "hook", category = info.cat,
                    modName = modName, modLabel = displayLabel,
                    featureId = target, featureLabel = info.name .. "   —   " .. target,
                    locked = locked, stateText = stateText,
                    consecutive = consecutive, hookers = hookerMods, isWinner = isWinner,
                    orderIdx = orderIdx, reorderable = reorderable, hasCustomOrder = hasCustomOrder,
                    hookKind = thisKind,
                }
                end
            end
        end
    end

    -- #3: live read-only state of the player's current vehicle. (Disabled — see flag.)
    if SHOW_VEHICLE_STATE then
        for _, r in ipairs(vehicleStateRows()) do data[#data + 1] = r end
    end

    return data
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BASIC MODE VIEW  (the friendly tiered face). prettyMod / areaName / areaCat and the
-- ModMixerCategoryOf publish live ABOVE (near the help helpers).
-- ─────────────────────────────────────────────────────────────────────────────
-- Basic-tier section order: Seating pinned first, Incompatible last, fight categories
-- in the same order as the Advanced view (CAT_ORDER via catOrder).
local BASIC_CAT_ORDER = { ["Seating"] = -2, ["King Pins"] = -1, ["Incompatible"] = 95 }
local function basicCatOrder(c) return BASIC_CAT_ORDER[c] or catOrder(c) end

local function basicHeader(rows, title)
    rows[#rows + 1] = {
        rowType  = "header",
        modLabel = "\226\148\128\226\148\128  " .. string.upper(title) .. "  \226\148\128\226\148\128",
        featureLabel = "", stateText = "",
    }
end

-- The three tiers, and the mode-toggle row that shows the current tier + what SPACE
-- switches to next (seating → category → advanced → seating).
local TIER_NAME = { seating = "Simple",  category = "By category", advanced = "Advanced", review = "Review" }
local TIER_NEXT = { seating = "category", category = "advanced",   advanced = "review",   review = "seating" }
local TIER_DESC = { seating = "rank your mods \226\128\148 higher wins everywhere",
                    category = "settle conflicts within each realm",
                    advanced = "full hook chains & manual control" }
local function modeToggleRow(mode)
    local nxt = TIER_NEXT[mode] or "seating"
    return {
        rowType = "modeToggle",
        modLabel = "\226\154\153  Mode: " .. (TIER_NAME[mode] or "?"),   -- ⚙
        featureLabel = TIER_DESC[mode] or "",
        stateText = "SPACE \226\134\146 " .. (TIER_NAME[nxt] or "?"),    -- →
    }
end

-- TIER 1 (Seating): one simple GLOBAL ranked list of the heavy-hitter mods (those in 2+
-- stomp fights). Rank with Move ▲▼; higher wins its stomps everywhere. Plus incompatible.
function ModMixerSwitchboardFrame:collectSeatingRows()
    local SB = ModMixerSwitchboard
    local data = {}
    if SB == nil or SB.buildConflicts == nil then return data end
    local conflicts = SB.buildConflicts()
    local stomps, incompat = {}, {}
    for _, c in ipairs(conflicts) do
        if c.kind == "hook" and (c.resolvability == "clean" or c.resolvability == "partial") then
            stomps[#stomps + 1] = c
        elseif c.kind == "incompatible" then
            incompat[#incompat + 1] = c
        end
    end
    local cnt, wins = {}, {}
    for _, c in ipairs(stomps) do
        local winner = SB.rankWinner(c.target, c.mods, c.category)
        for _, m in ipairs(c.mods) do cnt[m] = (cnt[m] or 0) + 1 end
        wins[winner] = (wins[winner] or 0) + 1
    end

    data[#data + 1] = {
        rowType = "basicInfo", category = "Seating", basicSort = 0,
        modLabel = "Conflicts to settle",
        featureLabel = string.format("%d stomp(s) to arbitrate, %d incompatible pair(s)", #stomps, #incompat),
        stateText = "",
    }

    local prank = {}
    for i, m in ipairs(SB.priorityGlobal) do prank[m] = i end
    local kings = {}
    for m, c in pairs(cnt) do if c >= 2 then kings[#kings + 1] = m end end
    table.sort(kings, function(a, b)
        local ra, rb = prank[a], prank[b]
        if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
        if ra ~= nil and rb ~= nil then return ra < rb end
        if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end
        return prettyMod(a) < prettyMod(b)
    end)
    for i, m in ipairs(kings) do
        local rankTxt = prank[m] and ("seat #" .. prank[m]) or "not seated"
        data[#data + 1] = {
            rowType = "basicPriority", category = "Seating", basicSort = 1, sortIdx = i,
            modName = m, modLabel = prettyMod(m),
            featureLabel = string.format("in %d fights, winning %d", cnt[m], wins[m] or 0),
            stateText = rankTxt .. "   (Promote / Move)", priorityMod = m,
        }
    end
    if #kings == 0 then
        data[#data + 1] = { rowType = "basicInfo", category = "Seating", basicSort = 1,
            modLabel = "(no mod is in 2+ fights)",
            featureLabel = "switch to By-category to settle individual fights", stateText = "" }
    end

    for _, c in ipairs(incompat) do
        local names = {}
        for _, m in ipairs(c.mods) do names[#names + 1] = prettyMod(m) end
        data[#data + 1] = {
            rowType = "basicIncompat", category = "Incompatible", basicSort = 2,
            modLabel = "\226\156\151  " .. table.concat(names, "  +  "),
            featureLabel = c.reason or "These mods fight \226\128\148 keep only one.",
            stateText = "remove one",
        }
    end
    return data
end

-- TIER 2 (By category): per-realm pages. Each category shows its per-category RANKING
-- (heavy mods in that realm), its STOMP fight cards (pick who's kept; others sit out), and
-- its SHARED stacks (all run, last-word noted — never muted). Incompatible last.
function ModMixerSwitchboardFrame:collectCategoryRows()
    local SB = ModMixerSwitchboard
    local data = {}
    if SB == nil or SB.buildConflicts == nil then return data end
    local conflicts = SB.buildConflicts()

    local stompsByCat, sharedByCat, catSet, incompat = {}, {}, {}, {}
    for _, c in ipairs(conflicts) do
        if c.kind == "hook" then
            if c.resolvability == "clean" or c.resolvability == "partial" then
                stompsByCat[c.category] = stompsByCat[c.category] or {}
                table.insert(stompsByCat[c.category], c); catSet[c.category] = true
            elseif c.resolvability == "shared" then
                sharedByCat[c.category] = sharedByCat[c.category] or {}
                table.insert(sharedByCat[c.category], c); catSet[c.category] = true
            end   -- locked → Advanced-only
        elseif c.kind == "incompatible" then
            incompat[#incompat + 1] = c
        end
    end

    for cat in pairs(catSet) do
        local stomps = stompsByCat[cat] or {}
        -- per-category ranking shortlist: mods in 2+ stomps within this realm
        local cnt = {}
        for _, c in ipairs(stomps) do for _, m in ipairs(c.mods) do cnt[m] = (cnt[m] or 0) + 1 end end
        local plist = SB.priorityByCat[cat] or {}
        local prank = {}
        for i, m in ipairs(plist) do prank[m] = i end
        local kings = {}
        for m, c in pairs(cnt) do if c >= 2 then kings[#kings + 1] = m end end
        table.sort(kings, function(a, b)
            local ra, rb = prank[a], prank[b]
            if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
            if ra ~= nil and rb ~= nil then return ra < rb end
            if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end
            return prettyMod(a) < prettyMod(b)
        end)
        for i, m in ipairs(kings) do
            local rankTxt = prank[m] and ("#" .. prank[m] .. " in " .. cat) or "not ranked"
            data[#data + 1] = {
                rowType = "catPriority", category = cat, basicSort = 1, sortIdx = i,
                modName = m, modLabel = prettyMod(m),
                featureLabel = string.format("in %d %s fights", cnt[m], cat),
                stateText = rankTxt .. "   (Promote / Move)", priorityMod = m, catName = cat,
            }
        end
        -- stomp fight cards
        for _, c in ipairs(stomps) do
            local winner, decided = SB.rankWinner(c.target, c.mods, c.category)
            local contestants = {}
            for _, m in ipairs(c.mods) do contestants[#contestants + 1] = prettyMod(m) end
            local tag
            if not decided then
                tag = "last loaded wins (" .. prettyMod(winner) .. ")"
            elseif c.resolvability == "partial" then
                tag = "\226\154\160 keep " .. prettyMod(winner) .. " \226\128\148 a hidden hook still runs"
            else
                tag = "\240\159\145\145 keep " .. prettyMod(winner) .. ", others sit out"
            end
            local overridden = (SB.basicWinners ~= nil and SB.basicWinners[c.target] ~= nil)
            data[#data + 1] = {
                rowType = "basicFight", category = cat, basicSort = 2,
                modName = winner, modLabel = areaName(c.target),
                featureLabel = table.concat(contestants, "  vs  "),
                stateText = tag .. (overridden and "   (your pick)" or ""),
                target = c.target, mods = c.mods, resolvability = c.resolvability,
            }
        end
        -- shared stacks (all run; last word noted; never muted)
        for _, c in ipairs(sharedByCat[cat] or {}) do
            local names = {}
            for _, m in ipairs(c.mods) do names[#names + 1] = prettyMod(m) end
            data[#data + 1] = {
                rowType = "basicShared", category = cat, basicSort = 3,
                modLabel = areaName(c.target),
                featureLabel = table.concat(names, "  +  "),
                stateText = "\240\159\141\189 all run \226\128\148 " .. prettyMod(c.mods[#c.mods]) .. " has the last word",
                target = c.target, mods = c.mods,
            }
        end
    end

    for _, c in ipairs(incompat) do
        local names = {}
        for _, m in ipairs(c.mods) do names[#names + 1] = prettyMod(m) end
        data[#data + 1] = {
            rowType = "basicIncompat", category = "Incompatible", basicSort = 2,
            modLabel = "\226\156\151  " .. table.concat(names, "  +  "),
            featureLabel = c.reason or "These mods fight \226\128\148 keep only one.",
            stateText = "remove one",
        }
    end
    return data
end

-- The category list for the filter switcher: "All" + every category present in
-- the current data, ordered by CAT_ORDER. Also clamps the active selection.
function ModMixerSwitchboardFrame:rebuildFilterCats()
    -- Basic mode pages by the same switcher, over its own categories (King Pins +
    -- fight categories + Incompatible).
    local sbMode = ModMixerSwitchboard ~= nil and ModMixerSwitchboard.mode or "advanced"
    -- Tier 1 (Seating) & Tier 4 (Review): single page, no category pager.
    if sbMode == "seating" or sbMode == "review" then
        self.filterCats = {}
        if self.categoryFilter ~= nil then pcall(function() self.categoryFilter:setVisible(false) end) end
        return
    end
    -- Tier 2 (Category): page by the same switcher, over the per-realm categories.
    if sbMode == "category" then
        local data = self:collectCategoryRows()
        local present = {}
        for _, r in ipairs(data) do present[r.category] = true end
        local cats = {}
        for c in pairs(present) do cats[#cats + 1] = c end
        table.sort(cats, function(a, b)
            local oa, ob = basicCatOrder(a), basicCatOrder(b)
            if oa ~= ob then return oa < ob end
            return a < b
        end)
        self.filterCats = { "All" }
        for _, c in ipairs(cats) do self.filterCats[#self.filterCats + 1] = c end
        local idx = 1
        for i, c in ipairs(self.filterCats) do if c == self.activeCategory then idx = i; break end end
        self.activeCategory = self.filterCats[idx]
        if self.categoryFilter ~= nil then
            pcall(function() self.categoryFilter:setVisible(true) end)
            pcall(function() self.categoryFilter:setTexts(self.filterCats) end)
            pcall(function() self.categoryFilter:setState(idx, false) end)
        end
        return
    end
    -- Tier 3 (Advanced).
    if self.categoryFilter ~= nil then
        pcall(function() self.categoryFilter:setVisible(true) end)
    end
    local data = self:collectRows()
    local present = {}
    for _, r in ipairs(data) do present[r.category] = true end
    local cats = {}
    for c in pairs(present) do cats[#cats + 1] = c end
    table.sort(cats, function(a, b)
        local oa, ob = catOrder(a), catOrder(b)
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    self.filterCats = { "All" }
    for _, c in ipairs(cats) do self.filterCats[#self.filterCats + 1] = c end

    -- Keep the current selection if it still exists, else fall back to "All".
    local idx = 1
    for i, c in ipairs(self.filterCats) do
        if c == self.activeCategory then idx = i break end
    end
    self.activeCategory = self.filterCats[idx]
    if self.categoryFilter ~= nil then
        self.categoryFilter:setTexts(self.filterCats)
        self.categoryFilter:setState(idx, false)
    end
end

-- Build the displayed rows: filter by active category, sort, insert headers.
-- TIER 4 (Review): the "worth a look" hub — possible duplicate-purpose mods, incompatible
-- pairs, and HUD overlaps. Advisory: select a row to read the evidence in the help box,
-- Dismiss (Space) to hide ones you've judged. Sourced from the OFFLINE detectors so it
-- works even where live attribution can't (HUD-class hooks).
function ModMixerSwitchboardFrame:collectReviewRows()
    local SB = ModMixerSwitchboard
    local rows = {}
    if SB == nil or SB.buildReviewItems == nil then
        basicHeader(rows, "Review")
        rows[#rows + 1] = { rowType = "reviewInfo", category = "Review",
            modLabel = "(review data unavailable)", featureLabel = "", stateText = "" }
        return rows
    end
    local red, inc, hud = {}, {}, {}
    for _, it in ipairs(SB.buildReviewItems()) do
        if not it.dismissed then
            if     it.rkind == "redundancy"  then red[#red + 1] = it
            elseif it.rkind == "incompatible" then inc[#inc + 1] = it
            elseif it.rkind == "hud"          then hud[#hud + 1] = it end
        end
    end
    local total = #red + #inc + #hud

    basicHeader(rows, "Review")
    rows[#rows + 1] = {
        rowType = "reviewInfo", category = "Review", modLabel = "Worth a look",
        featureLabel = string.format("%d possible duplicate(s), %d incompatible, %d HUD overlap(s)",
            #red, #inc, #hud),
        stateText = (total == 0 and "all clear / dismissed" or "select a row \226\134\146 details"),
    }

    if #red > 0 then
        table.sort(red, function(a, b)
            local ca = (a.confidence == "high" and 2) or (a.confidence == "med" and 1) or 0
            local cb = (b.confidence == "high" and 2) or (b.confidence == "med" and 1) or 0
            if ca ~= cb then return ca > cb end
            return (a.descOverlap or 0) > (b.descOverlap or 0)
        end)
        basicHeader(rows, "Possible duplicates")
        for _, it in ipairs(red) do
            rows[#rows + 1] = {
                rowType = "reviewRedundancy", category = "Review", reviewKey = it.key,
                modLabel = prettyMod(it.a) .. "  \226\159\183  " .. prettyMod(it.b),
                featureLabel = (it.confidence == "high" and "likely duplicate") or "review",
                stateText = "Dismiss", descA = it.descA or "", descB = it.descB or "",
            }
        end
    end
    if #inc > 0 then
        basicHeader(rows, "Incompatible \226\128\148 keep one")
        for _, it in ipairs(inc) do
            local names = {}
            for _, m in ipairs(it.mods) do names[#names + 1] = prettyMod(m) end
            rows[#rows + 1] = {
                rowType = "reviewIncompat", category = "Review", reviewKey = it.key,
                modLabel = "\226\156\151  " .. table.concat(names, "  +  "),
                featureLabel = it.reason or "replace the same system", stateText = "Dismiss",
            }
        end
    end
    if #hud > 0 then
        basicHeader(rows, "HUD overlaps")
        for _, it in ipairs(hud) do
            local names = {}
            for _, m in ipairs(it.mods) do names[#names + 1] = prettyMod(m) end
            rows[#rows + 1] = {
                rowType = "reviewHud", category = "Review", reviewKey = it.key, target = it.target,
                modLabel = table.concat(names, "  +  "),
                featureLabel = "both draw " .. (it.target or "a HUD element"), stateText = "Dismiss",
            }
        end
    end
    if total == 0 then
        rows[#rows + 1] = { rowType = "reviewInfo", category = "Review",
            modLabel = "(nothing to review)",
            featureLabel = "no duplicates, incompatibilities or HUD overlaps outstanding", stateText = "" }
    end
    return rows
end

function ModMixerSwitchboardFrame:buildRows()
    local sbMode = ModMixerSwitchboard ~= nil and ModMixerSwitchboard.mode or "advanced"

    if sbMode == "review" then return self:collectReviewRows() end

    -- Tiers 1 & 2 (Seating / Category) share the same sort + header machinery; they only
    -- differ in which collector feeds them and whether the category pager filters.
    if sbMode == "seating" or sbMode == "category" then
        local data = (sbMode == "seating") and self:collectSeatingRows() or self:collectCategoryRows()
        if sbMode == "category" and self.activeCategory ~= nil and self.activeCategory ~= "All" then
            local filtered = {}
            for _, r in ipairs(data) do
                if r.category == self.activeCategory then filtered[#filtered + 1] = r end
            end
            data = filtered
        end
        table.sort(data, function(a, b)
            local oa, ob = basicCatOrder(a.category), basicCatOrder(b.category)
            if oa ~= ob then return oa < ob end
            if (a.basicSort or 0) ~= (b.basicSort or 0) then return (a.basicSort or 0) < (b.basicSort or 0) end
            if (a.sortIdx or 0) ~= (b.sortIdx or 0) then return (a.sortIdx or 0) < (b.sortIdx or 0) end
            return (a.modLabel or "") < (b.modLabel or "")
        end)
        local rows, lastCat = {}, nil
        for _, r in ipairs(data) do
            if r.category ~= lastCat then lastCat = r.category; basicHeader(rows, r.category) end
            rows[#rows + 1] = r
        end
        return rows   -- tier switch is the VIEW widget now, not a chart row
    end

    local data = self:collectRows()

    -- Apply the category filter ("All" = no filter).
    if self.activeCategory ~= nil and self.activeCategory ~= "All" then
        local filtered = {}
        for _, r in ipairs(data) do
            if r.category == self.activeCategory then filtered[#filtered + 1] = r end
        end
        data = filtered
    end

    -- Sort by category first. WITHIN a category:
    --   Live Mod Features → group by MOD, then feature (so each mod's knobs cluster).
    --   everything else (hook rows) → group by FUNCTION, then mod (so every mod
    --     hooking the same function clusters — that's the conflict view).
    table.sort(data, function(a, b)
        local oa, ob = catOrder(a.category), catOrder(b.category)
        if oa ~= ob then return oa < ob end
        if a.category == "Current Vehicle" then
            return (a.orderIdx or 0) < (b.orderIdx or 0)   -- keep authored readout order
        end
        if a.category == "Live Mod Features" then
            if (a.modLabel or "") ~= (b.modLabel or "") then
                return (a.modLabel or "") < (b.modLabel or "")
            end
            return (a.featureLabel or "") < (b.featureLabel or "")
        end
        if a.featureLabel ~= b.featureLabel then return a.featureLabel < b.featureLabel end
        -- Within one target's chain, sort by firing order so the chain reads top→bottom.
        local ai, bi = a.orderIdx or 0, b.orderIdx or 0
        if ai ~= bi then return ai < bi end
        return (a.modLabel or "") < (b.modLabel or "")
    end)

    -- Insert a header row each time the category changes.
    local rows    = {}
    local lastCat = nil
    for _, r in ipairs(data) do
        if r.category ~= lastCat then
            lastCat = r.category
            rows[#rows + 1] = {
                rowType    = "header",
                modLabel   = "\226\148\128\226\148\128  " .. string.upper(r.category) .. "  \226\148\128\226\148\128",
                featureLabel = "", stateText = "",
            }
        end
        rows[#rows + 1] = r
    end
    return rows   -- tier switch is the VIEW widget now, not a chart row
end

-- Cycle Seating → Category → Advanced → Seating and rebuild around the new tier.
function ModMixerSwitchboardFrame:onModeSwitched()
    if ModMixerSwitchboard ~= nil and ModMixerSwitchboard.cycleMode ~= nil then
        ModMixerSwitchboard.cycleMode()
    end
    self:rebuildFilterCats()
    self:refresh()
    self:setMenuButtonInfoDirty()
end

-- Basic fight card: rotate the winner to the next contestant (a per-fight override).
function ModMixerSwitchboardFrame:cycleFightWinner(row)
    local SB = ModMixerSwitchboard
    if SB == nil or row == nil or row.mods == nil or SB.setBasicWinner == nil then return end
    local cur = SB.rankWinner ~= nil and (SB.rankWinner(row.target, row.mods, row.category)) or row.mods[1]
    local idx = 1
    for i, m in ipairs(row.mods) do if m == cur then idx = i; break end end
    local nextMod = row.mods[(idx % #row.mods) + 1]
    SB.setBasicWinner(row.target, nextMod)
    self._reselectFight = row.target
    self:refresh()
    self:setMenuButtonInfoDirty()
end

function ModMixerSwitchboardFrame:refresh()
    self.rowSource:setData(self:buildRows())
    if self.featureList ~= nil then
        self.featureList:reloadData()
        -- After an action that moves a row (reorder), keep the same logical row
        -- selected so repeated presses act on the same mod.
        if self._reselect ~= nil then
            local rows = self.rowSource.rows
            for i, r in ipairs(rows) do
                if r.modName == self._reselect.modName and r.featureId == self._reselect.featureId then
                    pcall(function() self.featureList:setSelectedIndex(i) end)
                    break
                end
            end
            self._reselect = nil
        elseif self._reselectBasic ~= nil then   -- king-pin (seating) row moved
            for i, r in ipairs(self.rowSource.rows) do
                if r.rowType == "basicPriority" and r.priorityMod == self._reselectBasic then
                    pcall(function() self.featureList:setSelectedIndex(i) end); break
                end
            end
            self._reselectBasic = nil
        elseif self._reselectCat ~= nil then      -- per-category rank row moved
            for i, r in ipairs(self.rowSource.rows) do
                if r.rowType == "catPriority" and r.priorityMod == self._reselectCat.mod
                   and r.catName == self._reselectCat.cat then
                    pcall(function() self.featureList:setSelectedIndex(i) end); break
                end
            end
            self._reselectCat = nil
        elseif self._reselectFight ~= nil then   -- fight card winner changed
            for i, r in ipairs(self.rowSource.rows) do
                if r.rowType == "basicFight" and r.target == self._reselectFight then
                    pcall(function() self.featureList:setSelectedIndex(i) end); break
                end
            end
            self._reselectFight = nil
        end
    end
end

-- Refresh that preserves the current selection (used by the live vehicle-state tick
-- so the list doesn't jump every refresh).
function ModMixerSwitchboardFrame:refreshLive()
    local idx = self.featureList ~= nil and self.featureList.selectedIndex or nil
    self:refresh()
    if idx ~= nil and self.featureList ~= nil then
        pcall(function() self.featureList:setSelectedIndex(idx) end)
    end
end

-- Live tick: while viewing the "Current Vehicle" category, re-read its values ~2×/sec
-- so you can WATCH a state race (e.g. ADS vs RealisticDamage fighting over damage).
function ModMixerSwitchboardFrame:update(dt)
    local sc = ModMixerSwitchboardFrame:superClass()
    if sc ~= nil and sc.update ~= nil then pcall(sc.update, self, dt) end
    if not SHOW_VEHICLE_STATE then return end
    -- The vehicle panel only exists in Advanced; don't live-refresh in the other tiers.
    if ModMixerSwitchboard ~= nil and ModMixerSwitchboard.mode ~= "advanced" then return end
    if self.activeCategory ~= "Current Vehicle" then return end
    local now = g_time or 0
    if self._lastLive == nil or (now - self._lastLive) >= 500 then
        self._lastLive = now
        pcall(function() self:refreshLive() end)
    end
end

function ModMixerSwitchboardFrame:onFrameOpen()
    if self.categoryHeaderText ~= nil then
        self.categoryHeaderText:setText("ModMixer - Switchboard")
    end
    self:rebuildFilterCats()
    self:refresh()
    self:updateChrome()   -- VIEW switch position + bottom legend follow the tier
    self:updateHelp()     -- prime the help box for the initial selection
    self:setMenuButtonInfoDirty()
end

function ModMixerSwitchboardFrame:onFrameClose()
    ModMixerSwitchboardFrame:superClass().onFrameClose(self)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CATEGORY FILTER
--   onFilterChanged : fired by the on-screen MTO switcher (mouse-clicking arrows).
--   onFilterStep    : driven by ModMixer_SB_FILTER_PREV/NEXT (custom actions,
--                     player assigns in Settings > Controls). Both land on the
--                     same activeCategory + refresh.
-- ─────────────────────────────────────────────────────────────────────────────
function ModMixerSwitchboardFrame:onFilterChanged(state)
    local s = state
    if type(s) ~= "number" and self.categoryFilter ~= nil then
        s = self.categoryFilter:getState()
    end
    self.activeCategory = self.filterCats[s] or "All"
    self:refresh()
    self:setMenuButtonInfoDirty()
end

function ModMixerSwitchboardFrame:onFilterStep(dir)
    local n = #self.filterCats
    if n <= 1 then return end
    local s = (self.categoryFilter ~= nil and self.categoryFilter:getState() or 1) + dir
    if s < 1 then s = n elseif s > n then s = 1 end
    if self.categoryFilter ~= nil then
        self.categoryFilter:setState(s, false)   -- update display; refresh explicitly below
    end
    self.activeCategory = self.filterCats[s] or "All"
    self:refresh()
    self:setMenuButtonInfoDirty()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- VALUE SLIDER  (MultiTextOption inside each list item, shown for value rows)
-- onClick="onValueSliderChanged" fires with the new state index when the user
-- clicks ◄/► on a value row's slider. We look up the selected row, map the
-- index back to the numeric value, and call setOverride live.
-- ─────────────────────────────────────────────────────────────────────────────
function ModMixerSwitchboardFrame:onValueSliderChanged(state)
    -- state may arrive as a number or (rarely, on direct arrow-click before list
    -- selection updates) not yet set — guard both cases.
    local s = state
    local SB = ModMixerSwitchboard
    if SB == nil then return end

    local idx  = self.featureList ~= nil and self.featureList.selectedIndex or nil
    if idx == nil then return end
    local rows = self.rowSource.rows
    local row  = rows[idx]
    if row == nil or row.kind ~= "value" then return end

    local tv = valueTextsFor(row)
    if tv == nil then return end

    if type(s) ~= "number" then
        -- Fallback: read current state from the slider element itself.
        local sliderEl = nil
        if self.featureList ~= nil then
            -- Try to get the slider from the selected cell via the list's internal API.
            pcall(function()
                local cell = self.featureList:getItemAtIndex(idx)
                if cell ~= nil then sliderEl = cell:getAttribute("valueSlider") end
            end)
        end
        if sliderEl ~= nil then
            s = sliderEl:getState()
        else
            return
        end
    end

    local val = tv.values[s]
    if val == nil then return end
    if SB.setOverride ~= nil then
        SB.setOverride(row.modName, row.featureId, val)
    end
    -- Refresh so the block-scale bar updates to the new position. setOverride
    -- already applied the value live. setState(state, false) in populateCell
    -- won't re-trigger this callback (the false flag suppresses onClick).
    self:refresh()
end

function ModMixerSwitchboardFrame:getSelectedRow()
    if self.featureList == nil then return nil end
    local idx  = self.featureList.selectedIndex
    local rows = self.rowSource.rows
    if idx ~= nil and idx >= 1 and idx <= #rows then
        return rows[idx]
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MENU_ACTIVATE  (SPACE / gamepad A)
--   toggle rows: 3-state cycle  default → ON (set) → OFF (set) → default
--                "default" stage clears the override so the mod controls it.
--   value rows:  step UP by vstep, wrapping from max back to min.
--   hook rows:   flip veto state (active ↔ VETOED).
-- ─────────────────────────────────────────────────────────────────────────────
function ModMixerSwitchboardFrame:onActivate()
    local row = self:getSelectedRow()
    if row == nil or row.rowType == "header" or row.rowType == "vehicleState" or ModMixerSwitchboard == nil then return end

    local SB = ModMixerSwitchboard

    -- Tiered rows + the mode toggle (works in every tier).
    if row.rowType == "modeToggle" then self:onModeSwitched(); return end

    -- Review tier: Space dismisses an item you've judged (persisted).
    if row.rowType == "reviewRedundancy" or row.rowType == "reviewIncompat"
       or row.rowType == "reviewHud" then
        if SB.dismissReview ~= nil and row.reviewKey ~= nil then SB.dismissReview(row.reviewKey, true) end
        self:refresh()
        self:setMenuButtonInfoDirty()
        return
    end
    if row.rowType == "reviewInfo" then return end
    if row.rowType == "basicFight" then self:cycleFightWinner(row); return end
    if row.rowType == "basicPriority" or row.rowType == "catPriority" then
        self:onMoveHook(-1); return   -- SPACE = promote
    end
    if row.rowType == "basicIncompat" or row.rowType == "basicInfo"
       or row.rowType == "basicShared" then return end

    -- Hook rows: flip veto. Load-critical rows are locked.
    if row.rowType == "hook" then
        if row.locked then return end
        if SB.setHookVeto ~= nil and SB.isHookVetoed ~= nil then
            SB.setHookVeto(row.modName, row.featureId,
                           not SB.isHookVetoed(row.modName, row.featureId))
        end
        self:refresh()
        self:setMenuButtonInfoDirty()
        return
    end

    if SB.setOverride == nil then return end

    -- Value rows: step UP, wrapping from max → min.
    if row.kind == "value" then
        local step  = row.vstep or 1
        local cur   = SB.getOverride(row.modName, row.featureId)
        local base  = cur or row.vdefault or row.vmin or 0
        local nextV = math.floor(base / step + 0.5) * step + step   -- next step boundary
        if nextV > (row.vmax or base) + 1e-9 then nextV = row.vmin or base end
        nextV = math.floor(nextV / step + 0.5) * step               -- snap, kill float drift
        SB.setOverride(row.modName, row.featureId, nextV)
        self:refresh()
        return
    end

    -- Toggle rows: 3-state cycle  nil → true → false → nil
    --   nil   ("default")  → true  ("ON  (set)")
    --   true  ("ON  (set)")  → false ("OFF  (set)")
    --   false ("OFF  (set)") → nil  ("default")  via clearOverride
    if row.kind ~= "toggle" then return end
    local cur = SB.getOverride(row.modName, row.featureId)
    if cur == nil then
        SB.setOverride(row.modName, row.featureId, true)
    elseif cur == true then
        SB.setOverride(row.modName, row.featureId, false)
    else
        SB.clearOverride(row.modName, row.featureId)
    end
    self:refresh()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MENU_EXTRA_1  (X / gamepad X)
--   toggle rows: clear override → back to mod's own default immediately.
--   value rows:  step DOWN by vstep, wrapping from min back to max.
--   hook rows:   clear veto (un-veto — lets the hook install again next load).
-- ─────────────────────────────────────────────────────────────────────────────
function ModMixerSwitchboardFrame:onExtra1()
    local row = self:getSelectedRow()
    if row == nil or row.rowType == "header" or row.rowType == "vehicleState" or ModMixerSwitchboard == nil then return end

    local SB = ModMixerSwitchboard

    -- Basic fight card: clear the per-fight pick (back to the ranking-decided winner).
    if row.rowType == "basicFight" then
        if SB.clearBasicWinner ~= nil then SB.clearBasicWinner(row.target) end
        self._reselectFight = row.target
        self:refresh()
        self:setMenuButtonInfoDirty()
        return
    end
    if row.rowType == "basicPriority" or row.rowType == "catPriority" or row.rowType == "modeToggle"
       or row.rowType == "basicIncompat" or row.rowType == "basicInfo" or row.rowType == "basicShared" then
        return
    end

    if row.rowType == "hook" then
        if row.locked then return end
        if SB.setHookVeto ~= nil then
            SB.setHookVeto(row.modName, row.featureId, false)
        end
        self:refresh()
        self:setMenuButtonInfoDirty()
        return
    end

    -- Value rows: step DOWN, wrapping from min → max.
    if row.kind == "value" then
        local step  = row.vstep or 1
        local cur   = SB.getOverride(row.modName, row.featureId)
        local base  = cur or row.vdefault or row.vmax or 0
        local nextV = math.floor(base / step + 0.5) * step - step   -- previous step boundary
        if nextV < (row.vmin or base) - 1e-9 then nextV = row.vmax or base end
        nextV = math.floor(nextV / step + 0.5) * step
        SB.setOverride(row.modName, row.featureId, nextV)
        self:refresh()
        return
    end

    -- Toggle / feature rows: clear the override (revert to mod's own default).
    if SB.clearOverride ~= nil then
        SB.clearOverride(row.modName, row.featureId)
    end
    self:refresh()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MENU_EXTRA_2  (Y / gamepad Y)
--   value rows:           reset to default (clear override) — live.
--   contested hook rows:  make this mod the winner (veto the other hookers) /
--                         if already the winner, clear the whole contest.
--                         Restart-to-apply (it's a load-time veto under the hood).
--   all other rows:       no-op (button not shown for them).
-- ─────────────────────────────────────────────────────────────────────────────
function ModMixerSwitchboardFrame:onExtra2()
    local row = self:getSelectedRow()
    if row == nil or row.rowType == "header" or row.rowType == "vehicleState" then return end
    local SB = ModMixerSwitchboard
    if SB == nil then return end

    -- Value rows: reset to mod default (live).
    if row.kind == "value" then
        if SB.clearOverride ~= nil then SB.clearOverride(row.modName, row.featureId) end
        self:refresh()
        return
    end

    -- Consecutive hook rows: pick the winner (or clear the contest if already winner).
    if row.rowType == "hook" and row.consecutive and not row.locked and row.hookers ~= nil then
        if row.isWinner then
            if SB.clearHookContest ~= nil then
                SB.clearHookContest(row.featureId, row.hookers)
            end
        else
            if SB.setHookWinner ~= nil then
                SB.setHookWinner(row.featureId, row.modName, row.hookers)
            end
        end
        self:refresh()
        self:setMenuButtonInfoDirty()
        return
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ModMixer_SB_MOVE_EARLIER / ModMixer_SB_MOVE_LATER on a reorderable hook row →
-- move this mod one slot earlier / later in the firing order. Restart-to-apply.
-- Custom actions avoid the MENU_PAGE_PREV/NEXT (Q/E) sidebar conflict.
-- Player assigns keys in Settings > Controls.
-- ─────────────────────────────────────────────────────────────────────────────
function ModMixerSwitchboardFrame:onMoveHook(dir)
    local row = self:getSelectedRow()
    -- Tier 1 seating list: move this mod up/down the GLOBAL priority.
    if row ~= nil and row.rowType == "basicPriority" then
        local SB = ModMixerSwitchboard
        if SB ~= nil and SB.moveGlobalPriority ~= nil then
            SB.moveGlobalPriority(row.priorityMod, dir)
            self._reselectBasic = row.priorityMod
            self:refresh()
            self:setMenuButtonInfoDirty()
        end
        return
    end
    -- Tier 2 per-category list: move this mod up/down WITHIN its realm.
    if row ~= nil and row.rowType == "catPriority" then
        local SB = ModMixerSwitchboard
        if SB ~= nil and SB.moveCatPriority ~= nil then
            SB.moveCatPriority(row.catName, row.priorityMod, dir)
            self._reselectCat = { mod = row.priorityMod, cat = row.catName }
            self:refresh()
            self:setMenuButtonInfoDirty()
        end
        return
    end
    if row == nil or row.rowType ~= "hook" or not row.reorderable or row.hookers == nil then return end
    local SB = ModMixerSwitchboard
    if SB == nil or SB.moveHookInOrder == nil then return end
    -- row.hookers is the chain in its CURRENT firing order — seed from it.
    if SB.moveHookInOrder(row.featureId, row.modName, dir, row.hookers) then
        self._reselect = { modName = row.modName, featureId = row.featureId }
        self:refresh()
        self:setMenuButtonInfoDirty()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RESET PAGE / RESET ALL  (Ctrl+Backspace / Shift+Backspace by default).
-- Both show a YesNoDialog confirmation before acting. API confirmed from
-- EasyDevControls: YesNoDialog.show(callback, target, message, title, yes, no)
-- callback receives a single boolean (true = confirmed).
-- ─────────────────────────────────────────────────────────────────────────────

function ModMixerSwitchboardFrame:onResetPageConfirm()
    -- Tiered modes — Reset page = clear all the tiered (seating/category) choices.
    if ModMixerSwitchboard ~= nil and ModMixerSwitchboard.mode ~= "advanced" then
        self:onResetAllConfirm()
        return
    end
    local cat = self.activeCategory or "All"
    local msg = (cat == "All")
        and "Reset ALL Switchboard settings to default?\n\nThis clears every override, veto and chain reorder."
        or  ("Reset all '" .. cat .. "' settings to default?\n\nThis clears overrides, vetoes and reorders in this category.")
    local frame = self
    local ok = pcall(YesNoDialog.show,
        function(yes) if yes then frame:doResetPage() end end,
        nil, msg, "ModMixer – Reset page")
    if not ok then self:doResetPage() end   -- dialog unavailable: act immediately
end

function ModMixerSwitchboardFrame:onResetAllConfirm()
    local basic = ModMixerSwitchboard ~= nil and ModMixerSwitchboard.mode ~= "advanced"
    local msg = basic
        and "Clear all your conflict choices?\n\nEvery mod ranking (seating + per-category) and per-fight pick is reset. Your mods all go back to their natural order."
        or  "Reset ALL Switchboard settings to default?\n\nEvery override, veto and chain reorder across all categories will be cleared."
    local frame = self
    local ok = pcall(YesNoDialog.show,
        function(yes) if yes then frame:doResetAll() end end,
        nil, msg, "ModMixer – Reset all")
    if not ok then self:doResetAll() end
end

-- Reset just the SELECTED row to default (Backspace). Instant — no dialog — because
-- it touches a single setting and is trivially redone. Header / vehicle-state rows
-- have nothing to reset, so it's a no-op there.
function ModMixerSwitchboardFrame:onResetOne()
    local row = self:getSelectedRow()
    if row == nil or row.rowType == "header" or row.rowType == "vehicleState"
       or row.rowType == "modeToggle" or row.rowType == "basicInfo"
       or row.rowType == "basicIncompat" or row.rowType == "basicShared" then return end
    self:doResetOne(row)
end

function ModMixerSwitchboardFrame:doResetOne(row)
    local SB = ModMixerSwitchboard
    if SB == nil or row == nil then return end
    -- Tiered rows reset to their own neutral state.
    if row.rowType == "basicFight" then
        if SB.clearBasicWinner ~= nil then SB.clearBasicWinner(row.target) end
        self._reselectFight = row.target
        self:refresh(); self:setMenuButtonInfoDirty(); return
    elseif row.rowType == "basicPriority" then
        if SB.unrankGlobal ~= nil then SB.unrankGlobal(row.priorityMod) end
        self._reselectBasic = row.priorityMod
        self:refresh(); self:setMenuButtonInfoDirty(); return
    elseif row.rowType == "catPriority" then
        if SB.unrankCat ~= nil then SB.unrankCat(row.catName, row.priorityMod) end
        self._reselectCat = { mod = row.priorityMod, cat = row.catName }
        self:refresh(); self:setMenuButtonInfoDirty(); return
    elseif row.rowType == "modeToggle" or row.rowType == "basicIncompat"
           or row.rowType == "basicInfo" or row.rowType == "basicShared" then
        return
    end
    if row.rowType == "feature" and SB.clearOverride ~= nil then
        SB.clearOverride(row.modName, row.featureId)
    elseif row.rowType == "hook" then
        -- Return this hook to default: un-veto it; if it was the lone winner, dissolve
        -- the contest so the whole chain runs again. (Chain reorder is target-wide, not
        -- row-scoped — that's cleared via Reset page / Reset all.)
        if SB.setHookVeto ~= nil then SB.setHookVeto(row.modName, row.featureId, false) end
        if row.isWinner and row.hookers ~= nil and SB.clearHookContest ~= nil then
            SB.clearHookContest(row.featureId, row.hookers)
        end
    end
    self._reselect = { modName = row.modName, featureId = row.featureId }
    self:refresh()
    self:setMenuButtonInfoDirty()
end

-- Clear every override / veto / reorder for the currently displayed category.
-- For "All" this is equivalent to doResetAll but routes through individual
-- clearOverride calls so live restore (parking-brake fix, etc.) fires correctly.
function ModMixerSwitchboardFrame:doResetPage()
    local SB = ModMixerSwitchboard
    if SB == nil then return end
    local rows = self:collectRows()
    local done = {}   -- dedupe per target for hook operations
    for _, r in ipairs(rows) do
        if self.activeCategory == "All" or r.category == self.activeCategory then
            if r.rowType == "feature" and SB.clearOverride ~= nil then
                SB.clearOverride(r.modName, r.featureId)
            elseif r.rowType == "hook" and not done[r.featureId] then
                done[r.featureId] = true
                -- Un-veto every mod on this target (clearHookContest handles all).
                if r.hookers ~= nil and SB.clearHookContest ~= nil then
                    SB.clearHookContest(r.featureId, r.hookers)
                end
                -- Drop custom chain order.
                if SB.clearHookOrder ~= nil then
                    SB.clearHookOrder(r.featureId)
                end
            end
        end
    end
    self:refresh()
    self:setMenuButtonInfoDirty()
end

-- Nuclear reset: wipe everything in one call (SB.resetAll batches the save).
-- In Basic mode, scope it to the king-pin choices (clearBasic) so the user's
-- Advanced overrides/value tweaks aren't collateral damage.
function ModMixerSwitchboardFrame:doResetAll()
    local SB = ModMixerSwitchboard
    if SB == nil then return end
    if SB.mode ~= "advanced" and SB.clearBasic ~= nil then
        SB.clearBasic()
    elseif SB.resetAll ~= nil then
        SB.resetAll()
    end
    self:refresh()
    self:setMenuButtonInfoDirty()
end
