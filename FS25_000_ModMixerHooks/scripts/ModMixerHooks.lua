-- ModMixerHooks.lua  v1.0.2
-- Loads first (000_ prefix). Patches both Utils.overwrittenFunction and
-- Utils.appendedFunction to record every wrapper in Utils.__ms_registry,
-- keyed by the returned function. FS25_zzz_ModMixer reads this registry
-- to verify and repair hook chains without needing the debug library or cross-mod globals.
--
-- Registry entry format: { prev = existingFn, impl = newFn, kind = "overwrite"|"append" }
--
-- NOTE: In Lua 5.1 you cannot set arbitrary fields on function objects —
-- functions are not tables. We use a plain table as a registry instead, with
-- function references as keys (functions ARE valid table keys in Lua 5.1).

local MSH_VERSION = "1.0.2"
local function log(msg)
    print(string.format("[ModMixerHooks %s] %s", MSH_VERSION, tostring(msg)))
end

if type(Utils) ~= "table" or type(Utils.overwrittenFunction) ~= "function" then
    log("Utils.overwrittenFunction not found — cannot install hooks.")
    return
end

-- Guard against double-installation on FS25's second load pass.
if Utils.__ms_hooks_installed then
    log("Already installed — skipping second-pass re-patch.")
    return
end
Utils.__ms_hooks_installed = true

-- Registry: keyed by the wrapper function returned by overwrittenFunction /
-- appendedFunction.  Value: { prev = existingFn, impl = newFn, kind = "overwrite"|"append" }
Utils.__ms_registry = {}

local _orig_overwrite = Utils.overwrittenFunction
Utils.overwrittenFunction = function(existingFn, newFn)
    local result = _orig_overwrite(existingFn, newFn)
    if type(result) == "function" then
        Utils.__ms_registry[result] = { prev = existingFn, impl = newFn, kind = "overwrite" }
    end
    return result
end

if type(Utils.appendedFunction) == "function" then
    local _orig_append = Utils.appendedFunction
    Utils.appendedFunction = function(existingFn, newFn)
        local result = _orig_append(existingFn, newFn)
        if type(result) == "function" then
            Utils.__ms_registry[result] = { prev = existingFn, impl = newFn, kind = "append" }
        end
        return result
    end
    log("Utils.overwrittenFunction + appendedFunction patched. Chain registry enabled for ModMixer.")
else
    log("Utils.overwrittenFunction patched (appendedFunction not found). Chain registry partially enabled.")
end
