-- SwitchboardMenu.lua  (FS25_ModMixer, Stage 2 / step 3)
-- Registers the Switchboard page into the in-game (ESC) menu's left sidebar.
-- Uses the Courseplay/RedTape addIngameMenuPage recipe. Runs at loadMap time,
-- once per game session (g_inGameMenu persists across savegame loads).

ModMixerSwitchboardMenu = ModMixerSwitchboardMenu or {}
local Menu = ModMixerSwitchboardMenu

-- g_currentModDirectory is only valid at file-load time — capture it now.
Menu.dir = Menu.dir or g_currentModDirectory

local PAGE_NAME   = "pageModMixerSwitchboard"
local GUI_NAME    = "ModMixerSwitchboard"
local INSERT_AFTER = "pageSettings"   -- slot near Settings; falls back to end if absent

local function sblog(msg)
    print("[ModMixer Switchboard] " .. tostring(msg))
end

-- Add a TabbedMenuFrameElement page to g_inGameMenu (sidebar). Robust against a
-- missing insertAfter anchor (then it just lands at the end).
local function addIngameMenuPage(frame, pageName, uvs, predicateFunc, insertAfter)
    if g_inGameMenu == nil or g_inGameMenu.pagingElement == nil then
        return false
    end

    if g_inGameMenu.controlIDs ~= nil then
        g_inGameMenu.controlIDs[pageName] = nil
    end

    g_inGameMenu[pageName] = frame
    g_inGameMenu.pagingElement:addElement(g_inGameMenu[pageName])
    g_inGameMenu:exposeControlsAsFields(pageName)

    g_inGameMenu.pagingElement:updateAbsolutePosition()
    g_inGameMenu.pagingElement:updatePageMapping()

    g_inGameMenu:registerPage(g_inGameMenu[pageName], nil, predicateFunc)

    -- White monochrome tab icon (renders cleanly in normal + selected states; a
    -- colored icon blanks when the tab goes to its selected/green state).
    local iconFileName = Utils.getFilename("gui/menuIcon.dds", Menu.dir)
    g_inGameMenu:addPageTab(g_inGameMenu[pageName], iconFileName, GuiUtils.getUVs(uvs))

    -- Optionally move the new page to sit right after a named page.
    if insertAfter ~= nil and g_inGameMenu[insertAfter] ~= nil then
        local targetPosition = 0
        for i = 1, #g_inGameMenu.pagingElement.elements do
            if g_inGameMenu.pagingElement.elements[i] == g_inGameMenu[insertAfter] then
                targetPosition = i + 1
                break
            end
        end
        if targetPosition > 0 then
            local function moveInto(list)
                for i = 1, #list do
                    local child = list[i]
                    local isOurs = (child == g_inGameMenu[pageName])
                        or (type(child) == "table" and child.element == g_inGameMenu[pageName])
                    if isOurs then
                        table.remove(list, i)
                        local pos = math.min(targetPosition, #list + 1)
                        table.insert(list, pos, child)
                        break
                    end
                end
            end
            moveInto(g_inGameMenu.pagingElement.elements)
            moveInto(g_inGameMenu.pagingElement.pages)
            if g_inGameMenu.pageFrames ~= nil then
                moveInto(g_inGameMenu.pageFrames)
            end
            g_inGameMenu.pagingElement:updateAbsolutePosition()
            g_inGameMenu.pagingElement:updatePageMapping()
        end
    end

    g_inGameMenu:rebuildTabList()
    return true
end

function Menu:loadMap(name)
    if Menu._installed then
        return
    end

    if g_gui == nil or g_inGameMenu == nil or ModMixerSwitchboardFrame == nil then
        sblog("UI: prerequisites missing at loadMap — page not installed this session.")
        return
    end

    local ok, err = pcall(function()
        g_gui:loadProfiles(Menu.dir .. "gui/guiProfiles.xml")

        local frame = ModMixerSwitchboardFrame.new(g_i18n)
        g_gui:loadGui(Menu.dir .. "gui/SwitchboardFrame.xml", GUI_NAME, frame, true)

        local installed = addIngameMenuPage(
            frame, PAGE_NAME, { 0, 0, 1024, 1024 },
            function() return true end,   -- always selectable
            INSERT_AFTER)

        if installed then
            frame:initialize()
            Menu.frame = frame
            Menu._installed = true
            sblog("UI: Switchboard page added to the in-game menu.")
        else
            sblog("UI: could not add page (in-game menu unavailable).")
        end
    end)

    if not ok then
        sblog("UI: page install errored (will retry behaviour disabled): " .. tostring(err))
    end
end

addModEventListener(Menu)
