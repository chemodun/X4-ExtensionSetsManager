-- Extension Sets Manager - the mod's own module registry.
--
-- Replaces Register_Require_With_Init from sn_mod_support_apis' Lua Loader API. That API
-- patches require() and drives its init list from an MD signal; neither is reliably in place
-- when this mod's files load, and MD never runs in the main menu, where the mod has to work.
-- Load order is fixed by ui.xml, so registering as each file loads is enough.

---@diagnostic disable-next-line: global-in-non-module
ESM_Loader = ESM_Loader or {}
ESM_Loader.modules = ESM_Loader.modules or {}

-- Same call shape as Register_Require_With_Init(module_name, response, init). init is optional
-- and runs straight away, after the module is published, because nothing signals a later load
-- point in the main menu.
function ESM_Loader.Register(module_name, response, init)
  ESM_Loader.modules[module_name] = response
  -- Also publish to the stock loader, so a plain require() of this module works too.
  if package ~= nil and package.preload ~= nil then
    package.preload[module_name] = function() return response end
  end
  if init ~= nil then
    init()
  end
  return response
end

-- Used instead of require() for this mod's own modules.
function ESM_Loader.Require(module_name)
  local response = ESM_Loader.modules[module_name]
  if response == nil then
    DebugError("ExtensionSetsManager: module " .. tostring(module_name) .. " is not registered")
  end
  return response
end
