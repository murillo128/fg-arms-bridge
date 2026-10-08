-- Command integration: real data validation/permissions with an in-memory FG DB.
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message or ("check " .. checks .. " failed"))
end
local function equal(actual, expected, message)
  check(actual == expected, (message or "unexpected value") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
end
local function contains(text, fragment, message)
  check(type(text) == "string" and text:find(fragment, 1, true) ~= nil, message or ("Missing text: " .. fragment))
end
local function isolated(path, injected)
  local env = setmetatable({}, {__index = _G})
  env._G = env
  for name, value in pairs(injected or {}) do env[name] = value end
  local chunk
  if setfenv then chunk = assert(loadfile(path)); setfenv(chunk, env)
  else chunk = assert(loadfile(path, "t", env)) end
  return chunk(), env
end

local values, imports, writes = {}, {}, 0
local Session = {IsHost = true}
local hero = {path = "combattracker.list.id-00001"}
values[hero.path .. ".name"] = "Hero With Spaces"
local function pathOf(node) return type(node) == "table" and node.path or node end
local DB = {}
function DB.getValue(node, fieldOrDefault, default)
  local path = pathOf(node)
  if default ~= nil then path = path .. "." .. fieldOrDefault else default = fieldOrDefault end
  if values[path] == nil then return default end
  return values[path]
end
function DB.setValue(node, fieldOrKind, kindOrValue, value)
  local path = pathOf(node)
  if value ~= nil then path = path .. "." .. fieldOrKind else value = kindOrValue end
  assert(path:sub(1, 11) == "armsbridge.", "Commands must not write character HP or native records")
  values[path] = value
  writes = writes + 1
end
function DB.getChildList(node)
  local path = pathOf(node)
  if path == "combattracker.list" then return {hero} end
  if path == "armsbridge.imports" then return imports end
  return {}
end
function DB.getPath(node) return pathOf(node) end
function DB.createNode(path) return {path = path} end
function DB.createChild(node)
  local child = {path = pathOf(node) .. string.format(".id-%05d", #imports + 1)}
  imports[#imports + 1] = child
  return child
end
function DB.deleteNode(node)
  local path = pathOf(node)
  assert(path:sub(1, 11) == "armsbridge.")
  for name in pairs(values) do
    if name == path or name:sub(1, #path + 1) == path .. "." then values[name] = nil end
  end
  writes = writes + 1
end
local ActorManager = {
  getCreatureNodeName = function(actor) return actor.path end,
  getCreatureNode = function(actor) return actor end,
  resolveActor = function(actor) return actor end,
}
local Engine = isolated("extension/scripts/arms_engine.lua")
local Catalog = isolated("extension/scripts/arms_catalog.lua")
local Data = isolated("extension/scripts/arms_data.lua", {
  DB = DB, Session = Session, ActorManager = ActorManager, ArmsEngine = Engine, ArmsCatalog = Catalog
})
local messages, slashHandlers = {}, {}
local Comm = {
  addChatMessage = function(message) messages[#messages + 1] = message.text end,
  registerSlashHandler = function(name, handler) slashHandlers[name] = handler end,
}
local ready, clears, bypasses, pending = false, 0, 0, 3
local Bridge = {}
function Bridge.getCapabilities() return {ready = ready} end
function Bridge.status()
  return {requestedMode = Data.getMode(), effectiveMode = ready and Data.getMode() or "off",
    ready = ready, missing = ready and {} or {"exampleMissingHook"}, pendingCount = pending,
    lastNotice = "Example diagnostic notice"}
end
function Bridge.clearPending() clears = clears + 1; local old = pending; pending = 0; return old end
function Bridge.getPending()
  if pending == 0 then return {} end
  return {{id = "attack-1", label = "Longsword", weapon = "sword", target = "target-1"}}
end
function Bridge.bypassNext() bypasses = bypasses + 1; return true end
local Commands, commandEnv = isolated("extension/scripts/arms_commands.lua", {
  ArmsEngine = Engine, ArmsData = Data, ArmsBridge = Bridge, ArmsCatalog = Catalog, Comm = Comm, Interface = false
})

-- Quoted actor/action names and incomplete quotes are handled before dispatch.
local tokens = assert(Commands.tokenize('weapon "Sword \\"Sun\\"" sword'))
equal(tokens[1], "weapon")
equal(tokens[2], 'Sword "Sun"')
equal(tokens[3], "sword")
tokens = assert(Commands.tokenize('  armor\t"Hero With Spaces"   mail 16 '))
equal(#tokens, 4); equal(tokens[2], "Hero With Spaces")
equal(#assert(Commands.tokenize("")), 0)
equal(assert(Commands.tokenize('weapon "" sword'))[2], "")
local badTokens, tokenError = Commands.tokenize('armor "Hero With Spaces')
check(badTokens == nil and type(tokenError) == "string")
local beforeWrites, beforeClears = writes, clears
Commands.onSlashCommand("", 'armor "Hero With Spaces')
equal(writes, beforeWrites); equal(clears, beforeClears)

-- Missing host integration blocks active mode; passive/off modes remain usable.
local status = Commands.showStatus()
check(not status.ready)
contains(table.concat(messages, "\n"), "exampleMissingHook")
contains(table.concat(messages, "\n"), "Example diagnostic notice")
check(not Commands.setMode("on"))
equal(Data.getMode(), "compare"); equal(writes, beforeWrites); equal(clears, beforeClears)
check(Commands.setMode("off")); equal(Data.getMode(), "off"); equal(clears, beforeClears + 1)
check(Commands.setMode("compare")); equal(Data.getMode(), "compare"); equal(clears, beforeClears + 2)
ready = true
check(Commands.setMode("on")); equal(Data.getMode(), "on")
beforeWrites, beforeClears = writes, clears
check(not Commands.setMode("invalid")); equal(writes, beforeWrites); equal(clears, beforeClears)

-- Authoritative permission checks happen in real ArmsData, not in stub logic.
Session.IsHost = false
Commands.onSlashCommand("", "mode off")
Commands.onSlashCommand("", 'armor "Hero With Spaces" plate 18')
Commands.onSlashCommand("", 'weapon "Longsword" off')
Commands.importCSV("not a table")
equal(writes, beforeWrites); equal(clears, beforeClears); equal(Data.getMode(), "on")
Session.IsHost = true
Commands.onSlashCommand("", 'armor "Hero With Spaces" plate 18')
equal(assert(Data.armorFor(hero, 21)).defense, 3)
equal(clears, beforeClears + 1)
Commands.onSlashCommand("", 'weapon "Longsword" off')
equal(Data.weaponFor({bWeapon = true, sLabel = "Longsword"}), nil)
equal(clears, beforeClears + 2)

-- Import rejects invalid data without discarding pending attacks or DB writes.
local header = "weapon,armor,min,max,hit,quality\n"
local valid = header .. "cmd-preview,mail,0,49,false,0\ncmd-preview,mail,50,99,true,0.75\ncmd-preview,mail,100,,true,1"
beforeWrites, beforeClears = writes, clears
local result, err = Commands.importCSV(header .. "broken")
check(result == nil and type(err) == "string")
equal(writes, beforeWrites); equal(clears, beforeClears); equal(#imports, 0)
check(Commands.importCSV(valid)); equal(#imports, 1); equal(clears, beforeClears + 1)
check(Engine.getTable("cmd-preview") ~= nil)

-- Preview returns actual table/quantile arithmetic without changing any state.
beforeWrites, beforeClears = writes, clears
local text = Commands.onSlashCommand("", "preview cmd-preview mail 12 5 3 2d6+4")
contains(text, "Fila 70")
contains(text, "calidad 0.750")
contains(text, "+4 = 13") -- 75th percentile of 2d6 is 9; fixed modifier is 4.
contains(text, "No se ha aplicado daño")
text = Commands.onSlashCommand("", "preview cmd-preview mail 12 5 3 1d8-2")
contains(text, "[6] -2 = 4")
text = Commands.onSlashCommand("", "preview cmd-preview mail 12 5 3 d8")
contains(text, "[6] +0 = 6")
text = Commands.onSlashCommand("", "preview cmd-preview mail 20 5 3 1d8+3")
contains(text, "crítico D&D")
contains(text, "continuación pendiente")
check(not text:find("calidad", 1, true) and not text:find("[8]", 1, true), "Critical preview must not present a maximum base-damage quantile")
text = Commands.onSlashCommand("", "preview sword plate 20+10 5 0 1d8+3")
contains(text, "20+10 = 30")
contains(text, "Fila 175")
contains(text, "daño nativo completo (2d8+3")
contains(text, "+4 por exceso")
text = Commands.onSlashCommand("", "preview sword plate 20+20+10 5 0 1d8+3")
contains(text, "20+20+10 = 50")
contains(text, "+13 por exceso")
text = Commands.onSlashCommand("", "preview sword plate 20+20+10 5 0 2d6+3")
contains(text, "4d6+3")
contains(text, "+20 por exceso")
text = Commands.onSlashCommand("", "preview sword plate 20+1 5 0 1d8+3")
contains(text, "20+1 = 21")
contains(text, "crítico D&D")
contains(text, "+0 por exceso")
text = Commands.onSlashCommand("", "preview sword plate 20+20 5 0 1d8+3")
contains(text, "continuación pendiente")
text = Commands.onSlashCommand("", "preview cmd-preview mail 19 10 3 1d8+3")
contains(text, "[8] +3 +2 por exceso = 13")
text = Commands.onSlashCommand("", "preview cmd-preview mail 1 5 3 1d8+3")
contains(text, "fallo")
for _, arguments in ipairs({"preview", "preview unknown mail 12 5 3 1d8", "preview cmd-preview mail bad 5 3 1d8",
  "preview cmd-preview mail 12 5 3 1d101", "preview cmd-preview mail 12 5 3 100d6",
  "preview cmd-preview mail 12 5 3 1d8+", "preview cmd-preview mail 12 5 3 1d8+" .. string.rep("9", 400)}) do
  local okay = pcall(Commands.onSlashCommand, "", arguments)
  check(okay, "Malformed or excessive preview inputs must report an error, not throw")
end
for _, sequence in ipairs({"19+10", "20+0", "20+21", "20++10", "20+", "+20", "20+1+20", "20.0+10"}) do
  text = Commands.onSlashCommand("", "preview sword plate " .. sequence .. " 5 0 1d8+3")
  check(not text:find("No se ha aplicado daño", 1, true), "Invalid open sequence must not produce a completed damage preview: " .. sequence)
end
equal(writes, beforeWrites); equal(clears, beforeClears)

-- Catalog queries preserve category/usage as separate read-only attributes.
text = Commands.onSlashCommand("", "catalog")
contains(text, "blunted"); contains(text, "firearms"); contains(text, "9 armas")
text = Commands.onSlashCommand("", 'catalog "Quarterstaff" 2h')
contains(text, "grupo polearms"); contains(text, "categoría simple"); contains(text, "uso 2h")
text = Commands.onSlashCommand("", 'catalog "War Pick"')
contains(text, "grupo blunted"); contains(text, "categoría martial"); contains(text, "uso unknown")
text = Commands.onSlashCommand("", 'catalog "Shuriken"')
contains(text, "categoría custom"); contains(text, "uso unknown")
text = Commands.onSlashCommand("", 'catalog "Quarterstaff" 3h')
contains(text, "Uso:")
equal(writes, beforeWrites); equal(clears, beforeClears)
Commands.onSlashCommand("", 'weapon "Filo oscuro" bladed martial 1h')
text = Commands.onSlashCommand("", 'catalog "Filo oscuro"')
contains(text, "grupo bladed"); contains(text, "categoría martial"); contains(text, "uso 1h")
Commands.onSlashCommand("", 'weapon "Filo oscuro" bladed auto auto')
local profile = assert(Data.weaponProfile({sLabel="Filo oscuro"}))
equal(profile.category, "unknown"); equal(profile.hands, "unknown")
beforeWrites, beforeClears = writes, clears
Commands.onSlashCommand("", 'weapon "Filo oscuro" bladed invalid 1h')
Commands.onSlashCommand("", 'weapon "Filo oscuro" bladed martial 3h')
equal(writes, beforeWrites); equal(clears, beforeClears)

-- A missing/unavailable UI still gives a usable chat help surface.
text = Commands.openPanel(); contains(text, "/arms mode")
commandEnv.Interface = {openWindow = function() error("No UI available") end}
text = Commands.openPanel(); contains(text, "/arms preview")
local capturedClass, capturedPath, window = nil, nil, {}
commandEnv.Interface = {openWindow = function(class, path) capturedClass = class; capturedPath = path; return window end}
equal(Commands.openPanel(), window)
equal(capturedClass, "arms_bridge"); equal(capturedPath, "armsbridge")
Session.IsHost = false
equal(Commands.openPanel(), window); equal(capturedPath, "")
Session.IsHost = true

-- Slash registration and read-only diagnostics do not touch native state.
Commands.onInit(); equal(slashHandlers.arms, Commands.onSlashCommand)
beforeWrites = writes
for _, command in ipairs({"help", "actors", "tables", "pending", "status", "unknown"}) do Commands.onSlashCommand("", command) end
equal(writes, beforeWrites)
Commands.onSlashCommand("", "bypass"); equal(bypasses, 1); equal(writes, beforeWrites)
pending = 2
text = Commands.onSlashCommand("", "clear"); contains(text, "2"); equal(pending, 0)
print("Command checks: " .. checks)
