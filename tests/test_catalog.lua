-- Contract checks for the user's weapon taxonomy and independent metadata.
local Catalog = dofile("extension/scripts/arms_catalog.lua")
local checks=0
local function check(value,message) checks=checks+1; assert(value,message) end
local function equal(actual,expected,message)
  check(actual==expected,(message or "unexpected value")..": got "..tostring(actual)..", expected "..tostring(expected))
end
equal(Catalog.getVersion(),"0.3.1")
equal(#Catalog.getGroups(),8)
equal(#Catalog.listWeapons(),40,"The supplied eight groups contain exactly forty distinct weapons")
local countByGroup={blunted=9,bladed=7,axes=3,polearms=7,bows=2,crossbows=3,exotic=6,firearms=3}
for group,count in pairs(countByGroup) do
  equal(#Catalog.listWeapons(group),count,"Group membership must match the requested taxonomy: "..group)
end
equal(Catalog.lookup("Dagger").group,"bladed")
equal(Catalog.lookup("Quarterstaff").group,"polearms")
equal(Catalog.lookup("Javelin").group,"exotic")
equal(Catalog.lookup("Halberd").group,"polearms")
equal(Catalog.lookup("Light Crossbow").category,"simple")
equal(Catalog.lookup("Hand Crossbow").category,"martial")
equal(Catalog.lookup("Pistol").category,"martial")
equal(Catalog.lookup("Musket").category,"martial")
equal(Catalog.lookup("War Pick").hands,"versatile","Use the 2024 property rather than the older edition's entry")
equal(Catalog.lookup("Lance").hands,"mounted","A lance has a mounted exception, so its name does not imply actual use")
equal(Catalog.lookup("Trident").hands,"versatile")
equal(Catalog.lookup("Espadón").id,"greatsword")
equal(Catalog.lookup("ballesta de mano").id,"hand_crossbow")
equal(Catalog.lookup("trabuco").id,"blunderbuss")
equal(Catalog.lookup("war_pick").id,"war_pick")
equal(Catalog.lookup("Unknown weapon"),nil)
for _,name in ipairs({"Shuriken","Blunderbuss"}) do
  local item=Catalog.lookup(name)
  equal(item.category,"custom")
  equal(item.hands,"unknown")
  equal(item.origin,"campaign")
end
local seen={}
for _,item in ipairs(Catalog.listWeapons()) do
  check(not seen[item.id],"Duplicate catalog ID: "..item.id); seen[item.id]=true
  check(Catalog.isGroup(item.group),"Every catalog weapon belongs to one requested family")
  equal(item.mastery,nil,"The group taxonomy must not assign new mastery effects")
  equal(item.dmgtype,nil,"The blunted group does not convert piercing weapons to bludgeoning")
  equal(item.dice,nil,"Damage dice remain in Fantasy Grounds, not this classification catalog")
end
local changed=Catalog.lookup("Longsword"); changed.group="changed"
equal(Catalog.lookup("Longsword").group,"bladed","Lookup returns a copy")
local changedList=Catalog.listWeapons(); changedList[1].group="changed"
equal(Catalog.listWeapons()[1].group,"blunted","Listings return copies")
local changedGroups=Catalog.getGroups(); changedGroups[1].id="changed"
equal(Catalog.getGroups()[1].id,"blunted")
print("Catalog checks: "..checks)
