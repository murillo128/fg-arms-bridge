-- Arms Bridge: original configuration/import code. MIT License.
-- This package contains no Iron Crown Enterprises attack or critical tables.
local ROOT = "armsbridge"
local VERSION = "0.3.1-alpha.1"

local function trim(s) return tostring(s or ""):match("^%s*(.-)%s*$") end
local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end
local function truthy(v) return v == true or v == 1 or v == "1" or v == "true" end
function getVersion() return VERSION end
function isHost() return Session and Session.IsHost == true end
function key(s)
  return (tostring(s or ""):gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
function normalize(s)
  s = trim(s):lower():gsub("%s+", " ")
  s = s:gsub("á", "a"):gsub("é", "e"):gsub("í", "i"):gsub("ó", "o"):gsub("ú", "u")
  return s
end
function normalizeAction(s)
  return trim(normalize(s):gsub("%s*%+%d+", ""):gsub("%s*%(1h%)", ""):gsub("%s*%(2h%)", ""):gsub("%s*%(oh%)", ""))
end
local function read(path, default)
  if not DB or not DB.getValue then return default end
  return DB.getValue(path, default)
end
local function write(path, kind, value)
  if not isHost() then return nil, "Solo el director de juego puede cambiar la configuración." end
  DB.setValue(path, kind, value)
  return true
end
function getMode() return read(ROOT .. ".mode", "compare") end
function setMode(mode)
  if mode ~= "off" and mode ~= "compare" and mode ~= "on" then return nil, "Modo: off, compare u on." end
  return write(ROOT .. ".mode", "string", mode)
end
function actorId(actor)
  if not actor or not ActorManager or not ActorManager.getCreatureNodeName then return nil end
  local id = ActorManager.getCreatureNodeName(actor)
  if not id or id == "" then return nil end
  return id
end
function actorNode(actor)
  if not actor or not ActorManager then return nil end
  if ActorManager.getCreatureNode then return ActorManager.getCreatureNode(actor) end
  if ActorManager.getTypeAndNode then local _, node = ActorManager.getTypeAndNode(actor); return node end
end
function findActor(name)
  local found = {}
  if not DB or not ActorManager then return nil, "Combat tracker no disponible." end
  local wanted = normalize(name)
  for _, node in ipairs(DB.getChildList("combattracker.list") or {}) do
    if normalize(DB.getValue(node, "name", "")) == wanted or DB.getPath(node) == name then
      table.insert(found, ActorManager.resolveActor(node))
    end
  end
  if #found == 1 then return found[1] end
  if #found > 1 then return nil, "Nombre duplicado: usa la ruta combattracker.list.id-xxxxx que muestra /arms actors." end
  return nil, "No encuentro ese nombre en el combat tracker. Usa /arms actors."
end
function listActors()
  local items = {}
  if DB then
    for _, node in ipairs(DB.getChildList("combattracker.list") or {}) do
      table.insert(items, {name=DB.getValue(node,"name",""), path=DB.getPath(node)})
    end
  end
  table.sort(items, function(a,b) return a.path < b.path end)
  return items
end
function setArmor(actor, armor, base)
  local id = actorId(actor)
  if not id then return nil, "Actor no válido." end
  if armor == "auto" then
    if not isHost() then return nil, "Solo el director de juego." end
    DB.deleteNode(ROOT .. ".actors." .. key(id)); return true
  end
  if type(armor) ~= "string" or #armor > 64 or not armor:match("^[a-z][a-z0-9_%-]*$") then return nil, "Perfil de armadura no válido." end
  base = tonumber(base)
  if not finite(base) or base < 0 or base > 50 then return nil, "CA base material debe estar entre 0 y 50." end
  if not isHost() then return nil, "Solo el director de juego." end
  local path = ROOT .. ".actors." .. key(id)
  DB.setValue(path .. ".actor", "string", id)
  DB.setValue(path .. ".armor", "string", armor)
  DB.setValue(path .. ".base", "number", base)
  return true
end

local armorNames = {
  ["padded armor"]="leather", ["padded"]="leather", ["leather armor"]="leather", ["leather"]="leather",
  ["studded leather armor"]="leather", ["studded leather"]="leather", ["hide armor"]="leather", ["hide"]="leather",
  ["chain shirt"]="mail", ["chain mail"]="mail", ["ring mail"]="mail", ["scale mail"]="mail",
  ["breastplate"]="plate", ["half plate armor"]="plate", ["half plate"]="plate", ["splint armor"]="plate",
  ["splint"]="plate", ["plate armor"]="plate", ["plate"]="plate",
  ["cuero"]="leather", ["cuero tachonado"]="leather", ["armadura de cuero"]="leather",
  ["cota de malla"]="mail", ["camisa de malla"]="mail", ["cota de escamas"]="mail",
  ["coraza"]="plate", ["armadura de placas"]="plate", ["placas"]="plate"
}
function armorFor(actor, effectiveAC)
  local id = actorId(actor)
  if not id or not finite(effectiveAC) then return nil, "Faltan actor o defensa nativa." end
  local path = ROOT .. ".actors." .. key(id)
  local profile = read(path .. ".armor", "")
  if profile ~= "" then
    local base = read(path .. ".base", 10)
    return {armor=profile, base=base, defense=effectiveAC-base, origin="manual"}
  end
  local node = actorNode(actor)
  if not node then return nil, "No hay ficha accesible para la armadura." end
  local selected = nil
  for _, item in ipairs(DB.getChildList(node, "inventorylist") or {}) do
    if DB.getValue(item, "carried", 0) == 2 and ItemManager and ItemManager.isArmor and ItemManager.isArmor(item)
      and not (ItemManager.isShield and ItemManager.isShield(item)) then
      if selected then return nil, "Varias armaduras equipadas: asigna perfil con /arms armor." end
      selected = item
    end
  end
  if selected then
    local name = normalize(DB.getValue(selected, "name", "")):gsub("%s*%+%d+", "")
    local profileName = armorNames[name]
    if not profileName then return nil, "Armadura sin perfil: usa /arms armor." end
    local base = tonumber(DB.getValue(selected, "ac", 0))
    if not finite(base) or base < 10 then return nil, "La armadura no tiene CA base válida." end
    return {armor=profileName, base=base, defense=effectiveAC-base, origin="equipment"}
  end
  -- A naked AC number does not identify natural armor, Mage Armor, or a monk.
  -- Explicit unarmored assignment is required as well: never silently call a dragon naked.
  return nil, "Asigna protección con /arms armor: unarmored 10 o un perfil material/natural con CA base explícita."
end

local function rawActionLabel(roll)
  if type(roll) ~= "table" then return "" end
  local label = roll.sLabel or roll.label or ""
  if label == "" then
    label = tostring(roll.sDesc or ""):gsub("%b[]", " ")
    label = trim(label)
  end
  return tostring(label)
end
function actionLabel(roll) return normalizeAction(rawActionLabel(roll)) end
local function catalogItem(label)
  return ArmsCatalog and ArmsCatalog.lookup and ArmsCatalog.lookup(label) or nil
end
local function canonicalTable(id)
  return ArmsEngine and ArmsEngine.canonicalTableId and ArmsEngine.canonicalTableId(id) or id
end
local function validHands(value) return value == "1h" or value == "2h" or value == "unknown" end
local function validCategory(value) return value == "simple" or value == "martial" or value == "custom" or value == "unknown" end
local function configuredWeapon(label, field)
  return read(ROOT .. ".weapons." .. key(label) .. "." .. field, "")
end
local function handsFor(roll, label, item)
  -- Scalars captured when FG builds the action are authoritative. Do not read
  -- the weapon node later: its handling may have changed since the attack.
  if validHands(roll.sArmsHands) then return roll.sArmsHands, "captured" end
  local raw = normalize(rawActionLabel(roll))
  local two = raw:find("%(2h%)") ~= nil
  local one = raw:find("%(1h%)") ~= nil or raw:find("%(oh%)") ~= nil
  if two and one then return "unknown", "conflicting-label" end
  if two then return "2h", "action-label" end
  if one then return "1h", "action-label" end
  local configured = configuredWeapon(label, "hands")
  if validHands(configured) then return configured, "manual" end
  if item and (item.hands == "1h" or item.hands == "2h") then return item.hands, "catalog" end
  -- The name of a versatile weapon does not tell us how this attack used it.
  -- The same applies to the mounted exception for a Lance and custom weapons.
  return "unknown", "unknown"
end
function weaponHands(roll)
  if type(roll) ~= "table" then return "unknown" end
  local label = actionLabel(roll)
  local hands = handsFor(roll, label, catalogItem(label))
  return hands
end
function weaponProfile(roll)
  if type(roll) ~= "table" or truthy(roll.bSpell) then return nil end
  local label = actionLabel(roll)
  local configured = configuredWeapon(label, "table_id")
  if configured == "off" then return nil end
  local item = catalogItem(label)
  -- Custom/NPC actions require an explicit mapping. Spells are never opted in.
  if configured == "" and (not truthy(roll.bWeapon) or not item) then return nil end
  local tableId = canonicalTable(configured ~= "" and configured or item.group)
  local hands, origin = handsFor(roll, label, item)
  local category = validCategory(roll.sArmsCategory) and roll.sArmsCategory or configuredWeapon(label, "category")
  if not validCategory(category) then category = item and item.category or "unknown" end
  local group = ArmsCatalog and ArmsCatalog.isGroup and ArmsCatalog.isGroup(tableId) and tableId or nil
  if not group then group = item and item.group or "custom" end
  -- A user may import a hand-specific table; absent that table, the native
  -- damage dice already supply the 1H/2H scale and no bonus is manufactured.
  if ArmsCatalog and ArmsCatalog.isGroup and ArmsCatalog.isGroup(tableId)
      and (hands == "1h" or hands == "2h") then
    local specific = tableId .. "_" .. hands
    if ArmsEngine.getTable(specific) then tableId = specific end
  end
  return {table_id=tableId, group=group, category=category, hands=hands,
    hands_origin=origin, label=label, catalog_id=item and item.id or nil,
    hands_property=item and item.hands or "unknown"}
end
function weaponFor(roll)
  local profile = weaponProfile(roll)
  return profile and profile.table_id or nil
end
function captureWeaponMetadata(action, nodeWeapon)
  if type(action) ~= "table" then return end
  local handling = nodeWeapon and DB and DB.getValue and DB.getValue(nodeWeapon, "handling", -1) or -1
  if handling == 1 then action.sArmsHands = "2h"
  elseif handling == 0 or handling == 2 then action.sArmsHands = "1h"
  else action.sArmsHands = weaponHands(action) end
  local profile = weaponProfile(action)
  if profile then action.sArmsCategory, action.sArmsGroup = profile.category, profile.group end
end
function mapWeapon(label, tableId, category, hands)
  label = normalizeAction(label)
  if label == "" then return nil, "Falta el nombre de la acción." end
  tableId = canonicalTable(tableId)
  if tableId ~= "off" and not ArmsEngine.getTable(tableId) then return nil, "No existe esa tabla." end
  if category ~= nil and category ~= "auto" and not validCategory(category) then return nil, "Categoría: simple, martial, custom, unknown o auto." end
  if hands ~= nil and hands ~= "auto" and not validHands(hands) then return nil, "Uso: 1h, 2h, unknown o auto." end
  if not isHost() then return nil, "Solo el director de juego." end
  local path = ROOT .. ".weapons." .. key(label)
  DB.setValue(path .. ".label", "string", label)
  DB.setValue(path .. ".table_id", "string", tableId)
  if category ~= nil then DB.setValue(path .. ".category", "string", category == "auto" and "" or category) end
  if hands ~= nil then DB.setValue(path .. ".hands", "string", hands == "auto" and "" or hands) end
  return true
end

-- RFC4180-style quoted cells, bounded, data-only CSV; never eval/loadstring.
function parseCSV(csv)
  if type(csv) ~= "string" or #csv > 262144 then return nil, "CSV no válido o mayor de 256 KiB." end
  csv = csv:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local rows, row, cell, quoted, afterQuote = {}, {}, {}, false, false
  local i = 1
  local function pushCell() table.insert(row, table.concat(cell)); cell={}; afterQuote=false end
  local function pushRow()
    pushCell()
    if not (#row == 1 and trim(row[1]) == "") then table.insert(rows,row) end
    row={}
  end
  while i <= #csv do
    local c = csv:sub(i,i)
    if quoted then
      if c == '"' then
        if csv:sub(i+1,i+1) == '"' then table.insert(cell,'"'); i=i+1 else quoted=false; afterQuote=true end
      else table.insert(cell,c) end
    elseif c == '"' then
      if #cell ~= 0 or afterQuote then return nil, "Comillas CSV mal situadas." end
      quoted=true
    elseif c == "," then pushCell()
    elseif c == "\n" then pushRow()
    elseif afterQuote then
      if c ~= " " and c ~= "\t" then return nil, "Texto después de cierre de comillas." end
    else table.insert(cell,c) end
    if #rows > 4000 then return nil, "CSV: máximo 4000 filas." end
    i=i+1
  end
  if quoted then return nil, "Comillas CSV sin cerrar." end
  if #cell > 0 or #row > 0 or afterQuote then pushRow() end
  if #rows > 4000 then return nil, "CSV: máximo 4000 filas." end
  if #rows == 0 then return nil, "CSV vacío." end
  return rows
end
function decodeTables(csv)
  local rows, err = parseCSV(csv); if not rows then return nil,err end
  local header = {"weapon","armor","min","max","hit","quality"}
  if #rows[1] ~= #header then return nil,"Cabecera: weapon,armor,min,max,hit,quality" end
  for i,v in ipairs(header) do if normalize(rows[1][i]) ~= v then return nil,"Cabecera: weapon,armor,min,max,hit,quality" end end
  local defs, sourceIds = {}, {}
  for i=2,#rows do
    local row=rows[i]
    if #row ~= 6 then return nil,"Fila "..i..": se esperan seis columnas." end
    local w,a = trim(row[1]),trim(row[2])
    if #w>96 or #a>64 or not w:match("^[a-z][a-z0-9_%-]*$") or not a:match("^[a-z][a-z0-9_%-]*$") then return nil,"Fila "..i..": identificador no válido." end
    local canonical = canonicalTable(w)
    if sourceIds[canonical] and sourceIds[canonical] ~= w then
      return nil, "Fila "..i..": "..w.." y "..sourceIds[canonical].." identifican la misma tabla; usa un solo nombre en cada CSV."
    end
    sourceIds[canonical] = w
    w = canonical
    local lo,hi,q=tonumber(row[3]),tonumber(row[4]),tonumber(row[6])
    local hitText=normalize(row[5]); local hit=hitText=="true" or hitText=="1"
    if not hit and hitText~="false" and hitText~="0" then return nil,"Fila "..i..": hit debe ser true/false." end
    if not finite(lo) or lo~=math.floor(lo) or (trim(row[4])~="" and (not finite(hi) or hi~=math.floor(hi))) or not finite(q) then return nil,"Fila "..i..": número no válido." end
    defs[w]=defs[w] or {version=1,label=w,provenance="User-provided adapted table; not verified ICE data",armors={}}
    defs[w].armors[a]=defs[w].armors[a] or {}
    table.insert(defs[w].armors[a],{min=lo,max=hi,hit=hit,quality=q})
  end
  if next(defs)==nil then return nil,"CSV sin filas de datos." end
  for w,def in pairs(defs) do
    local ok,e=ArmsEngine.validateTable(def); if not ok then return nil,w..": "..tostring(e) end
  end
  return defs
end
function importTables(csv)
  if not isHost() then return nil,"Solo el director de juego puede importar tablas." end
  local defs,err=decodeTables(csv); if not defs then return nil,err end
  -- Append an import batch. Validation is all-or-nothing before persistence/registration.
  local parent=DB.createNode(ROOT..".imports")
  local node=DB.createChild(parent)
  if not node then return nil,"No se pudo guardar la importación." end
  DB.setValue(node,"csv","string",csv)
  for id,def in pairs(defs) do ArmsEngine.registerTable(id,def) end
  return true
end
function reloadTables()
  if not DB then return end
  local nodes=DB.getChildList(ROOT..".imports") or {}
  table.sort(nodes,function(a,b) return DB.getPath(a)<DB.getPath(b) end)
  for _,node in ipairs(nodes) do
    local defs=decodeTables(DB.getValue(node,"csv",""))
    if defs then for id,def in pairs(defs) do ArmsEngine.registerTable(id,def) end end
  end
end
function invalidatePending()
  if ArmsBridge and ArmsBridge.clearPending then ArmsBridge.clearPending() end
end
function refreshImportedTables()
  reloadTables()
  invalidatePending()
end
function onInit()
  if DB and isHost() then
    local node=DB.createNode(ROOT)
    if DB.setPublic then DB.setPublic(node,true) end
    if DB.getValue(ROOT..".version","")=="" then DB.setValue(ROOT..".version","string",VERSION) end
  end
  reloadTables()
  if DB and DB.addHandler then
    DB.addHandler(ROOT..".imports.*.csv","onUpdate",refreshImportedTables)
    for _,path in ipairs({".mode",".actors.*.armor",".actors.*.base",".weapons.*.table_id",".weapons.*.category",".weapons.*.hands"}) do
      DB.addHandler(ROOT..path,"onUpdate",invalidatePending)
    end
  end
end
function onClose()
  if DB and DB.removeHandler then
    DB.removeHandler(ROOT..".imports.*.csv","onUpdate",refreshImportedTables)
    for _,path in ipairs({".mode",".actors.*.armor",".actors.*.base",".weapons.*.table_id",".weapons.*.category",".weapons.*.hands"}) do
      DB.removeHandler(ROOT..path,"onUpdate",invalidatePending)
    end
  end
end
return {getVersion=getVersion,key=key,normalize=normalize,normalizeAction=normalizeAction,parseCSV=parseCSV,decodeTables=decodeTables,
  getMode=getMode,setMode=setMode,actorId=actorId,actorNode=actorNode,findActor=findActor,listActors=listActors,
  setArmor=setArmor,armorFor=armorFor,actionLabel=actionLabel,weaponFor=weaponFor,mapWeapon=mapWeapon,
  weaponProfile=weaponProfile,weaponHands=weaponHands,captureWeaponMetadata=captureWeaponMetadata,
  importTables=importTables,reloadTables=reloadTables,onInit=onInit,isHost=isHost}
