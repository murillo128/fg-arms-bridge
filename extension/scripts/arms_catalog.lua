-- Arms Bridge weapon metadata. MIT License.
-- Groups are the user's campaign taxonomy, not official 2024 mastery groups.
-- Category/hand properties: D&D Beyond 2024 Basic Rules, Equipment.
-- https://www.dndbeyond.com/sources/dnd/br-2024/equipment
-- Shuriken and Blunderbuss are user-specified custom entries. Their category,
-- usage and damage are not invented here. All damage still comes from FG.
local VERSION = "0.3.1"
local groups = {
  {id="blunted", label="Blunted weapons"}, {id="bladed", label="Bladed weapons"},
  {id="axes", label="Axes"}, {id="polearms", label="Pole arms"},
  {id="bows", label="Bows"}, {id="crossbows", label="Crossbows"},
  {id="exotic", label="Exotic"}, {id="firearms", label="Firearms"},
}
local weapons, aliases = {}, {}
local function clone(t)
  if type(t) ~= "table" then return t end
  local out = {}; for k,v in pairs(t) do out[k]=clone(v) end; return out
end
local function normalized(s)
  s = tostring(s or ""):lower():gsub("á", "a"):gsub("é", "e"):gsub("í", "i"):gsub("ó", "o"):gsub("ú", "u")
  return (s:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end
local function add(name, group, category, hands, names)
  local id = normalized(name):gsub(" ", "_")
  local item = {id=id, name=name, group=group, category=category, hands=hands,
    origin=category == "custom" and "campaign" or "dnd2024"}
  weapons[#weapons+1] = item
  aliases[normalized(name)] = item
  aliases[id] = item
  for _,alias in ipairs(names or {}) do aliases[normalized(alias)] = item end
end

add("Club", "blunted", "simple", "1h", {"garrote", "clava"})
add("Greatclub", "blunted", "simple", "2h", {"gran garrote", "clava grande"})
add("Light Hammer", "blunted", "simple", "1h", {"martillo ligero"})
add("Mace", "blunted", "simple", "1h", {"maza"})
add("Flail", "blunted", "martial", "1h", {"mangual"})
add("Morningstar", "blunted", "martial", "1h", {"lucero del alba"})
add("Warhammer", "blunted", "martial", "versatile", {"martillo de guerra"})
add("War Pick", "blunted", "martial", "versatile", {"pico de guerra"})
add("Maul", "blunted", "martial", "2h", {"gran maza", "mazo"})

add("Dagger", "bladed", "simple", "1h", {"daga"})
add("Sickle", "bladed", "simple", "1h", {"hoz"})
add("Greatsword", "bladed", "martial", "2h", {"espadon", "mandoble"})
add("Longsword", "bladed", "martial", "versatile", {"espada larga"})
add("Shortsword", "bladed", "martial", "1h", {"espada corta"})
add("Scimitar", "bladed", "martial", "1h", {"cimitarra"})
add("Rapier", "bladed", "martial", "1h", {"estoque", "ropera"})

add("Handaxe", "axes", "simple", "1h", {"hacha de mano"})
add("Battleaxe", "axes", "martial", "versatile", {"hacha", "hacha de batalla"})
add("Greataxe", "axes", "martial", "2h", {"hacha a dos manos", "gran hacha"})

add("Spear", "polearms", "simple", "versatile", {"lanza"})
add("Quarterstaff", "polearms", "simple", "versatile", {"baston", "baston de combate"})
add("Glaive", "polearms", "martial", "2h", {"guja"})
add("Halberd", "polearms", "martial", "2h", {"alabarda"})
add("Lance", "polearms", "martial", "mounted", {"lanza de caballeria"})
add("Pike", "polearms", "martial", "2h", {"pica"})
add("Trident", "polearms", "martial", "versatile", {"tridente"})

add("Shortbow", "bows", "simple", "2h", {"arco corto"})
add("Longbow", "bows", "martial", "2h", {"arco largo"})

add("Hand Crossbow", "crossbows", "martial", "1h", {"ballesta de mano"})
add("Light Crossbow", "crossbows", "simple", "2h", {"ballesta ligera"})
add("Heavy Crossbow", "crossbows", "martial", "2h", {"ballesta pesada"})

add("Javelin", "exotic", "simple", "1h", {"jabalina"})
add("Sling", "exotic", "simple", "1h", {"honda"})
add("Dart", "exotic", "simple", "1h", {"dardo"})
add("Blowgun", "exotic", "martial", "1h", {"cerbatana"})
add("Whip", "exotic", "martial", "1h", {"latigo"})
add("Shuriken", "exotic", "custom", "unknown", {"estrella arrojadiza"})

add("Pistol", "firearms", "martial", "1h", {"pistola"})
add("Blunderbuss", "firearms", "custom", "unknown", {"trabuco"})
add("Musket", "firearms", "martial", "2h", {"mosquete"})

function getVersion() return VERSION end
function getGroups() return clone(groups) end
function lookup(label) return clone(aliases[normalized(label)]) end
function listWeapons(group)
  local result = {}
  for _,item in ipairs(weapons) do if group == nil or item.group == group then result[#result+1]=clone(item) end end
  return result
end
function isGroup(id)
  for _,group in ipairs(groups) do if group.id == id then return true end end
  return false
end
return {getVersion=getVersion,getGroups=getGroups,lookup=lookup,listWeapons=listWeapons,isGroup=isGroup}
