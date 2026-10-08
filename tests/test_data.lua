-- Independent input, persistence, and armor/weapon mapping checks.
-- Small hand-authored fixtures below are original test data, not ICE tables.
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message or ("check " .. checks .. " failed"))
end
local function equal(actual, expected, message)
  check(actual == expected, (message or "unexpected value") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
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

local nodes, values, childSequence = {}, {}, 0
local function pathOf(node) return type(node) == "table" and node.path or node end
local function ensure(path)
  if not nodes[path] then nodes[path] = {path = path} end
  return nodes[path]
end
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
  values[path] = value
  ensure(path)
end
function DB.createNode(path) return ensure(path) end
function DB.createChild(parent)
  childSequence = childSequence + 1
  return ensure(pathOf(parent) .. string.format(".id-%05d", childSequence))
end
function DB.getChildList(parent, child)
  local prefix = pathOf(parent) .. (child and ("." .. child) or "") .. "."
  local result = {}
  for path, node in pairs(nodes) do
    if path:sub(1, #prefix) == prefix and not path:sub(#prefix + 1):find(".", 1, true) then
      table.insert(result, node)
    end
  end
  table.sort(result, function(a, b) return a.path < b.path end)
  return result
end
function DB.getPath(node) return pathOf(node) end
function DB.deleteNode(node)
  local path = pathOf(node)
  for name in pairs(nodes) do
    if name == path or name:sub(1, #path + 1) == path .. "." then nodes[name], values[name] = nil, nil end
  end
end
function DB.setPublic() end
function DB.addHandler() end
local Session = {IsHost = true}
local ActorManager = {}
function ActorManager.getCreatureNodeName(actor) return actor and actor.path end
function ActorManager.getCreatureNode(actor) return actor and nodes[actor.path] end
function ActorManager.resolveActor(node) return node.actor or node end
local ItemManager = {}
function ItemManager.isArmor(item) return DB.getValue(item, "kind", "") == "armor" end
function ItemManager.isShield(item) return DB.getValue(item, "shield", false) == true end
local Engine = isolated("extension/scripts/arms_engine.lua")
local Catalog = isolated("extension/scripts/arms_catalog.lua")
local Data, dataEnv = isolated("extension/scripts/arms_data.lua", {
  DB = DB, Session = Session, ActorManager = ActorManager, ItemManager = ItemManager, ArmsEngine = Engine, ArmsCatalog = Catalog
})

-- CSV syntax, quoting, bounds, and the last row without a terminating newline.
local parsed = assert(Data.parseCSV('\239\187\191one,two\r\n"a,b","line1\nline2"\r\n"say ""hi""",tail'))
equal(#parsed, 3)
equal(parsed[2][1], "a,b")
equal(parsed[2][2], "line1\nline2")
equal(parsed[3][1], 'say "hi"')
equal(assert(Data.parseCSV("a,b,"))[1][3], "")
for _, bad in ipairs({'"unclosed', 'un"quoted', '"closed"junk', '"closed""junk', "", string.rep("x", 262145)}) do
  local result, err = Data.parseCSV(bad)
  check(result == nil and type(err) == "string", "Malformed CSV must return nil,error")
end
equal(#assert(Data.parseCSV(string.rep("x\n", 4000))), 4000)
local overflow = Data.parseCSV(string.rep("x\n", 4000) .. "last")
check(overflow == nil, "4001st CSV row must fail even without final newline")

local header = "weapon,armor,min,max,hit,quality\n"
local valid = header .. "custom,plate,-100,0,false,0\ncustom,plate,1,49,true,0.25\ncustom,plate,50,,true,0.9"
local defs = assert(Data.decodeTables(valid))
check(defs.custom ~= nil and defs.custom.armors.plate ~= nil)
equal(defs.custom.armors.plate[2].quality, 0.25)
equal(defs.custom.armors.plate[3].max, nil)
local invalid = {
  "weapon,armor,min,max,hit\n",
  header,
  header .. "custom,plate,-100,0,false,0\ncustom,plate,2,,true,0.5", -- gap
  header .. "custom,plate,-100,1,false,0\ncustom,plate,1,,true,0.5", -- overlap
  header .. "custom,plate,-100,0,false,0\ncustom,plate,1,100,true,0.5", -- finite last range
  header .. "custom,plate,1,,true,0.5", -- lacks miss range
  header .. "custom,plate,-100,0,false,0\ncustom,plate,1,,true,1.01",
  header .. "custom,plate,-100,0,false,0\ncustom,plate,1,,true,-0.1",
  header .. "custom,plate,-100,0,false,0\ncustom,plate,1,,maybe,0.5",
  header .. "custom,plate,-100,0,false,0\ncustom,plate,1e400,,true,0.5",
  header .. "custom,plate,-100,0,false,0\ncustom,plate,1,,true,1e400",
  header .. "custom,plate,-100.5,0,false,0\ncustom,plate,1,,true,0.5",
  header .. string.rep("w", 97) .. ",plate,-100,0,false,0\n" .. string.rep("w", 97) .. ",plate,1,,true,0.5",
  header .. "custom," .. string.rep("a", 65) .. ",-100,0,false,0\ncustom," .. string.rep("a", 65) .. ",1,,true,0.5",
}
for _, bad in ipairs(invalid) do
  local result, err = Data.decodeTables(bad)
  check(result == nil and type(err) == "string", "Invalid table CSV must fail closed")
end
dataEnv.EXECUTED = false
dataEnv.loadstring = function() dataEnv.EXECUTED = true; error("Evaluation forbidden") end
dataEnv.load = dataEnv.loadstring
local malicious = header .. "custom,plate,-100,0,false,0\ncustom,plate,1,,true,0; EXECUTED=true"
check(Data.decodeTables(malicious) == nil)
equal(dataEnv.EXECUTED, false, "CSV must remain data")

-- Persistence is host-only; validation must complete before writing a batch.
equal(Data.getMode(), "compare")
check(Data.setMode("on")); equal(Data.getMode(), "on")
check(not Data.setMode("unexpected")); equal(Data.getMode(), "on")
Session.IsHost = false
check(not Data.setMode("off")); equal(Data.getMode(), "on")
check(not Data.importTables(valid)); equal(#DB.getChildList("armsbridge.imports"), 0)
Session.IsHost = true
check(not Data.importTables(invalid[3])); equal(#DB.getChildList("armsbridge.imports"), 0)
check(not Data.importTables(invalid[#invalid - 1])); equal(#DB.getChildList("armsbridge.imports"), 0)
check(Data.importTables(valid)); equal(#DB.getChildList("armsbridge.imports"), 1)
check(Engine.getTable("custom") ~= nil)
local secondEngine = isolated("extension/scripts/arms_engine.lua")
local restored = isolated("extension/scripts/arms_data.lua", {DB = DB, Session = Session, ArmsEngine = secondEngine, ArmsCatalog = Catalog})
restored.reloadTables()
check(secondEngine.getTable("custom") ~= nil, "Imported table must restore from saved campaign data")

-- Armor material is distinct from bonuses: a shield and +1 armor add defense.
local hero = ensure("charsheet.hero")
local function item(id, properties)
  local node = ensure("charsheet.hero.inventorylist." .. id)
  for field, value in pairs(properties) do DB.setValue(node, field, type(value), value) end
  return node
end
local plate = item("plate", {name = "Plate Armor +1", kind = "armor", carried = 2, ac = 18, bonus = 1})
local shield = item("shield", {name = "Shield", kind = "armor", carried = 2, ac = 2, shield = true})
local profile = assert(Data.armorFor(hero, 21))
equal(profile.armor, "plate")
equal(profile.base, 18)
equal(profile.defense, 3, "Magic +1 and shield +2 must remain in defense")
DB.setValue(shield, "carried", "number", 0)
equal(assert(Data.armorFor(hero, 19)).defense, 1)
DB.setValue(shield, "carried", "number", 2)
item("leather", {name = "Leather Armor", kind = "armor", carried = 2, ac = 11})
check(Data.armorFor(hero, 21) == nil, "Multiple equipped suits need explicit mapping")
DB.deleteNode("charsheet.hero.inventorylist.leather")
check(Data.setArmor(hero, "mail", 16))
profile = assert(Data.armorFor(hero, 21))
equal(profile.armor, "mail"); equal(profile.defense, 5); equal(profile.origin, "manual")
Session.IsHost = false
check(not Data.setArmor(hero, "plate", 18))
equal(assert(Data.armorFor(hero, 21)).armor, "mail")
Session.IsHost = true
check(Data.setArmor(hero, "auto"))
equal(assert(Data.armorFor(hero, 21)).armor, "plate")
DB.deleteNode(plate)
check(Data.armorFor(hero, 21) == nil, "Shield alone must not imply an armor material")
check(Data.setArmor(hero, "unarmored", 10))
equal(assert(Data.armorFor(hero, 16)).defense, 6, "Explicit unarmored profile must preserve native defenses")
for _, base in ipairs({-1, 51, math.huge, -math.huge, 0/0}) do check(not Data.setArmor(hero, "plate", base)) end
check(not Data.setArmor(hero, string.rep("a", 65), 18), "Armor identifiers must fit the engine contract")
check(Data.armorFor(hero, math.huge) == nil)

-- Weapon opt-in, explicit exclusion, magic-name normalization, and safe spells.
equal(Data.weaponFor({sLabel = "Longsword", bWeapon = true}), "bladed")
equal(Data.weaponFor({sLabel = "Longsword"}), nil)
equal(Data.weaponFor({sLabel = "Longsword", bWeapon = true, bSpell = true}), nil)
check(Data.mapWeapon("Breath", "custom"))
equal(Data.weaponFor({sLabel = "Breath"}), "custom")
equal(Data.weaponFor({sLabel = "Breath", bSpell = true}), nil)
check(Data.mapWeapon("Longsword", "off"))
equal(Data.weaponFor({sLabel = "Longsword", bWeapon = true}), nil)
check(Data.mapWeapon("Longsword +1", "custom"))
equal(Data.weaponFor({sLabel = "Longsword +1", bWeapon = true}), "custom", "Configured names must normalize like incoming action labels")
check(not Data.mapWeapon("Anything", "nonexistent-table"))
Session.IsHost = false
check(not Data.mapWeapon("Breath", "off"))
equal(Data.weaponFor({sLabel = "Breath"}), "custom")
Session.IsHost = true

-- Natural protection is explicitly assigned, never inferred from a large AC.
local dragon = ensure("charsheet.dragon")
check(Data.armorFor(dragon, 22) == nil, "High AC alone cannot identify natural armor")
for _, natural in ipairs({"natural_hide", "natural_scales", "natural_shell"}) do
  check(Data.setArmor(dragon, natural, 18))
  local naturalProfile = assert(Data.armorFor(dragon, 22))
  equal(naturalProfile.armor, natural)
  equal(naturalProfile.defense, 4, "Other AC bonuses must survive a natural-armor assignment")
  equal(naturalProfile.origin, "manual")
end
check(Data.setArmor(dragon, "auto"))
check(Data.armorFor(dragon, 22) == nil, "Removing a manual profile must not silently classify the creature")

-- User-selected groups do not imply a damage type or a mastery.
local warPick = assert(Data.weaponProfile({sLabel="War Pick",bWeapon=true}))
equal(warPick.group, "blunted")
equal(warPick.category, "martial")
equal(warPick.hands_property, "versatile")
equal(warPick.hands, "unknown")
equal(warPick.dmgtype, nil)
equal(warPick.mastery, nil)
equal(Data.weaponFor({sLabel="Quarterstaff",bWeapon=true}), "polearms")
equal(Data.weaponFor({sLabel="Javelin",bWeapon=true}), "exotic")
equal(Data.weaponFor({sLabel="Dagger",bWeapon=true}), "bladed")
equal(Data.weaponFor({sLabel="Hand Crossbow",bWeapon=true}), "crossbows")
equal(Data.weaponFor({sLabel="Shortbow",bWeapon=true}), "bows")
equal(Data.weaponFor({sLabel="Pistol",bWeapon=true}), "firearms")
equal(Data.weaponFor({sLabel="Shuriken",bWeapon=true}), "exotic")
equal(Data.weaponFor({sLabel="Blunderbuss",bWeapon=true}), "firearms")
equal(assert(Data.weaponProfile({sLabel="Shuriken",bWeapon=true})).category, "custom")
equal(assert(Data.weaponProfile({sLabel="Blunderbuss",bWeapon=true})).hands, "unknown")

-- Actual handling is separate from the weapon's legal hand properties.
equal(Data.weaponHands({sLabel="Battleaxe"}), "unknown")
equal(Data.weaponHands({sLabel="Battleaxe +1 (2H)"}), "2h")
equal(Data.weaponHands({sLabel="Battleaxe (1H)"}), "1h")
equal(Data.weaponHands({sLabel="Battleaxe (OH)"}), "1h")
equal(Data.weaponHands({sLabel="Battleaxe (2H) (OH)"}), "unknown")
equal(Data.weaponHands({sLabel="Lance"}), "unknown", "Mounted state is absent, so a Lance's use is not guessed")
equal(Data.weaponHands({sLabel="Greatsword"}), "2h")
equal(Data.weaponHands({sLabel="Musket"}), "2h")
equal(Data.weaponHands({sLabel="Dagger"}), "1h")
equal(Data.weaponHands({sLabel="Battleaxe (2H)",sArmsHands="1h"}), "1h", "Captured handling is authoritative")
equal(Data.weaponHands({sLabel="Battleaxe (2H)",sArmsHands="unknown"}), "unknown", "Captured uncertainty must survive transport")
equal(Data.actionLabel({sLabel="Espada larga +2 (1H)"}), "espada larga")
equal(Data.actionLabel({label="Longsword (2H)"}), "longsword", "Native action metadata uses label before getRoll")

local actualWeapon = ensure("charsheet.hero.weaponlist.id-00001")
DB.setValue(actualWeapon,"handling","number",1)
local action = {label="Trident",bWeapon=true}
Data.captureWeaponMetadata(action, actualWeapon)
equal(action.sArmsHands, "2h")
equal(action.sArmsCategory, "martial")
equal(action.sArmsGroup, "polearms")
DB.setValue(actualWeapon,"handling","number",0)
equal(Data.weaponHands(action), "2h", "Changing the sheet after attack must not rewrite captured usage")
action = {label="Trident",bWeapon=true}
Data.captureWeaponMetadata(action, actualWeapon)
equal(action.sArmsHands, "1h")
DB.setValue(actualWeapon,"handling","number",2)
action = {label="War Pick",bWeapon=true}
Data.captureWeaponMetadata(action, actualWeapon)
equal(action.sArmsHands, "1h", "Off-hand is still one-handed use")
DB.deleteNode("charsheet.hero.weaponlist.id-00001.handling")
action = {label="Trident",bWeapon=true}
Data.captureWeaponMetadata(action, actualWeapon)
equal(action.sArmsHands, "unknown", "A missing handling field is not a declared one-handed use")
action = {label="Trident (2H)",bWeapon=true}
Data.captureWeaponMetadata(action, actualWeapon)
equal(action.sArmsHands, "2h")

-- Metadata overrides are opt-in, host-only and individually removable.
check(Data.mapWeapon("Acid blade", "sword", "martial", "1h"))
local acidBlade = assert(Data.weaponProfile({sLabel="Acid blade"}))
equal(acidBlade.table_id, "bladed", "Legacy table IDs must canonicalize in saved mappings")
equal(acidBlade.category, "martial")
equal(acidBlade.hands, "1h")
equal(acidBlade.group, "bladed")
check(not Data.mapWeapon("Acid blade", "bladed", "invalid", "2h"))
check(not Data.mapWeapon("Acid blade", "bladed", "simple", "3h"))
equal(assert(Data.weaponProfile({sLabel="Acid blade"})).hands, "1h", "Invalid metadata is atomic")
Session.IsHost = false
check(not Data.mapWeapon("Acid blade", "bladed", "simple", "2h"))
Session.IsHost = true
equal(assert(Data.weaponProfile({sLabel="Acid blade"})).category, "martial")
check(Data.mapWeapon("Acid blade", "bladed"))
equal(assert(Data.weaponProfile({sLabel="Acid blade"})).hands, "1h", "Omitted metadata preserves the existing override")
check(Data.mapWeapon("Acid blade", "bladed", "auto", "auto"))
acidBlade = assert(Data.weaponProfile({sLabel="Acid blade"}))
equal(acidBlade.category, "unknown")
equal(acidBlade.hands, "unknown")
check(Data.mapWeapon("Battleaxe", "axes", "martial", "1h"))
equal(Data.weaponHands({sLabel="Battleaxe"}), "1h")
equal(Data.weaponHands({sLabel="Battleaxe (2H)"}), "2h", "An explicit native 2H action takes precedence over a manual fallback")
equal(Data.weaponHands({sLabel="Battleaxe",sArmsHands="2h"}), "2h")

-- Optional hand-specific imported tables use real action usage, without
-- changing standard shared tables or guessing usage for versatile weapons.
local specific = header .. "axes_2h,plate,0,0,false,0\naxes_2h,plate,1,,true,0.8"
check(Data.importTables(specific))
equal(Data.weaponFor({sLabel="Battleaxe (2H)",bWeapon=true}), "axes_2h")
equal(Data.weaponFor({sLabel="Battleaxe (1H)",bWeapon=true}), "axes")
check(Data.mapWeapon("Battleaxe", "axes", "auto", "auto"))
equal(Data.weaponFor({sLabel="Battleaxe",bWeapon=true}), "axes", "Unknown hands retain the common family table")
check(Data.mapWeapon("Custom blade", "custom", "martial", "2h"))
equal(Data.weaponFor({sLabel="Custom blade"}), "custom", "An explicit custom table must not be replaced by inferred variants")

-- Legacy aliases share canonical tables. A single CSV may not silently
-- combine different IDs for that same table; later batches replace in order.
local oldName = header .. "sword,plate,0,0,false,0\nsword,plate,1,,true,0.6"
local decodedOld = assert(Data.decodeTables(oldName))
check(decodedOld.bladed ~= nil and decodedOld.sword == nil)
local ambiguous = header .. "sword,plate,0,0,false,0\nbladed,plate,1,,true,0.6"
local ambiguousResult, ambiguousError = Data.decodeTables(ambiguous)
check(ambiguousResult == nil and ambiguousError:find("misma tabla",1,true) ~= nil)
local beforeBatches = #DB.getChildList("armsbridge.imports")
check(not Data.importTables(ambiguous))
equal(#DB.getChildList("armsbridge.imports"), beforeBatches, "Alias collision must fail before saving any import")
check(Data.importTables(oldName))
local newName = header .. "bladed,plate,0,0,false,0\nbladed,plate,1,,true,0.7"
check(Data.importTables(newName))
equal(Engine.getTable("sword").armors.plate[2].quality, 0.7)
local replayEngine = isolated("extension/scripts/arms_engine.lua")
local replayData = isolated("extension/scripts/arms_data.lua", {DB=DB,Session=Session,ArmsEngine=replayEngine,ArmsCatalog=Catalog})
replayData.reloadTables()
equal(replayEngine.getTable("sword").armors.plate[2].quality, 0.7, "Saved batches replay with identical canonical precedence")

-- Similar names never resolve to an arbitrary combatant.
local first, second = ensure("combattracker.list.id-00001"), ensure("combattracker.list.id-00002")
DB.setValue(first, "name", "string", "Goblin")
DB.setValue(second, "name", "string", "Goblin")
check(Data.findActor("Goblin") == nil)
equal(Data.findActor("combattracker.list.id-00002"), second)
equal(#Data.listActors(), 2)
check(Data.key("charsheet.a") ~= Data.key("charsheet.b"))
check(Data.key("a.b") ~= Data.key("a_b"))
print("Data checks: " .. checks)
